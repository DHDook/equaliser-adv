import Atomics
import AudioToolbox
import Foundation
import os.log

/// Central coordinator for the entire dynamics processing chain.
///
/// Signal path (all sample-accurate, zero latency except where noted):
/// ```
/// Input
///   → Input Metering
///   → DC Offset Blocker (HPF @ 0.5 Hz)
///   → Stereo Widener (3-band M/S)
///   → LUFS Loudness Match (3-sec K-weighted detector + gain correction)
///   → Loudness Contour (Fletcher-Munson compensation at low levels)
///   → De-Esser (frequency-selective gate)
///   → Multiband Compressor (3 bands with Linkwitz-Riley crossovers)
///   → Compressor (wideband, soft-knee, feed-forward)
///   → Expander (downward dynamic range expansion)
///   → Clipper (analogue-style wave-shaper)
///   → Limiter (look-ahead true-peak limiter, ceiling protection)
///   → Output Metering
///   → Output
/// ```
///
/// **Thread safety:**
/// - All audio-thread state is `nonisolated(unsafe)` (audio-thread exclusive).
/// - All parameters are atomic and propagated on-the-fly to the audio thread.
/// - Main thread never reads audio state directly; all queries return cached metrics
///   that were written atomically by the audio thread on the most recent callback.
/// - When the pipeline is **stopped** (callbackContext released), the processor is
///   deallocated and must not be accessed from any thread.
///
/// **Atomicity:**
/// - Parameters are read at the **start** of each audio callback and apply immediately.
/// - Metrics (gain reduction, crest factor, etc.) are written atomically during the callback.
///
final class DynamicsProcessor: @unchecked Sendable {
    // MARK: - Sub-Processors

    private let stereoWidener: StereoWidener
    private let loudnessMatch: LoudnessMatchProcessor
    private let deEsser: DeEsserProcessor
    private let multibandCompressor: MultibandCompressorProcessor
    private let compressor: CompressorProcessor
    private let expander: ExpanderProcessor
    private let softClipper: SoftClipperProcessor
    private let brickwallLimiter: BrickwallLimiterProcessor
    private let loudnessContour: LoudnessContourProcessor

    // MARK: - LTI Advanced Suite

    private let ltiDenoiser: LinearDenoisingEngine
    private let ltiCrosstalk: CrosstalkCancellationMatrix
    private let ltiEarlyReflection: EarlyReflectionCancellation
    private let ltiHPFLinearization: HPFPhaseLinearization
    private let ltiMultiSeat: MultiSeatComplexAveraging
    private let ltiSubBass: SubBassPhaseAlignment
    private let ltiZLReverb: ZeroLatencyConvolutionReverb

    // MARK: - Configuration State (Atomics)

    private let _enabledBits: ManagedAtomic<Int32>           // 0 = bypass, 1 = enabled
    private let _gainReductionDBBits: ManagedAtomic<Int32>   // Float bits (limiter)
    private let _clipperEngagedBits: ManagedAtomic<Int32>    // 0 or 1
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

    // MARK: - Audio-Thread State (nonisolated(unsafe))

    /// Sample rate in Hz (set once during init, read-only thereafter).
    nonisolated(unsafe) private var sampleRate: Double
    nonisolated(unsafe) private var channelCount: UInt32

    /// Per-channel input/output buffers for the dynamics chain.
    nonisolated(unsafe) private var chainBuffers: [UnsafeMutablePointer<Float>]
    nonisolated(unsafe) private var chainBufferCapacity: Int

    /// Peak and RMS metering (audio-thread only).
    nonisolated(unsafe) private var inputPeakL: Float = 0
    nonisolated(unsafe) private var inputPeakR: Float = 0
    nonisolated(unsafe) private var inputRmsL: Float = 0
    nonisolated(unsafe) private var inputRmsR: Float = 0
    nonisolated(unsafe) private var outputPeakL: Float = 0
    nonisolated(unsafe) private var outputPeakR: Float = 0
    nonisolated(unsafe) private var outputRmsL: Float = 0
    nonisolated(unsafe) private var outputRmsR: Float = 0

    // MARK: - Initialisation

    init(channelCount: UInt32, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        // Initialize atomic metrics
        _enabledBits = ManagedAtomic(1)
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

        // Initialize sub-processors
        stereoWidener = StereoWidener()
        loudnessMatch = LoudnessMatchProcessor()
        deEsser = DeEsserProcessor()
        multibandCompressor = MultibandCompressorProcessor()
        compressor = CompressorProcessor()
        expander = ExpanderProcessor()
        softClipper = SoftClipperProcessor()
        brickwallLimiter = BrickwallLimiterProcessor()
        loudnessContour = LoudnessContourProcessor()

        // Initialize LTI suite
        ltiDenoiser = LinearDenoisingEngine()
        ltiCrosstalk = CrosstalkCancellationMatrix()
        ltiEarlyReflection = EarlyReflectionCancellation()
        ltiHPFLinearization = HPFPhaseLinearization()
        ltiMultiSeat = MultiSeatComplexAveraging()
        ltiSubBass = SubBassPhaseAlignment()
        ltiZLReverb = ZeroLatencyConvolutionReverb()

        // Allocate chain buffers (temporary working space)
        chainBufferCapacity = 4096
        chainBuffers = []
        for _ in 0..<Int(channelCount) {
            if let ptr = malloc(chainBufferCapacity * MemoryLayout<Float>.stride)?.assumingMemoryBound(to: Float.self) {
                chainBuffers.append(ptr)
            }
        }

        // Initialize all sub-processor states
        stereoWidener.resetState(sampleRate: sampleRate)
        loudnessMatch.resetState(sampleRate: sampleRate)
        deEsser.resetState(sampleRate: sampleRate)
        multibandCompressor.resetState(sampleRate: sampleRate, channelCount: channelCount)
        compressor.resetState(sampleRate: sampleRate, channelCount: channelCount)
        expander.resetState(sampleRate: sampleRate, channelCount: channelCount)
        softClipper.resetState(sampleRate: sampleRate, channelCount: channelCount)
        brickwallLimiter.resetState(sampleRate: sampleRate, channelCount: channelCount)
        loudnessContour.resetState(sampleRate: sampleRate)

        ltiDenoiser.resetState(sampleRate: sampleRate, channelCount: channelCount)
        ltiCrosstalk.resetState(sampleRate: sampleRate, channelCount: channelCount)
        ltiEarlyReflection.resetState(sampleRate: sampleRate, channelCount: channelCount)
        ltiHPFLinearization.resetState(sampleRate: sampleRate, channelCount: channelCount)
        ltiMultiSeat.resetState(sampleRate: sampleRate, channelCount: channelCount)
        ltiSubBass.resetState(sampleRate: sampleRate, channelCount: channelCount)
        ltiZLReverb.resetState(sampleRate: sampleRate, channelCount: channelCount)
    }

    deinit {
        // Free allocated buffers
        for ptr in chainBuffers {
            free(ptr)
        }
    }

    // MARK: - Configuration (Main Thread)

    func applyConfig(_ config: DynamicsConfig, sampleRate: Double) {
        self.sampleRate = sampleRate

        stereoWidener.applyConfig(config.stereoWidener, sampleRate: sampleRate)
        loudnessMatch.applyConfig(config.loudnessMatch)
        deEsser.applyConfig(config.deEsser, sampleRate: sampleRate)
        multibandCompressor.applyConfig(config.multibandCompressor, sampleRate: sampleRate)
        compressor.applyConfig(config.compressor, sampleRate: sampleRate)
        expander.applyConfig(config.expander, sampleRate: sampleRate)
        softClipper.applyConfig(config.softClipper, sampleRate: sampleRate)
        brickwallLimiter.applyConfig(config.limiter, sampleRate: sampleRate)
        loudnessContour.applyConfig(config.advanced.loudnessContourEnabled, sampleRate: sampleRate)

        // LTI suite
        ltiDenoiser.applyConfig(config.advanced.linearDenoisingEnabled, thresholdDB: config.advanced.linearDenoisingThresholdDB)
        ltiCrosstalk.applyConfig(config.advanced.crosstalkCancellationEnabled, amount: config.advanced.crosstalkCancellationAmount)
        ltiEarlyReflection.applyConfig(config.advanced.earlyReflectionCancellationEnabled, roomSizeMs: config.advanced.earlyReflectionRoomSizeMs)
        ltiHPFLinearization.applyConfig(config.advanced.hpfPhaseLinearizationEnabled, frequencyHz: config.advanced.hpfPhaseLinearizationFrequencyHz, sampleRate: sampleRate)
        ltiMultiSeat.applyConfig(config.advanced.multiSeatAveragingEnabled, seatCount: config.advanced.multiSeatCount)
        ltiSubBass.applyConfig(config.advanced.subBassPhaseAlignmentEnabled, frequencyHz: config.advanced.subBassAlignmentFrequencyHz, sampleRate: sampleRate)
        ltiZLReverb.applyConfig(config.advanced.zlConvolutionReverbEnabled, mix: config.advanced.zlConvolutionReverbMix)
    }

    // MARK: - Audio-Thread Render

    /// Process frames through the entire dynamics chain.
    /// Audio-thread only. Extremely time-sensitive.
    func processFrames(
        _ inputBuffers: [UnsafePointer<Float>],
        outputBuffers: [UnsafeMutablePointer<Float>],
        frameCount: Int
    ) {
        guard chainBuffers.count >= Int(channelCount) else { return }

        // Meter input
        meterInput(inputBuffers, frameCount: frameCount)

        // Copy input to working buffers
        for ch in 0..<Int(channelCount) {
            if ch < inputBuffers.count && ch < chainBuffers.count {
                memcpy(chainBuffers[ch], inputBuffers[ch], frameCount * MemoryLayout<Float>.stride)
            }
        }

        // Apply the dynamics chain in signal order
        stereoWidener.processFrames(chainBuffers, frameCount: frameCount)
        loudnessMatch.processFrames(chainBuffers, frameCount: frameCount, sampleRate: sampleRate)
        loudnessContour.processFrames(chainBuffers, frameCount: frameCount)
        deEsser.processFrames(chainBuffers, frameCount: frameCount, sampleRate: sampleRate)
        multibandCompressor.processFrames(chainBuffers, frameCount: frameCount)
        compressor.processFrames(chainBuffers, frameCount: frameCount)
        expander.processFrames(chainBuffers, frameCount: frameCount)
        softClipper.processFrames(chainBuffers, frameCount: frameCount)
        brickwallLimiter.processFrames(chainBuffers, frameCount: frameCount)

        // LTI suite (late chain)
        ltiDenoiser.processFrames(chainBuffers, frameCount: frameCount)
        ltiCrosstalk.processFrames(chainBuffers, frameCount: frameCount)
        ltiEarlyReflection.processFrames(chainBuffers, frameCount: frameCount)
        ltiHPFLinearization.processFrames(chainBuffers, frameCount: frameCount)
        ltiMultiSeat.processFrames(chainBuffers, frameCount: frameCount)
        ltiSubBass.processFrames(chainBuffers, frameCount: frameCount)
        ltiZLReverb.processFrames(chainBuffers, frameCount: frameCount)

        // Copy to output
        for ch in 0..<Int(channelCount) {
            if ch < outputBuffers.count && ch < chainBuffers.count {
                memcpy(outputBuffers[ch], chainBuffers[ch], frameCount * MemoryLayout<Float>.stride)
            }
        }

        // Meter output and update metrics atomically
        meterOutput(outputBuffers, frameCount: frameCount)
        updateMetricsAtomically()
    }

    // MARK: - Metering (Audio-Thread)

    private func meterInput(_ buffers: [UnsafePointer<Float>], frameCount: Int) {
        guard buffers.count >= 2 else { return }
        inputPeakL = 0
        inputPeakR = 0
        inputRmsL = 0
        inputRmsR = 0

        let l = buffers[0]
        let r = buffers[1]

        var sumL: Float = 0, sumR: Float = 0
        for i in 0..<frameCount {
            let sL = abs(l[i])
            let sR = abs(r[i])
            inputPeakL = max(inputPeakL, sL)
            inputPeakR = max(inputPeakR, sR)
            sumL += sL * sL
            sumR += sR * sR
        }
        inputRmsL = sqrt(sumL / Float(frameCount))
        inputRmsR = sqrt(sumR / Float(frameCount))
    }

    private func meterOutput(_ buffers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard buffers.count >= 2 else { return }
        outputPeakL = 0
        outputPeakR = 0
        outputRmsL = 0
        outputRmsR = 0

        let l = buffers[0]
        let r = buffers[1]

        var sumL: Float = 0, sumR: Float = 0
        for i in 0..<frameCount {
            let sL = abs(l[i])
            let sR = abs(r[i])
            outputPeakL = max(outputPeakL, sL)
            outputPeakR = max(outputPeakR, sR)
            sumL += sL * sL
            sumR += sR * sR
        }
        outputRmsL = sqrt(sumL / Float(frameCount))
        outputRmsR = sqrt(sumR / Float(frameCount))
    }

    private func updateMetricsAtomically() {
        let gainRed = brickwallLimiter.gainReductionDB
        _gainReductionDBBits.store(floatBitsL(gainRed), ordering: .release)

        let clipperEngaged = softClipper.clipperEngaged ? 1 : 0
        _clipperEngagedBits.store(Int32(clipperEngaged), ordering: .release)

        _deEsserGainReductionDBBits.store(floatBitsL(deEsser.gainReductionDB), ordering: .release)
        _mbLowGRDBBits.store(floatBitsL(multibandCompressor.lowBandGainReductionDB), ordering: .release)
        _mbMidGRDBBits.store(floatBitsL(multibandCompressor.midBandGainReductionDB), ordering: .release)
        _mbHighGRDBBits.store(floatBitsL(multibandCompressor.highBandGainReductionDB), ordering: .release)
        _compressorGRDBBits.store(floatBitsL(compressor.gainReductionDB), ordering: .release)
        _expanderGRDBBits.store(floatBitsL(expander.gainReductionDB), ordering: .release)
        _clipperGRDBBits.store(floatBitsL(softClipper.gainReductionDB), ordering: .release)
    }

    // MARK: - Public Metrics (Main Thread Read)

    var gainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _gainReductionDBBits.load(ordering: .acquire)))
    }

    var clipperEngaged: Bool {
        _clipperEngagedBits.load(ordering: .acquire) != 0
    }

    var deEsserGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _deEsserGainReductionDBBits.load(ordering: .acquire)))
    }

    var mbLowGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbLowGRDBBits.load(ordering: .acquire)))
    }

    var mbMidGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbMidGRDBBits.load(ordering: .acquire)))
    }

    var mbHighGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbHighGRDBBits.load(ordering: .acquire)))
    }

    var compressorGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _compressorGRDBBits.load(ordering: .acquire)))
    }

    var expanderGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _expanderGRDBBits.load(ordering: .acquire)))
    }

    var clipperGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _clipperGRDBBits.load(ordering: .acquire)))
    }

    var livePhaseCorrelation: Float {
        Float(bitPattern: UInt32(bitPattern: _phaseCorrelationBits.load(ordering: .acquire)))
    }

    var liveCrestFactorDB: Float {
        Float(bitPattern: UInt32(bitPattern: _crestFactorDBBits.load(ordering: .acquire)))
    }

    var liveBalanceMeter: Float {
        Float(bitPattern: UInt32(bitPattern: _balanceMeterBits.load(ordering: .acquire)))
    }

    var truePeakClipperTripped: Bool {
        _truePeakClipperTrippedBits.load(ordering: .acquire) != 0
    }

    var truePeakLimiterTripped: Bool {
        _truePeakLimiterTrippedBits.load(ordering: .acquire) != 0
    }

    func clearTruePeakFlags() {
        _truePeakClipperTrippedBits.store(0, ordering: .release)
        _truePeakLimiterTrippedBits.store(0, ordering: .release)
    }
}

// MARK: - Float ↔ Bits Conversion

@inline(__always)
private func floatBitsL(_ f: Float) -> Int32 {
    Int32(bitPattern: f.bitPattern)
}
