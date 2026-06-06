// SweepAnalyser.swift
// Sweep analyser for room measurement and calibration

import Foundation
import Accelerate

/// Sweep analyser for measuring room response using log-swept sine waves.
final class SweepAnalyser {

    // MARK: - Constants

    private let sampleRate: Double
    private let duration: Double
    private let startFrequency: Double
    private let endFrequency: Double

    // MARK: - State

    /// Sweep signal buffer.
    var sweepSignal: [Float]

    /// Inverse sweep for deconvolution.
    private var inverseSweep: [Float]

    /// Whether analyser is currently recording.
    private var isRecording: Bool = false

    /// Recorded response buffer.
    private var recordedResponse: [Float]

    /// Channel count.
    private let channelCount: Int

    // MARK: - Initialization

    init(sampleRate: Double, duration: Double = 10.0, startFrequency: Double = 20.0, endFrequency: Double = 20000.0, channelCount: Int = 2) {
        self.sampleRate = sampleRate
        self.duration = duration
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.channelCount = channelCount

        let frameCount = Int(sampleRate * duration)
        self.sweepSignal = Array(repeating: 0.0, count: frameCount)
        self.inverseSweep = Array(repeating: 0.0, count: frameCount)
        self.recordedResponse = Array(repeating: 0.0, count: frameCount * channelCount)

        generateSweep()
    }

    // MARK: - Sweep Generation

    private func generateSweep() {
        let frameCount = sweepSignal.count
        let sampleRate = self.sampleRate
        let duration = self.duration
        let startFreq = self.startFrequency
        let endFreq = self.endFrequency

        // Generate exponential sweep
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let k = (endFreq / startFreq).pow(1.0 / duration)
            let phase = 2.0 * .pi * startFreq * duration * (k.pow(t) - 1.0) / log(k)
            sweepSignal[i] = Float(sin(phase))
        }

        // Generate inverse sweep for deconvolution
        // Time-reversed sweep with amplitude compensation
        let amplitudeCompensation = 1.0 / Float(frameCount)
        for i in 0..<frameCount {
            inverseSweep[i] = sweepSignal[frameCount - 1 - i] * amplitudeCompensation
        }
    }

    // MARK: - Recording

    func startRecording() {
        isRecording = true
        recordedResponse = Array(repeating: 0.0, count: recordedResponse.count)
    }

    func stopRecording() {
        isRecording = false
    }

    func processSamples(_ samples: [Float], channel: Int) {
        guard isRecording else { return }
        guard channel < channelCount else { return }

        let offset = channel * sweepSignal.count
        let copyCount = min(samples.count, sweepSignal.count)

        for i in 0..<copyCount {
            if offset + i < recordedResponse.count {
                recordedResponse[offset + i] = samples[i]
            }
        }
    }

    // MARK: - Analysis

    /// Computes the impulse response from the recorded sweep.
    /// - Parameter channel: Channel to analyse
    /// - Returns: Impulse response
    func computeImpulseResponse(channel: Int = 0) -> [Float] {
        guard channel < channelCount else { return [] }

        let offset = channel * sweepSignal.count
        var channelResponse = Array(repeating: Float(0.0), count: sweepSignal.count)

        for i in 0..<sweepSignal.count {
            if offset + i < recordedResponse.count {
                channelResponse[i] = recordedResponse[offset + i]
            }
        }

        // Convolve with inverse sweep to get impulse response
        let fftSize = nextPowerOfTwo(2 * sweepSignal.count)
        let fftEngine = FFTEngine(fftSize: fftSize)

        return fftEngine.convolve(signal: channelResponse, impulse: inverseSweep)
    }

    /// Computes the frequency response from the impulse response.
    /// - Parameter channel: Channel to analyse
    /// - Returns: Frequency response data (frequency in Hz, gain in dB)
    func computeFrequencyResponse(channel: Int = 0) -> [(frequency: Double, gainDB: Double)] {
        let impulseResponse = computeImpulseResponse(channel: channel)

        // FFT to get frequency response
        let fftSize = nextPowerOfTwo(impulseResponse.count)
        let fftEngine = FFTEngine(fftSize: fftSize)

        // Pad impulse response to FFT size
        var paddedIR = Array(repeating: Float(0.0), count: fftSize)
        for i in 0..<impulseResponse.count {
            paddedIR[i] = impulseResponse[i]
        }

        let fftResult = fftEngine.forwardFFT(input: paddedIR)

        // Compute magnitude response
        var response: [(frequency: Double, gainDB: Double)] = []
        let halfSize = fftSize / 2

        for i in 0..<halfSize {
            let real = fftResult.real[i]
            let imag = fftResult.imag[i]
            let magnitude = sqrt(Double(real * real + imag * imag))
            let magnitudeDB = magnitude > 0 ? 20.0 * log10(magnitude) : -100.0

            let frequency = Double(i) * sampleRate / Double(fftSize)
            response.append((frequency, magnitudeDB))
        }

        return response
    }

    // MARK: - Helpers

    private func nextPowerOfTwo(_ n: Int) -> Int {
        var v = n
        v -= 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v += 1
        return v
    }
}

// Helper for power function
extension Double {
    func pow(_ exponent: Double) -> Double {
        Darwin.pow(self, exponent)
    }
}
