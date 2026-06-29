// EqualiserStore.swift
// Thin coordinator for EQ application state

import Combine
import Foundation
import OSLog
import AppKit
import SwiftUI
import CoreAudio

@MainActor
final class EqualiserStore: ObservableObject {
    
    // MARK: - Computed Properties (delegate to EQConfiguration)
    
    /// Global bypass state - delegates to eqConfiguration.globalBypass.
    var isBypassed: Bool {
        get { eqConfiguration.globalBypass }
        set {
            eqConfiguration.globalBypass = newValue
            routingCoordinator.updateProcessingMode(systemEQOff: newValue, compareMode: compareMode, channelMode: channelMode)
        }
    }
    
    /// Band count - delegates to eqConfiguration.focusedChannelBandCount.
    /// In linked mode, returns the band count for both channels.
    /// In stereo mode, returns the band count for the currently focused channel.
    var bandCount: Int {
        get { eqConfiguration.focusedChannelBandCount }
        set {
            eqConfiguration.setActiveBandCount(newValue)

            // Only update pipeline if routing is active
            guard routingCoordinator.routingStatus.isActive else { return }

            // Reconfigure only if new band count exceeds current capacity
            if newValue > routingCoordinator.currentBandCapacity() {
                routingCoordinator.reconfigureRouting()
            } else {
                routingCoordinator.reapplyConfiguration()
            }
        }
    }
    
    /// Input gain (dB) - delegates to eqConfiguration.inputGain.
    var inputGain: Float {
        get { eqConfiguration.inputGain }
        set {
            let clamped = Self.clampGain(newValue)
        eqConfiguration.inputGain = clamped
        routingCoordinator.updateInputGain(linear: AudioMath.dbToLinear(clamped))
        }
    }
    
    /// Output gain (dB) - delegates to eqConfiguration.outputGain.
    var outputGain: Float {
        get { eqConfiguration.outputGain }
        set {
            let clamped = Self.clampGain(newValue)
        eqConfiguration.outputGain = clamped
        routingCoordinator.updateOutputGain(linear: AudioMath.dbToLinear(clamped))
        }
    }
    
    // MARK: - Published Properties
    
    @Published var compareMode: CompareMode = .eq {
        didSet {
            routingCoordinator.updateProcessingMode(systemEQOff: isBypassed, compareMode: compareMode, channelMode: channelMode)

            switch compareMode {
            case .flat:
                compareModeTimer.start()
            default:
                compareModeTimer.cancel()
            }

            // Delta mode drives the delta solo DSP flag; clear it on any other mode.
            var adv = dynamicsConfig.advanced
            adv.deltaSoloActive = (compareMode == .delta)
            updateAdvancedProcessing(adv)
            if compareMode == .linearEQ {
                routingCoordinator.eqStager.refreshLinearPhaseIRIfNeeded()
            }
            if compareMode == .mixedPhase {
                routingCoordinator.eqStager.refreshMixedPhaseIRIfNeeded()
            }
        }
    }
    
    /// User preference for displaying bandwidth as octaves or Q factor.
    @Published var bandwidthDisplayMode: BandwidthDisplayMode = .qFactor

    /// Convolution engine configuration.
    @Published var convolutionConfig: ConvolutionConfig = ConvolutionConfig()
    /// Error message from the most recent IR load attempt.
    @Published var convolutionLoadError: String? = nil

    /// Flag indicating whether app state was reset to defaults on launch due to decode failure.
    @Published var didResetStateOnLaunch: Bool = false

    // MARK: - Transfer Function Measurement State (Task E)

    enum TransferFunctionMeasurementStep: Equatable, Sendable {
        case idle
        case preparingChannel(channelIndex: Int, label: String)
        case awaitingMicPosition(positionIndex: Int, totalPositions: Int)
        case playingSweep(channelIndex: Int, label: String,
                          sweepIndex: Int, totalSweeps: Int,
                          positionIndex: Int, progress: Double)
        case computingIR(channelIndex: Int, label: String)
        case channelComplete(channelIndex: Int, label: String, snrDB: Double)
        case allChannelsComplete
        case failed(channelIndex: Int, reason: String)
    }

    @Published var tfMeasurementStep: TransferFunctionMeasurementStep = .idle
    @Published var transferFunctionDataset: TransferFunctionDataset = TransferFunctionDataset()

    // MARK: - Diaphragm Resonance Detection (Part 2 Task AB)
    @Published var resonanceCandidates: [Int: [DiaphragmResonanceDetector.ResonanceCandidate]] = [:]

    private var micPositionContinuation: CheckedContinuation<Void, Never>?

    @MainActor
    func confirmMicPositioned() {
        micPositionContinuation?.resume()
        micPositionContinuation = nil
    }

    /// Runs a multi-channel transfer function measurement.
    ///
    /// - Parameters:
    ///   - micInputDeviceID: Physical microphone input device.
    ///   - channelIndices: Which channels to measure; –1 = main chain.
    ///   - micPositionCount: Number of mic positions for spatial averaging.
    ///   - sweepsPerPosition: Number of sweeps to average per position.
    ///   - sweepDurationSeconds: Duration of each sweep.
    ///   - minSNRDB: Minimum acceptable SNR.
    @MainActor
    func runTransferFunctionMeasurement(
        micInputDeviceID: AudioDeviceID,
        channelIndices: [Int],
        micPositionCount: Int = 1,
        sweepsPerPosition: Int = 3,
        sweepDurationSeconds: Double = 10.0,
        minSNRDB: Double = 30.0
    ) async {
        tfMeasurementStep = .idle
        transferFunctionDataset = TransferFunctionDataset()

        for (channelIdx, channelIndex) in channelIndices.enumerated() {
            let label = channelIndex == -1 ? "Main Chain" : "Channel \(channelIndex)"

            // Prepare channel
            tfMeasurementStep = .preparingChannel(channelIndex: channelIndex, label: label)

            // Initialize channel data
            var channelData = ChannelTransferFunctionData(
                channelIndex: channelIndex,
                channelLabel: label,
                signalSource: .mainsLeft // Placeholder - should be derived from channelIndex
            )
            channelData.sweepsByPosition = Array(repeating: [], count: micPositionCount)

            // Measure at each position
            for positionIndex in 0..<micPositionCount {
                // Pause for mic repositioning if not first position
                if positionIndex > 0 {
                    tfMeasurementStep = .awaitingMicPosition(positionIndex: positionIndex, totalPositions: micPositionCount)
                    await withCheckedContinuation { continuation in
                        micPositionContinuation = continuation
                    }
                }

                // Play sweeps at this position
                var positionSweeps: [SingleSweepMeasurement] = []

                for sweepIndex in 0..<sweepsPerPosition {
                    tfMeasurementStep = .playingSweep(
                        channelIndex: channelIndex,
                        label: label,
                        sweepIndex: sweepIndex,
                        totalSweeps: sweepsPerPosition,
                        positionIndex: positionIndex,
                        progress: 0.0
                    )

                    // TODO: Implement actual sweep playback and capture
                    // This requires integration with RenderCallbackContext
                    // For now, this is a placeholder

                    // Simulate progress
                    for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
                        tfMeasurementStep = .playingSweep(
                            channelIndex: channelIndex,
                            label: label,
                            sweepIndex: sweepIndex,
                            totalSweeps: sweepsPerPosition,
                            positionIndex: positionIndex,
                            progress: progress
                        )
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    }

                    // TODO: Store actual sweep measurement
                    // positionSweeps.append(sweepMeasurement)
                }

                channelData.sweepsByPosition[positionIndex] = positionSweeps
            }

            // Compute averaged IR for this channel
            tfMeasurementStep = .computingIR(channelIndex: channelIndex, label: label)

            // TODO: Compute averaged IR using RoomCorrectionEngine.averageImpulseResponses
            // TODO: Estimate SNR using RoomCorrectionEngine.estimateSNR
            let averageSNR = 40.0 // Placeholder

            // Set placeholder averaged IR to mark as measured
            channelData.averagedIR = [Float](repeating: 0.0, count: 48000) // Placeholder

            // Add to dataset
            transferFunctionDataset.channels.append(channelData)

            tfMeasurementStep = .channelComplete(channelIndex: channelIndex, label: label, snrDB: averageSNR)
        }

        tfMeasurementStep = .allChannelsComplete
    }

    // MARK: - Diaphragm Resonance Detection (Part 2 Task AB)

    /// Runs resonance detection on the measured transfer function for a given channel
    /// and stores the candidates for UI display.
    @MainActor
    func detectResonances(for channelIndex: Int, params: DiaphragmResonanceDetector.DetectionParameters = .init()) {
        guard let channel = transferFunctionDataset.channels.first(where: { $0.channelIndex == channelIndex }),
              let magnitude = channel.averagedMagnitudeDB else { return }
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: magnitude, params: params)
        resonanceCandidates[channelIndex] = candidates
    }

    // MARK: - Combined Multi-Driver Measurement (Part 2 Task AD)

    @Published var combinedMeasurementResult: CombinedMeasurementResult? = nil

    /// Plays a log-swept sine through ALL enabled output channels simultaneously
    /// and captures the result at the listening position.
    ///
    /// All DSP processing (per-output EQ, crossover, delays, limiters) is active
    /// during this measurement — the result reflects the actual system output
    /// as configured, not the raw driver responses.
    ///
    /// - Parameters:
    ///   - micInputDeviceID: Physical microphone input device.
    ///   - sweepDurationSeconds: Default: 10 s.
    ///   - repetitions: Number of sweeps to average. Default: 1 (combined measurement
    ///     is typically used for verification, not precision; 1 sweep is sufficient).
    @MainActor
    func runCombinedVerificationMeasurement(
        micInputDeviceID: AudioDeviceID,
        sweepDurationSeconds: Double = 10.0,
        repetitions: Int = 1
    ) async -> CombinedMeasurementResult? {
        // TODO: Implement combined measurement logic
        // This requires:
        // 1. Setting up sweep injection before crossover in render pipeline
        // 2. Capturing from microphone input
        // 3. Computing impulse response and frequency response
        // 4. Returning CombinedMeasurementResult
        return nil
    }

    // MARK: - Loopback Measurement State

    enum MeasurementState {
        case idle
        case playing
        case capturing
        case computing
        case done
    }

    @Published var measurementState: MeasurementState = .idle
    @Published var measuredResponse: [(frequency: Double, gainDB: Double)] = []
    @Published var measurementError: String? = nil
    @Published var firCorrectionTapCount: Int = 4096
    @Published var targetCurve: [(frequency: Double, gainDB: Double)] = TargetCurveLibrary.flat
    @Published var selectedTargetCurveName: String = "Flat"
    @Published var micCalibration: MicCalibration? = nil
    @Published var micCalibrationLoadError: String? = nil
    @Published var excessPhaseConfig: ExcessPhaseConfig = ExcessPhaseConfig()
    @Published var staticPreampDB: Float = 0.0

    // MARK: - Snapshot Comparison (Part 9.1)

    /// Snapshot of EQ configuration for A/B/C/D comparison
    struct EQSnapshot: Codable {
        var leftBands: [EQBandConfiguration]
        var rightBands: [EQBandConfiguration]
        var activeBandCount: Int
        var channelMode: ChannelMode
        var inputGain: Float
        var outputGain: Float
        var globalBypass: Bool
        var timestamp: Date
    }

    /// Stored snapshots for A/B/C/D comparison
    @Published var snapshots: [String: EQSnapshot] = [:]
    @Published var selectedSnapshotKey: String? = nil

    /// Saves the current EQ configuration to a snapshot slot (A, B, C, or D)
    func saveSnapshot(key: String) {
        let snapshot = EQSnapshot(
            leftBands: Array(eqConfiguration.leftState.userEQ.bands),
            rightBands: Array(eqConfiguration.rightState.userEQ.bands),
            activeBandCount: eqConfiguration.activeBandCount,
            channelMode: eqConfiguration.channelMode,
            inputGain: eqConfiguration.inputGain,
            outputGain: eqConfiguration.outputGain,
            globalBypass: eqConfiguration.globalBypass,
            timestamp: Date()
        )
        snapshots[key] = snapshot
        logger.info("Saved EQ snapshot to slot: \(key)")
    }

    /// Restores the EQ configuration from a snapshot slot
    func restoreSnapshot(key: String) {
        guard let snapshot = snapshots[key] else {
            logger.warning("No snapshot found for slot: \(key)")
            return
        }

        // Restore EQ bands by using update methods
        for (index, band) in snapshot.leftBands.enumerated() {
            eqConfiguration.updateBandGain(index: index, gain: band.gain, channel: .left)
            eqConfiguration.updateBandQ(index: index, q: band.q, channel: .left)
            eqConfiguration.updateBandFrequency(index: index, frequency: band.frequency, channel: .left)
            eqConfiguration.updateBandBypass(index: index, bypass: band.bypass, channel: .left)
            eqConfiguration.updateBandFilterType(index: index, filterType: band.filterType, channel: .left)
            eqConfiguration.updateBandSlope(index: index, slope: band.slope, channel: .left)
        }
        for (index, band) in snapshot.rightBands.enumerated() {
            eqConfiguration.updateBandGain(index: index, gain: band.gain, channel: .right)
            eqConfiguration.updateBandQ(index: index, q: band.q, channel: .right)
            eqConfiguration.updateBandFrequency(index: index, frequency: band.frequency, channel: .right)
            eqConfiguration.updateBandBypass(index: index, bypass: band.bypass, channel: .right)
            eqConfiguration.updateBandFilterType(index: index, filterType: band.filterType, channel: .right)
            eqConfiguration.updateBandSlope(index: index, slope: band.slope, channel: .right)
        }
        eqConfiguration.setActiveBandCount(snapshot.activeBandCount)
        eqConfiguration.channelMode = snapshot.channelMode
        eqConfiguration.inputGain = snapshot.inputGain
        eqConfiguration.outputGain = snapshot.outputGain
        eqConfiguration.globalBypass = snapshot.globalBypass

        // Reapply configuration to pipeline
        routingCoordinator.reapplyConfiguration()

        selectedSnapshotKey = key
        logger.info("Restored EQ snapshot from slot: \(key)")
    }

    /// Clears a snapshot slot
    func clearSnapshot(key: String) {
        snapshots.removeValue(forKey: key)
        if selectedSnapshotKey == key {
            selectedSnapshotKey = nil
        }
        logger.info("Cleared EQ snapshot slot: \(key)")
    }

    // MARK: - Forwarded Properties from RoutingCoordinator

    var routingStatus: RoutingStatus { routingCoordinator.routingStatus }

    var listeningRTAEnabled: Bool {
        get { routingCoordinator.listeningRTAEnabled }
        set { routingCoordinator.listeningRTAEnabled = newValue }
    }

    var listeningRTAMicDeviceID: String? {
        get { routingCoordinator.listeningRTAMicDeviceID }
        set { routingCoordinator.listeningRTAMicDeviceID = newValue }
    }
    
    var selectedInputDeviceID: String? {
        get { routingCoordinator.selectedInputDeviceID }
        set {
            routingCoordinator.selectedInputDeviceID = newValue
            if newValue != nil && routingCoordinator.selectedOutputDeviceID != nil {
                routingCoordinator.reconfigureRouting()
            }
        }
    }
    
    var selectedOutputDeviceID: String? {
        get { routingCoordinator.selectedOutputDeviceID }
        set {
            routingCoordinator.selectedOutputDeviceID = newValue
            if routingCoordinator.selectedInputDeviceID != nil && newValue != nil {
                routingCoordinator.reconfigureRouting()
            }
        }
    }
    
    var manualModeEnabled: Bool {
        get { routingCoordinator.manualModeEnabled }
        set { routingCoordinator.manualModeEnabled = newValue }
    }

    /// Capture mode preference for automatic routing.
    /// Only applies when using the Equaliser driver in automatic mode.
    /// Manual mode always uses HAL input capture.
    var captureMode: CaptureMode {
        get { routingCoordinator.captureMode }
        set {
            routingCoordinator.captureMode = newValue
            // Reconfigure routing in automatic mode if not idle
            // This covers: active, starting, error states (e.g., permission denied then retry)
            if !routingCoordinator.manualModeEnabled && routingCoordinator.routingStatus != .idle {
                routingCoordinator.reconfigureRouting()
            }
        }
    }
    
    /// The capture mode currently in use (may differ from preference when driver doesn't support shared memory).
    /// Returns `halInput` when driver doesn't support shared memory or in fallback mode.
    var effectiveCaptureMode: CaptureMode {
        routingCoordinator.effectiveCaptureMode
    }

    // MARK: - Output Channel Matrix Properties (forwarded from RoutingCoordinator)

    var outputChannelMatrix: OutputChannelMatrixConfig {
        get { routingCoordinator.outputChannelMatrix }
        set { routingCoordinator.outputChannelMatrix = newValue }
    }

    var multiDeviceSyncMode: MultiDeviceSyncMode {
        get { routingCoordinator.multiDeviceSyncMode }
        set { routingCoordinator.multiDeviceSyncMode = newValue }
    }

    var aggregateClockMasterUID: String? {
        get { routingCoordinator.aggregateClockMasterUID }
        set { routingCoordinator.aggregateClockMasterUID = newValue }
    }

    var hasMultipleDevices: Bool {
        routingCoordinator.hasMultipleDevices
    }

    var activeCrossoverConfig: ActiveCrossoverConfig {
        get { routingCoordinator.activeCrossoverConfig }
        set { routingCoordinator.activeCrossoverConfig = newValue }
    }

    /// Requests microphone permission and switches to HAL capture mode.
    /// Returns true if permission was granted, false otherwise.
    @MainActor
    func requestMicPermissionAndSwitchToHALCapture() async -> Bool {
        await routingCoordinator.requestMicPermissionAndSwitchToHALCapture()
    }

    var showDriverPrompt: Bool {
        get { routingCoordinator.showDriverPrompt }
        set { routingCoordinator.showDriverPrompt = newValue }
    }

    /// Binding for the update alert visibility.
    var showUpdateAlert: Binding<Bool> {
        Binding(
            get: { self.updateService.showUpdateAlert },
            set: { self.updateService.showUpdateAlert = $0 }
        )
    }

    /// Whether the driver needs updating (missing shared memory support).
    var showDriverUpdateRequired: Bool {
        routingCoordinator.showDriverUpdateRequired
    }
    
    /// Clears the driver update required flag (after user visits Settings).
    func clearDriverUpdateRequired() {
        routingCoordinator.showDriverUpdateRequired = false
    }
    
    var inputDevices: [AudioDevice] { deviceManager.inputDevices }
    var outputDevices: [AudioDevice] { deviceManager.outputDevices }

    /// Enumerates input devices.
    /// May trigger TCC permission dialog for microphone access.
    /// Should be called after microphone permission is granted or when switching to manual mode.
    func enumerateInputDevices() {
        deviceManager.enumerateInputDevices()
    }

    // MARK: - Channel Mode

    /// Channel processing mode - delegates to eqConfiguration.
    var channelMode: ChannelMode {
        get { eqConfiguration.channelMode }
        set {
            eqConfiguration.setChannelMode(newValue)
            routingCoordinator.reapplyConfiguration()
            routingCoordinator.updateProcessingMode(
                systemEQOff: isBypassed,
                compareMode: compareMode,
                channelMode: newValue
            )
            presetManager.markAsModified()
        }
    }

    /// Which channel is being edited in stereo mode.
    var channelFocus: ChannelFocus {
        get { eqConfiguration.channelFocus }
        set { eqConfiguration.channelFocus = newValue }
    }

    // MARK: - Components

    let deviceManager = DeviceManager()
    let volumeService: VolumeControlling
    let sampleRateService: SampleRateObserving
    let eqConfiguration: EQConfiguration
    let presetManager: PresetManager
    let roomCorrectionPresetManager = RoomCorrectionPresetManager()
    let meterStore: MeterStore
    let updateService = UpdateCheckService()
    let rtaAnalyzer        = AdvancedDualSpectrumAnalyzer()
    let goniometerEngine   = GoniometerBufferEngine()
    private var sweepAnalyser: SweepAnalyser?

    // MARK: - Listening RTA Data

    /// Published listening RTA data for room measurement overlay.
    /// Contains (frequency, gainDB) tuples for the 31 ISO 1/3-octave bands.
    @Published var listeningRTAData: [(frequency: Double, gainDB: Double)] = []

    // MARK: - Coordinators
    
    private(set) var deviceChangeCoordinator: DeviceChangeCoordinator
    private(set) var routingCoordinator: AudioRoutingCoordinator
    private let systemDefaultObserver: SystemDefaultObserver
    private let compareModeTimer = CompareModeTimer()
    
    // MARK: - Private Properties
    
    let persistence: AppStatePersistence
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "EqualiserStore")
    private var cancellables = Set<AnyCancellable>()

    private func makeSweepAnalyser() -> SweepAnalyser {
        let sr = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        return SweepAnalyser(sampleRate: sr, duration: 10.0,
                             startFrequency: 20.0, endFrequency: 20_000.0,
                             channelCount: 2)
    }
    
    // MARK: - Snapshot

    var currentSnapshot: AppStateSnapshot {
        AppStateSnapshot(
            globalBypass: eqConfiguration.globalBypass,
            inputGain: eqConfiguration.inputGain,
            outputGain: eqConfiguration.outputGain,
            channelMode: eqConfiguration.channelMode,
            channelFocus: eqConfiguration.channelFocus,
            leftState: eqConfiguration.leftState,
            rightState: eqConfiguration.rightState,
            inputDeviceID: manualModeEnabled ? routingCoordinator.selectedInputDeviceID : nil,
            outputDeviceID: routingCoordinator.selectedOutputDeviceID,
            bandwidthDisplayMode: bandwidthDisplayMode.rawValue,
            manualModeEnabled: manualModeEnabled,
            captureMode: routingCoordinator.captureMode.rawValue,
            dynamicsConfig: eqConfiguration.dynamicsConfig,
            metersEnabled: meterStore.metersEnabled
        )
    }

    // MARK: - Dynamics Configuration

    /// Current dynamics configuration (soft clipper + brickwall limiter).
    var dynamicsConfig: DynamicsConfig {
        get { eqConfiguration.dynamicsConfig }
        set {
            var merged = newValue
            merged.advanced.dynamicEQ = buildMergedDynamicEQConfig()
            eqConfiguration.dynamicsConfig = merged
            routingCoordinator.updateDynamicsConfig(merged)
            presetManager.markAsModified()
        }
    }

    /// Updates the full dynamics configuration and propagates it to the audio pipeline.
    func updateDynamicsConfig(_ config: DynamicsConfig) {
        dynamicsConfig = config
    }

    /// Updates soft clipper parameters individually.
    func updateSoftClipper(_ softClipper: SoftClipperConfig) {
        var config = eqConfiguration.dynamicsConfig
        config.softClipper = softClipper
        dynamicsConfig = config
    }

    /// Updates brickwall limiter parameters individually.
    func updateLimiter(_ limiter: BrickwallLimiterConfig) {
        var config = eqConfiguration.dynamicsConfig
        config.limiter = limiter
        dynamicsConfig = config
    }

    func updateDeEsser(_ deEsser: DeEsserConfig) {
        var config = eqConfiguration.dynamicsConfig
        config.deEsser = deEsser
        dynamicsConfig = config
    }

    func updateMultibandCompressor(_ mb: MultibandCompressorConfig) {
        var config = eqConfiguration.dynamicsConfig
        config.multibandCompressor = mb
        dynamicsConfig = config
    }

    func updateCompressor(_ comp: CompressorConfig) {
        var config = eqConfiguration.dynamicsConfig
        config.compressor = comp
        dynamicsConfig = config
    }

    func updateExpander(_ exp: ExpanderConfig) {
        var config = eqConfiguration.dynamicsConfig
        config.expander = exp
        dynamicsConfig = config
    }

    func updateStereoWidener(_ config: StereoWidenerConfig) {
        var dyn = eqConfiguration.dynamicsConfig
        dyn.stereoWidener = config
        dynamicsConfig = dyn
    }

    func updateLoudnessMatch(_ config: LoudnessMatchConfig) {
        var dyn = eqConfiguration.dynamicsConfig
        dyn.loudnessMatch = config
        dynamicsConfig = dyn
    }

    func updateChannelBalance(_ balance: Float) {
        var dyn = eqConfiguration.dynamicsConfig
        dyn.channelBalance = max(-1.0, min(1.0, balance))
        dynamicsConfig = dyn
    }

    /// Updates advanced processing parameters (sections A–J) and propagates to the audio pipeline.
    func updateAdvancedProcessing(_ advanced: AdvancedProcessingConfig) {
        let prevDecoupling = dynamicsConfig.advanced.coefficientDecouplingEnabled
        var config = eqConfiguration.dynamicsConfig
        config.advanced = advanced
        dynamicsConfig = config
        if prevDecoupling != advanced.coefficientDecouplingEnabled {
            refreshHighResDecouplingStatus(forceReapply: true)
        }
        // Recompute static preamp when bass management gain changes
        recomputeStaticPreamp()
    }

    /// Recomputes the static preamp gain based on current EQ, room correction, target curve, and bass management settings.
    /// This is called when any of these parameters change to prevent clipping from EQ boosts.
    func recomputeStaticPreamp() {
        guard let pipeline = routingCoordinator.pipelineManager.renderPipeline else { return }

        guard dynamicsConfig.advanced.eqHeadroomCompensationEnabled else {
            staticPreampDB = 0.0
            pipeline.callbackContext?.setStaticPreampGain(gainDB: 0.0)
            return
        }

        // Gather current EQ layer bands (user EQ)
        let eqLayer = eqConfiguration.bands.map { band in
            PresetBand(
                frequency: band.frequency,
                q: band.q,
                gain: band.gain,
                filterType: band.filterType,
                bypass: band.bypass,
                slope: band.slope
            )
        }

        // Gather room correction layer bands
        let roomCorrectionLayer = eqConfiguration.leftState.roomCorrection.bands.map { band in
            PresetBand(
                frequency: band.frequency,
                q: band.q,
                gain: band.gain,
                filterType: band.filterType,
                bypass: band.bypass,
                slope: band.slope
            )
        }

        // Build target curve
        let targetCurve = buildTargetCurve()

        // Get bass management low band gain
        let lowBandGainDB = dynamicsConfig.advanced.bassManagement.lowBandGainDB

        // Compute static preamp gain
        let staticPreampDB = EQHeadroomCompensator.computeStaticPreampDB(
            eqLayer: eqLayer,
            roomCorrectionLayer: roomCorrectionLayer,
            targetCurve: targetCurve,
            lowBandGainDB: lowBandGainDB
        )

        // Apply to render pipeline
        self.staticPreampDB = staticPreampDB
        pipeline.callbackContext?.setStaticPreampGain(gainDB: staticPreampDB)
    }

    @Published var pendingMeasuredCurve: [(frequency: Double, gainDB: Double)]? = nil
    @Published var roomCorrectionBandCount: Int = 0
    @Published var customREWTargetCurve: [(frequency: Double, gainDB: Double)]? = nil

    /// Accumulated measurement curves for multi-seat averaging (Part 4.2).
    /// Each element is one full-range frequency response measurement with complex data.
    @Published var seatMeasurements: [SeatMeasurement] = []

    /// Seat measurement with complex frequency response and weighting (Part 4.2).
    struct SeatMeasurement: Codable, Sendable {
        struct ComplexPoint: Codable, Sendable {
            let frequency: Double
            let real: Double
            let imag: Double
        }

        var complexResponse: [ComplexPoint]
        var weight: Double = 1.0

        /// Computed magnitude curve for backward compatibility.
        var magnitudeCurve: [(frequency: Double, gainDB: Double)] {
            complexResponse.map { point in
                let magnitude = sqrt(point.real * point.real + point.imag * point.imag)
                let gainDB = magnitude > 0 ? 20.0 * log10(magnitude) : -120.0
                return (point.frequency, gainDB)
            }
        }
    }

    // MARK: - Advanced Live Metrics (audio thread → main thread)

    /// Smoothed Pearson L/R phase correlation (−1.0 anti-phase … +1.0 in-phase).
    var livePhaseCorrelation: Float {
        routingCoordinator.pipelineManager.renderPipeline?.livePhaseCorrelation ?? 0.0
    }
    /// Current auto-headroom rider gain in dB, published for UI consumption.
    var liveAutoHeadroomGainDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.liveAutoHeadroomGainDB ?? 0.0
    }
    /// Active pipeline sample rate (Hz), or 48 kHz when idle.
    var streamSampleRate: Double {
        routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
    }
    /// Peak-to-RMS crest factor in dB after the compressor stage.
    var liveCrestFactorDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.liveCrestFactorDB ?? 0.0
    }
    /// Channel balance meter (−1.0 = full left, 0.0 = centre, +1.0 = full right).
    var liveBalanceMeter: Float {
        routingCoordinator.pipelineManager.renderPipeline?.liveBalanceMeter ?? 0.0
    }
    /// True if the soft clipper exceeded 0 dBFS since the last `clearTruePeakFlags()`.
    var truePeakClipperTripped: Bool {
        routingCoordinator.pipelineManager.renderPipeline?.truePeakClipperTripped ?? false
    }
    /// True if the brickwall limiter ceiling was breached since the last `clearTruePeakFlags()`.
    var truePeakLimiterTripped: Bool {
        routingCoordinator.pipelineManager.renderPipeline?.truePeakLimiterTripped ?? false
    }
    /// Continuous inter-sample true-peak level (dBTP) measured on the final output signal.
    var liveTruePeakDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.liveTruePeakDB ?? -90.0
    }
    /// Whether the signal path is currently running through the 4× oversampled clipper/limiter.
    var isOversamplingActive: Bool {
        routingCoordinator.pipelineManager.renderPipeline?.isOversamplingActive ?? false
    }
    /// Resets sticky true-peak trip indicators (call from main thread after displaying).
    func clearTruePeakFlags() {
        routingCoordinator.pipelineManager.renderPipeline?.clearTruePeakFlags()
    }

    // MARK: - Per-Stage Gain Reduction (audio thread → main thread)

    /// Reads the latest value atomically from the audio thread. 0 dB = no reduction.
    var limiterGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.limiterGainReductionDB ?? 0.0
    }

    var clipperEngaged: Bool {
        routingCoordinator.pipelineManager.renderPipeline?.clipperEngaged ?? false
    }

    var deEsserGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.deEsserGainReductionDB ?? 0.0
    }
    var mbLowGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.mbLowGainReductionDB ?? 0.0
    }
    var mbMidGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.mbMidGainReductionDB ?? 0.0
    }
    var mbHighGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.mbHighGainReductionDB ?? 0.0
    }
    var compressorGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.compressorGainReductionDB ?? 0.0
    }
    var expanderGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.expanderGainReductionDB ?? 0.0
    }
    var preEQPeakDB:  Float { routingCoordinator.pipelineManager.renderPipeline?.preEQPeakDB  ?? -90.0 }
    var postEQPeakDB: Float { routingCoordinator.pipelineManager.renderPipeline?.postEQPeakDB ?? -90.0 }

    var clipperGainReductionDB: Float {
        routingCoordinator.pipelineManager.renderPipeline?.clipperGainReductionDB ?? 0.0
    }

    // MARK: - Crossover Analysis Accessors

    /// Returns the active crossover coefficients for a given signal source.
    /// This accessor is used by the CrossoverAnalysisView to compute group delay,
    /// acoustic summation, and other crossover-related analyses.
    /// - Parameter source: The signal source to get coefficients for.
    /// - Returns: A tuple containing the crossover sections and FIR kernel (if any).
    /// Note: Currently returns nil for all sources since ActiveCrossoverEngine
    /// is not yet integrated into DynamicsProcessor. This is a placeholder for
    /// when the crossover engine is integrated (see TODO in RenderCallbackContext.swift).
    func activeCrossoverCoefficients(for source: SignalSource) -> (sections: ActiveCrossoverEngine.SectionArray?, firKernel: [Float]?) {
        // TODO: Read from DynamicsProcessor.activeCrossoverEngine once integrated
        // For now, return nil since the crossover engine is not yet integrated
        return (nil, nil)
    }
    
    // MARK: - Initialization
    
    init(persistence: AppStatePersistence = AppStatePersistence()) {
        self.persistence = persistence

        // Load snapshot if exists
        let (snapshot, didReset) = persistence.load()

        // Initialize EQ configuration
        self.eqConfiguration = EQConfiguration(from: snapshot)

        // Initialize other components
        self.presetManager = PresetManager()
        self.meterStore = MeterStore(metersEnabled: snapshot.metersEnabled)

        // Set reset flag if state was reset
        self.didResetStateOnLaunch = didReset
        
        // Create services
        self.volumeService = DeviceVolumeService()
        self.sampleRateService = DeviceSampleRateService()
        
        // Create coordinators
        self.systemDefaultObserver = SystemDefaultObserver(deviceManager: deviceManager)
        self.deviceChangeCoordinator = DeviceChangeCoordinator(
            deviceEnumerator: deviceManager.enumerator
        )
        self.routingCoordinator = AudioRoutingCoordinator(
            deviceProvider: deviceManager,
            deviceChangeCoordinator: deviceChangeCoordinator,
            eqConfiguration: eqConfiguration,
            meterStore: meterStore,
            volumeService: volumeService,
            permissionService: AudioPermissionService(),
            systemDefaultObserver: systemDefaultObserver,
            sampleRateService: sampleRateService
        )
        
        // Log macOS system default output
        if let macDefault = systemDefaultObserver.getCurrentSystemDefaultOutputUID() {
            if let device = deviceManager.device(forUID: macDefault) {
                logger.info("EqualiserStore.init: macOS default output: '\(device.name)' (uid=\(macDefault))")
            } else {
                logger.info("EqualiserStore.init: macOS default output uid=\(macDefault) (device not in list)")
            }
        } else {
            logger.warning("EqualiserStore.init: No macOS default output device found")
        }

        // Restore app-level state
        logger.debug("Loading from snapshot: outputDeviceID=\(snapshot.outputDeviceID ?? "nil"), manualMode=\(snapshot.manualModeEnabled)")
        _bandwidthDisplayMode = Published(initialValue: BandwidthDisplayMode(rawValue: snapshot.bandwidthDisplayMode) ?? .qFactor)

        // Restore capture mode preference
        routingCoordinator.captureMode = CaptureMode(rawValue: snapshot.captureMode) ?? .sharedMemory

        if snapshot.manualModeEnabled {
            // Manual mode: load saved devices
            routingCoordinator.selectedInputDeviceID = snapshot.inputDeviceID
            routingCoordinator.selectedOutputDeviceID = snapshot.outputDeviceID
            routingCoordinator.manualModeEnabled = true
            logger.debug("Manual mode: loaded saved devices")
        } else {
            // Automatic mode: use unified selection logic
            routingCoordinator.manualModeEnabled = false
            restoreAutomaticOutputDevice(currentSelected: snapshot.outputDeviceID)
        }

        compareModeTimer.onRevert = { [weak self] in
            self?.compareMode = .eq
        }

        persistence.setStore(self)
        
        // Start observing system default changes
        systemDefaultObserver.startObserving()
        
        // Check if driver prompt should be shown (automatic mode without driver)
        // Defer to next run loop so onChange can observe the transition
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            // Forward driver prompt state from routing coordinator
            routingCoordinator.$showDriverPrompt
                .receive(on: DispatchQueue.main)
                .sink { [weak self] showPrompt in
                    guard let self else { return }
                    if showPrompt && !self.routingCoordinator.manualModeEnabled && !self.routingCoordinator.driverAccess.isReady {
                        self.logger.info("Automatic mode but driver not installed - showing prompt")
                    }
                }
                .store(in: &self.cancellables)
            
            if !routingCoordinator.manualModeEnabled && !routingCoordinator.driverAccess.isReady {
                self.logger.info("Automatic mode but driver not installed - showing prompt")
                self.routingCoordinator.showDriverPrompt = true
                self.routingCoordinator.routingStatus = .driverNotInstalled
            } else {
                // Driver visibility is now automatic
                if routingCoordinator.selectedOutputDeviceID != nil {
                    // Auto-start routing if devices are selected
                    self.routingCoordinator.reconfigureRouting()
                }
            }

        }
        
        // Wire up EQ configuration changes
        eqConfiguration.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        presetManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        // Forward routing coordinator changes
        routingCoordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward device manager changes (device list updates)
        deviceManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Re-wire RTA / goniometer taps when routing becomes active (new pipeline context).
        routingCoordinator.$routingStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, case .active = status else { return }
                self.wireRTAAnalyzer()
                if let sr = self.routingCoordinator.pipelineManager.renderPipeline?.sampleRate {
                    self.rtaAnalyzer.assumedSampleRate = Float(sr)
                }
                self.refreshHighResDecouplingStatus()
                // ADD: restore processing mode and IR state after pipeline restart
                self.routingCoordinator.updateProcessingMode(systemEQOff: self.isBypassed, compareMode: self.compareMode, channelMode: self.channelMode)
                if self.compareMode == .linearEQ {
                    self.routingCoordinator.eqStager.refreshLinearPhaseIRIfNeeded()
                }
                if self.compareMode == .mixedPhase {
                    self.routingCoordinator.eqStager.refreshMixedPhaseIRIfNeeded()
                }
            }
            .store(in: &cancellables)

        // Observe listening RTA enabled state to update RTA analyzer display mode
        routingCoordinator.$listeningRTAEnabled
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if enabled {
                    self.rtaAnalyzer.displayMode = .slowAverage(seconds: 20.0)
                } else {
                    self.rtaAnalyzer.displayMode = .standard
                    self.listeningRTAData = []
                }
            }
            .store(in: &cancellables)

        // Observe RTA analyzer display mode to publish slow average data
        rtaAnalyzer.$displayMode
            .sink { [weak self] mode in
                guard let self = self else { return }
                if case .slowAverage = mode {
                    // Publish slow average data periodically
                    Timer.publish(every: 0.1, on: .main, in: .common)
                        .autoconnect()
                        .sink { [weak self] _ in
                            self?.listeningRTAData = self?.rtaAnalyzer.getSlowAverageData() ?? []
                        }
                        .store(in: &self.cancellables)
                }
            }
            .store(in: &cancellables)

        // Listen for app termination
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        // After all state is restored, check if settings differ from selected preset
        if presetManager.selectedPresetName != nil {
            let matches = presetManager.settingsMatchSelectedPreset(
                activeBandCount: eqConfiguration.activeBandCount,
                bands: eqConfiguration.bands,
                inputGain: eqConfiguration.inputGain,
                outputGain: eqConfiguration.outputGain,
                dynamicsConfig: eqConfiguration.dynamicsConfig
            )
            if !matches {
                presetManager.isModified = true
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - App Lifecycle
    
    @objc private func handleAppWillTerminate() {
        logger.info("App terminating, stopping routing")
        routingCoordinator.stopRouting()
        // Driver visibility is now automatic
    }
    
    // MARK: - Routing Delegation
    
    func reconfigureRouting() {
        routingCoordinator.reconfigureRouting()
    }
    
    func stopRouting() {
        routingCoordinator.stopRouting()
    }
    
    func handleDriverInstalled() {
        routingCoordinator.handleDriverInstalled()
    }
    
    /// Switches to manual mode after requesting microphone permission.
    /// Manual mode uses HAL input capture, which requires microphone permission.
    /// - Returns: True if permission was granted and mode switched, false otherwise.
    @discardableResult
    @MainActor
    func switchToManualMode() async -> Bool {
        await routingCoordinator.requestMicPermissionAndSwitchToManualMode()
    }
    
    /// Switches to manual mode synchronously (for compatibility).
    /// Note: This should only be used when permission is already known to be granted.
    func switchToManualMode() {
        routingCoordinator.switchToManualMode()
    }
    
    /// Switches to automatic mode (uses shared memory capture by default).
    func switchToAutomaticMode() {
        routingCoordinator.switchToAutomaticMode()
    }

    // MARK: - Room Correction Sweep Measurement

    /// Starts a loopback measurement for room correction.
    /// Generates a sweep, plays it through the output, captures via mic input,
    /// and computes the room response.
    func startLoopbackMeasurement() {
        measurementState = .playing
        measurementError = nil

        // Generate 10-second log-swept sine from 20 Hz to 20 kHz
        let sampleRate = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        let analyser = SweepAnalyser(sampleRate: sampleRate, duration: 10.0, startFrequency: 20.0, endFrequency: 20000.0)
        sweepAnalyser = analyser

        // Store reference sweep signal
        let sweep = analyser.sweepSignal

        // Start sweep playback
        routingCoordinator.pipelineManager.renderPipeline?.setSweepAnalyser(analyser)
        routingCoordinator.pipelineManager.renderPipeline?.onSweepPlaybackComplete = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                // Wait 0.5s for reverb tail
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.measurementState = .capturing
                self.sweepAnalyser?.stopRecording()

                // Compute impulse response and frequency response on background thread
                self.measurementState = .computing

                // Capture data needed for computation
                guard let analyser = self.sweepAnalyser else { return }
                let capturedSweep = sweep

                Task { @MainActor in
                    let ir = analyser.computeImpulseResponse(referenceSweep: capturedSweep)
                    let response = analyser.computeFrequencyResponse(ir: ir, micCalibration: micCalibration)

                    self.measuredResponse = response
                    self.measurementState = .done
                }
            }
        }
        routingCoordinator.pipelineManager.renderPipeline?.startSweepPlayback(signal: sweep)
    }

    /// Applies room correction bands to the current EQ.
    /// - Parameter maxBands: Maximum number of correction bands (8-20, default 16)
    func applyRoomCorrection(maxBands: Int = 16) {
        let sampleRate = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        let bands = RoomCorrectionEngine.fitBands(
            measured: measuredResponse,
            target: targetCurve,
            sampleRate: sampleRate,
            maxBands: maxBands
        )

        // Apply bands using the existing stager API
        routingCoordinator.eqStager.applyRoomCorrectionBands(bands)

        // Enable room correction
        var adv = dynamicsConfig.advanced
        adv.roomCorrectionEnabled = true
        updateAdvancedProcessing(adv)
        roomCorrectionBandCount = bands.count
    }

    /// Computes and loads a minimum-phase FIR correction from the most recent loopback measurement.
    /// Call after `applyRoomCorrection()` to upgrade from IIR to FIR correction.
    /// - Parameters:
    ///   - tapCount: IR length in samples. Must be a power of two. 4096 ≈ 85 ms at 48 kHz.
    func applyFIRRoomCorrection(tapCount: Int = 4096) {
        guard !measuredResponse.isEmpty else { return }
        let sr  = Double(streamSampleRate)
        let measured = measuredResponse
        let tgt = targetCurve

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let (left, right) = RoomCorrectionEngine.minimumPhaseFIRCorrection(
                measured:              measured,
                target:                tgt,
                sampleRate:            sr,
                tapCount:              tapCount
            )
            await MainActor.run {
                self.routingCoordinator.pipelineManager.renderPipeline?
                    .callbackContext?.updateConvolutionIR(left: left, right: right)
                self.routingCoordinator.pipelineManager.renderPipeline?
                    .callbackContext?.setConvolutionEnabled(true)
                self.convolutionConfig.enabled = true
                self.convolutionConfig.irDisplayName = "Room Correction (FIR)"
                self.convolutionConfig.irBookmark = nil
            }
        }
    }

    /// Loads a target curve from a CSV file.
    /// Expected format: one row per point, comma-separated: `frequency_hz,gain_db`
    /// Lines beginning with '#' are treated as comments and ignored.
    func importTargetCurveFromCSV(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var points: [(frequency: Double, gainDB: Double)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 2,
                  let f = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let g = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  f > 0 else { continue }
            points.append((frequency: f, gainDB: g))
        }
        guard points.count >= 2 else { throw TargetCurveError.insufficientPoints }
        targetCurve = points.sorted { $0.frequency < $1.frequency }
        selectedTargetCurveName = url.deletingPathExtension().lastPathComponent
    }

    /// Exports the current EQ band configuration to REW (Room EQ Wizard) filter text format.
    func exportREW(channel: EQChannelTarget = .left) -> String {
        let bands = channel == .left ? eqConfiguration.leftState.userEQ.bands : eqConfiguration.rightState.userEQ.bands
        return REWExporter.export(bands: bands, channelLabel: channel == .left ? "Left" : "Right")
    }

    /// Exports the current EQ configuration to AutoEQ ParametricEQ text format.
    func exportAutoEQ() -> String {
        // Export left channel (or linked if in linked mode)
        let bands = eqConfiguration.leftState.userEQ.bands
        let preampDB = -max(0, bands.map { $0.gain }.filter { !$0.isNaN }.max() ?? 0)
        return AutoEQExporter.exportParametricEQ(bands: bands, preampDB: preampDB)
    }

    /// Called by the UI "Start Sweep" button.
    func startSweepMeasurement() {
        sweepAnalyser = makeSweepAnalyser()
        sweepAnalyser?.startRecording()
        routingCoordinator.pipelineManager.renderPipeline?.setSweepAnalyser(sweepAnalyser)
        routingCoordinator.pipelineManager.renderPipeline?.startSweepPlayback(
            signal: sweepAnalyser!.sweepSignal
        )
    }

    /// Called by the UI "Stop Measurement" button (or automatically when sweep ends).
    func stopSweepMeasurement(seatIndex: Int) {
        routingCoordinator.pipelineManager.renderPipeline?.stopSweepPlayback()
        sweepAnalyser?.stopRecording()
        guard let analyser = sweepAnalyser else { return }
        let ir = analyser.computeImpulseResponse(referenceSweep: analyser.sweepSignal)
        let curve = analyser.computeFrequencyResponse(ir: ir, micCalibration: micCalibration)
        if seatIndex == 0 || pendingMeasuredCurve == nil {
            pendingMeasuredCurve = curve
        } else {
            // Average with existing measurement (logarithmic average in dB).
            pendingMeasuredCurve = averageFrequencyCurves(pendingMeasuredCurve!, curve)
        }
    }

    /// Adds a single-seat measurement to the multi-seat collection (Part 4.2).
    func addSeatMeasurement() {
        guard let curve = pendingMeasuredCurve else { return }
        // For now, convert magnitude-only to complex with zero phase (legacy path)
        // TODO: Update to use complex data from SweepAnalyser
        let complexResponse = curve.map { point in
            let magnitude = pow(10.0, point.gainDB / 20.0)
            return SeatMeasurement.ComplexPoint(frequency: point.frequency, real: magnitude, imag: 0.0) // Zero phase for legacy
        }
        let weight = seatMeasurements.isEmpty ? 1.5 : 1.0 // Primary seat gets higher weight
        seatMeasurements.append(SeatMeasurement(complexResponse: complexResponse, weight: weight))
        pendingMeasuredCurve = nil
        roomCorrectionPresetManager.markAsModified()
    }

    /// Clears all accumulated seat measurements.
    func clearSeatMeasurements() {
        seatMeasurements.removeAll()
        roomCorrectionPresetManager.markAsModified()
    }

    /// Updates the weight for a specific seat measurement (Part 4.2).
    func updateSeatWeight(at index: Int, weight: Double) {
        guard index >= 0 && index < seatMeasurements.count else { return }
        seatMeasurements[index].weight = max(0.25, min(2.0, weight))
        roomCorrectionPresetManager.markAsModified()
    }

    /// Imports a REW measurement file as a seat measurement (Part 4.3).
    func importREWMeasurement(url: URL) {
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let result = try REWImporter.importMeasurement(from: url)
                await MainActor.run { [self] in
                    let weight = self.seatMeasurements.isEmpty ? 1.5 : 1.0 // Primary seat gets higher weight
                    let seatMeasurement = SeatMeasurement(complexResponse: result.complexResponse, weight: weight)
                    self.seatMeasurements.append(seatMeasurement)
                    self.roomCorrectionPresetManager.markAsModified()
                    // Show warnings if any
                    if !result.warnings.isEmpty {
                        self.measurementError = result.warnings.joined(separator: "\n")
                    }
                }
            } catch {
                await MainActor.run { [self] in
                    self.measurementError = error.localizedDescription
                }
            }
        }
    }

    /// Computes complex average of all seat measurements and stores in pendingMeasuredCurve (Part 4.2).
    func applyMultiSeatCalibration() {
        guard !seatMeasurements.isEmpty else { return }
        pendingMeasuredCurve = averageComplexResponses(seatMeasurements)
    }

    /// Computes weighted complex average of seat measurements (Part 4.2).
    private func averageComplexResponses(_ seats: [SeatMeasurement]) -> [(frequency: Double, gainDB: Double)] {
        guard !seats.isEmpty else { return [] }

        let first = seats[0]
        var weightedSum: [(re: Double, im: Double)] = first.complexResponse.map { _ in (0.0, 0.0) }
        var totalWeight: Double = 0.0

        for seat in seats {
            let weight = seat.weight
            totalWeight += weight
            for (i, point) in seat.complexResponse.enumerated() {
                weightedSum[i].re += weight * point.real
                weightedSum[i].im += weight * point.imag
            }
        }

        // Convert weighted complex average back to magnitude in dB
        return first.complexResponse.enumerated().map { i, point in
            let avgRe = weightedSum[i].re / totalWeight
            let avgIm = weightedSum[i].im / totalWeight
            let avgMag = sqrt(avgRe * avgRe + avgIm * avgIm)
            let avgGainDB = avgMag > 0 ? 20.0 * log10(avgMag) : -120.0
            return (point.frequency, avgGainDB)
        }
    }

    private func averageFrequencyCurves(
        _ a: [(frequency: Double, gainDB: Double)],
        _ b: [(frequency: Double, gainDB: Double)]
    ) -> [(frequency: Double, gainDB: Double)] {
        // Use curve A's frequency grid; interpolate B onto it.
        return a.map { pointA in
            let gainB = interpolateLog(curve: b, atHz: pointA.frequency)
            return (pointA.frequency, (pointA.gainDB + gainB) / 2.0)
        }
    }

    private func interpolateLog(
        curve: [(frequency: Double, gainDB: Double)], atHz f: Double
    ) -> Double {
        guard curve.count > 1 else { return curve.first?.gainDB ?? 0 }
        if f <= curve.first!.frequency { return curve.first!.gainDB }
        if f >= curve.last!.frequency  { return curve.last!.gainDB }
        for i in 0..<(curve.count - 1) {
            let lo = curve[i], hi = curve[i + 1]
            if f >= lo.frequency && f <= hi.frequency {
                let t = log(f / lo.frequency) / log(hi.frequency / lo.frequency)
                return lo.gainDB + t * (hi.gainDB - lo.gainDB)
            }
        }
        return 0
    }

    // MARK: - EQ Control
    
    /// Updates the gain for a specific EQ band.
    func updateBandGain(index: Int, gain: Float) {
        eqConfiguration.updateBandGain(index: index, gain: gain)
        routingCoordinator.updateBandGain(index: index)
        if eqConfiguration.bands[index].isDynamic {
            let merged = eqConfiguration.buildMergedDynamicEQConfig()
            var updatedDynamics = dynamicsConfig
            updatedDynamics.advanced.dynamicEQ = merged
            routingCoordinator.updateDynamicsConfig(updatedDynamics)
        }
        presetManager.markAsModified()
    }
    
    /// Updates the Q factor for a specific EQ band.
    func updateBandQ(index: Int, q: Float) {
        eqConfiguration.updateBandQ(index: index, q: q)
        routingCoordinator.updateBandQ(index: index)
        if eqConfiguration.bands[index].isDynamic {
            let merged = eqConfiguration.buildMergedDynamicEQConfig()
            var updatedDynamics = dynamicsConfig
            updatedDynamics.advanced.dynamicEQ = merged
            routingCoordinator.updateDynamicsConfig(updatedDynamics)
        }
        presetManager.markAsModified()
    }
    
    /// Updates the frequency for a specific EQ band.
    func updateBandFrequency(index: Int, frequency: Float) {
        eqConfiguration.updateBandFrequency(index: index, frequency: frequency)
        routingCoordinator.updateBandFrequency(index: index)
        if eqConfiguration.bands[index].isDynamic {
            let merged = eqConfiguration.buildMergedDynamicEQConfig()
            var updatedDynamics = dynamicsConfig
            updatedDynamics.advanced.dynamicEQ = merged
            routingCoordinator.updateDynamicsConfig(updatedDynamics)
        }
        presetManager.markAsModified()
    }
    
    /// Updates the filter type for a specific EQ band.
    func updateBandFilterType(index: Int, filterType: FilterType) {
        eqConfiguration.updateBandFilterType(index: index, filterType: filterType)
        routingCoordinator.updateBandFilterType(index: index)
        presetManager.markAsModified()
    }

    /// Updates the filter slope for a specific EQ band.
    func updateBandSlope(index: Int, slope: FilterSlope) {
        eqConfiguration.updateBandSlope(index: index, slope: slope)
        routingCoordinator.updateBandSlope(index: index)
        presetManager.markAsModified()
    }

    /// Updates the bypass state for a specific EQ band.
    func updateBandBypass(index: Int, bypass: Bool) {
        eqConfiguration.updateBandBypass(index: index, bypass: bypass)
        routingCoordinator.updateBandBypass(index: index)
        if eqConfiguration.bands[index].isDynamic {
            let merged = eqConfiguration.buildMergedDynamicEQConfig()
            var updatedDynamics = dynamicsConfig
            updatedDynamics.advanced.dynamicEQ = merged
            routingCoordinator.updateDynamicsConfig(updatedDynamics)
        }
        presetManager.markAsModified()
    }

    /// Removes the band at the given index, shifting subsequent bands left.
    /// Propagates the change to the audio pipeline.
    func removeBand(at index: Int) {
        eqConfiguration.removeBand(at: index)
        guard routingCoordinator.routingStatus.isActive else { return }
        routingCoordinator.reapplyConfiguration()
        presetManager.markAsModified()
    }

    /// Sets whether an EQ band operates in Dynamic mode and propagates the
    /// change to the audio pipeline via a full dynamics config push.
    func updateBandDynamicMode(index: Int, isDynamic: Bool) {
        // Enforce 8-band cap
        if isDynamic {
            let currentDynamicCount = eqConfiguration.bands.filter { $0.isDynamic }.count
            if currentDynamicCount >= DynamicEQConfig.maxDynamicEQBands {
                return // Reject toggle - UI should show message
            }
        }
        
        eqConfiguration.updateBandDynamicMode(index: index, isDynamic: isDynamic)
        let merged = eqConfiguration.buildMergedDynamicEQConfig()
        var updatedDynamics = dynamicsConfig
        updatedDynamics.advanced.dynamicEQ = merged
        routingCoordinator.updateDynamicsConfig(updatedDynamics)
        routingCoordinator.reapplyConfiguration()
        presetManager.markAsModified()
    }

    /// Updates the dynamic envelope parameters for an EQ band and propagates
    /// the change to the audio pipeline.
    func updateBandDynamicParams(index: Int, params: DynamicBandParams) {
        eqConfiguration.updateBandDynamicParams(index: index, params: params)
        let merged = eqConfiguration.buildMergedDynamicEQConfig()
        var updatedDynamics = dynamicsConfig
        updatedDynamics.advanced.dynamicEQ = merged
        routingCoordinator.updateDynamicsConfig(updatedDynamics)
        presetManager.markAsModified()
    }
    
    /// Updates the band count and marks the preset as modified.
    func updateBandCount(_ count: Int) {
        let clamped = EQConfiguration.clampBandCount(count)
        bandCount = clamped
        presetManager.markAsModified()
    }
    
    /// Updates the input gain and marks the preset as modified.
    func updateInputGain(_ gain: Float) {
        inputGain = gain
        presetManager.markAsModified()
    }
    
    /// Updates the output gain and marks the preset as modified.
    func updateOutputGain(_ gain: Float) {
        outputGain = gain
        presetManager.markAsModified()
    }
    
    /// Sets the window reference for visibility checking.
    func setEqualiserWindow(_ window: NSWindow?) {
        meterStore.setEqualiserWindow(window)
    }

    /// Starts noise profile capture on the denoiser.
    func startNoiseCapture() {
        routingCoordinator.pipelineManager.renderPipeline?.callbackContext?.startNoiseCapture()
    }

    /// Resets the noise profile on the denoiser.
    func resetNoiseProfile() {
        routingCoordinator.pipelineManager.renderPipeline?.callbackContext?.resetNoiseProfile()
    }
    
    // MARK: - Preset Management
    
    /// Saves the current EQ settings as a new preset.
    @discardableResult
    func saveCurrentAsPreset(named name: String) throws -> Preset {
        let preset = try presetManager.createPreset(
            named: name,
            from: eqConfiguration,
            inputGain: inputGain,
            outputGain: outputGain
        )
        presetManager.selectPreset(named: name)
        return preset
    }
    
    /// Updates the currently selected preset with current EQ settings.
    func updateCurrentPreset() throws {
        guard let currentName = presetManager.selectedPresetName else { return }
        try saveCurrentAsPreset(named: currentName)
    }
    
    /// Loads a preset and applies it to the EQ configuration.
    func loadPreset(_ preset: Preset) {
        // Apply settings to EQ configuration (also sets eqConfiguration.dynamicsConfig)
        presetManager.applyPreset(preset, to: eqConfiguration)

        // Apply input/output gains
        inputGain = preset.settings.inputGain
        outputGain = preset.settings.outputGain

        // Push dynamics config to the running pipeline (pipeline rebuild via
        // reapplyConfiguration also picks it up, but an explicit push ensures
        // the processor is updated even when no rebuild occurs).
        routingCoordinator.updateDynamicsConfig(preset.settings.dynamicsConfig)

        // Reapply to audio engine if active
        routingCoordinator.reapplyConfiguration()

        // Mark as selected (not modified since we just loaded it)
        presetManager.selectPreset(named: preset.metadata.name)
    }
    
    /// Loads a preset by name.
    func loadPreset(named name: String) {
        guard let preset = presetManager.preset(named: name) else {
            logger.warning("Preset not found: \(name)")
            return
        }
        loadPreset(preset)
    }
    
    /// Flattens all band gains to 0 dB while preserving current band configuration.
    func flattenBands() {
        // Reset all bands to flat
        for i in 0..<eqConfiguration.activeBandCount {
            eqConfiguration.updateBandGain(index: i, gain: 0)
        }
        
        // Reset gains
        inputGain = 0
        outputGain = 0
        isBypassed = false
        
        // Reapply to audio engine if active
        routingCoordinator.reapplyConfiguration()
        
        // Mark preset as modified
        presetManager.markAsModified()
    }
    
    /// Creates a new preset with 10 bands spread across the frequency spectrum.
    func createNewPreset() {
        // Always reset to 10 bands with proper frequency spreading
        bandCount = 10
        _ = eqConfiguration.setActiveBandCount(10, preserveConfiguredBands: false)
        
        // Force frequency reset
        eqConfiguration.resetBandsWithFrequencySpread()
        
        // Reset gains
        inputGain = 0
        outputGain = 0
        isBypassed = false
        
        // Reapply to audio engine
        routingCoordinator.reapplyConfiguration()
        
        // Clear preset selection (this is a new unsaved preset)
        presetManager.selectPreset(named: nil)
    }

    // MARK: - Room Correction Preset Management

    /// Saves the current room correction settings as a new preset.
    @discardableResult
    func saveCurrentAsRoomCorrectionPreset(named name: String) throws -> RoomCorrectionPreset {
        let settings = RoomCorrectionPresetSettings(
            targetCurveName: selectedTargetCurveName,
            customTargetCurve: selectedTargetCurveName == "Custom…" ? targetCurve.map(TargetCurvePoint.init) : nil,
            seatMeasurements: seatMeasurements,
            measuredResponse: measuredResponse.map(TargetCurvePoint.init),
            micCalibration: micCalibration,
            appliedBands: eqConfiguration.leftState.roomCorrection.bands
                .prefix(eqConfiguration.leftState.roomCorrection.activeBandCount)
                .map { PresetBand(from: $0) },
            roomCorrectionEnabled: dynamicsConfig.advanced.roomCorrectionEnabled,
            firTapCount: nil, // FIR correction not yet implemented for room correction presets
            firCorrectionApplied: false
        )
        let preset = RoomCorrectionPreset(
            metadata: RoomCorrectionPresetMetadata(name: name, createdAt: Date(), modifiedAt: Date()),
            settings: settings
        )
        try roomCorrectionPresetManager.savePreset(preset)
        roomCorrectionPresetManager.selectPreset(named: name)
        return preset
    }

    /// Updates the currently selected room correction preset with current settings.
    func updateCurrentRoomCorrectionPreset() throws {
        guard let currentName = roomCorrectionPresetManager.selectedPresetName else { return }
        try saveCurrentAsRoomCorrectionPreset(named: currentName)
    }

    /// Loads a room correction preset and applies it.
    func loadRoomCorrectionPreset(_ preset: RoomCorrectionPreset) {
        selectedTargetCurveName = preset.settings.targetCurveName
        if let custom = preset.settings.customTargetCurve {
            targetCurve = custom.map { ($0.frequency, $0.gainDB) }
        } else if let curve = TargetCurveLibrary.allCurves.first(where: { $0.name == preset.settings.targetCurveName }) {
            targetCurve = curve.curve
        }
        seatMeasurements = preset.settings.seatMeasurements
        measuredResponse = preset.settings.measuredResponse.map { ($0.frequency, $0.gainDB) }
        micCalibration = preset.settings.micCalibration

        // Re-stage the already-fitted bands directly (instant path — no re-fit needed).
        let bands = preset.settings.appliedBands.map { $0.toEQBandConfiguration() }
        routingCoordinator.eqStager.applyRoomCorrectionBands(bands)
        roomCorrectionBandCount = bands.count
        routingCoordinator.eqStager.setRoomCorrectionLayerBypass(!preset.settings.roomCorrectionEnabled)

        if preset.settings.firCorrectionApplied, let tapCount = preset.settings.firTapCount {
            // Recompute path, per §4.2 recommendation — re-derive rather than store raw samples.
            // Note: FIR room correction not yet implemented, this is a placeholder.
            logger.info("FIR room correction not yet implemented")
        }

        var adv = dynamicsConfig.advanced
        adv.roomCorrectionEnabled = preset.settings.roomCorrectionEnabled
        updateAdvancedProcessing(adv)
        recomputeStaticPreamp()

        roomCorrectionPresetManager.selectPreset(named: preset.metadata.name)
    }

    /// Loads a room correction preset by name.
    func loadRoomCorrectionPreset(named name: String) {
        guard let preset = roomCorrectionPresetManager.preset(named: name) else { return }
        loadRoomCorrectionPreset(preset)
    }

    /// Discards the current room correction calibration and deselects any preset.
    func createNewRoomCorrectionPreset() {
        clearRoomCalibration()
        clearSeatMeasurements()
        measuredResponse = []
        pendingMeasuredCurve = nil
        roomCorrectionPresetManager.selectPreset(named: nil)
    }

    // MARK: - Helpers

    /// Determines the automatic-mode output device at startup using unified selection logic.
    /// Handles both snapshot restoration (currentSelected from saved state) and first launch (nil).
    private func restoreAutomaticOutputDevice(currentSelected: String?) {
        let macDefault = systemDefaultObserver.getCurrentSystemDefaultOutputUID()
        let selection = OutputDeviceSelection.determine(
            currentSelected: currentSelected,
            macDefault: macDefault,
            availableDevices: deviceManager.outputDevices
        )

        switch selection {
        case .preserveCurrent(let uid):
            routingCoordinator.selectedOutputDeviceID = uid
            logger.debug("Startup: preserving saved output device")

        case .useMacDefault(let uid):
            routingCoordinator.selectedOutputDeviceID = uid
            if let device = deviceManager.device(forUID: uid) {
                logger.debug("Startup: using macOS default '\(device.name)'")
            }

        case .useFallback:
            if let fallback = deviceManager.selectFallbackOutputDevice() {
                routingCoordinator.selectedOutputDeviceID = fallback.uid
                logger.info("Startup: using fallback output '\(fallback.name)'")
            } else {
                logger.error("Startup: no output device available")
            }
        }

        // Input is always driver in automatic mode
        routingCoordinator.selectedInputDeviceID = DRIVER_DEVICE_UID
    }

    static func clampGain(_ gain: Float) -> Float {
        AudioConstants.clampGain(gain)
    }

    /// Builds a `DynamicEQConfig` that merges all inline dynamic bands from the
    /// current EQ configuration into a single config for the DynamicsProcessor.
    ///
    /// Inline bands (from the EQ band strip) are listed first in band-strip order.
    /// Legacy standalone bands from `dynamicsConfig.advanced.dynamicEQ` follow,
    /// preserved for backward compatibility with older presets.
    ///
    /// The total is clamped to `DynamicEQConfig.maxDynamicEQBands`.
    func buildMergedDynamicEQConfig() -> DynamicEQConfig {
        let activeBands = eqConfiguration.bands.prefix(eqConfiguration.activeBandCount)

        let inlineBands: [DynamicEQBand] = activeBands.compactMap { band in
            guard band.isDynamic else { return nil }
            return DynamicEQBand(
                frequency:   band.frequency,
                q:           band.q,
                gain:        band.gain,
                thresholdDB: band.dynamicParams.thresholdDB,
                ratio:       band.dynamicParams.ratio,
                attackMs:    band.dynamicParams.attackMs,
                releaseMs:   band.dynamicParams.releaseMs,
                bypass:      band.bypass
            )
        }

        // Legacy standalone bands — non-zero only when loading old presets
        let standaloneBands = eqConfiguration.dynamicsConfig.advanced.dynamicEQ.bands

        let allBands = Array((inlineBands + standaloneBands)
            .prefix(DynamicEQConfig.maxDynamicEQBands))

        let hasActiveBand = allBands.contains { !$0.bypass }

        return DynamicEQConfig(enabled: hasActiveBand, bands: allBands)
    }

    // MARK: - RTA

    /// Connects the RTA analyser's ring buffers to the audio render pipeline's tap points.
    /// Safe to call multiple times; no-op when no pipeline is active.
    /// Updates runtime high-res decoupling status and re-stages EQ if needed.
    func refreshHighResDecouplingStatus(forceReapply: Bool = false) {
        let sr = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        let engaged = dynamicsConfig.advanced.coefficientDecouplingEnabled && sr > 96_000
        let statusChanged = dynamicsConfig.advanced.highResDecouplingActive != engaged
        if statusChanged {
            var adv = dynamicsConfig.advanced
            adv.highResDecouplingActive = engaged
            var config = dynamicsConfig
            config.advanced = adv
            dynamicsConfig = config
        }
        if forceReapply || statusChanged {
            routingCoordinator.eqStager.reapplyConfiguration()
        }
    }

    func wireRTAAnalyzer() {
        routingCoordinator.pipelineManager.renderPipeline?.setRTABuffers(
            input:  rtaAnalyzer.inputRingBuffer,
            output: rtaAnalyzer.outputRingBuffer
        )
        routingCoordinator.pipelineManager.renderPipeline?.setGoniometerEngine(goniometerEngine)
    }

    func applyRoomCalibration() {
        guard let measured = pendingMeasuredCurve else { return }
        let target = buildTargetCurve()
        let sr = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        let bands = RoomCorrectionEngine.fitBands(measured: measured, target: target, sampleRate: sr)
        routingCoordinator.eqStager.applyRoomCorrectionBands(bands)
        var adv = dynamicsConfig.advanced
        adv.roomCorrectionEnabled = true
        updateAdvancedProcessing(adv)
        roomCorrectionBandCount = bands.count
        pendingMeasuredCurve = nil
        recomputeStaticPreamp()
        roomCorrectionPresetManager.markAsModified()
    }

    func clearRoomCalibration() {
        routingCoordinator.eqStager.clearRoomCorrectionBands()
        var adv = dynamicsConfig.advanced
        adv.roomCorrectionEnabled = false
        updateAdvancedProcessing(adv)
        roomCorrectionBandCount = 0
        if convolutionConfig.irDisplayName == "Room Correction (FIR)" {
            clearConvolutionIR()
        }
        recomputeStaticPreamp()
        roomCorrectionPresetManager.markAsModified()
    }

    // MARK: - Convolution Engine

    func loadConvolutionIR(url: URL) {
        convolutionLoadError = nil
        let sr = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        Task.detached(priority: .userInitiated) {
            do {
                let result = try IRFileLoader.load(url: url, targetSampleRate: sr)
                let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                await MainActor.run {
                    self.routingCoordinator.updateConvolutionIR(
                        left: result.leftSamples,
                        right: result.rightSamples
                    )
                    self.convolutionConfig.irDisplayName = result.displayName
                    self.convolutionConfig.irBookmark    = bookmark
                    // Auto-enable on successful load
                    if !self.convolutionConfig.enabled {
                        self.setConvolutionEnabled(true)
                    }
                }
            } catch {
                await MainActor.run {
                    self.convolutionLoadError = error.localizedDescription
                }
            }
        }
    }

    func setConvolutionEnabled(_ enabled: Bool) {
        convolutionConfig.enabled = enabled
        routingCoordinator.pipelineManager.renderPipeline?.callbackContext?
            .setConvolutionEnabled(enabled && convolutionConfig.irDisplayName != nil)
    }

    func clearConvolutionIR() {
        setConvolutionEnabled(false)
        convolutionConfig.irDisplayName = nil
        convolutionConfig.irBookmark = nil
        convolutionLoadError = nil
        routingCoordinator.updateConvolutionIR(left: [], right: [])
    }

    func loadFIRImpulseResponse(url: URL) {
        let sr = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        Task.detached(priority: .userInitiated) {
            do {
                let result = try IRFileLoader.load(url: url, targetSampleRate: sr)
                await MainActor.run {
                    var adv = self.dynamicsConfig.advanced
                    adv.firImpulseResponse.leftIR = result.leftSamples
                    adv.firImpulseResponse.rightIR = result.rightSamples
                    adv.firImpulseResponse.sampleRate = sr
                    adv.firImpulseResponse.tapCount = result.leftSamples.count
                    if !adv.firImpulseResponse.enabled {
                        adv.firImpulseResponse.enabled = true
                    }
                    self.updateAdvancedProcessing(adv)
                }
            } catch {
                await MainActor.run {
                    self.convolutionLoadError = error.localizedDescription
                }
            }
        }
    }

    func clearFIRImpulseResponse() {
        var adv = dynamicsConfig.advanced
        adv.firImpulseResponse = FIRImpulseResponseConfig()
        updateAdvancedProcessing(adv)
    }

    /// Loads a FIR kernel from a WAV/AIFF file into a specific EQ band.
    /// The band must have filterType == .fir for the kernel to be applied.
    func loadFIRBandKernel(url: URL, bandIndex: Int) {
        let sr = routingCoordinator.pipelineManager.renderPipeline?.sampleRate ?? 48_000
        Task.detached(priority: .userInitiated) {
            do {
                let result = try IRFileLoader.load(url: url, targetSampleRate: sr)
                await MainActor.run {
                    self.eqConfiguration.updateFIRBandKernel(
                        index: bandIndex,
                        leftKernel:  result.leftSamples,
                        rightKernel: result.rightSamples,
                        displayName: result.displayName
                    )
                    // Restage EQ to pick up the new kernel in LinearPhaseEQEngine.
                    self.routingCoordinator.reapplyConfiguration()
                    self.presetManager.markAsModified()
                }
            } catch {
                await MainActor.run {
                    self.convolutionLoadError = error.localizedDescription
                }
            }
        }
    }

    /// Clears the FIR kernel from a specific EQ band.
    func clearFIRBandKernel(bandIndex: Int) {
        eqConfiguration.updateFIRBandKernel(
            index: bandIndex,
            leftKernel: nil, rightKernel: nil, displayName: nil)
        routingCoordinator.reapplyConfiguration()
        presetManager.markAsModified()
    }

    /// Exports the complete current configuration as a CamillaDSP YAML string.
    ///
    /// Includes: main-chain EQ bands, room correction, active crossover, output channel routing,
    /// per-channel delays/gain/polarity/EQ/limiters, and group delay all-pass corrections.
    /// FIR bands are included as inline Conv filters (kernel values embedded in YAML).
    ///
    /// - Returns: A YAML string loadable directly by CamillaDSP.
    func exportCamillaDSP() -> String {
        let sr = Int(streamSampleRate)
        let playbackName = outputChannelMatrix.channels.first(where: { $0.isEnabled })?
            .target?.displayLabel ?? "Default Output Device"

        let leftRC  = Array(eqConfiguration.leftState.roomCorrection.bands
            .prefix(eqConfiguration.leftState.roomCorrection.activeBandCount))

        let config = CamillaDSPExportConfig(
            sampleRate: sr,
            chunkSize: 1024,
            captureDeviceName: "Notch Sixty",
            playbackDeviceName: playbackName,
            leftEQBands:  Array(eqConfiguration.leftState.userEQ.bands
                .prefix(eqConfiguration.leftState.userEQ.activeBandCount)),
            rightEQBands: Array(eqConfiguration.rightState.userEQ.bands
                .prefix(eqConfiguration.rightState.userEQ.activeBandCount)),
            roomCorrectionBands: leftRC,
            activeCrossover: dynamicsConfig.advanced.activeCrossover.isEnabled
                ? dynamicsConfig.advanced.activeCrossover
                : nil,
            outputMatrix: outputChannelMatrix.isEnabled
                ? outputChannelMatrix
                : nil,
            bassManagementCrossoverHz: dynamicsConfig.advanced.bassManagement.enabled
                ? dynamicsConfig.advanced.bassManagement.crossoverHz
                : nil,
            bassManagementSlope: dynamicsConfig.advanced.bassManagement.enabled
                ? dynamicsConfig.advanced.bassManagement.slope
                : nil
        )

        return CamillaDSPExporter.exportToYAML(config)
    }

    // MARK: - Microphone Calibration (Part 4.1)

    func loadMicCalibration(url: URL) {
        micCalibrationLoadError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let calibration = try MicCalibrationLoader.parse(from: url)
                await MainActor.run {
                    self.micCalibration = calibration
                    self.roomCorrectionPresetManager.markAsModified()
                }
            } catch {
                await MainActor.run {
                    self.micCalibrationLoadError = error.localizedDescription
                }
            }
        }
    }

    func clearMicCalibration() {
        micCalibration = nil
        micCalibrationLoadError = nil
        roomCorrectionPresetManager.markAsModified()
    }

    /// Call from routingStatus .active case (pipeline restart) alongside
    /// the linearEQ and mixedPhase restore calls from the prior spec.
    func reloadConvolutionIRFromBookmark() {
        guard let bookmark = convolutionConfig.irBookmark else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        // IRFileLoader.load will call stopAccessingSecurityScopedResource after reading
        loadConvolutionIR(url: url)
    }

    private func buildTargetCurve() -> [(frequency: Double, gainDB: Double)] {
        switch dynamicsConfig.advanced.targetCurveType {
        case .flat:
            return TargetCurveLibrary.flat
        case .houseCurve:
            // B&K / IEC 268-13 house curve: 3 dB/octave bass rise below 1 kHz.
            // Matches the "B&K house" option in the room correction target curve picker.
            return TargetCurveLibrary.bkHouse
        case .customREW:
            return customREWTargetCurve ?? TargetCurveLibrary.flat
        }
    }
}

enum TargetCurveError: Error {
    case insufficientPoints
}
