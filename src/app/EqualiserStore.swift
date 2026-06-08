// EqualiserStore.swift
// Thin coordinator for EQ application state

import Combine
import Foundation
import OSLog
import AppKit
import SwiftUI

@MainActor
final class EqualiserStore: ObservableObject {
    
    // MARK: - Computed Properties (delegate to EQConfiguration)
    
    /// Global bypass state - delegates to eqConfiguration.globalBypass.
    var isBypassed: Bool {
        get { eqConfiguration.globalBypass }
        set {
            eqConfiguration.globalBypass = newValue
            routingCoordinator.updateProcessingMode(systemEQOff: newValue, compareMode: compareMode)
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
            routingCoordinator.updateProcessingMode(systemEQOff: isBypassed, compareMode: compareMode)

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

    // MARK: - Forwarded Properties from RoutingCoordinator
    
    var routingStatus: RoutingStatus { routingCoordinator.routingStatus }
    
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
    let meterStore: MeterStore
    let updateService = UpdateCheckService()
    let rtaAnalyzer        = AdvancedDualSpectrumAnalyzer()
    let goniometerEngine   = GoniometerBufferEngine()
    private var sweepAnalyser: SweepAnalyser?

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
            eqConfiguration.dynamicsConfig = newValue
            routingCoordinator.updateDynamicsConfig(newValue)
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
    }

    @Published var pendingMeasuredCurve: [(frequency: Double, gainDB: Double)]? = nil
    @Published var roomCorrectionBandCount: Int = 0
    @Published var customREWTargetCurve: [(frequency: Double, gainDB: Double)]? = nil

    /// Accumulated measurement curves for multi-seat averaging.
    /// Each element is one full-range frequency response measurement.
    @Published var seatMeasurements: [[(frequency: Double, gainDB: Double)]] = []

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
    
    // MARK: - Initialization
    
    init(persistence: AppStatePersistence = AppStatePersistence()) {
        self.persistence = persistence
        
        // Load snapshot if exists
        let snapshot = persistence.load()
        
        // Initialize EQ configuration
        if let snapshot = snapshot {
            self.eqConfiguration = EQConfiguration(from: snapshot)
        } else {
            self.eqConfiguration = EQConfiguration()
        }
        
        // Initialize other components
        self.presetManager = PresetManager()
        self.meterStore = MeterStore(metersEnabled: snapshot?.metersEnabled ?? true)
        
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
        
        // Wire up callbacks
        compareModeTimer.onRevert = { [weak self] in
            self?.compareMode = .eq
        }
        
        persistence.setStore(self)
        
        // Restore app-level state
        if let snapshot = snapshot {
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
        } else {
            // First launch: automatic mode, use unified selection logic
            logger.info("First launch, no snapshot")
            routingCoordinator.manualModeEnabled = false
            restoreAutomaticOutputDevice(currentSelected: nil)
        }
        
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
                self.routingCoordinator.updateProcessingMode(systemEQOff: self.isBypassed, compareMode: self.compareMode)
                if self.compareMode == .linearEQ {
                    self.routingCoordinator.eqStager.refreshLinearPhaseIRIfNeeded()
                }
                if self.compareMode == .mixedPhase {
                    self.routingCoordinator.eqStager.refreshMixedPhaseIRIfNeeded()
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
        let curve = analyser.computeFrequencyResponse(channel: 0)
        if seatIndex == 0 || pendingMeasuredCurve == nil {
            pendingMeasuredCurve = curve
        } else {
            // Average with existing measurement (logarithmic average in dB).
            pendingMeasuredCurve = averageFrequencyCurves(pendingMeasuredCurve!, curve)
        }
    }

    /// Adds a single-seat measurement to the multi-seat collection.
    func addSeatMeasurement() {
        guard let curve = pendingMeasuredCurve else { return }
        seatMeasurements.append(curve)
        pendingMeasuredCurve = nil
    }

    /// Clears all accumulated seat measurements.
    func clearSeatMeasurements() {
        seatMeasurements.removeAll()
    }

    /// Computes complex average of all seat measurements and stores in pendingMeasuredCurve.
    func applyMultiSeatCalibration() {
        guard !seatMeasurements.isEmpty else { return }
        let first = seatMeasurements[0]
        var complexSum: [(re: Double, im: Double)] = first.map { _ in (0.0, 0.0) }
        for measurement in seatMeasurements {
            for (i, point) in measurement.enumerated() {
                let gain = pow(10.0, point.gainDB / 20.0)
                let phase = 0.0 // Assume zero phase for magnitude-only measurements
                complexSum[i].re += gain * cos(phase)
                complexSum[i].im += gain * sin(phase)
            }
        }
        let count = Double(seatMeasurements.count)
        pendingMeasuredCurve = first.enumerated().map { i, point in
            let avgRe = complexSum[i].re / count
            let avgIm = complexSum[i].im / count
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
        presetManager.markAsModified()
    }
    
    /// Updates the Q factor for a specific EQ band.
    func updateBandQ(index: Int, q: Float) {
        eqConfiguration.updateBandQ(index: index, q: q)
        routingCoordinator.updateBandQ(index: index)
        presetManager.markAsModified()
    }
    
    /// Updates the frequency for a specific EQ band.
    func updateBandFrequency(index: Int, frequency: Float) {
        eqConfiguration.updateBandFrequency(index: index, frequency: frequency)
        routingCoordinator.updateBandFrequency(index: index)
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
    }

    func clearRoomCalibration() {
        routingCoordinator.eqStager.clearRoomCorrectionBands()
        var adv = dynamicsConfig.advanced
        adv.roomCorrectionEnabled = false
        updateAdvancedProcessing(adv)
        roomCorrectionBandCount = 0
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
            return [(20, 0), (20000, 0)]
        case .houseCurve:
            return [(20, 2.0), (80, 2.0), (500, 0.0), (2000, 0.0), (10000, -1.0), (20000, -2.5)]
        case .customREW:
            return customREWTargetCurve ?? [(20, 0), (20000, 0)]
        }
    }
}
