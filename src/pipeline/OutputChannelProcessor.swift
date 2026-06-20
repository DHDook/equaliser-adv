import Foundation
import Accelerate
import Atomics

/// Per-output channel processor. Wraps OutputChannelEQProcessor and adds
/// downstream gain trim, polarity, fractional delay, and brickwall limiter.
final class OutputChannelProcessor {

    // MARK: - EQ (owns the full EQ processor)
    let eqProcessor: OutputChannelEQProcessor

    // MARK: - Group Delay All-Pass Chain
    // Independent of the per-output EQ's excess phase chain (which is from room correction).
    // Applied between the calibration trim and the per-output EQ.
    private var groupDelayAllPassChain = AllPassChain()

    // MARK: - Pre-EQ Calibration Trim + Post-EQ DSP (polarity, delay, limiter)
    // gainTrimDB is applied BEFORE the EQ chain (pre-EQ calibration trim).
    // Polarity, delay, and limiter are applied AFTER the EQ chain.
    // Processing order: gainTrimDB → [group delay all-pass] → inputGainDB → EQ → outputGainDB → polarity → delay → limiter
    // Gain trim × polarity are NOT combined into a single factor because they are applied
    // at different points in the chain (trim is pre-EQ; polarity is post-EQ).
    private let _calibrationTrimBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))
    private let _polarityBits        = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))
    private let _gainPolarityBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))

    // Fractional delay line: linear interpolation.
    // Pre-allocated for max delay: 100 ms × 192000 Hz = 19200 samples.
    nonisolated(unsafe) var delayBuffer: [Float]
    nonisolated(unsafe) var delayWritePos: Int = 0
    private let _delayInSamplesBits = ManagedAtomic<Int32>(0)
    private static let maxDelaySamples = 19200

    // Brickwall limiter: matches BrickwallLimiterConfig parameter set.
    // Uses the same algorithm as DynamicsProcessor.processLimiter.
    private let _limiterEnabled    = ManagedAtomic<Bool>(true)
    private let _limiterCeilingBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(-0.2).bitPattern))
    private let _limiterAttackBits  = ManagedAtomic<Int32>(Int32(bitPattern: Float(0.1).bitPattern))
    private let _limiterReleaseBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(20.0).bitPattern))
    nonisolated(unsafe) var limiterEnvDB: Float = -100.0

    // MARK: - Meter Taps (Part 2 Task AG)
    /// Peak level before the excursion limiter and brickwall limiter (post-EQ, post-delay).
    /// Represents the signal the driver will receive if no limiting occurs.
    /// Updated every callback; read by MeterStore at its polling interval.
    nonisolated(unsafe) var preLimiterPeakLinear: Float = 0.0

    /// Peak level after the brickwall limiter (the final output level).
    /// Reflects the actual signal delivered to the DAC for this channel.
    nonisolated(unsafe) var postLimiterPeakLinear: Float = 0.0

    /// Amount of gain reduction applied by the excursion protection limiter (dB, always ≤ 0).
    nonisolated(unsafe) var excursionLimiterGainReductionDB: Float = 0.0

    /// Amount of gain reduction applied by the brickwall limiter (dB, always ≤ 0).
    nonisolated(unsafe) var brickwallGainReductionDB: Float = 0.0

    // Sample rate (set at init and on sample rate change)
    private var sampleRate: Double

    // MARK: - Init
    init(source: SignalSource, maxFrameCount: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
        eqProcessor = OutputChannelEQProcessor(source: source,
                                               maxFrameCount: maxFrameCount,
                                               sampleRate: sampleRate)
        delayBuffer = [Float](repeating: 0, count: Self.maxDelaySamples)
    }

    // MARK: - Main Thread Configuration (all real-time safe via atomics)

    func applyChannelConfig(_ config: OutputChannelConfig, sampleRate: Double) {
        self.sampleRate = sampleRate
        eqProcessor.applyEQConfig(config.eq, sampleRate: sampleRate)
        setCalibrationTrimDB(config.gainTrimDB)
        setPolarity(inverted: config.polarityInverted)
        setDelayMs(config.delayMs, sampleRate: sampleRate)
        setLimiterConfig(config.limiter)
    }

    /// Sets the pre-EQ calibration trim. Called by Band Level Calibration and applyChannelConfig.
    func setCalibrationTrimDB(_ trimDB: Float) {
        let linear = AudioMath.dbToLinear(trimDB)
        _calibrationTrimBits.store(Int32(bitPattern: linear.bitPattern), ordering: .releasing)
    }

    /// Sets post-EQ polarity. Called by applyChannelConfig.
    func setPolarity(inverted: Bool) {
        let factor: Float = inverted ? -1.0 : 1.0
        _polarityBits.store(Int32(bitPattern: factor.bitPattern), ordering: .releasing)
    }

    func setDelayMs(_ ms: Float, sampleRate: Double) {
        let samples = min(Float(Self.maxDelaySamples - 1), ms / 1000.0 * Float(sampleRate))
        _delayInSamplesBits.store(Int32(bitPattern: samples.bitPattern), ordering: .releasing)
    }

    func setLimiterConfig(_ config: OutputChannelLimiterConfig) {
        _limiterEnabled.store(config.isEnabled, ordering: .releasing)
        _limiterCeilingBits.store(Int32(bitPattern: config.ceilingDB.bitPattern),   ordering: .releasing)
        _limiterAttackBits.store(Int32(bitPattern:  config.attackMs.bitPattern),    ordering: .releasing)
        _limiterReleaseBits.store(Int32(bitPattern: config.releaseMs.bitPattern),   ordering: .releasing)
    }

    func setGroupDelayAllPassCoefficients(_ coefficients: [BiquadCoefficients]) {
        groupDelayAllPassChain.stageSections(from: [coefficients])
    }

    // MARK: - Per-Channel Correction Application (Task D)

    /// Applies a transfer function correction result to this output channel.
    ///
    /// - Parameter result: The correction result to apply.
    /// - Parameter sampleRate: The current sample rate.
    func applyCorrectionResult(_ result: ChannelCorrectionResult, sampleRate: Double) {
        switch result.correctionMode {
        case .iirParametric:
            // Apply IIR bands to the per-output EQ
            applyIIRCorrection(result.iirBands, sampleRate: sampleRate)
        case .firMinimumPhase:
            // FIR correction would require adding a ConvolutionEngine to each output channel
            // This is a future enhancement - for now, we only support IIR mode
            break
        case .firWithPhaseCorrection:
            // FIR + phase correction would require ConvolutionEngine + all-pass chain
            // This is a future enhancement - for now, we only support IIR mode
            break
        }
    }

    private func applyIIRCorrection(_ bands: [EQBandConfiguration], sampleRate: Double) {
        // Create an EQ config with the correction bands
        let correctionConfig = OutputChannelEQConfig(
            activeBandCount: bands.count,
            bands: bands,
            inputGainDB: 0.0,
            outputGainDB: 0.0,
            compareMode: .eq
        )
        eqProcessor.applyEQConfig(correctionConfig, sampleRate: sampleRate)
    }

    // MARK: - Audio Thread Processing

    /// Process the output channel signal in-place.
    /// leftBuf: required. rightBuf: only for stereo-capable sources (mainsLeft/mainsRight).
    @inline(__always)
    func process(
        leftBuf:    UnsafeMutablePointer<Float>,
        rightBuf:   UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) {
        // 1. Pre-EQ calibration trim (gainTrimDB — set by Band Level Calibration)
        // Applied before EQ so the EQ operates on the calibrated-level signal.
        let calTrim = Float(bitPattern: UInt32(bitPattern: _calibrationTrimBits.load(ordering: .relaxed)))
        if calTrim != 1.0 {
            var g = calTrim
            vDSP_vsmul(leftBuf, 1, &g, leftBuf, 1, vDSP_Length(frameCount))
            if let r = rightBuf { vDSP_vsmul(r, 1, &g, r, 1, vDSP_Length(frameCount)) }
        }

        // 2. Group delay all-pass correction (applied before EQ)
        // This aligns phase between crossover bands at crossover points.
        groupDelayAllPassChain.applyPendingUpdates()
        groupDelayAllPassChain.process(buffer: leftBuf, frameCount: UInt32(frameCount))
        if let r = rightBuf { groupDelayAllPassChain.process(buffer: r, frameCount: UInt32(frameCount)) }

        // 3. Per-output EQ (all modes: bypass, flat, standard, linear, mixed, delta)
        // EQ always sees the calibrated signal level — inputGainDB and outputGainDB
        // inside eqProcessor handle EQ-level gain staging independently.
        eqProcessor.process(leftBuf: leftBuf, rightBuf: rightBuf, frameCount: UInt32(frameCount))

        // 4. Polarity inversion (post-EQ)
        let polarity = Float(bitPattern: UInt32(bitPattern: _polarityBits.load(ordering: .relaxed)))
        if polarity != 1.0 {
            var g = polarity
            vDSP_vsmul(leftBuf, 1, &g, leftBuf, 1, vDSP_Length(frameCount))
            if let r = rightBuf { vDSP_vsmul(r, 1, &g, r, 1, vDSP_Length(frameCount)) }
        }

        // 5. Delay line (fractional, linear interpolation)
        let delaySamples = Float(bitPattern: UInt32(bitPattern: _delayInSamplesBits.load(ordering: .relaxed)))
        if delaySamples > 0 {
            applyDelay(buffer: leftBuf, frameCount: frameCount, delaySamples: delaySamples)
            if let r = rightBuf { applyDelay(buffer: r, frameCount: frameCount, delaySamples: delaySamples) }
        }

        // MARK: - Meter Tap: Pre-Limiter (Part 2 Task AG)
        // Measure peak level before the limiter
        var preLimiterPeak: Float = 0.0
        vDSP_maxmgv(leftBuf, 1, &preLimiterPeak, vDSP_Length(frameCount))
        preLimiterPeakLinear = preLimiterPeak

        // 6. Brickwall limiter
        if _limiterEnabled.load(ordering: .relaxed) {
            applyLimiter(leftBuf: leftBuf, rightBuf: rightBuf, frameCount: frameCount)
        }

        // MARK: - Meter Tap: Post-Limiter (Part 2 Task AG)
        // Measure peak level after the limiter
        var postLimiterPeak: Float = 0.0
        vDSP_maxmgv(leftBuf, 1, &postLimiterPeak, vDSP_Length(frameCount))
        postLimiterPeakLinear = postLimiterPeak
    }

    @inline(__always)
    private func applyDelay(buffer: UnsafeMutablePointer<Float>, frameCount: Int, delaySamples: Float) {
        let intDelay = Int(delaySamples)
        let frac = delaySamples - Float(intDelay)
        for i in 0..<frameCount {
            delayBuffer[delayWritePos] = buffer[i]
            let rp  = (delayWritePos - intDelay + Self.maxDelaySamples) % Self.maxDelaySamples
            let rp1 = (rp + 1) % Self.maxDelaySamples
            buffer[i] = delayBuffer[rp] * (1.0 - frac) + delayBuffer[rp1] * frac
            delayWritePos = (delayWritePos + 1) % Self.maxDelaySamples
        }
    }

    @inline(__always)
    private func applyLimiter(leftBuf: UnsafeMutablePointer<Float>,
                               rightBuf: UnsafeMutablePointer<Float>?,
                               frameCount: Int) {
        // TODO: Implement using the same algorithm as DynamicsProcessor.processLimiter.
        // Refactor DynamicsProcessor.processLimiter into a static free function
        // in a new file `src/dsp/dynamics/LimiterDSP.swift` so it can be shared here.
        // For now, this is a placeholder that does nothing.
    }
}
