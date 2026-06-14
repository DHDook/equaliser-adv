import Accelerate

/// Single biquad filter section — or a cascade of N sections — using vDSP.
///
/// Owns a `vDSP_biquad_Setup` and pre-allocated delay elements.
/// NOT Sendable — must be owned exclusively by one thread (the audio thread via EQChain).
///
/// Supports variable section counts to implement higher-order filters:
///   - 1 section  → 2nd-order  (12 dB/oct LP/HP, standard parametric, etc.)
///   - 2 sections → 4th-order  (24 dB/oct LP/HP)
///   - 4 sections → 8th-order  (48 dB/oct LP/HP)
///   - 1 degenerate section (b2=a2=0) → 1st-order (6 dB/oct LP/HP/shelf)
///
/// The transfer function for each section is:
///
///   H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)
///
/// Where coefficients are normalised (a0 has been divided out).
final class BiquadFilter {
    // MARK: - Properties

    /// The vDSP setup object for biquad processing.
    /// Created on init, recreated on coefficient change.
    private var setup: vDSP_biquad_Setup?

    /// Delay elements for the filter state.
    /// Size = 2 * (sections + 1) as required by vDSP.
    private var delay: [Float]

    /// Double-precision setup — used when `useDoublePrecision` is true.
    private var setupD: vDSP_biquad_SetupD?

    /// Double-precision delay elements (length = 2 * (sections + 1)).
    private var delayD: [Double]

    /// Number of sections currently configured.
    private var sectionCount: Int = 1

    /// Whether the setup is valid (coefficients have been set).
    private var isValid: Bool = false

    /// Whether to use double-precision processing.
    /// Set to true by EQChain when any active band has Q > 4.0 or frequency < 300 Hz.
    var useDoublePrecision: Bool = false

    /// Pending vDSP setup created on the main thread, swapped in on the audio thread.
    private var pendingSetup:  vDSP_biquad_Setup?
    private var pendingSetupD: vDSP_biquad_SetupD?
    private let hasPendingSetup = ManagedAtomic<Bool>(false)

    /// Pending delay-reset flag.
    private var pendingResetState: Bool = false

    /// Scratch buffer for double-precision processing (Float ↔ Double conversion).
    /// Sized to accommodate maximum callback frames.
    private var scratchD: [Double]

    // MARK: - Initialization

    init(maxFrameCount: Int = 4096) {
        // Pre-allocate for maximum supported sections (8) to avoid runtime reallocation.
        // vDSP requires delay = 2 * (sections + 1) → 2*(8+1) = 18 for 8 sections (96 dB/oct).
        let maxSections = 8
        delay = [Float](repeating: 0, count: 2 * (maxSections + 1))
        delayD = [Double](repeating: 0, count: 2 * (maxSections + 1))

        // Scratch buffer for double-precision processing (Float ↔ Double conversion).
        // Sized to accommodate maximum callback frames.
        scratchD = [Double](repeating: 0, count: maxFrameCount)

        // Start with identity (passthrough), resetting delay state on init
        stageCoefficients([BiquadCoefficients.identity], resetState: true)
        applyPendingSetup()
    }

    deinit {
        if let s = setup {
            vDSP_biquad_DestroySetup(s)
        }
        if let s = setupD {
            vDSP_biquad_DestroySetupD(s)
        }
        if let ps = pendingSetup {
            vDSP_biquad_DestroySetup(ps)
        }
        if let pd = pendingSetupD {
            vDSP_biquad_DestroySetupD(pd)
        }
    }

    // MARK: - Coefficient Update

    /// Called from the main thread. Builds new vDSP setups and stages them
    /// for the audio thread to swap in via applyPendingSetup().
    func stageCoefficients(_ sections: [BiquadCoefficients], resetState: Bool) {
        let count = max(1, sections.count)
        sectionCount = count

        var coeffsD = [Double](repeating: 0, count: 5 * count)
        for (i, section) in sections.enumerated() {
            coeffsD[5 * i + 0] = section.b0
            coeffsD[5 * i + 1] = section.b1
            coeffsD[5 * i + 2] = section.b2
            coeffsD[5 * i + 3] = section.a1
            coeffsD[5 * i + 4] = section.a2
        }

        // Destroy previously staged (but not yet consumed) setups.
        if let ps = pendingSetup  { vDSP_biquad_DestroySetup(ps) }
        if let pd = pendingSetupD { vDSP_biquad_DestroySetupD(pd) }

        pendingSetup  = vDSP_biquad_CreateSetup(&coeffsD, vDSP_Length(count))
        pendingSetupD = vDSP_biquad_CreateSetupD(&coeffsD, vDSP_Length(count))
        pendingResetState = resetState
        hasPendingSetup.store(true, ordering: .releasing)
    }

    /// Called at the start of each render cycle on the audio thread.
    /// Swaps in any staged setup without allocating memory.
    @inline(__always)
    func applyPendingSetup() {
        guard hasPendingSetup.load(ordering: .acquiring) else { return }

        if let old = setup  { vDSP_biquad_DestroySetup(old) }
        if let old = setupD { vDSP_biquad_DestroySetupD(old) }

        setup  = pendingSetup;  pendingSetup  = nil
        setupD = pendingSetupD; pendingSetupD = nil

        if pendingResetState {
            let delaySize = 2 * (sectionCount + 1)
            for i in 0..<delaySize { delay[i] = 0 }
            for i in 0..<delaySize { delayD[i] = 0 }
        }

        hasPendingSetup.store(false, ordering: .relaxed)
        isValid = true
    }

    /// Updates the filter with new coefficients for one or more sections.
    ///
    /// Must be called from the audio thread or during setup (not from main thread during audio).
    /// - Parameters:
    ///   - sections: Array of biquad coefficients, one entry per filter section.
    ///     Pass a single `.identity` to create a passthrough filter.
    ///   - resetState: Whether to zero the delay elements (filter state).
    ///     Pass `true` for preset loads and initialisation — produces a clean start at the cost
    ///     of a brief transient if audio is playing.
    ///     Pass `false` for incremental changes (slider drags) — preserves continuity and
    ///     avoids the audible click caused by resetting filter state mid-stream.
    func setCoefficients(_ sections: [BiquadCoefficients], resetState: Bool) {
        let count = max(1, sections.count)
        sectionCount = count

        // Build the flat coefficient array for vDSP: [b0, b1, b2, a1, a2] × sections
        var coeffsD = [Double](repeating: 0, count: 5 * count)
        for (i, section) in sections.enumerated() {
            coeffsD[5 * i + 0] = section.b0
            coeffsD[5 * i + 1] = section.b1
            coeffsD[5 * i + 2] = section.b2
            coeffsD[5 * i + 3] = section.a1
            coeffsD[5 * i + 4] = section.a2
        }

        // Destroy old setup if exists
        if let s = setup {
            vDSP_biquad_DestroySetup(s)
        }
        if let s = setupD {
            vDSP_biquad_DestroySetupD(s)
        }

        setup = vDSP_biquad_CreateSetup(&coeffsD, vDSP_Length(count))
        setupD = vDSP_biquad_CreateSetupD(&coeffsD, vDSP_Length(count))

        // Only reset delay elements when explicitly requested.
        // For incremental coefficient changes (slider drags), preserving delay state
        // avoids a discontinuity that produces an audible click.
        if resetState {
            let delaySize = 2 * (count + 1)
            for i in 0..<delaySize { delay[i] = 0 }
            for i in 0..<delaySize { delayD[i] = 0 }
        }

        isValid = true
    }

    /// Convenience overload for single-section filters.
    /// Equivalent to `setCoefficients([section], resetState: resetState)`.
    func setCoefficients(_ section: BiquadCoefficients, resetState: Bool) {
        setCoefficients([section], resetState: resetState)
    }

    // MARK: - Audio Processing

    /// Processes audio through this biquad filter (or cascade of sections).
    /// Input and output may alias (in-place processing supported).
    /// - Parameters:
    ///   - input: Pointer to input samples.
    ///   - output: Pointer to output samples (may be same as input).
    ///   - frameCount: Number of frames to process.
    @inline(__always)
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: UInt32
    ) {
        guard isValid else {
            if input != output {
                memcpy(output, input, Int(frameCount) * MemoryLayout<Float>.size)
            }
            return
        }

        if useDoublePrecision, let sd = setupD {
            // Convert input to Double, process with vDSP_biquadD, convert back to Float.
            let n = Int(frameCount)
            guard n <= scratchD.count else {
                // Fallback to single precision if scratch buffer is too small
                if let s = setup {
                    delay.withUnsafeMutableBufferPointer { delayPtr in
                        vDSP_biquad(s, delayPtr.baseAddress!, input, 1, output, 1, vDSP_Length(frameCount))
                    }
                }
                return
            }
            scratchD.withUnsafeMutableBufferPointer { scratchPtr in
                // Float → Double input conversion
                vDSP_vspdp(input, 1, scratchPtr.baseAddress!, 1, vDSP_Length(n))
                // Double-precision biquad processing (in-place)
                delayD.withUnsafeMutableBufferPointer { delayPtr in
                    vDSP_biquadD(sd, delayPtr.baseAddress!, scratchPtr.baseAddress!, 1,
                                 scratchPtr.baseAddress!, 1, vDSP_Length(n))
                }
                // Double → Float output conversion
                vDSP_vdpsp(scratchPtr.baseAddress!, 1, output, 1, vDSP_Length(n))
            }
        } else if let s = setup {
            delay.withUnsafeMutableBufferPointer { delayPtr in
                vDSP_biquad(s, delayPtr.baseAddress!, input, 1, output, 1, vDSP_Length(frameCount))
            }
        } else {
            if input != output {
                memcpy(output, input, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }
    }
}
