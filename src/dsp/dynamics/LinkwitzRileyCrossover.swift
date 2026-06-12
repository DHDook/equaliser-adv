// LinkwitzRileyCrossover.swift
// Linkwitz-Riley crossover processor for bass management.

import Foundation

/// Linkwitz-Riley crossover processor for bass management.
///
/// Builds cascaded Butterworth biquad sections to create true Linkwitz-Riley
/// crossovers (LR2, LR4, LR8). Each section uses Q = 1/√2 ≈ 0.70710678.
struct LinkwitzRileyCrossover {
    /// Low-pass filter coefficients for each cascaded section (Float for audio processing).
    var lowPassSections: [(b0: Float, b1: Float, b2: Float, na1: Float, na2: Float)] = []
    /// High-pass filter coefficients for each cascaded section (Float for audio processing).
    var highPassSections: [(b0: Float, b1: Float, b2: Float, na1: Float, na2: Float)] = []
    /// Number of cascaded sections per channel.
    let sectionCount: Int
    /// State array size per channel: sectionCount * 2 (w1, w2 per section) * 2 (LP + HP paths).
    let stateSizePerChannel: Int

    /// Initialize the crossover with given parameters.
    /// - Parameters:
    ///   - crossoverHz: Crossover frequency in Hz
    ///   - slope: Crossover slope (LR2, LR4, or LR8)
    ///   - sampleRate: Sample rate in Hz
    init(crossoverHz: Float, slope: BassCrossoverSlope, sampleRate: Double) {
        let q = 0.7071067811865476  // 1/√2 for Butterworth sections
        sectionCount = slope.cascadedStageCount
        stateSizePerChannel = sectionCount * 2 * 2  // sections * 2 state vars * 2 paths (LP + HP)

        // Build cascaded sections
        lowPassSections = []
        highPassSections = []
        for _ in 0..<sectionCount {
            let lpCoeffs = BiquadMath.calculateCoefficients(
                type: .lowPass,
                sampleRate: sampleRate,
                frequency: Double(crossoverHz),
                q: q,
                gain: 0.0
            )
            let hpCoeffs = BiquadMath.calculateCoefficients(
                type: .highPass,
                sampleRate: sampleRate,
                frequency: Double(crossoverHz),
                q: q,
                gain: 0.0
            )
            // Convert Double coefficients to Float for audio processing
            lowPassSections.append((
                b0: Float(lpCoeffs.b0),
                b1: Float(lpCoeffs.b1),
                b2: Float(lpCoeffs.b2),
                na1: Float(lpCoeffs.a1),  // a1 is already negated in BiquadCoefficients
                na2: Float(lpCoeffs.a2)   // a2 is already negated in BiquadCoefficients
            ))
            highPassSections.append((
                b0: Float(hpCoeffs.b0),
                b1: Float(hpCoeffs.b1),
                b2: Float(hpCoeffs.b2),
                na1: Float(hpCoeffs.a1),
                na2: Float(hpCoeffs.a2)
            ))
        }
    }

    /// Direct Form II Transposed biquad processing.
    /// na1 and na2 are pre-negated (as returned by BiquadMath).
    @inline(__always)
    private static func processBiquad(
        _ x: Float,
        b0: Float, b1: Float, b2: Float, na1: Float, na2: Float,
        w1: inout Float, w2: inout Float
    ) -> Float {
        let y = b0 * x + w1
        w1 = b1 * x + na1 * y + w2
        w2 = b2 * x + na2 * y
        return y
    }

    /// Process low-pass filter through all cascaded sections.
    /// - Parameters:
    ///   - buf: Input/output buffer (modified in-place)
    ///   - state: State array for all channels (must be sized to channelCount * stateSizePerChannel)
    ///   - channelIndex: Channel index (0 for left, 1 for right, etc.)
    ///   - frameCount: Number of frames to process
    /// - Note: State layout: [ch * stateSizePerChannel + section * 4 + 0] = LP w1,
    ///       [ch * stateSizePerChannel + section * 4 + 1] = LP w2,
    ///       [ch * stateSizePerChannel + section * 4 + 2] = HP w1,
    ///       [ch * stateSizePerChannel + section * 4 + 3] = HP w2
    mutating func processLowPass(_ buf: inout [Float], state: inout [Float], channelIndex: Int, frameCount: Int) {
        var temp = buf
        let stateOffset = channelIndex * stateSizePerChannel
        for section in 0..<sectionCount {
            let coeffs = lowPassSections[section]
            var w1 = state[stateOffset + section * 4]
            var w2 = state[stateOffset + section * 4 + 1]
            for i in 0..<frameCount {
                temp[i] = Self.processBiquad(
                    temp[i],
                    b0: coeffs.b0,
                    b1: coeffs.b1,
                    b2: coeffs.b2,
                    na1: coeffs.na1,
                    na2: coeffs.na2,
                    w1: &w1,
                    w2: &w2
                )
            }
            state[stateOffset + section * 4] = w1
            state[stateOffset + section * 4 + 1] = w2
        }
        buf = temp
    }

    /// Process high-pass filter through all cascaded sections.
    /// - Parameters:
    ///   - buf: Input/output buffer (modified in-place)
    ///   - state: State array for all channels (must be sized to channelCount * stateSizePerChannel)
    ///   - channelIndex: Channel index (0 for left, 1 for right, etc.)
    ///   - frameCount: Number of frames to process
    /// - Note: State layout: [ch * stateSizePerChannel + section * 4 + 0] = LP w1,
    ///       [ch * stateSizePerChannel + section * 4 + 1] = LP w2,
    ///       [ch * stateSizePerChannel + section * 4 + 2] = HP w1,
    ///       [ch * stateSizePerChannel + section * 4 + 3] = HP w2
    mutating func processHighPass(_ buf: inout [Float], state: inout [Float], channelIndex: Int, frameCount: Int) {
        var temp = buf
        let stateOffset = channelIndex * stateSizePerChannel
        for section in 0..<sectionCount {
            let coeffs = highPassSections[section]
            var w1 = state[stateOffset + section * 4 + 2]
            var w2 = state[stateOffset + section * 4 + 3]
            for i in 0..<frameCount {
                temp[i] = Self.processBiquad(
                    temp[i],
                    b0: coeffs.b0,
                    b1: coeffs.b1,
                    b2: coeffs.b2,
                    na1: coeffs.na1,
                    na2: coeffs.na2,
                    w1: &w1,
                    w2: &w2
                )
            }
            state[stateOffset + section * 4 + 2] = w1
            state[stateOffset + section * 4 + 3] = w2
        }
        buf = temp
    }
}
