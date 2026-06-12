// ExcessPhaseCorrector.swift
// Excess-phase / group-delay room correction (Part 5)
//
// This module computes and applies a linear-phase FIR correction filter
// that flattens group delay in the modal/low-frequency region.

import Foundation
import Accelerate

/// Excess-phase correction configuration.
struct ExcessPhaseConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var cutoffFreqHz: Float = 300.0  // Range 100-500 Hz
    var filterTaps: Int = 8192      // 4096/8192/16384 taps
}

/// Excess-phase corrector for flattening group delay in the modal region.
enum ExcessPhaseCorrector {

    /// Computes the excess-phase correction filter from the measured response.
    /// - Parameters:
    ///   - measuredResponse: Complex frequency response of the measured system
    ///   - minPhaseResponse: Complex response of the minimum-phase equivalent
    ///   - config: Configuration for the correction filter
    ///   - sampleRate: Sample rate in Hz
    /// - Returns: Linear-phase FIR filter coefficients (causal, centered)
    static func computeCorrectionFilter(
        measuredResponse: [(frequency: Double, real: Double, imag: Double)],
        minPhaseResponse: [(frequency: Double, real: Double, imag: Double)],
        config: ExcessPhaseConfig,
        sampleRate: Double
    ) -> [Float] {
        // Step 1: Compute excess phase
        // excessPhase(f) = phase(H_measured(f)) - phase(H_measured_minphase(f))
        var excessPhase: [(frequency: Double, phase: Double)] = []
        for (i, measured) in measuredResponse.enumerated() {
            guard i < minPhaseResponse.count else { break }
            let minPhase = minPhaseResponse[i]

            let measuredPhase = atan2(measured.imag, measured.real)
            let minPhaseAngle = atan2(minPhase.imag, minPhase.real)
            let excess = measuredPhase - minPhaseAngle

            excessPhase.append((measured.frequency, excess))
        }

        // Step 2: Build target complex response for correction filter
        // magnitude = 1 everywhere, phase = -excessPhase(f) below cutoff, crossfading to 0 above
        let fftSize = config.filterTaps
        let halfSize = fftSize / 2
        var targetComplex: [(real: Double, imag: Double)] = Array(repeating: (0.0, 0.0), count: halfSize)

        for (i, point) in excessPhase.enumerated() {
            guard i < halfSize else { break }

            let freq = Float(point.frequency)
            let cutoff = config.cutoffFreqHz

            // Crossfade: -excessPhase below cutoff, smoothly fading to 0 above
            var correctionPhase: Double
            if freq < cutoff {
                correctionPhase = -point.phase
            } else {
                // Raised-cosine crossfade over one octave
                let crossfadeFreq = cutoff * 2.0
                if freq < crossfadeFreq {
                    let t = Double(freq - cutoff) / Double(crossfadeFreq - cutoff)
                    let fade = 0.5 * (1.0 - cos(Double.pi * t))
                    correctionPhase = -point.phase * (1.0 - fade)
                } else {
                    correctionPhase = 0.0
                }
            }

            // Magnitude = 1 (phase-only correction)
            targetComplex[i] = (cos(correctionPhase), sin(correctionPhase))
        }

        // Step 3: Inverse FFT to get time-domain impulse response
        let fftEngine = FFTEngine(fftSize: fftSize)

        // Convert targetComplex to Float arrays for FFT engine
        var realPart: [Float] = Array(repeating: 0.0, count: halfSize)
        var imagPart: [Float] = Array(repeating: 0.0, count: halfSize)

        for (i, point) in targetComplex.enumerated() {
            realPart[i] = Float(point.real)
            imagPart[i] = Float(point.imag)
        }

        // Perform inverse FFT
        var impulseResponse = fftEngine.inverseFFT(real: realPart, imag: imagPart)

        // Step 4: Apply Blackman-Harris windowing
        let window = blackmanHarrisWindow(size: fftSize)
        for i in 0..<fftSize {
            impulseResponse[i] *= window[i]
        }

        // Step 5: Center the result to produce a causal linear-phase FIR
        // Circular shift by N/2 to center the impulse response
        let halfSizeInt = fftSize / 2
        var centeredResponse = Array(repeating: Float(0.0), count: fftSize)
        for i in 0..<fftSize {
            let srcIdx = (i + halfSizeInt) % fftSize
            centeredResponse[i] = impulseResponse[srcIdx]
        }

        return centeredResponse
    }

    /// Blackman-Harris window function for FIR filter design.
    private static func blackmanHarrisWindow(size: Int) -> [Float] {
        var window: [Float] = []
        let n = Float(size - 1)
        for i in 0..<size {
            let iFloat = Float(i)
            let w = 0.35875 - 0.48829 * cos(2.0 * .pi * iFloat / n) +
                      0.14128 * cos(4.0 * .pi * iFloat / n) -
                      0.01168 * cos(6.0 * .pi * iFloat / n)
            window.append(Float(w))
        }
        return window
    }

    /// Estimates the latency added by the excess-phase correction filter.
    /// - Parameter filterTaps: Number of taps in the linear-phase FIR
    /// - Returns: Latency in milliseconds
    static func estimateLatency(filterTaps: Int, sampleRate: Double) -> Double {
        // Linear-phase FIR has N/2 samples of group delay
        let delaySamples = Double(filterTaps) / 2.0
        return (delaySamples / sampleRate) * 1000.0
    }
}
