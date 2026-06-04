// RoomCorrectionEngine.swift
// Room correction using inverse filters and target curves

import Foundation

/// Room correction engine using inverse filtering to match target response curves.
final class RoomCorrectionEngine {

    // MARK: - Constants

    private let fftSize: Int
    private let filterLength: Int

    // MARK: - State

    /// FFT engine for convolution.
    private let fftEngine: FFTEngine

    /// Inverse filter coefficients (room correction filter).
    private var inverseFilter: [Float]

    /// Whether room correction is enabled.
    private var enabled: Bool = false

    /// Current sample rate.
    private var sampleRate: Double = 48000.0

    /// Target curve type.
    private var targetCurveType: TargetCurveType = .flat

    /// Channel count.
    private let channelCount: Int

    // MARK: - Initialization

    init(channelCount: Int, sampleRate: Double, filterLength: Int = 1024) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.filterLength = filterLength

        // FFT size must be >= 2 * filterLength for convolution
        self.fftSize = nextPowerOfTwo(2 * filterLength)

        self.fftEngine = FFTEngine(fftSize: fftSize)
        self.inverseFilter = Array(repeating: 0.0, count: filterLength)
    }

    // MARK: - Configuration

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    func setSampleRate(_ rate: Double) {
        self.sampleRate = rate
        generateInverseFilter()
    }

    func setTargetCurveType(_ type: TargetCurveType) {
        self.targetCurveType = type
        generateInverseFilter()
    }

    /// Sets room measurement data for generating inverse filter.
    /// - Parameter measurement: Measured frequency response data (frequency in Hz, magnitude in dB)
    func setMeasurement(_ measurement: [(frequency: Double, magnitude: Double)]) {
        // Generate inverse filter from measurement
        generateInverseFilterFromMeasurement(measurement)
    }

    // MARK: - Processing

    /// Applies room correction filter to audio.
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

        // For each channel, apply inverse filter via convolution
        for ch in 0..<channelCount {
            let inPtr = input[ch]
            let outPtr = output[ch]

            // Convert input to array for convolution
            var inputArray = Array(repeating: 0.0, count: frameCount)
            for i in 0..<frameCount {
                inputArray[i] = inPtr[i]
            }

            // Perform convolution
            let result = fftEngine.convolve(signal: inputArray, impulse: inverseFilter)

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

    // MARK: - Filter Generation

    private func generateInverseFilter() {
        // Generate inverse filter based on target curve type
        switch targetCurveType {
        case .flat:
            // Flat target - no correction needed
            inverseFilter = Array(repeating: 0.0, count: filterLength)
            inverseFilter[0] = 1.0 // Unity gain

        case .houseCurve:
            // House curve - gentle bass and treble lift
            generateHouseCurveFilter()

        case .custom:
            // Custom curve - would be loaded from measurement data
            inverseFilter = Array(repeating: 0.0, count: filterLength)
            inverseFilter[0] = 1.0
        }
    }

    private func generateHouseCurveFilter() {
        // Generate FIR filter for house curve (gentle bass/treble boost)
        // This is a simplified implementation - real implementation would use
        // frequency sampling or windowed sinc method
        inverseFilter = Array(repeating: 0.0, count: filterLength)

        let nyquist = sampleRate / 2.0
        let mid = filterLength / 2

        for i in 0..<filterLength {
            let n = Double(i - mid)
            // Sinc function
            let sinc = n == 0 ? 1.0 : sin(.pi * n / Double(mid)) / (.pi * n / Double(mid))

            // Apply house curve weighting (boost bass and treble)
            let freq = abs(n) / Double(filterLength) * nyquist
            let bassBoost = freq < 200.0 ? 1.2 : 1.0
            let trebleBoost = freq > 8000.0 ? 1.15 : 1.0
            let curve = bassBoost * trebleBoost

            // Apply window
            let window = 0.54 + 0.46 * cos(.pi * Double(i) / Double(filterLength))

            inverseFilter[i] = Float(sinc * curve * window)
        }

        // Normalize
        let sum = inverseFilter.reduce(0, +)
        if sum > 0 {
            for i in 0..<filterLength {
                inverseFilter[i] /= sum
            }
        }
    }

    private func generateInverseFilterFromMeasurement(_ measurement: [(frequency: Double, magnitude: Double)]) {
        // Generate inverse filter from measured frequency response
        // This is a simplified implementation - real implementation would use
        // frequency sampling method with proper interpolation

        inverseFilter = Array(repeating: 0.0, count: filterLength)

        // For now, use a simple approximation
        // Real implementation would:
        // 1. Interpolate measurement data to FFT frequency bins
        // 2. Compute inverse response (1/measured magnitude)
        // 3. Convert to time domain via inverse FFT
        // 4. Apply window and truncate to filter length

        // Placeholder: unity gain
        inverseFilter[0] = 1.0
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

    func resetState() {
        // No state to reset for FIR filter
    }
}
