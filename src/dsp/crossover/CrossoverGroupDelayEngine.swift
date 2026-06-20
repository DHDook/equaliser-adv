// CrossoverGroupDelayEngine.swift
// Group delay analysis and all-pass fitting for crossover phase alignment.
// Computes group delay of crossover + EQ chains and fits all-pass filters
// to minimise group delay error at crossover points.

import Accelerate
import Foundation

enum CrossoverGroupDelayEngine {

    /// Computes the group delay of a complete output channel signal path.
    /// Combines the crossover filter group delay with the per-output EQ group delay.
    ///
    /// - Parameters:
    ///   - crossoverSections: The IIR section array for this channel's crossover filter
    ///     (e.g. activeLowerLP for a woofer channel). Nil for FIR crossover filters.
    ///   - crossoverFIRKernel: FIR kernel for this channel's crossover filter. Nil for IIR.
    ///   - eqBands: The per-output EQ band configurations active on this channel.
    ///   - frequencies: Frequency points at which to compute group delay (Hz).
    ///   - sampleRate: System sample rate.
    /// - Returns: Group delay in milliseconds at each frequency point.
    static func channelGroupDelay(
        crossoverSections: ActiveCrossoverEngine.SectionArray?,
        crossoverFIRKernel: [Float]?,
        eqBands: [EQBandConfiguration],
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        var groupDelay = Array(repeating: 0.0, count: frequencies.count)

        // For FIR crossover: group delay is constant = (tapCount / 2) samples
        if let firKernel = crossoverFIRKernel {
            let firDelaySamples = Double(firKernel.count) / 2.0
            let firDelayMs = firDelaySamples / sampleRate * 1000.0
            for i in 0..<groupDelay.count {
                groupDelay[i] += firDelayMs
            }
        }

        // For IIR crossover: compute group delay from biquad sections
        if let sections = crossoverSections {
            for section in sections {
                let sectionDelay = biquadGroupDelay(
                    b0: section.b0, b1: section.b1, b2: section.b2,
                    a1: section.na1, a2: section.na2,
                    frequencies: frequencies,
                    sampleRate: sampleRate
                )
                for i in 0..<groupDelay.count {
                    groupDelay[i] += sectionDelay[i]
                }
            }
        }

        // For EQ bands: compute group delay from each active band
        for band in eqBands {
            guard !band.bypass else { continue }
            let coeffs = BiquadMath.calculateCoefficients(
                type: band.filterType,
                sampleRate: sampleRate,
                frequency: Double(band.frequency),
                q: Double(band.q),
                gain: Double(band.gain)
            )
            let bandDelay = biquadGroupDelay(
                b0: Float(coeffs.b0), b1: Float(coeffs.b1), b2: Float(coeffs.b2),
                a1: Float(coeffs.a1), a2: Float(coeffs.a2),
                frequencies: frequencies,
                sampleRate: sampleRate
            )
            for i in 0..<groupDelay.count {
                groupDelay[i] += bandDelay[i]
            }
        }

        return groupDelay
    }

    /// Computes group delay of a single biquad section at specified frequencies.
    private static func biquadGroupDelay(
        b0: Float, b1: Float, b2: Float,
        a1: Float, a2: Float,
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        // Group delay = -d(φ)/dω where φ is phase response
        // Compute numerically using finite differences
        let deltaF = 1.0  // 1 Hz frequency step
        var groupDelay: [Double] = []

        for f in frequencies {
            let omega1 = 2.0 * Double.pi * (f - deltaF / 2.0) / sampleRate
            let omega2 = 2.0 * Double.pi * (f + deltaF / 2.0) / sampleRate

            let phase1 = biquadPhase(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, omega: omega1)
            let phase2 = biquadPhase(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, omega: omega2)

            // Unwrap phase difference
            var deltaPhase = phase2 - phase1
            while deltaPhase > Double.pi { deltaPhase -= 2.0 * Double.pi }
            while deltaPhase < -Double.pi { deltaPhase += 2.0 * Double.pi }

            let delay = -deltaPhase / (2.0 * Double.pi * deltaF / sampleRate)
            groupDelay.append(delay * 1000.0)  // Convert to ms
        }

        return groupDelay
    }

    /// Computes phase response of a biquad at a given normalized frequency.
    private static func biquadPhase(
        b0: Float, b1: Float, b2: Float,
        a1: Float, a2: Float,
        omega: Double
    ) -> Double {
        let cosW = cos(omega)
        let cos2W = cos(2.0 * omega)
        let sinW = sin(omega)
        let sin2W = sin(2.0 * omega)

        // Numerator
        let numReal = Double(b0) + Double(b1) * cosW + Double(b2) * cos2W
        let numImag = Double(b1) * sinW + Double(b2) * sin2W

        // Denominator
        let denReal = 1.0 + Double(a1) * cosW + Double(a2) * cos2W
        let denImag = Double(a1) * sinW + Double(a2) * sin2W

        // Complex division
        let denMag = denReal * denReal + denImag * denImag
        guard denMag > 1e-30 else { return 0.0 }

        let real = (numReal * denReal + numImag * denImag) / denMag
        let imag = (numImag * denReal - numReal * denImag) / denMag

        return atan2(imag, real)
    }

    /// Computes the group delay error between two output channels at the crossover point.
    /// Used to determine how much all-pass correction is needed to align them.
    ///
    /// - Parameters:
    ///   - channelADelays: Group delay of the lower-frequency channel (e.g. woofer).
    ///   - channelBDelays: Group delay of the higher-frequency channel (e.g. tweeter).
    ///   - crossoverHz: The crossover frequency between these two channels.
    ///   - frequencies: Must be the same array used to compute both delay arrays.
    /// - Returns: Group delay difference (A − B) in ms at each frequency. Positive means
    ///   channel A has more group delay (is "slower") than channel B at that frequency.
    static func groupDelayError(
        channelADelays: [Double],
        channelBDelays: [Double],
        crossoverHz: Double,
        frequencies: [Double]
    ) -> [Double] {
        // TODO: Implement group delay error computation
        // Subtract channel B delays from channel A delays at each frequency
        return zip(channelADelays, channelBDelays).map { $0 - $1 }
    }

    /// Fits an all-pass biquad chain to minimise group delay error at a crossover point.
    /// The fitted chain is applied to the channel with LESS group delay to bring it
    /// into alignment with the channel that has MORE group delay.
    ///
    /// Uses iterative least-squares fitting of second-order all-pass sections,
    /// minimising weighted group delay error in the region around the crossover frequency
    /// (one octave below to one octave above).
    ///
    /// - Parameters:
    ///   - delayErrorMs: From groupDelayError — positive means channel A needs more delay.
    ///   - applyToChannelA: True if the all-pass should be applied to channel A.
    ///   - crossoverHz: Crossover frequency for weighting the fit.
    ///   - frequencies: Frequency points of delayErrorMs.
    ///   - sampleRate: System sample rate.
    ///   - maxSections: Maximum all-pass sections to fit. Default: 4.
    /// - Returns: All-pass BiquadCoefficients for the channel that needs correction.
    static func fitGroupDelayAllPass(
        delayErrorMs: [Double],
        applyToChannelA: Bool,
        crossoverHz: Double,
        frequencies: [Double],
        sampleRate: Double,
        maxSections: Int = 4
    ) -> [BiquadCoefficients] {
        var coefficients: [BiquadCoefficients] = []
        var residualError = delayErrorMs

        // Weight frequencies around crossover (one octave below to one octave above)
        let lowWeightFreq = crossoverHz / 2.0
        let highWeightFreq = crossoverHz * 2.0

        for _ in 0..<maxSections {
            // Find frequency with maximum weighted error
            var maxWeightedError: Double = 0
            var targetFreq: Double = crossoverHz

            for (idx, f) in frequencies.enumerated() {
                let weight = f >= lowWeightFreq && f <= highWeightFreq ? 1.0 : 0.1
                let weightedError = abs(residualError[idx]) * weight

                if weightedError > maxWeightedError {
                    maxWeightedError = weightedError
                    targetFreq = f
                }
            }

            guard maxWeightedError > 0.1 else { break }

            // Create all-pass biquad at target frequency
            let q = 1.0
            let allPassCoeffs = BiquadMath.calculateCoefficients(
                type: .allPass,
                sampleRate: sampleRate,
                frequency: targetFreq,
                q: q,
                gain: 0.0
            )

            coefficients.append(allPassCoeffs)

            // Remove this all-pass's contribution from residual error
            let allPassDelay = biquadGroupDelay(
                b0: Float(allPassCoeffs.b0), b1: Float(allPassCoeffs.b1), b2: Float(allPassCoeffs.b2),
                a1: Float(allPassCoeffs.a1), a2: Float(allPassCoeffs.a2),
                frequencies: frequencies,
                sampleRate: sampleRate
            )

            for i in 0..<residualError.count {
                residualError[i] -= allPassDelay[i]
            }
        }

        return coefficients
    }
}
