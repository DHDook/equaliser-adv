// EQCoefficientStager.swift
// Stages EQ coefficient updates from configuration to render pipeline

import OSLog

/// Stages EQ coefficient updates from `EQConfiguration` to `RenderPipeline`.
/// Separates the DSP concern of coefficient calculation from routing orchestration.
@MainActor
final class EQCoefficientStager {

    // MARK: - Dependencies

    private let eqConfiguration: EQConfiguration
    private weak var renderPipeline: RenderPipeline?

    // MARK: - State

    /// Current sample rate for coefficient calculations.
    /// Updated when pipeline starts or sample rate changes.
    private var currentSampleRate: Double = 48000.0

    private let logger = Logger(subsystem: "net.knage.equaliser", category: "EQCoefficientStager")

    // MARK: - Initialization

    init(eqConfiguration: EQConfiguration) {
        self.eqConfiguration = eqConfiguration
    }

    // MARK: - Pipeline Lifecycle

    func setRenderPipeline(_ pipeline: RenderPipeline?) {
        renderPipeline = pipeline
    }

    func setCurrentSampleRate(_ rate: Double) {
        currentSampleRate = rate
    }

    // MARK: - Single Band Updates

    /// Updates a band's gain by recalculating and staging coefficients.
    func updateBandGain(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's Q factor by recalculating and staging coefficients.
    func updateBandQ(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's frequency by recalculating and staging coefficients.
    func updateBandFrequency(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's filter type by recalculating and staging coefficients.
    func updateBandFilterType(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's bypass state.
    func updateBandBypass(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Returns the current band capacity from EQConfiguration.
    func currentBandCapacity() -> Int {
        eqConfiguration.activeBandCount
    }

    /// Reapplies all coefficients from the current configuration.
    func reapplyConfiguration() {
        reapplyAllCoefficients()
    }

    // MARK: - Private Coefficient Helpers

    /// Stages coefficients for a single band.
    private func stageBandCoefficients(index: Int, config: EQBandConfiguration) {
        let frequency = Double(config.frequency)
        let q = Double(config.q)
        let gain = Double(config.gain)

        // Validate parameters before calculation
        let paramResult = BiquadValidator.validate(
            type: config.filterType,
            sampleRate: currentSampleRate,
            frequency: frequency,
            q: q,
            gain: gain
        )
        if case .invalid(let message) = paramResult {
            logger.warning("Band \(index) invalid parameters: \(message) — using passthrough")
            renderPipeline?.updateBandCoefficients(
                channel: eqConfiguration.channelMode == .linked ? .both :
                    (eqConfiguration.channelFocus == .left ? .left : .right),
                layerIndex: EQLayerConstants.userEQLayerIndex,
                bandIndex: index,
                coefficients: .identity,
                bypass: config.bypass
            )
            return
        }
        if case .warning(let message) = paramResult {
            logger.debug("Band \(index) parameter warning: \(message)")
        }

        let coefficients = BiquadMath.calculateCoefficients(
            type: config.filterType,
            sampleRate: currentSampleRate,
            frequency: frequency,
            q: q,
            gain: gain
        )

        // Validate coefficient stability — unstable filters can damage speakers
        if !BiquadValidator.isFinite(coefficients) {
            logger.warning("Band \(index) coefficients are non-finite — using passthrough")
            renderPipeline?.updateBandCoefficients(
                channel: eqConfiguration.channelMode == .linked ? .both :
                    (eqConfiguration.channelFocus == .left ? .left : .right),
                layerIndex: EQLayerConstants.userEQLayerIndex,
                bandIndex: index,
                coefficients: .identity,
                bypass: config.bypass
            )
            return
        }
        if !BiquadValidator.isStable(coefficients) {
            logger.warning("Band \(index) coefficients are unstable — using passthrough")
            renderPipeline?.updateBandCoefficients(
                channel: eqConfiguration.channelMode == .linked ? .both :
                    (eqConfiguration.channelFocus == .left ? .left : .right),
                layerIndex: EQLayerConstants.userEQLayerIndex,
                bandIndex: index,
                coefficients: .identity,
                bypass: config.bypass
            )
            return
        }

        // Use channel mode and editing channel from configuration
        let target: EQChannelTarget = eqConfiguration.channelMode == .linked ? .both :
            (eqConfiguration.channelFocus == .left ? .left : .right)

        renderPipeline?.updateBandCoefficients(
            channel: target,
            layerIndex: EQLayerConstants.userEQLayerIndex,
            bandIndex: index,
            coefficients: coefficients,
            bypass: config.bypass
        )
    }

    /// Recalculates and stages all coefficients for all active bands.
    private func reapplyAllCoefficients() {
        let activeCount = eqConfiguration.activeBandCount

        // Get the appropriate bands based on channel mode
        let leftBands = eqConfiguration.leftState.userEQ.bands
        let rightBands = eqConfiguration.rightState.userEQ.bands

        // Stage coefficients for left channel
        var leftCoefficients: [BiquadCoefficients] = []
        var leftBypassFlags: [Bool] = []

        for index in 0..<activeCount {
            guard index < leftBands.count else { break }
            let config = leftBands[index]

            let coeff = BiquadMath.calculateCoefficients(
                type: config.filterType,
                sampleRate: currentSampleRate,
                frequency: Double(config.frequency),
                q: Double(config.q),
                gain: Double(config.gain)
            )
            leftCoefficients.append(coeff)
            leftBypassFlags.append(config.bypass)
        }

        // Determine channel target based on mode
        let leftTarget: EQChannelTarget = eqConfiguration.channelMode == .linked ? .both : .left

        renderPipeline?.stageFullEQUpdate(
            channel: leftTarget,
            layerIndex: EQLayerConstants.userEQLayerIndex,
            coefficients: leftCoefficients,
            bypassFlags: leftBypassFlags,
            activeBandCount: activeCount,
            layerBypass: eqConfiguration.globalBypass
        )

        // In stereo mode, also stage right channel coefficients
        if eqConfiguration.channelMode == .stereo {
            var rightCoefficients: [BiquadCoefficients] = []
            var rightBypassFlags: [Bool] = []

            for index in 0..<activeCount {
                guard index < rightBands.count else { break }
                let config = rightBands[index]

                let coeff = BiquadMath.calculateCoefficients(
                    type: config.filterType,
                    sampleRate: currentSampleRate,
                    frequency: Double(config.frequency),
                    q: Double(config.q),
                    gain: Double(config.gain)
                )
                rightCoefficients.append(coeff)
                rightBypassFlags.append(config.bypass)
            }

            renderPipeline?.stageFullEQUpdate(
                channel: .right,
                layerIndex: EQLayerConstants.userEQLayerIndex,
                coefficients: rightCoefficients,
                bypassFlags: rightBypassFlags,
                activeBandCount: activeCount,
                layerBypass: eqConfiguration.globalBypass
            )
        }
    }
}
