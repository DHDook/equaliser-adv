import Foundation
import Atomics

/// Active crossover engine that splits the fully processed mains L/R signal
/// into up to 3 band signals per channel using a cascaded topology.
///
/// Cascaded topology:
/// Full range → [Lower crossover LP] → Low band
///           → [Lower crossover HP] → Mid+High combined
///                                  → [Upper crossover LP] → Mid band (tri-amp only)
///                                  → [Upper crossover HP] → High band
///
/// Each crossover point carries independent LP and HP coefficients,
/// supporting asymmetric frequencies, slopes, and types per side.
struct ActiveCrossoverEngine {
    static let maxSections = 8

    // MARK: - Band Output Buffers
    // Pre-allocated, sized to AudioConstants.maxFrameCount
    nonisolated(unsafe) var leftLow:   [Float]
    nonisolated(unsafe) var leftMid:   [Float]
    nonisolated(unsafe) var leftHigh:  [Float]
    nonisolated(unsafe) var rightLow:  [Float]
    nonisolated(unsafe) var rightMid:  [Float]
    nonisolated(unsafe) var rightHigh: [Float]

    /// Scratch working buffers for crossover processing. Pre-allocated as raw pointers
    /// to avoid audio-thread heap allocation and Swift exclusivity violations.
    /// Written and discarded within each `process()` call.
    private let leftWorkBuf:  UnsafeMutablePointer<Float>
    private let rightWorkBuf: UnsafeMutablePointer<Float>

    // MARK: - Flat IIR Filter State
    // 8 blocks × 8 max sections × 2 state vars = 128 Floats
    // Each block: lower LP left, lower LP right, lower HP left, lower HP right,
    //             upper LP left, upper LP right, upper HP left, upper HP right
    nonisolated(unsafe) var filterState: [Float]

    // MARK: - Active IIR Coefficient Arrays
    // One per filter block, LP and HP independent
    nonisolated(unsafe) var activeLowerLP: SectionArray
    nonisolated(unsafe) var activeLowerHP: SectionArray
    nonisolated(unsafe) var activeUpperLP: SectionArray
    nonisolated(unsafe) var activeUpperHP: SectionArray
    nonisolated(unsafe) var activeBandCount: Int = 1

    // MARK: - Pending IIR Coefficients
    // Staged on main thread
    nonisolated(unsafe) var pendingLowerLP: SectionArray
    nonisolated(unsafe) var pendingLowerHP: SectionArray
    nonisolated(unsafe) var pendingUpperLP: SectionArray
    nonisolated(unsafe) var pendingUpperHP: SectionArray
    nonisolated(unsafe) var pendingBandCount: Int = 1
    let hasIIRPendingUpdate = ManagedAtomic<Bool>(false)

    // MARK: - FIR Crossover (Linear Phase Mode)
    // One ConvolutionEngine per filter block that uses FIR type.
    // Nil when the corresponding filter block uses IIR.
    nonisolated(unsafe) var lowerLPConvolution: ConvolutionEngine?
    nonisolated(unsafe) var lowerHPConvolution: ConvolutionEngine?
    nonisolated(unsafe) var upperLPConvolution: ConvolutionEngine?
    nonisolated(unsafe) var upperHPConvolution: ConvolutionEngine?
    let hasFIRPendingUpdate = ManagedAtomic<Bool>(false)

    typealias SectionArray = [(b0: Float, b1: Float, b2: Float, na1: Float, na2: Float)]

    // MARK: - Constants
    private static let stateSize = 8 * maxSections * 2  // 8 blocks × 8 sections × 2 state vars

    // MARK: - Initialization
    init(maxFrameCount: Int) {
        // Allocate band output buffers
        leftLow   = Array(repeating: 0.0, count: maxFrameCount)
        leftMid   = Array(repeating: 0.0, count: maxFrameCount)
        leftHigh  = Array(repeating: 0.0, count: maxFrameCount)
        rightLow  = Array(repeating: 0.0, count: maxFrameCount)
        rightMid  = Array(repeating: 0.0, count: maxFrameCount)
        rightHigh = Array(repeating: 0.0, count: maxFrameCount)

        // Allocate scratch work buffers as raw pointers to avoid exclusivity violations
        // when passing them to mutating filter-section helpers alongside self.filterState.
        leftWorkBuf  = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        rightWorkBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        leftWorkBuf.initialize(repeating: 0.0, count: maxFrameCount)
        rightWorkBuf.initialize(repeating: 0.0, count: maxFrameCount)

        // Allocate filter state
        filterState = Array(repeating: 0.0, count: Self.stateSize)

        // Initialize coefficient arrays with identity (pass-through)
        let identitySection: (b0: Float, b1: Float, b2: Float, na1: Float, na2: Float) = (1.0, 0.0, 0.0, 0.0, 0.0)
        activeLowerLP = Array(repeating: identitySection, count: Self.maxSections)
        activeLowerHP = Array(repeating: identitySection, count: Self.maxSections)
        activeUpperLP = Array(repeating: identitySection, count: Self.maxSections)
        activeUpperHP = Array(repeating: identitySection, count: Self.maxSections)

        pendingLowerLP = activeLowerLP
        pendingLowerHP = activeLowerHP
        pendingUpperLP = activeUpperLP
        pendingUpperHP = activeUpperHP

        // FIR engines are initially nil (IIR mode by default)
        lowerLPConvolution = nil
        lowerHPConvolution = nil
        upperLPConvolution = nil
        upperHPConvolution = nil
    }

    // MARK: - Processing
    mutating func process(leftIn: UnsafePointer<Float>, rightIn: UnsafePointer<Float>, frameCount: Int) {
        guard activeBandCount > 1 else { return }

        // Apply pending IIR update
        if hasIIRPendingUpdate.exchange(false, ordering: .acquiringAndReleasing) {
            activeLowerLP = pendingLowerLP
            activeLowerHP = pendingLowerHP
            activeUpperLP = pendingUpperLP
            activeUpperHP = pendingUpperHP
            activeBandCount = pendingBandCount
        }

        // Load input into pre-allocated work buffers (no heap allocation).
        for i in 0..<frameCount {
            leftWorkBuf[i]  = leftIn[i]
            rightWorkBuf[i] = rightIn[i]
        }

        // Apply lower LP → leftLow, rightLow
        applyFilterSections(leftWorkBuf, sections: activeLowerLP, stateOffset: 0, frameCount: frameCount)
        for i in 0..<frameCount { leftLow[i] = leftWorkBuf[i] }

        // Reset left work buffer from input for HP pass
        for i in 0..<frameCount { leftWorkBuf[i] = leftIn[i] }

        applyFilterSections(rightWorkBuf, sections: activeLowerLP, stateOffset: 4, frameCount: frameCount)
        for i in 0..<frameCount { rightLow[i] = rightWorkBuf[i] }

        // Reset right work buffer from input for HP pass
        for i in 0..<frameCount { rightWorkBuf[i] = rightIn[i] }

        // Apply lower HP → leftHigh, rightHigh (mid+high combined)
        applyFilterSections(leftWorkBuf, sections: activeLowerHP, stateOffset: 2, frameCount: frameCount)
        for i in 0..<frameCount { leftHigh[i] = leftWorkBuf[i] }

        for i in 0..<frameCount { leftWorkBuf[i] = leftIn[i] }

        applyFilterSections(rightWorkBuf, sections: activeLowerHP, stateOffset: 6, frameCount: frameCount)
        for i in 0..<frameCount { rightHigh[i] = rightWorkBuf[i] }

        for i in 0..<frameCount { rightWorkBuf[i] = rightIn[i] }

        // For tri-amp: extract mid and final high from upper crossover
        if activeBandCount == 3 {
            applyFilterSections(leftWorkBuf, sections: activeUpperLP, stateOffset: 8, frameCount: frameCount)
            for i in 0..<frameCount { leftMid[i] = leftWorkBuf[i] }

            for i in 0..<frameCount { leftWorkBuf[i] = leftIn[i] }

            applyFilterSections(rightWorkBuf, sections: activeUpperLP, stateOffset: 12, frameCount: frameCount)
            for i in 0..<frameCount { rightMid[i] = rightWorkBuf[i] }

            for i in 0..<frameCount { rightWorkBuf[i] = rightIn[i] }

            applyFilterSections(leftWorkBuf, sections: activeUpperHP, stateOffset: 10, frameCount: frameCount)
            for i in 0..<frameCount { leftHigh[i] = leftWorkBuf[i] }

            for i in 0..<frameCount { leftWorkBuf[i] = leftIn[i] }

            applyFilterSections(rightWorkBuf, sections: activeUpperHP, stateOffset: 14, frameCount: frameCount)
            for i in 0..<frameCount { rightHigh[i] = rightWorkBuf[i] }
        }
    }

    // MARK: - Filter Section Application

    @inline(__always)
    private mutating func applyFilterSections(
        _ buf: UnsafeMutablePointer<Float>,
        sections: SectionArray,
        stateOffset: Int,
        frameCount: Int
    ) {
        for (sectionIndex, coeffs) in sections.enumerated() {
            var w1 = filterState[stateOffset + sectionIndex * 2]
            var w2 = filterState[stateOffset + sectionIndex * 2 + 1]
            for i in 0..<frameCount {
                let y = coeffs.b0 * buf[i] + w1
                w1 = coeffs.b1 * buf[i] + coeffs.na1 * y + w2
                w2 = coeffs.b2 * buf[i] + coeffs.na2 * y
                buf[i] = y
            }
            filterState[stateOffset + sectionIndex * 2] = w1
            filterState[stateOffset + sectionIndex * 2 + 1] = w2
        }
    }

    // MARK: - Pending Update Application
    mutating func applyPendingUpdate() {
        if hasIIRPendingUpdate.exchange(false, ordering: .acquiringAndReleasing) {
            activeLowerLP = pendingLowerLP
            activeLowerHP = pendingLowerHP
            activeUpperLP = pendingUpperLP
            activeUpperHP = pendingUpperHP
            activeBandCount = pendingBandCount
        }
        // FIR updates are handled by ConvolutionEngine.updateIR's own atomic IR swap
    }

    // MARK: - Group Delay Computation

    /// Computes the group delay of one crossover filter block at the given frequencies.
    ///
    /// For IIR sections: sums the group delay of each non-identity biquad section
    /// using numerical phase differentiation (finite differences at ±0.5 Hz).
    /// For FIR: constant group delay = (tapCount − 1) / 2 samples.
    /// Both contributions are summed when both are non-nil.
    ///
    /// - Parameters:
    ///   - sections: IIR biquad sections (b0, b1, b2, na1, na2). Identity sections
    ///     (b0=1, others=0) are skipped — they contribute zero group delay.
    ///   - firKernel: Optional FIR impulse response. If non-nil, adds constant
    ///     linear-phase delay of (tapCount−1)/2 samples.
    ///   - frequencies: Frequencies in Hz at which to compute group delay.
    ///   - sampleRate: Sample rate in Hz.
    /// - Returns: Group delay in milliseconds at each frequency.
    static func groupDelay(
        sections: SectionArray,
        firKernel: [Float]?,
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        var result = [Double](repeating: 0.0, count: frequencies.count)

        // IIR contribution: sum phase differentiation across non-identity sections
        let deltaF = 1.0  // 1 Hz finite-difference step
        let identityEps: Float = 1e-6

        for section in sections {
            // Skip identity sections — they contribute zero group delay
            guard !(abs(section.b0 - 1.0) < identityEps &&
                    abs(section.b1) < identityEps &&
                    abs(section.b2) < identityEps &&
                    abs(section.na1) < identityEps &&
                    abs(section.na2) < identityEps) else { continue }

            let b0 = Double(section.b0)
            let b1 = Double(section.b1)
            let b2 = Double(section.b2)
            let a1 = Double(section.na1)  // na1 == a1 in standard notation
            let a2 = Double(section.na2)  // na2 == a2 in standard notation

            for (i, f) in frequencies.enumerated() {
                let omega1 = 2.0 * Double.pi * (f - deltaF * 0.5) / sampleRate
                let omega2 = 2.0 * Double.pi * (f + deltaF * 0.5) / sampleRate

                let phase1 = biquadPhase(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, omega: omega1)
                let phase2 = biquadPhase(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, omega: omega2)

                // Unwrap phase difference to (−π, π]
                var deltaPhase = phase2 - phase1
                while deltaPhase >  Double.pi { deltaPhase -= 2.0 * Double.pi }
                while deltaPhase < -Double.pi { deltaPhase += 2.0 * Double.pi }

                // Group delay in samples = −dφ/dω; convert to ms
                let delaySamples = -deltaPhase / (2.0 * Double.pi * deltaF / sampleRate)
                result[i] += delaySamples / sampleRate * 1000.0
            }
        }

        // FIR contribution: constant linear-phase delay
        if let kernel = firKernel, !kernel.isEmpty {
            let firDelaySamples = Double(kernel.count - 1) / 2.0
            let firDelayMs = firDelaySamples / sampleRate * 1000.0
            for i in result.indices { result[i] += firDelayMs }
        }

        return result
    }

    // MARK: - Phase Computation (private helper)

    /// Evaluates the phase response of a normalised biquad at the given angular frequency.
    ///
    /// H(e^{jω}) = (b0 + b1·e^{−jω} + b2·e^{−2jω}) / (1 + a1·e^{−jω} + a2·e^{−2jω})
    /// Returns atan2(Im(H), Re(H)).
    private static func biquadPhase(
        b0: Double, b1: Double, b2: Double,
        a1: Double, a2: Double,
        omega: Double
    ) -> Double {
        let cosW  = cos(omega)
        let sinW  = sin(omega)
        let cos2W = cos(2.0 * omega)
        let sin2W = sin(2.0 * omega)

        let numReal = b0 + b1 * cosW  + b2 * cos2W
        let numImag =      b1 * sinW  + b2 * sin2W   // negative convention: e^{−jω} = cos−j·sin
        let denReal = 1.0 + a1 * cosW + a2 * cos2W
        let denImag =       a1 * sinW + a2 * sin2W

        // Complex division: (num / den)
        let denMagSq = denReal * denReal + denImag * denImag
        guard denMagSq > 1e-30 else { return 0.0 }

        let real = (numReal * denReal + numImag * denImag) / denMagSq
        let imag = (numImag * denReal - numReal * denImag) / denMagSq

        return atan2(imag, real)
    }
}
