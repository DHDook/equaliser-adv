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

    /// Updates a band's filter slope by recalculating and staging coefficients.
    func updateBandSlope(index: Int) {
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

    func applyRoomCorrectionBands(_ bands: [EQBandConfiguration]) {
        let layerIdx = EQLayerConstants.roomCorrectionLayerIndex
        guard let pipeline = renderPipeline else { return }
        var sections: [[BiquadCoefficients]] = []
        var bypassFlags: [Bool] = []
        let decoupling = eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled
        for band in bands {
            let designRate = BiquadMath.designSampleRate(
                actualRate: currentSampleRate,
                coefficientDecouplingEnabled: decoupling)
            let freq = designRate != currentSampleRate
                ? BiquadMath.prewarpFrequency(frequency: Double(band.frequency),
                                              actualRate: currentSampleRate,
                                              designRate: designRate)
                : Double(band.frequency)
            let secs = BiquadMath.calculateSections(
                type: band.filterType, sampleRate: designRate,
                frequency: freq, q: Double(band.q),
                gain: Double(band.gain), slope: band.slope)
            sections.append(secs)
            bypassFlags.append(band.bypass)
        }
        pipeline.stageFullEQUpdate(
            channel: .both,
            layerIndex: layerIdx,
            sections: sections,
            bypassFlags: bypassFlags,
            activeBandCount: bands.count,
            layerBypass: false
        )
        refreshLinearPhaseIRIfNeeded()
        refreshMixedPhaseIRIfNeeded()
    }

    func clearRoomCorrectionBands() {
        let layerIdx = EQLayerConstants.roomCorrectionLayerIndex
        renderPipeline?.stageFullEQUpdate(
            channel: .both,
            layerIndex: layerIdx,
            sections: [],
            bypassFlags: [],
            activeBandCount: 0,
            layerBypass: true
        )
        refreshLinearPhaseIRIfNeeded()
        refreshMixedPhaseIRIfNeeded()
    }

    func setRoomCorrectionLayerBypass(_ bypass: Bool) {
        renderPipeline?.stageEQLayerBypass(
            channel: .both,
            layerIndex: EQLayerConstants.roomCorrectionLayerIndex,
            bypass: bypass
        )
    }

    func refreshLinearPhaseIRIfNeeded() {
        guard let pipeline = renderPipeline,
              let ctx = pipeline.callbackContext,
              ctx.isLinearPhaseEnabled else { return }
        let leftBands = Array(eqConfiguration.leftState.userEQ.bands.prefix(
            eqConfiguration.leftState.userEQ.activeBandCount))
        let rightBands = Array(eqConfiguration.rightState.userEQ.bands.prefix(
            eqConfiguration.rightState.userEQ.activeBandCount))
        ctx.updateLinearPhaseIR(leftBands: leftBands,
                                 rightBands: rightBands,
                                 sampleRate: currentSampleRate)
    }

    func refreshMixedPhaseIRIfNeeded() {
        guard let pipeline = renderPipeline,
              let ctx = pipeline.callbackContext,
              ctx.isMixedPhaseEnabled else { return }

        let activeCount = eqConfiguration.activeBandCount
        let decoupling  = eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled

        let leftBands  = Array(eqConfiguration.leftState.userEQ.bands.prefix(activeCount))
        let rightBands = Array(eqConfiguration.rightState.userEQ.bands.prefix(activeCount))

        // Build per-band section arrays (bypassed bands contribute no sections).
        // The all-pass sections are derived from the same biquad coefficients used
        // by the EQ chains, so we recalculate them here using the same design path.
        var leftSections:  [[BiquadCoefficients]] = []
        var rightSections: [[BiquadCoefficients]] = []

        let designRate = BiquadMath.designSampleRate(
            actualRate: currentSampleRate,
            coefficientDecouplingEnabled: decoupling)

        for band in leftBands where !band.bypass && !band.isDynamic {
            let freq = designRate != currentSampleRate
                ? BiquadMath.prewarpFrequency(frequency: Double(band.frequency),
                                              actualRate: currentSampleRate,
                                              designRate: designRate)
                : Double(band.frequency)
            let secs = BiquadMath.calculateSections(
                type: band.filterType, sampleRate: designRate,
                frequency: freq, q: Double(band.q),
                gain: Double(band.gain), slope: band.slope)
            leftSections.append(secs)
        }

        // In linked mode, right = left; in stereo, compute independently.
        if eqConfiguration.channelMode == .linked {
            rightSections = leftSections
        } else {
            for band in rightBands where !band.bypass && !band.isDynamic {
                let freq = designRate != currentSampleRate
                    ? BiquadMath.prewarpFrequency(frequency: Double(band.frequency),
                                                  actualRate: currentSampleRate,
                                                  designRate: designRate)
                    : Double(band.frequency)
                let secs = BiquadMath.calculateSections(
                    type: band.filterType, sampleRate: designRate,
                    frequency: freq, q: Double(band.q),
                    gain: Double(band.gain), slope: band.slope)
                rightSections.append(secs)
            }
        }

        pipeline.updateMixedPhaseSections(
            leftSections:  leftSections,
            rightSections: rightSections
        )
    }

    // MARK: - Excess-Phase Correction (Part 5.4)

    /// Refreshes the excess-phase correction impulse response in the convolution engine
    /// when excess-phase correction is enabled and measurement data is available.
    func refreshExcessPhaseIRIfNeeded(measuredResponse: [(frequency: Double, real: Double, imag: Double)]? = nil,
                                     minPhaseResponse: [(frequency: Double, real: Double, imag: Double)]? = nil) {
        guard let pipeline = renderPipeline,
              let ctx = pipeline.callbackContext else { return }

        // Check if excess-phase correction is enabled in the configuration
        let excessPhaseConfig = eqConfiguration.dynamicsConfig.advanced.excessPhaseConfig
        guard excessPhaseConfig.enabled else {
            // Disable convolution if excess-phase correction is disabled
            ctx.setConvolutionEnabled(false)
            return
        }

        // Compute excess-phase correction impulse response if measurement data is available
        guard let measured = measuredResponse,
              let minPhase = minPhaseResponse else {
            logger.warning("Excess-phase correction enabled but measurement data not available")
            return
        }

        let ir = ExcessPhaseCorrector.computeCorrectionFilter(
            measuredResponse: measured,
            minPhaseResponse: minPhase,
            config: excessPhaseConfig,
            sampleRate: currentSampleRate
        )

        // Update convolution engine with the excess-phase IR (same for both channels)
        ctx.updateConvolutionIR(left: ir, right: ir)
        ctx.setConvolutionEnabled(true)
        logger.info("Excess-phase correction IR updated: \(ir.count) taps, cutoff: \(excessPhaseConfig.cutoffFreqHz) Hz")
    }

    // MARK: - Private Coefficient Helpers

    /// Stages coefficients for a single band (incremental update path).
    private func stageBandCoefficients(index: Int, config: EQBandConfiguration) {
        let designRate = BiquadMath.designSampleRate(
            actualRate: currentSampleRate,
            coefficientDecouplingEnabled: eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled
        )
        let warpedFrequency: Double
        if designRate != currentSampleRate {
            warpedFrequency = BiquadMath.prewarpFrequency(
                frequency: Double(config.frequency),
                actualRate: currentSampleRate,
                designRate: designRate
            )
        } else {
            warpedFrequency = Double(config.frequency)
        }
        let sections = BiquadMath.calculateSections(
            type: config.filterType,
            sampleRate: designRate,
            frequency: warpedFrequency,
            q: Double(config.q),
            gain: Double(config.gain),
            slope: config.slope
        )

        let target: EQChannelTarget
        switch eqConfiguration.channelMode {
        case .linked:
            target = .both
        case .stereo:
            target = eqConfiguration.channelFocus == .left ? .left : .right
        case .midSide:
            // Mid stored in leftState → leftEQChain
            // Side stored in rightState → rightEQChain
            let editingMid = (eqConfiguration.channelFocus == .mid ||
                              eqConfiguration.channelFocus == .left)
            target = editingMid ? .left : .right
        }

        renderPipeline?.updateBandCoefficients(
            channel: target,
            layerIndex: EQLayerConstants.userEQLayerIndex,
            bandIndex: index,
            sections: sections,
            bypass: config.bypass,
            needsDoublePrecision: !config.bypass && (Double(config.q) > 4.0 || Double(config.frequency) < 300.0)
        )
        refreshMixedPhaseIRIfNeeded()
    }

    /// Recalculates and stages all coefficients for all active bands (full update path).
    private func reapplyAllCoefficients() {
        let activeCount = eqConfiguration.activeBandCount

        let leftBands = eqConfiguration.leftState.userEQ.bands
        let rightBands = eqConfiguration.rightState.userEQ.bands

        // Build left-channel sections
        var leftSections: [[BiquadCoefficients]] = []
        var leftBypassFlags: [Bool] = []
        var leftNeedsDoublePrecision: [Bool] = []

        let designRate = BiquadMath.designSampleRate(
            actualRate: currentSampleRate,
            coefficientDecouplingEnabled: eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled
        )

        for index in 0..<activeCount {
            guard index < leftBands.count else { break }
            let config = leftBands[index]
            let warpedFrequency: Double
            if designRate != currentSampleRate {
                warpedFrequency = BiquadMath.prewarpFrequency(
                    frequency: Double(config.frequency),
                    actualRate: currentSampleRate,
                    designRate: designRate
                )
            } else {
                warpedFrequency = Double(config.frequency)
            }
            let sections = BiquadMath.calculateSections(
                type: config.filterType,
                sampleRate: designRate,
                frequency: warpedFrequency,
                q: Double(config.q),
                gain: Double(config.gain),
                slope: config.slope
            )
            leftSections.append(sections)
            leftBypassFlags.append(config.bypass)
            leftNeedsDoublePrecision.append(!config.bypass && (Double(config.q) > 4.0 || Double(config.frequency) < 300.0))
        }

        let leftTarget: EQChannelTarget = eqConfiguration.channelMode == .linked ? .both : .left

        renderPipeline?.stageFullEQUpdate(
            channel: leftTarget,
            layerIndex: EQLayerConstants.userEQLayerIndex,
            sections: leftSections,
            bypassFlags: leftBypassFlags,
            activeBandCount: activeCount,
            layerBypass: eqConfiguration.globalBypass,
            needsDoublePrecision: leftNeedsDoublePrecision
        )

        // In stereo mode, also stage right-channel coefficients
        if eqConfiguration.channelMode == .stereo {
            var rightSections: [[BiquadCoefficients]] = []
            var rightBypassFlags: [Bool] = []
            var rightNeedsDoublePrecision: [Bool] = []

            for index in 0..<activeCount {
                guard index < rightBands.count else { break }
                let config = rightBands[index]
                let warpedFrequency: Double
                if designRate != currentSampleRate {
                    warpedFrequency = BiquadMath.prewarpFrequency(
                        frequency: Double(config.frequency),
                        actualRate: currentSampleRate,
                        designRate: designRate
                    )
                } else {
                    warpedFrequency = Double(config.frequency)
                }
                let sections = BiquadMath.calculateSections(
                    type: config.filterType,
                    sampleRate: designRate,
                    frequency: warpedFrequency,
                    q: Double(config.q),
                    gain: Double(config.gain),
                    slope: config.slope
                )
                rightSections.append(sections)
                rightBypassFlags.append(config.bypass)
                rightNeedsDoublePrecision.append(!config.bypass && (Double(config.q) > 4.0 || Double(config.frequency) < 300.0))
            }

            renderPipeline?.stageFullEQUpdate(
                channel: .right,
                layerIndex: EQLayerConstants.userEQLayerIndex,
                sections: rightSections,
                bypassFlags: rightBypassFlags,
                activeBandCount: activeCount,
                layerBypass: eqConfiguration.globalBypass,
                needsDoublePrecision: rightNeedsDoublePrecision
            )
        }
        refreshLinearPhaseIRIfNeeded()
        refreshMixedPhaseIRIfNeeded()
    }
}
