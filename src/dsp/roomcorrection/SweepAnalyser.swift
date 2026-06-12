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

    /// Reference sweep for deconvolution (stored during measurement).
    private var referenceSweep: [Float] = []

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
        self.recordedResponse = Array(repeating: 0.0, count: frameCount)

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
        currentSampleIndex = 0
    }

    func stopRecording() {
        isRecording = false
    }

    /// Sets the reference sweep signal for deconvolution.
    func setReferenceSweep(_ sweep: [Float]) {
        referenceSweep = sweep
    }

    /// Accumulates captured mic audio.
    func recordSamples(_ samples: [Float]) {
        guard isRecording else { return }

        let copyCount = min(samples.count, recordedResponse.count - currentSampleIndex)
        for i in 0..<copyCount {
            recordedResponse[currentSampleIndex + i] = samples[i]
        }
        currentSampleIndex += copyCount
    }

    private var currentSampleIndex: Int = 0

    // MARK: - Analysis

    /// Computes the impulse response from the recorded sweep via deconvolution.
    /// - Parameter referenceSweep: The reference sweep signal that was played
    /// - Returns: Impulse response (causal portion, max 1 second)
    func computeImpulseResponse(referenceSweep: [Float]) -> [Float] {
        let captured = recordedResponse
        let reference = referenceSweep

        // Zero-pad both to next power of two ≥ captured.count + reference.count
        let outputLen = captured.count + reference.count - 1
        let fftSize = nextPowerOfTwo(outputLen)

        var paddedCaptured = Array(repeating: Float(0.0), count: fftSize)
        var paddedReference = Array(repeating: Float(0.0), count: fftSize)

        for i in 0..<captured.count {
            paddedCaptured[i] = captured[i]
        }
        for i in 0..<reference.count {
            paddedReference[i] = reference[i]
        }

        // Forward FFT both
        let fftEngine = FFTEngine(fftSize: fftSize)
        let capturedFFT = fftEngine.forwardFFT(input: paddedCaptured)
        let referenceFFT = fftEngine.forwardFFT(input: paddedReference)

        // Complex division with regularisation: IR(f) = Captured(f) / Reference(f)
        var realResult = Array(repeating: Float(0.0), count: fftSize / 2)
        var imagResult = Array(repeating: Float(0.0), count: fftSize / 2)

        for i in 0..<(fftSize / 2) {
            let ar = capturedFFT.real[i]
            let ai = capturedFFT.imag[i]
            let br = referenceFFT.real[i]
            let bi = referenceFFT.imag[i]

            // Regularise denominator to avoid division by near-zero
            let denomMag = br * br + bi * bi + 1e-6

            // Complex division: (a+bi) / (c+di) = ((ac+bd) + i(bc-ad)) / (c²+d²)
            realResult[i] = (ar * br + ai * bi) / denomMag
            imagResult[i] = (ai * br - ar * bi) / denomMag
        }

        // Inverse FFT to get time-domain IR
        let ir = fftEngine.inverseFFT(real: realResult, imag: imagResult)

        // Window with Hann window to suppress pre-ringing
        let windowSize = min(ir.count, Int(sampleRate * 1.0)) // Max 1 second
        var windowedIR = Array(repeating: Float(0.0), count: windowSize)
        for i in 0..<windowSize {
            let hann = 0.5 * (1.0 - cos(2.0 * .pi * Double(i) / Double(windowSize - 1)))
            windowedIR[i] = ir[i] * Float(hann)
        }

        // Return causal portion (trim to min(captured.count, sampleRate * 1.0))
        let causalLength = min(captured.count, Int(sampleRate * 1.0))
        return Array(windowedIR.prefix(causalLength))
    }

    /// Computes the frequency response from the impulse response.
    /// - Parameters:
    ///   - ir: Impulse response
    ///   - micCalibration: Optional microphone calibration data to apply
    /// - Returns: Frequency response data (frequency in Hz, gain in dB) covering 20 Hz–20 kHz
    func computeFrequencyResponse(ir: [Float], micCalibration: MicCalibration? = nil) -> [(frequency: Double, gainDB: Double)] {
        let complexResponse = computeComplexFrequencyResponse(ir: ir, micCalibration: micCalibration)
        return complexResponse.map { point in
            let magnitude = sqrt(point.real * point.real + point.imag * point.imag)
            let gainDB = magnitude > 0 ? 20.0 * log10(magnitude) : -120.0
            return (point.frequency, gainDB)
        }
    }

    /// Computes the complex frequency response from the impulse response.
    /// - Parameters:
    ///   - ir: Impulse response
    ///   - micCalibration: Optional microphone calibration data to apply
    /// - Returns: Complex frequency response data (frequency in Hz, real, imag) covering 20 Hz–20 kHz
    func computeComplexFrequencyResponse(ir: [Float], micCalibration: MicCalibration? = nil) -> [(frequency: Double, real: Double, imag: Double)] {
        // FFT to get frequency response
        let fftSize = nextPowerOfTwo(ir.count)
        let fftEngine = FFTEngine(fftSize: fftSize)

        // Pad IR to FFT size
        var paddedIR = Array(repeating: Float(0.0), count: fftSize)
        for i in 0..<ir.count {
            paddedIR[i] = ir[i]
        }

        let fftResult = fftEngine.forwardFFT(input: paddedIR)

        // Compute complex response
        var response: [(frequency: Double, real: Double, imag: Double)] = []
        let halfSize = fftSize / 2

        for i in 0..<halfSize {
            let real = fftResult.real[i]
            let imag = fftResult.imag[i]
            let magnitude = sqrt(Double(real * real + imag * imag))
            var magnitudeDB = magnitude > 0 ? 20.0 * log10(magnitude) : -100.0

            let frequency = Double(i) * sampleRate / Double(fftSize)

            // Apply microphone calibration correction if available
            if let calibration = micCalibration {
                let deviation = calibration.deviationAtFrequency(frequency)
                magnitudeDB -= deviation
                // Reconstruct magnitude from corrected dB
                let correctedMagnitude = pow(10.0, magnitudeDB / 20.0)
                // Preserve original phase, apply corrected magnitude
                let phase = atan2(Double(imag), Double(real))
                let correctedReal = correctedMagnitude * cos(phase)
                let correctedImag = correctedMagnitude * sin(phase)

                // Only include 20 Hz–20 kHz range
                if frequency >= 20.0 && frequency <= 20000.0 {
                    response.append((frequency, correctedReal, correctedImag))
                }
            } else {
                // Only include 20 Hz–20 kHz range
                if frequency >= 20.0 && frequency <= 20000.0 {
                    response.append((frequency, Double(real), Double(imag)))
                }
            }
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
