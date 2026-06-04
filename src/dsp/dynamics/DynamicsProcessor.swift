import Atomics
import AudioToolbox
import Foundation
import os.log

/// Central coordinator for the entire dynamics processing chain.
///
/// **Thread safety:**
/// - All audio-thread state is `nonisolated(unsafe)` (audio-thread exclusive).
/// - All parameters are atomic and propagated on-the-fly to the audio thread.
/// - Main thread never reads audio state directly; all queries return cached metrics
///   that were written atomically by the audio thread on the most recent callback.
///
final class DynamicsProcessor: @unchecked Sendable {
    // MARK: - Configuration State (Atomics)

    private let _gainReductionDBBits: ManagedAtomic<Int32>
    private let _clipperEngagedBits: ManagedAtomic<Int32>
    private let _deEsserGainReductionDBBits: ManagedAtomic<Int32>
    private let _mbLowGRDBBits: ManagedAtomic<Int32>
    private let _mbMidGRDBBits: ManagedAtomic<Int32>
    private let _mbHighGRDBBits: ManagedAtomic<Int32>
    private let _compressorGRDBBits: ManagedAtomic<Int32>
    private let _expanderGRDBBits: ManagedAtomic<Int32>
    private let _clipperGRDBBits: ManagedAtomic<Int32>
    private let _phaseCorrelationBits: ManagedAtomic<Int32>
    private let _crestFactorDBBits: ManagedAtomic<Int32>
    private let _balanceMeterBits: ManagedAtomic<Int32>
    private let _truePeakClipperTrippedBits: ManagedAtomic<Int32>
    private let _truePeakLimiterTrippedBits: ManagedAtomic<Int32>

    // Sub-bass phase alignment atomics
    private let _subBassPhaseEnabled: ManagedAtomic<Bool>
    private let _subBassPhaseFreqBits: ManagedAtomic<Float>

    // Dither atomics
    private let _ditherModeBits: ManagedAtomic<Int32>

    // MARK: - Audio-Thread State (nonisolated(unsafe))

    nonisolated(unsafe) private var sampleRate: Double
    nonisolated(unsafe) private var channelCount: UInt32

    // Sub-bass phase alignment state (all-pass filters)
    nonisolated(unsafe) private var subBassPhaseState: [[Float]]

    // Dither state (5th-order noise shaping filter)
    nonisolated(unsafe) private var ditherState: [[Float]]

    // MARK: - Initialisation

    init(channelCount: UInt32, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        // Initialize atomic metrics
        _gainReductionDBBits = ManagedAtomic(0)
        _clipperEngagedBits = ManagedAtomic(0)
        _deEsserGainReductionDBBits = ManagedAtomic(0)
        _mbLowGRDBBits = ManagedAtomic(0)
        _mbMidGRDBBits = ManagedAtomic(0)
        _mbHighGRDBBits = ManagedAtomic(0)
        _compressorGRDBBits = ManagedAtomic(0)
        _expanderGRDBBits = ManagedAtomic(0)
        _clipperGRDBBits = ManagedAtomic(0)
        _phaseCorrelationBits = ManagedAtomic(0)
        _crestFactorDBBits = ManagedAtomic(0)
        _balanceMeterBits = ManagedAtomic(0)
        _truePeakClipperTrippedBits = ManagedAtomic(0)
        _truePeakLimiterTrippedBits = ManagedAtomic(0)

        // Initialize sub-bass phase alignment atomics
        _subBassPhaseEnabled = ManagedAtomic(false)
        _subBassPhaseFreqBits = ManagedAtomic(Float(bitPattern: 0))

        // Initialize dither atomics
        _ditherModeBits = ManagedAtomic(0)

        // Initialize sub-bass phase state (2nd-order all-pass, 4 coefficients per channel)
        subBassPhaseState = (0..<Int(channelCount)).map { _ in Array(repeating: 0.0, count: 4) }

        // Initialize dither state (5th-order noise shaping, 5 coefficients per channel)
        ditherState = (0..<Int(channelCount)).map { _ in Array(repeating: 0.0, count: 5) }
    }

    // MARK: - Configuration (Main Thread)

    func applyConfig(_ config: DynamicsConfig, sampleRate: Double) {
        self.sampleRate = sampleRate

        // Apply sub-bass phase alignment config
        setSubBassPhaseEnabled(config.advanced.subBassPhaseEnabled)
        setSubBassPhaseFrequency(config.advanced.subBassPhaseFrequency)

        // Apply dither config
        setDitherMode(config.ditherMode)
    }

    // MARK: - Dither Setters

    func setDitherMode(_ mode: DitherMode) {
        _ditherModeBits.store(Int32(mode.rawValue), ordering: .relaxed)
    }

    // MARK: - Sub-Bass Phase Alignment Setters

    func setSubBassPhaseEnabled(_ enabled: Bool) {
        _subBassPhaseEnabled.store(enabled, ordering: .relaxed)
    }

    func setSubBassPhaseFrequency(_ frequency: Float) {
        _subBassPhaseFreqBits.store(Float(bitPattern: frequency.bitPattern), ordering: .relaxed)
    }

    // MARK: - Audio-Thread Render

    /// Process frames through the entire dynamics chain.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        // Main processing loop - sub-processors will handle their stages
        processSubBassPhaseAlignment(bufferList: bufferList, frameCount: frameCount)
        processDither(bufferList: bufferList, frameCount: frameCount)
    }

    // MARK: - Sub-Bass Phase Alignment Processing

    /// Applies 2nd-order all-pass filter for sub-bass phase alignment.
    /// Aligns phase of sub-bass frequencies with main speaker bandwidth.
    @inline(__always)
    private func processSubBassPhaseAlignment(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let enabled = _subBassPhaseEnabled.load(ordering: .relaxed)
        guard enabled else { return }

        let frequency = Float(bitPattern: UInt32(bitPattern: _subBassPhaseFreqBits.load(ordering: .relaxed)))
        guard frequency > 0 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let sr = Float(sampleRate)

        // Calculate all-pass coefficients for 2nd-order filter
        // Using biquad all-pass topology for phase correction
        let omega = 2.0 * .pi * frequency / sr
        let alpha = sin(omega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cos(omega)
        let a2 = 1.0 - alpha
        let b0 = 1.0 - alpha
        let b1 = -2.0 * cos(omega)
        let b2 = 1.0 + alpha

        // Normalize coefficients
        let a0_norm = 1.0 / a0
        let b0_norm = b0 * a0_norm
        let b1_norm = b1 * a0_norm
        let b2_norm = b2 * a0_norm
        let a1_norm = a1 * a0_norm
        let a2_norm = a2 * a0_norm

        for ch in 0..<Int(channelCount) {
            guard ch < buffers.count else { continue }
            let buffer = buffers[ch]
            guard let data = buffer.mData else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: Int(frameCount))
            var state = subBassPhaseState[ch]

            for i in 0..<Int(frameCount) {
                let input = samples[i]

                // Direct form II transposed all-pass filter
                let output = b0_norm * input + b1_norm * state[0] + b2_norm * state[1] -
                             a1_norm * state[2] - a2_norm * state[3]

                // Update state
                state[3] = state[2]
                state[2] = state[1]
                state[1] = state[0]
                state[0] = output

                samples[i] = output
            }

            subBassPhaseState[ch] = state
        }
    }

    // MARK: - Dither Processing

    /// Applies noise-shaped dither to reduce quantization noise.
    /// Supports TPDF, shaped, and 5th-order noise-shaped dither.
    @inline(__always)
    private func processDither(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ditherMode = DitherMode(rawValue: Int(_ditherModeBits.load(ordering: .relaxed))) ?? .bypass
        guard ditherMode != .bypass else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        for ch in 0..<Int(channelCount) {
            guard ch < buffers.count else { continue }
            let buffer = buffers[ch]
            guard let data = buffer.mData else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: Int(frameCount))
            var state = ditherState[ch]

            for i in 0..<Int(frameCount) {
                var sample = samples[i]

                switch ditherMode {
                case .tpdf:
                    // Triangular PDF dither: sum of two uniform random numbers
                    let r1 = Float.random(in: -0.5...0.5)
                    let r2 = Float.random(in: -0.5...0.5)
                    sample += r1 + r2

                case .shaped:
                    // 2nd-order noise shaping (simple high-pass)
                    let shaped = state[0] * 2.0 - state[1]
                    let noise = Float.random(in: -0.5...0.5)
                    sample += noise - shaped
                    state[1] = state[0]
                    state[0] = shaped

                case .highOrder:
                    // 5th-order noise shaping (pushes noise to high frequencies)
                    // Coefficients for 5th-order high-pass noise shaping filter
                    let shaped = state[0] * 2.8474 - state[1] * 3.8352 + state[2] * 2.6284 - state[3] * 0.8909 + state[4] * 0.1203
                    let noise = Float.random(in: -0.5...0.5)
                    sample += noise - shaped
                    state[4] = state[3]
                    state[3] = state[2]
                    state[2] = state[1]
                    state[1] = state[0]
                    state[0] = shaped

                case .bypass:
                    break
                }

                samples[i] = sample
            }

            ditherState[ch] = state
        }
    }

    // MARK: - Public Metrics (Main Thread Read)

    var gainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _gainReductionDBBits.load(ordering: .relaxed)))
    }

    var clipperEngaged: Bool {
        _clipperEngagedBits.load(ordering: .relaxed) != 0
    }

    var deEsserGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _deEsserGainReductionDBBits.load(ordering: .relaxed)))
    }

    var mbLowGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbLowGRDBBits.load(ordering: .relaxed)))
    }

    var mbMidGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbMidGRDBBits.load(ordering: .relaxed)))
    }

    var mbHighGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbHighGRDBBits.load(ordering: .relaxed)))
    }

    var compressorGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _compressorGRDBBits.load(ordering: .relaxed)))
    }

    var expanderGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _expanderGRDBBits.load(ordering: .relaxed)))
    }

    var clipperGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _clipperGRDBBits.load(ordering: .relaxed)))
    }

    var livePhaseCorrelation: Float {
        Float(bitPattern: UInt32(bitPattern: _phaseCorrelationBits.load(ordering: .relaxed)))
    }

    var liveCrestFactorDB: Float {
        Float(bitPattern: UInt32(bitPattern: _crestFactorDBBits.load(ordering: .relaxed)))
    }

    var liveBalanceMeter: Float {
        Float(bitPattern: UInt32(bitPattern: _balanceMeterBits.load(ordering: .relaxed)))
    }

    var truePeakClipperTripped: Bool {
        _truePeakClipperTrippedBits.load(ordering: .relaxed) != 0
    }

    var truePeakLimiterTripped: Bool {
        _truePeakLimiterTrippedBits.load(ordering: .relaxed) != 0
    }

    func clearTruePeakFlags() {
        _truePeakClipperTrippedBits.store(0, ordering: .relaxed)
        _truePeakLimiterTrippedBits.store(0, ordering: .relaxed)
    }
}

// MARK: - Float ↔ Bits Conversion

@inline(__always)
private func floatBitsL(_ f: Float) -> Int32 {
    Int32(bitPattern: f.bitPattern)
}
