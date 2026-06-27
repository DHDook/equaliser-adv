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
    ///
    /// Returns the per-frequency difference (channelA − channelB) in milliseconds.
    /// Positive values mean channel A arrives later (has more group delay) than channel B.
    /// The fitter uses this to decide which channel needs additional all-pass delay.
    ///
    /// - Parameters:
    ///   - channelADelays: Group delay of the lower-frequency channel (e.g. woofer), in ms.
    ///   - channelBDelays: Group delay of the higher-frequency channel (e.g. tweeter), in ms.
    ///   - crossoverHz: The crossover frequency. Not used in computation; retained for
    ///     caller documentation and future weighted-error variants.
    ///   - frequencies: The frequency grid used to compute both delay arrays.
    /// - Returns: Group delay difference (A − B) in ms at each frequency point.
    static func groupDelayError(
        channelADelays: [Double],
        channelBDelays: [Double],
        crossoverHz: Double,
        frequencies: [Double]
    ) -> [Double] {
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
        // Only fit if there is actually a channel that needs MORE delay.
        // applyToChannelA == true means channel A is the faster channel and needs delay added.
        // applyToChannelA == false means channel B needs delay added.
        // The sign of delayErrorMs values determines which channel is slower:
        //   positive → channel A is slower, no all-pass needed on A
        //   negative → channel B is slower, no all-pass needed on B
        // If the caller passes applyToChannelA = true, we are fitting to add delay to channel A,
        // which means we should only proceed when residual errors are negative (channel A is faster).
        // If all errors have the wrong sign, return empty — no correction is needed in this direction.
        let signMultiplier: Double = applyToChannelA ? -1.0 : 1.0
        let effectiveError = delayErrorMs.map { $0 * signMultiplier }
        guard effectiveError.contains(where: { $0 > 0 }) else { return [] }

        var coefficients: [BiquadCoefficients] = []
        var residualError = effectiveError

        // Weight window: full weight within ±1 octave of crossover, reduced outside
        let lowWeightFreq  = crossoverHz / 2.0
        let highWeightFreq = crossoverHz * 2.0

        // Candidate Q values to sweep per section
        let candidateQs: [Double] = [0.5, 0.7071, 1.0, 1.414, 2.0, 2.828, 4.0]

        for _ in 0..<maxSections {
            // Find the frequency index with maximum weighted residual error
            var maxWeightedError: Double = 0
            var bestFreq: Double = crossoverHz

            for (idx, f) in frequencies.enumerated() {
                let weight = (f >= lowWeightFreq && f <= highWeightFreq) ? 1.0 : 0.1
                let weighted = residualError[idx] * weight
                if weighted > maxWeightedError {
                    maxWeightedError = weighted
                    bestFreq = f
                }
            }

            // Stop if peak weighted error is below threshold (0.1 ms)
            guard maxWeightedError > 0.1 else { break }

            // Sweep Q values: choose the Q that minimises weighted squared error after subtraction
            var bestQ:    Double = 1.0
            var bestCost: Double = .infinity
            var bestCoeffs: BiquadCoefficients = BiquadMath.calculateCoefficients(
                type: .allPass, sampleRate: sampleRate, frequency: bestFreq, q: 1.0, gain: 0.0)

            for candidateQ in candidateQs {
                let candidateCoeffs = BiquadMath.calculateCoefficients(
                    type: .allPass,
                    sampleRate: sampleRate,
                    frequency: bestFreq,
                    q: candidateQ,
                    gain: 0.0
                )
                let candidateDelay = biquadGroupDelay(
                    b0: Float(candidateCoeffs.b0), b1: Float(candidateCoeffs.b1),
                    b2: Float(candidateCoeffs.b2),
                    a1: Float(candidateCoeffs.a1), a2: Float(candidateCoeffs.a2),
                    frequencies: frequencies,
                    sampleRate: sampleRate
                )

                // Compute weighted squared error after subtracting this candidate
                var cost: Double = 0
                for (idx, f) in frequencies.enumerated() {
                    let weight = (f >= lowWeightFreq && f <= highWeightFreq) ? 1.0 : 0.1
                    let remaining = residualError[idx] - candidateDelay[idx]
                    cost += weight * remaining * remaining
                }

                if cost < bestCost {
                    bestCost   = cost
                    bestQ      = candidateQ
                    bestCoeffs = candidateCoeffs
                }
            }

            _ = bestQ  // used in selection above; suppress unused-variable warning if any
            coefficients.append(bestCoeffs)

            // Subtract the chosen section's delay contribution from the residual
            let chosenDelay = biquadGroupDelay(
                b0: Float(bestCoeffs.b0), b1: Float(bestCoeffs.b1), b2: Float(bestCoeffs.b2),
                a1: Float(bestCoeffs.a1), a2: Float(bestCoeffs.a2),
                frequencies: frequencies,
                sampleRate: sampleRate
            )
            for i in residualError.indices {
                residualError[i] -= chosenDelay[i]
            }
        }

        return coefficients
    }
}
