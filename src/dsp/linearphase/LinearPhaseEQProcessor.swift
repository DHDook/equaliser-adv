// LinearPhaseEQProcessor.swift
// Linear-phase EQ using FIR filters and FFT convolution

import Foundation

/// Linear-phase EQ processor using FIR filters for zero-phase distortion.
/// Uses FFT convolution for efficient processing.
final class LinearPhaseEQProcessor {

    // MARK: - Constants

    private let fftSize: Int
    private let filterLength: Int

    // MARK: - State

    /// FFT engine for convolution.
    private let fftEngine: FFTEngine

    /// FIR filter coefficients (impulse response).
    private var filterCoefficients: [Float]

    /// Whether linear-phase EQ is enabled.
    private var enabled: Bool = false

    /// Current sample rate.
    private var sampleRate: Double = 48000.0

    /// Channel count.
    private let channelCount: Int

    // MARK: - Initialization

    init(channelCount: Int, sampleRate: Double, filterLength: Int = 512) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.filterLength = filterLength

        // FFT size must be >= 2 * filterLength for convolution
        self.fftSize = Self.nextPowerOfTwo(2 * filterLength)

        self.fftEngine = FFTEngine(fftSize: fftSize)
        self.filterCoefficients = Array(repeating: Float(0.0), count: filterLength)
    }

    // MARK: - Configuration

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    func setSampleRate(_ rate: Double) {
        self.sampleRate = rate
        // Recalculate filter coefficients if needed
    }

    /// Sets FIR filter coefficients for linear-phase EQ.
    /// - Parameter coefficients: FIR filter coefficients (impulse response)
    func setFilterCoefficients(_ coefficients: [Float]) {
        precondition(coefficients.count <= filterLength, "Coefficients must not exceed filter length")
        filterCoefficients = Array(repeating: Float(0.0), count: filterLength)
        for i in 0..<coefficients.count {
            filterCoefficients[i] = coefficients[i]
        }
    }

    // MARK: - Processing

    /// Processes audio through linear-phase FIR filter using FFT convolution.
    /// - Parameters:
    ///   - input: Input audio buffer (deinterleaved, one buffer per channel)
    ///   - frameCount: Number of frames in input
    ///   - output: Output buffer (same layout as input)
    func process(input: [UnsafePointer<Float>], frameCount: Int, output: [UnsafeMutablePointer<Float>]) {
        guard enabled else {
            // Passthrough
            for ch in 0..<channelCount {
                let inPtr = input[ch]
                let outPtr = output[ch]
                for i in 0..<frameCount {
                    outPtr[i] = inPtr[i]
                }
            }
            return
        }

        // For each channel, perform convolution
        for ch in 0..<channelCount {
            let inPtr = input[ch]
            let outPtr = output[ch]

            // Convert input to array for convolution
            var inputArray = Array(repeating: Float(0.0), count: frameCount)
            for i in 0..<frameCount {
                inputArray[i] = inPtr[i]
            }

            // Perform convolution
            let result = fftEngine.convolve(signal: inputArray, impulse: filterCoefficients)

            // Copy result to output (trim to frameCount)
            let copyCount = min(frameCount, result.count)
            for i in 0..<copyCount {
                outPtr[i] = result[i]
            }

            // Zero remaining samples if result is shorter
            for i in copyCount..<frameCount {
                outPtr[i] = 0.0
            }
        }
    }

    // MARK: - Helpers

    private static func nextPowerOfTwo(_ n: Int) -> Int {
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

    func resetState() {
        // No state to reset for FIR filter
    }
}
