import Accelerate

/// Single biquad filter section using vDSP.
///
/// Owns a `vDSP_biquad_Setup` and pre-allocated delay elements.
/// NOT Sendable — must be owned exclusively by one thread (the audio thread via EQChain).
///
/// This class processes audio through a single second-order IIR filter section.
/// The transfer function is:
///
///   H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)
///
/// Where coefficients are normalised (a0 has been divided out).
///
/// vDSP setups are pre-created on the main thread via `prepareSetup()` and
/// installed on the audio thread via `setCoefficients(_:setup:resetState:)`.
/// This avoids allocation on the audio thread — a real-time safety requirement.
final class BiquadFilter {
    // MARK: - Properties

    /// The vDSP setup object for biquad processing.
    /// Pre-created on the main thread, installed on the audio thread.
    private var setup: vDSP_biquad_Setup?

    /// Delay elements for the filter state (2 * (sections + 1) = 4 for single section).
    /// Pre-allocated to avoid runtime allocation.
    private var delay: [Float]

    /// Whether the setup is valid (a vDSP setup has been installed).
    private var isValid: Bool = false

    // MARK: - Initialization

    init() {
        // Pre-allocate delay elements: 2 * (sections + 1) = 4 for a single biquad section
        // vDSP requires this exact size
        delay = [Float](repeating: 0, count: 4)

        // Start with identity (passthrough) — no vDSP setup needed for passthrough
        isValid = false
    }

    deinit {
        if let s = setup {
            vDSP_biquad_DestroySetup(s)
        }
    }

    // MARK: - Setup Creation (Main Thread)

    /// Creates a vDSP biquad setup for the given coefficients.
    /// Call this from the main thread to avoid allocation on the audio thread.
    /// - Parameter coefficients: The biquad coefficients to create a setup for.
    /// - Returns: A vDSP setup object, or nil if the coefficients are invalid.
    static func prepareSetup(_ coefficients: BiquadCoefficients) -> vDSP_biquad_Setup? {
        var coeffsD: [Double] = [
            coefficients.b0,
            coefficients.b1,
            coefficients.b2,
            coefficients.a1,
            coefficients.a2
        ]
        return vDSP_biquad_CreateSetup(&coeffsD, 1)
    }

    // MARK: - Coefficient Update (Audio Thread)

    /// Updates the filter with new coefficients and a pre-built vDSP setup.
    /// The setup must be created via `prepareSetup()` on the main thread before calling this.
    /// This method performs no allocation — it only swaps the setup pointer and optionally
    /// resets filter delay state.
    /// - Parameters:
    ///   - newCoefficients: The new biquad coefficients.
    ///   - setup: A pre-built vDSP setup for these coefficients, or nil for passthrough.
    ///   - resetState: Whether to zero the delay elements (filter state).
    ///     Pass `true` for preset loads and initialisation — produces a clean start at the cost
    ///     of a brief transient if audio is playing.
    ///     Pass `false` for incremental changes (slider drags) — preserves continuity and
    ///     avoids the audible click caused by resetting filter state mid-stream.
    func setCoefficients(_ newCoefficients: BiquadCoefficients, setup: vDSP_biquad_Setup?, resetState: Bool) {
        // Destroy old setup if exists (free() — safe on audio thread)
        if let s = self.setup {
            vDSP_biquad_DestroySetup(s)
        }

        // Install pre-built setup
        self.setup = setup

        // Only reset delay elements when explicitly requested.
        // For incremental coefficient changes (slider drags), preserving delay state
        // avoids a discontinuity that produces an audible click.
        if resetState {
            for i in 0..<4 { delay[i] = 0 }
        }

        isValid = setup != nil
    }

    // MARK: - Audio Processing

    /// Processes audio through this biquad filter.
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
        guard isValid, let s = setup else {
            // If not set up, copy input to output (passthrough)
            if input != output {
                memcpy(output, input, Int(frameCount) * MemoryLayout<Float>.size)
            }
            return
        }

        // Process through vDSP biquad
        // Use withUnsafeMutableBufferPointer to avoid Swift's dynamic exclusivity checking
        delay.withUnsafeMutableBufferPointer { delayPtr in
            vDSP_biquad(s, delayPtr.baseAddress!, input, 1, output, 1, vDSP_Length(frameCount))
        }
    }
}
