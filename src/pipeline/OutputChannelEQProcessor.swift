import Foundation
import Accelerate
import Atomics

/// Per-output EQ processor. Mirrors RenderCallbackContext.processEQ exactly
/// for stereo-capable sources. Restricted modes apply for mono/sub sources.
final class OutputChannelEQProcessor {

    // MARK: - EQ Chain Arrays (mirroring RenderCallbackContext)
    // maxLayerCount = EQLayerConstants.maxLayerCount (3).
    // Layer 0: user EQ. Layer 1: reserved for future per-output room correction.
    let leftEQChains:  [EQChain]
    let rightEQChains: [EQChain]

    // MARK: - Phase Mode Infrastructure
    // Allocated for all output types; only activated when capabilities allow.
    private nonisolated(unsafe) var linearPhaseEngine: LinearPhaseEQEngine
    private nonisolated(unsafe) var leftAllPassChain:  AllPassChain
    private nonisolated(unsafe) var rightAllPassChain: AllPassChain
    private let _linearPhaseEnabled  = ManagedAtomic<Int32>(0)
    private let _mixedPhaseEnabled   = ManagedAtomic<Int32>(0)
    private let _midSideEnabled      = ManagedAtomic<Int32>(0)
    /// Pre-ringing blend (Float bit-cast). 0.0 = pure linear-phase, 1.0 = pure minimum-phase.
    /// Active only when _linearPhaseEnabled == 1.
    private let _preRingingBlendBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(0.0).bitPattern))

    // MARK: - Processing Mode (mirrors RenderPipeline.processingMode semantics)
    // 0 = full bypass (isBypassed)
    // 1 = normal EQ processing
    // 2 = flat / gains-only (CompareMode.flat)
    nonisolated(unsafe) var processingMode: Int32 = 1

    // MARK: - Delta Monitoring
    // Pre-EQ signal is captured in deltaBufs; subtracted post-EQ to produce difference signal.
    // Mirrors DynamicsProcessor.captureDeltaInput / processDeltaSolo.
    private nonisolated(unsafe) var deltaBufs: [UnsafeMutablePointer<Float>]
    private let _deltaSoloEnabled = ManagedAtomic<Int32>(0)

    // MARK: - Gain (mirrors RenderCallbackContext gain ramp pattern)
    nonisolated(unsafe) var inputGainLinear:  Float = 1.0
    nonisolated(unsafe) var outputGainLinear: Float = 1.0
    private let _targetInputGainBits  = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))
    private let _targetOutputGainBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))

    // MARK: - Capabilities (immutable after init)
    let capabilities: OutputChannelEQCapabilities

    // MARK: - FIR Crossover Promotion Flag
    // Published for UI badge display.
    // True when the FIR crossover auto-promotion from .eq → .linearEQ is active.
    let _firPromotedToLinear = ManagedAtomic<Bool>(false)

    // MARK: - Sample Rate
    private var currentSampleRate: Double

    // MARK: - Init

    init(source: SignalSource, maxFrameCount: Int, sampleRate: Double) {
        capabilities = .capabilities(for: source)
        currentSampleRate = sampleRate
        let layerCount = EQLayerConstants.maxLayerCount
        leftEQChains  = (0..<layerCount).map { _ in EQChain(maxFrameCount: UInt32(maxFrameCount)) }
        rightEQChains = (0..<layerCount).map { _ in EQChain(maxFrameCount: UInt32(maxFrameCount)) }
        linearPhaseEngine = LinearPhaseEQEngine(maxFrameCount: maxFrameCount)
        leftAllPassChain  = AllPassChain()
        rightAllPassChain = AllPassChain()
        deltaBufs = (0..<2).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        }
    }

    deinit {
        deltaBufs.forEach { $0.deallocate() }
    }

    // MARK: - Main Thread Configuration

    /// Apply a new EQ configuration. Mirrors EQCoefficientStager.reapplyConfiguration().
    func applyEQConfig(_ config: OutputChannelEQConfig, sampleRate: Double) {
        currentSampleRate = sampleRate

        // 1. Update EQ chains (left chain layer 0 = user bands)
        let leftConfig  = bandConfigs(for: config, channel: .left)
        let rightConfig = bandConfigs(for: config, channel: .right)
        stageChainUpdate(chains: leftEQChains,  bands: leftConfig,  sampleRate: sampleRate)
        stageChainUpdate(chains: rightEQChains, bands: rightConfig, sampleRate: sampleRate)

        // 2. Update processing mode
        updateProcessingMode(config: config)

        // 3. Update phase engines if applicable
        if capabilities.supportsAdvancedPhase {
            if config.compareMode == .linearEQ || config.compareMode == .mixedPhase {
                refreshLinearPhaseIR(config: config, sampleRate: sampleRate)
            }
            if config.compareMode == .mixedPhase {
                refreshMixedPhaseIR(config: config, sampleRate: sampleRate)
            }
        }

        // 4. Update gains
        let inLinear  = AudioMath.dbToLinear(config.inputGainDB)
        let outLinear = AudioMath.dbToLinear(config.outputGainDB)
        _targetInputGainBits.store(Int32(bitPattern: inLinear.bitPattern), ordering: .releasing)
        _targetOutputGainBits.store(Int32(bitPattern: outLinear.bitPattern), ordering: .releasing)

        // 5. Delta solo
        if capabilities.supportsDeltaMode {
            _deltaSoloEnabled.store(config.compareMode == .delta ? 1 : 0, ordering: .releasing)
        }
    }

    /// Mirrors EqualiserStore.flattenBands():
    /// Sets all band gains to 0 dB, resets input/output gains.
    /// Returns the modified config for the caller to persist.
    func flattenBands(config: inout OutputChannelEQConfig) {
        for i in 0..<config.activeBandCount {
            config.bands[i].gain = 0.0
        }
        config.inputGainDB  = 0.0
        config.outputGainDB = 0.0
        config.isBypassed   = false
        applyEQConfig(config, sampleRate: currentSampleRate)
    }

    // MARK: - Audio Thread Processing

    /// Process left (and optionally right) buffers in-place.
    /// For mono sources: rightBuf must be nil.
    /// Mirrors RenderCallbackContext.processEQ exactly.
    @inline(__always)
    func process(
        leftBuf:    UnsafeMutablePointer<Float>,
        rightBuf:   UnsafeMutablePointer<Float>?,
        frameCount: UInt32
    ) {
        let isStereo = rightBuf != nil

        // Apply input gain ramp (mirrors RenderPipeline output callback gain ramp)
        applyGainRamp(to: leftBuf, frameCount: Int(frameCount), currentGain: &inputGainLinear,
                      targetBits: _targetInputGainBits)
        if isStereo, let r = rightBuf {
            applyGainRamp(to: r, frameCount: Int(frameCount), currentGain: &inputGainLinear,
                          targetBits: _targetInputGainBits)
        }

        // Full bypass — skip all EQ processing
        guard processingMode != 0 else { return }

        // Capture pre-EQ signal for delta solo
        let deltaOn = _deltaSoloEnabled.load(ordering: .relaxed) != 0
        if deltaOn {
            captureDelta(leftBuf: leftBuf, rightBuf: rightBuf, frameCount: Int(frameCount))
        }

        // Flat mode (mode = 2): skip EQ, apply gains only
        if processingMode == 2 {
            applyOutputGainRamp(leftBuf: leftBuf, rightBuf: rightBuf, frameCount: Int(frameCount))
            return
        }

        // Normal processing (mode = 1):

        // M/S encode (stereo capable + midSide mode)
        let midSideOn = _midSideEnabled.load(ordering: .relaxed) != 0 && isStereo
        if midSideOn, let r = rightBuf {
            encodeMidSide(left: leftBuf, right: r, frameCount: Int(frameCount))
        }

        // EQ chain dispatch — mirrors processEQ phase mode switch exactly
        if _linearPhaseEnabled.load(ordering: .relaxed) != 0 {
            // TODO: Implement setPreRingingBlend in LinearPhaseEQEngine
            // let blend = Float(bitPattern: UInt32(bitPattern: _preRingingBlendBits.load(ordering: .relaxed)))
            // if blend > 0.001 {
            //     linearPhaseEngine.setPreRingingBlend(blend)
            // }
            linearPhaseEngine.process(bufL: leftBuf, bufR: rightBuf, frameCount: Int(frameCount))
        } else if _mixedPhaseEnabled.load(ordering: .relaxed) != 0 {
            // IIR biquad
            processChains(leftEQChains,  buffer: leftBuf, frameCount: frameCount)
            if isStereo, let r = rightBuf {
                processChains(rightEQChains, buffer: r, frameCount: frameCount)
            }
            // All-pass phase complement
            leftAllPassChain.applyPendingUpdates()
            leftAllPassChain.process(buffer: leftBuf, frameCount: frameCount)
            if isStereo, let r = rightBuf {
                rightAllPassChain.applyPendingUpdates()
                rightAllPassChain.process(buffer: r, frameCount: frameCount)
            }
        } else {
            // Standard IIR biquad
            processChains(leftEQChains, buffer: leftBuf, frameCount: frameCount)
            if isStereo, let r = rightBuf {
                processChains(rightEQChains, buffer: r, frameCount: frameCount)
            }
        }

        // M/S decode
        if midSideOn, let r = rightBuf {
            decodeMidSide(left: leftBuf, right: r, frameCount: Int(frameCount))
        }

        // Delta subtraction: output − input = EQ difference signal
        if deltaOn {
            subtractDelta(leftBuf: leftBuf, rightBuf: rightBuf, frameCount: Int(frameCount))
        }

        applyOutputGainRamp(leftBuf: leftBuf, rightBuf: rightBuf, frameCount: Int(frameCount))
    }

    // MARK: - Private Helpers

    @inline(__always)
    private func processChains(_ chains: [EQChain], buffer: UnsafeMutablePointer<Float>, frameCount: UInt32) {
        for chain in chains {
            chain.applyPendingUpdates()
            chain.process(buffer: buffer, frameCount: frameCount)
        }
    }

    @inline(__always)
    private func encodeMidSide(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Mid  = 0.5 * (L + R) → left buffer
        // Side = 0.5 * (L − R) → right buffer
        for i in 0..<frameCount {
            let l = left[i], r = right[i]
            left[i]  = 0.5 * (l + r)
            right[i] = 0.5 * (l - r)
        }
    }

    @inline(__always)
    private func decodeMidSide(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        // L = Mid + Side
        // R = Mid − Side
        for i in 0..<frameCount {
            let m = left[i], s = right[i]
            left[i]  = m + s
            right[i] = m - s
        }
    }

    private func captureDelta(leftBuf: UnsafeMutablePointer<Float>,
                              rightBuf: UnsafeMutablePointer<Float>?,
                              frameCount: Int) {
        memcpy(deltaBufs[0], leftBuf,  frameCount * MemoryLayout<Float>.size)
        if let r = rightBuf { memcpy(deltaBufs[1], r, frameCount * MemoryLayout<Float>.size) }
    }

    private func subtractDelta(leftBuf: UnsafeMutablePointer<Float>,
                               rightBuf: UnsafeMutablePointer<Float>?,
                               frameCount: Int) {
        for i in 0..<frameCount { leftBuf[i] -= deltaBufs[0][i] }
        if let r = rightBuf { for i in 0..<frameCount { r[i] -= deltaBufs[1][i] } }
    }

    /// Maps CompareMode + ChannelMode + isBypassed → processingMode Int32.
    /// Mirrors RenderPipeline.updateProcessingMode exactly.
    ///
    /// FIR crossover interaction (item 2):
    /// When config.firCrossoverIsActive is true and compareMode is .eq (the factory default),
    /// the method automatically promotes compareMode to .linearEQ to preserve the crossover's
    /// linear-phase behaviour. The user can override by explicitly choosing .eq or .mixedPhase.
    /// This promotion is logged so the UI can show the "FIR active — using linear phase" badge.
    private func updateProcessingMode(config: OutputChannelEQConfig) {
        // Resolve effective compare mode (FIR crossover promotion)
        let effectiveCompareMode: CompareMode
        if config.firCrossoverIsActive && config.compareMode == .eq &&
           capabilities.supportsAdvancedPhase {
            effectiveCompareMode = .linearEQ
            // Signal to UI that auto-promotion occurred
            _firPromotedToLinear.store(true, ordering: .releasing)
        } else {
            effectiveCompareMode = config.compareMode
            _firPromotedToLinear.store(false, ordering: .releasing)
        }

        if config.isBypassed {
            processingMode = 0
        } else if effectiveCompareMode == .flat {
            processingMode = 2
        } else {
            processingMode = 1
        }
        let canMS = capabilities.supportsChannelModes
        let canPhase = capabilities.supportsAdvancedPhase
        setLinearPhaseEnabled(canPhase && effectiveCompareMode == .linearEQ && !config.isBypassed)
        setMixedPhaseEnabled(canPhase && effectiveCompareMode == .mixedPhase && !config.isBypassed)
        setMidSideEnabled(canMS && config.channelMode == .midSide && !config.isBypassed)
    }

    private func bandConfigs(for config: OutputChannelEQConfig, channel: Channel) -> [EQBandConfiguration] {
        // For linked mode: return config.bands for both channels.
        // For stereo/midSide: return left-specific or right-specific band configs.
        // Mirror the exact storage pattern from EQConfiguration.leftBands / rightBands.
        // For now, use config.bands for all channels (linked mode only).
        // TODO: Add leftBands/rightBands to OutputChannelEQConfig for stereo/MS support.
        return config.bands
    }

    private func stageChainUpdate(chains: [EQChain], bands: [EQBandConfiguration], sampleRate: Double) {
        // TODO: Implement band staging similar to EQCoefficientStager
        // For now, this is a placeholder
    }

    private func refreshLinearPhaseIR(config: OutputChannelEQConfig, sampleRate: Double) {
        // TODO: Implement linear phase IR refresh
    }

    private func refreshMixedPhaseIR(config: OutputChannelEQConfig, sampleRate: Double) {
        // TODO: Implement mixed phase IR refresh
    }

    private func setLinearPhaseEnabled(_ enabled: Bool) {
        _linearPhaseEnabled.store(enabled ? 1 : 0, ordering: .releasing)
    }

    private func setMixedPhaseEnabled(_ enabled: Bool) {
        _mixedPhaseEnabled.store(enabled ? 1 : 0, ordering: .releasing)
    }

    private func setMidSideEnabled(_ enabled: Bool) {
        _midSideEnabled.store(enabled ? 1 : 0, ordering: .releasing)
    }

    @inline(__always)
    private func applyGainRamp(to buf: UnsafeMutablePointer<Float>, frameCount: Int,
                               currentGain: inout Float, targetBits: ManagedAtomic<Int32>) {
        let target = Float(bitPattern: UInt32(bitPattern: targetBits.load(ordering: .relaxed)))
        if currentGain == target { return }
        let step = (target - currentGain) / Float(frameCount)
        for i in 0..<frameCount {
            currentGain += step
            buf[i] *= currentGain
        }
        currentGain = target
    }

    @inline(__always)
    private func applyOutputGainRamp(leftBuf: UnsafeMutablePointer<Float>,
                                     rightBuf: UnsafeMutablePointer<Float>?,
                                     frameCount: Int) {
        applyGainRamp(to: leftBuf, frameCount: frameCount, currentGain: &outputGainLinear,
                      targetBits: _targetOutputGainBits)
        if let r = rightBuf {
            applyGainRamp(to: r, frameCount: frameCount, currentGain: &outputGainLinear,
                          targetBits: _targetOutputGainBits)
        }
    }
}

// MARK: - Channel Helper

private enum Channel {
    case left
    case right
}
