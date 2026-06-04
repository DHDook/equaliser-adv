// OversamplingProcessor.swift
// 4x oversampling using polyphase FIR filters

import Foundation

/// 4x oversampling processor using polyphase FIR filters.
/// Upsamples by 4x before EQ, downsamples by 4x after EQ.
/// Uses 64-tap FIR filters per phase for high-quality anti-aliasing.
final class OversamplingProcessor {

    // MARK: - Constants

    private static let upsampleFactor: Int = 4
    private static let filterTaps: Int = 64
    private static let phases: Int = 4

    // MARK: - State

    /// Whether oversampling is enabled.
    private var enabled: Bool = false

    /// Current sample rate.
    private var sampleRate: Double = 48000.0

    /// Upsampling filter coefficients (polyphase: phases × taps).
    private var upsampleCoefficients: [[Float]] = []

    /// Downsampling filter coefficients (polyphase: phases × taps).
    private var downsampleCoefficients: [[Float]] = []

    /// Upsampling state buffers (taps per channel).
    private var upsampleState: [[Float]] = []

    /// Downsampling state buffers (taps per channel).
    private var downsampleState: [[Float]] = []

    /// Temporary buffer for upsampled audio (4× frame count).
    private var upsampledBuffer: [Float] = []

    /// Temporary buffer for downsampled audio (original frame count).
    private var downsampledBuffer: [Float] = []

    private let channelCount: Int

    // MARK: - Initialization

    init(channelCount: Int, sampleRate: Double) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        generateCoefficients()
        allocateBuffers()
    }

    // MARK: - Configuration

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    func setSampleRate(_ rate: Double) {
        self.sampleRate = rate
        generateCoefficients()
    }

    // MARK: - Processing

    /// Upsamples audio by 4x using polyphase FIR filtering.
    /// - Parameters:
    ///   - input: Input audio buffer (deinterleaved, one buffer per channel)
    ///   - frameCount: Number of frames in input
    ///   - output: Output buffer (must be 4× frameCount capacity)
    @inline(__always)
    func upsample(input: [UnsafePointer<Float>], frameCount: Int, output: UnsafeMutablePointer<Float>) {
        guard enabled else {
            // Passthrough: copy input to output
            for ch in 0..<channelCount {
                let inPtr = input[ch]
                var outPtr = output.advanced(by: ch * frameCount * Self.upsampleFactor)
                for i in 0..<frameCount {
                    outPtr.pointee = inPtr[i]
                    outPtr = outPtr.advanced(by: Self.upsampleFactor)
                }
            }
            return
        }

        for ch in 0..<channelCount {
            let inPtr = input[ch]
            var state = upsampleState[ch]
            var outPtr = output.advanced(by: ch * frameCount * Self.upsampleFactor)

            for i in 0..<frameCount {
                let sample = inPtr[i]

                // Insert 3 zeros between samples for 4x upsampling
                for phase in 0..<Self.upsampleFactor {
                    let coeff = upsampleCoefficients[phase]
                    var acc: Float = 0

                    // FIR filter using polyphase coefficients
                    for tap in 0..<Self.filterTaps {
                        let stateIdx = (i * Self.upsampleFactor + phase - tap) % Self.filterTaps
                        if stateIdx >= 0 && stateIdx < state.count {
                            acc += state[stateIdx] * coeff[tap]
                        }
                    }

                    // Update state
                    for tap in stride(from: Self.filterTaps - 1, through: 1, by: -1) {
                        state[tap] = state[tap - 1]
                    }
                    state[0] = phase == 0 ? sample : 0

                    outPtr.pointee = acc + (phase == 0 ? sample * coeff[0] : 0)
                    outPtr = outPtr.advanced(by: 1)
                }
            }
            upsampleState[ch] = state
        }
    }

    /// Downsamples audio by 4x using polyphase FIR filtering.
    /// - Parameters:
    ///   - input: Input audio buffer (deinterleaved, 4× frame count)
    ///   - frameCount: Number of frames in output (input is 4× this)
    ///   - output: Output buffer (must have frameCount capacity)
    @inline(__always)
    func downsample(input: UnsafePointer<Float>, frameCount: Int, output: [UnsafeMutablePointer<Float>]) {
        guard enabled else {
            // Passthrough: copy input to output (decimate by 4)
            for ch in 0..<channelCount {
                let inPtr = input.advanced(by: ch * frameCount * Self.upsampleFactor)
                let outPtr = output[ch]
                for i in 0..<frameCount {
                    outPtr[i] = inPtr[i * Self.upsampleFactor]
                }
            }
            return
        }

        for ch in 0..<channelCount {
            let inPtr = input.advanced(by: ch * frameCount * Self.upsampleFactor)
            let outPtr = output[ch]
            var state = downsampleState[ch]

            for i in 0..<frameCount {
                var acc: Float = 0

                // FIR filter using polyphase coefficients
                for phase in 0..<Self.upsampleFactor {
                    let coeff = downsampleCoefficients[phase]
                    let sampleIdx = i * Self.upsampleFactor + phase

                    for tap in 0..<Self.filterTaps {
                        let stateIdx = (sampleIdx - tap) % Self.filterTaps
                        if stateIdx >= 0 && stateIdx < state.count {
                            acc += state[stateIdx] * coeff[tap]
                        }
                    }

                    // Update state
                    if sampleIdx < state.count {
                        state[sampleIdx % Self.filterTaps] = inPtr[sampleIdx]
                    }
                }

                outPtr[i] = acc
            }
            downsampleState[ch] = state
        }
    }

    // MARK: - Coefficient Generation

    private func generateCoefficients() {
        // Generate low-pass FIR filter coefficients for Nyquist/2 at upsampled rate
        // Cutoff at original Nyquist (sampleRate / 2) when upsampled to 4× sampleRate
        let cutoff = 0.5 / Double(Self.upsampleFactor)
        let nyquist = 0.5

        upsampleCoefficients = (0..<Self.phases).map { phase in
            (0..<Self.filterTaps).map { tap in
                let t = Double(tap) - Double(Self.filterTaps - 1) / 2.0
                let n = t + Double(phase) / Double(Self.phases)
                // Sinc windowed by Hamming
                let sinc = n == 0 ? 1.0 : sin(.pi * cutoff * n) / (.pi * cutoff * n)
                let hamming = 0.54 + 0.46 * cos(.pi * n / Double(Self.filterTaps))
                return Float(sinc * hamming)
            }
        }

        downsampleCoefficients = (0..<Self.phases).map { phase in
            (0..<Self.filterTaps).map { tap in
                let t = Double(tap) - Double(Self.filterTaps - 1) / 2.0
                let n = t + Double(phase) / Double(Self.phases)
                let sinc = n == 0 ? 1.0 : sin(.pi * cutoff * n) / (.pi * cutoff * n)
                let hamming = 0.54 + 0.46 * cos(.pi * n / Double(Self.filterTaps))
                return Float(sinc * hamming)
            }
        }
    }

    // MARK: - Buffer Allocation

    private func allocateBuffers() {
        upsampleState = (0..<channelCount).map { _ in Array(repeating: 0.0, count: Self.filterTaps) }
        downsampleState = (0..<channelCount).map { _ in Array(repeating: 0.0, count: Self.filterTaps) }
        let maxFrames = 512 // Maximum frame count per callback
        upsampledBuffer = Array(repeating: 0.0, count: maxFrames * Self.upsampleFactor * channelCount)
        downsampledBuffer = Array(repeating: 0.0, count: maxFrames * channelCount)
    }

    func resetState() {
        for i in 0..<upsampleState.count {
            for j in 0..<upsampleState[i].count {
                upsampleState[i][j] = 0
            }
        }
        for i in 0..<downsampleState.count {
            for j in 0..<downsampleState[i].count {
                downsampleState[i][j] = 0
            }
        }
    }
}
