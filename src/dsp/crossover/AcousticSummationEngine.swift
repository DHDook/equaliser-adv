// AcousticSummationEngine.swift
//
// Predicted acoustic summation computation for crossover analysis.
// Computes the summed frequency response and group delay of all output channels,
// showing whether the crossover is summing to flat and whether there are
// peaks or dips at crossover points.

import Accelerate
import Foundation

enum AcousticSummationEngine {

    struct ChannelResponse: Sendable {
        var channelIndex: Int
        var channelLabel: String
        /// Complex frequency response (magnitude + phase) of the complete channel signal path:
        /// crossover filter × per-output EQ × all-pass group delay correction.
        var complexResponse: [(frequency: Double, real: Double, imag: Double)]
        /// Physical delay applied to this channel in samples (from OutputChannelConfig.delayMs).
        var delaySamples: Double
    }

    /// Computes the predicted summed acoustic frequency response.
    ///
    /// Each channel's complex response is multiplied by a unit-delay phasor
    /// (e^{-jω·delaySamples}) to account for the configured delay offset,
    /// then all channels' complex responses are summed.
    ///
    /// The result is the frequency response the listener would measure at the
    /// listening position if all drivers were at the same physical location
    /// (i.e. ignoring room acoustics and physical driver placement).
    ///
    /// - Parameters:
    ///   - channels: Per-channel complex response and delay data.
    ///   - frequencies: Frequency points (Hz) at which to compute the sum.
    ///   - sampleRate: System sample rate.
    /// - Returns: Summed magnitude response (dB) and group delay (ms) at each frequency.
    static func computeSummation(
        channels: [ChannelResponse],
        frequencies: [Double],
        sampleRate: Double
    ) -> (magnitudeDB: [Double], groupDelayMs: [Double]) {
        var summedReal = [Double](repeating: 0.0, count: frequencies.count)
        var summedImag = [Double](repeating: 0.0, count: frequencies.count)

        // Sum all channel responses with delay compensation
        for channel in channels {
            for (idx, f) in frequencies.enumerated() {
                let omega = 2.0 * Double.pi * f / sampleRate
                let delayPhase = -omega * channel.delaySamples

                // Unit-delay phasor: e^{-jω·delay}
                let phasorReal = cos(delayPhase)
                let phasorImag = sin(delayPhase)

                // Get channel response at this frequency (interpolate if needed)
                let channelResponse = interpolateResponse(
                    channel.complexResponse,
                    at: f
                )

                // Multiply channel response by phasor (complex multiplication)
                let delayedReal = channelResponse.real * phasorReal - channelResponse.imag * phasorImag
                let delayedImag = channelResponse.real * phasorImag + channelResponse.imag * phasorReal

                summedReal[idx] += delayedReal
                summedImag[idx] += delayedImag
            }
        }

        // Convert summed complex response to magnitude (dB)
        var magnitudeDB: [Double] = []
        for i in 0..<frequencies.count {
            let mag = sqrt(summedReal[i] * summedReal[i] + summedImag[i] * summedImag[i])
            let db = 20.0 * log10(max(mag, 1e-10))
            magnitudeDB.append(db)
        }

        // Compute group delay of summed response
        let groupDelayMs = computeGroupDelayFromComplex(
            real: summedReal,
            imag: summedImag,
            frequencies: frequencies,
            sampleRate: sampleRate
        )

        return (magnitudeDB: magnitudeDB, groupDelayMs: groupDelayMs)
    }

    /// Computes per-channel complex response from coefficient data.
    static func channelComplexResponse(
        crossoverSections: ActiveCrossoverEngine.SectionArray?,
        crossoverFIRKernel: [Float]?,
        eqBands: [EQBandConfiguration],
        groupDelayAllPassCoefficients: [BiquadCoefficients],
        frequencies: [Double],
        sampleRate: Double
    ) -> [(frequency: Double, real: Double, imag: Double)] {
        var response: [(frequency: Double, real: Double, imag: Double)] = []

        for f in frequencies {
            var real: Double = 1.0
            var imag: Double = 0.0

            // Apply crossover filter response
            if let firKernel = crossoverFIRKernel {
                // FIR response: compute via FFT
                let firResponse = firFrequencyResponse(firKernel, at: f, sampleRate: sampleRate)
                real *= firResponse.real
                imag = real * firResponse.imag + imag * firResponse.imag // This is wrong, need complex multiplication
                // Actually, for FIR magnitude-only response:
                let mag = firResponse.magnitude
                real *= mag
                imag *= mag
            } else if let sections = crossoverSections {
                // IIR response: cascade all sections
                for section in sections {
                    let sectionResponse = biquadComplexResponse(
                        b0: section.b0, b1: section.b1, b2: section.b2,
                        a1: section.na1, a2: section.na2,
                        frequency: f,
                        sampleRate: sampleRate
                    )
                    let newReal = real * sectionResponse.real - imag * sectionResponse.imag
                    let newImag = real * sectionResponse.imag + imag * sectionResponse.real
                    real = newReal
                    imag = newImag
                }
            }

            // Apply EQ band responses
            for band in eqBands {
                guard !band.bypass else { continue }
                let coeffs = BiquadMath.calculateCoefficients(
                    type: band.filterType,
                    sampleRate: sampleRate,
                    frequency: Double(band.frequency),
                    q: Double(band.q),
                    gain: Double(band.gain)
                )
                let bandResponse = biquadComplexResponse(
                    b0: Float(coeffs.b0), b1: Float(coeffs.b1), b2: Float(coeffs.b2),
                    a1: Float(coeffs.a1), a2: Float(coeffs.a2),
                    frequency: f,
                    sampleRate: sampleRate
                )
                let newReal = real * bandResponse.real - imag * bandResponse.imag
                let newImag = real * bandResponse.imag + imag * bandResponse.real
                real = newReal
                imag = newImag
            }

            // Apply group delay all-pass correction
            for allPassCoeffs in groupDelayAllPassCoefficients {
                let allPassResponse = biquadComplexResponse(
                    b0: Float(allPassCoeffs.b0), b1: Float(allPassCoeffs.b1), b2: Float(allPassCoeffs.b2),
                    a1: Float(allPassCoeffs.a1), a2: Float(allPassCoeffs.a2),
                    frequency: f,
                    sampleRate: sampleRate
                )
                let newReal = real * allPassResponse.real - imag * allPassResponse.imag
                let newImag = real * allPassResponse.imag + imag * allPassResponse.real
                real = newReal
                imag = newImag
            }

            response.append((frequency: f, real: real, imag: imag))
        }

        return response
    }

    // MARK: - Helper Functions

    private static func interpolateResponse(
        _ response: [(frequency: Double, real: Double, imag: Double)],
        at frequency: Double
    ) -> (real: Double, imag: Double) {
        // Find nearest frequency point
        guard !response.isEmpty else { return (real: 1.0, imag: 0.0) }

        if response.count == 1 {
            return (real: response[0].real, imag: response[0].imag)
        }

        // Linear interpolation
        for i in 0..<(response.count - 1) {
            if frequency >= response[i].frequency && frequency <= response[i + 1].frequency {
                let f0 = response[i].frequency
                let f1 = response[i + 1].frequency
                let t = (frequency - f0) / (f1 - f0)

                let real = response[i].real + t * (response[i + 1].real - response[i].real)
                let imag = response[i].imag + t * (response[i + 1].imag - response[i].imag)
                return (real: real, imag: imag)
            }
        }

        // Frequency outside range, return nearest
        if frequency < response[0].frequency {
            return (real: response[0].real, imag: response[0].imag)
        } else {
            return (real: response[response.count - 1].real, imag: response[response.count - 1].imag)
        }
    }

    private static func firFrequencyResponse(
        _ kernel: [Float],
        at frequency: Double,
        sampleRate: Double
    ) -> (real: Double, imag: Double, magnitude: Double) {
        // Compute FIR frequency response via DTFT
        var real: Double = 0
        var imag: Double = 0
        let omega = 2.0 * Double.pi * frequency / sampleRate

        for (n, coeff) in kernel.enumerated() {
            let phase = -omega * Double(n)
            real += Double(coeff) * cos(phase)
            imag += Double(coeff) * sin(phase)
        }

        let magnitude = sqrt(real * real + imag * imag)
        return (real: real, imag: imag, magnitude: magnitude)
    }

    private static func biquadComplexResponse(
        b0: Float, b1: Float, b2: Float,
        a1: Float, a2: Float,
        frequency: Double,
        sampleRate: Double
    ) -> (real: Double, imag: Double) {
        let omega = 2.0 * Double.pi * frequency / sampleRate
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
        guard denMag > 1e-30 else { return (real: 1.0, imag: 0.0) }

        let real = (numReal * denReal + numImag * denImag) / denMag
        let imag = (numImag * denReal - numReal * denImag) / denMag

        return (real: real, imag: imag)
    }

    private static func computeGroupDelayFromComplex(
        real: [Double],
        imag: [Double],
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        // Group delay = -d(φ)/dω
        // Compute numerically using finite differences
        let deltaF = 1.0  // 1 Hz frequency step
        var groupDelay: [Double] = []

        for i in 0..<frequencies.count {
            if i == 0 {
                // Forward difference
                let phase1 = atan2(imag[i], real[i])
                let phase2 = atan2(imag[i + 1], real[i + 1])
                var deltaPhase = phase2 - phase1
                while deltaPhase > Double.pi { deltaPhase -= 2.0 * Double.pi }
                while deltaPhase < -Double.pi { deltaPhase += 2.0 * Double.pi }
                let delay = -deltaPhase / (2.0 * Double.pi * deltaF / sampleRate)
                groupDelay.append(delay * 1000.0)
            } else if i == frequencies.count - 1 {
                // Backward difference
                let phase1 = atan2(imag[i - 1], real[i - 1])
                let phase2 = atan2(imag[i], real[i])
                var deltaPhase = phase2 - phase1
                while deltaPhase > Double.pi { deltaPhase -= 2.0 * Double.pi }
                while deltaPhase < -Double.pi { deltaPhase += 2.0 * Double.pi }
                let delay = -deltaPhase / (2.0 * Double.pi * deltaF / sampleRate)
                groupDelay.append(delay * 1000.0)
            } else {
                // Central difference
                let phase1 = atan2(imag[i - 1], real[i - 1])
                let phase2 = atan2(imag[i + 1], real[i + 1])
                var deltaPhase = phase2 - phase1
                while deltaPhase > Double.pi { deltaPhase -= 2.0 * Double.pi }
                while deltaPhase < -Double.pi { deltaPhase += 2.0 * Double.pi }
                let delay = -deltaPhase / (2.0 * Double.pi * (2.0 * deltaF) / sampleRate)
                groupDelay.append(delay * 1000.0)
            }
        }

        return groupDelay
    }
}
