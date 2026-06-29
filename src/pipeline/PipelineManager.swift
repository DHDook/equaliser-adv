// PipelineManager.swift
// Manages the audio render pipeline lifecycle

import Combine
import CoreAudio
import Foundation
import OSLog

/// Result of starting the audio pipeline.
enum PipelineStartResult {
    /// Pipeline started successfully.
    case success(sampleRate: Double)
    /// Pipeline configuration failed.
    case configurationFailed(String)
    /// Pipeline start failed.
    case startFailed(String)
}

/// Manages the RenderPipeline lifecycle: creation, configuration, starting, stopping,
/// and teardown. Also manages VolumeManager and EQ coefficient staging integration.
@MainActor
final class PipelineManager {

    // MARK: - Dependencies

    private let eqConfiguration: EQConfiguration
    private let meterStore: MeterStore
    private let volumeService: VolumeControlling
    private let eqStager: EQCoefficientStager

    // MARK: - State

    private(set) var renderPipeline: RenderPipeline?
    private(set) var volumeManager: VolumeManager?
    private var volumeManagerCancellable: AnyCancellable?

    /// Called on the main thread whenever the VolumeManager's gain or muted
    /// state changes. AudioRoutingCoordinator sets this to forward changes
    /// into its own objectWillChange so SwiftUI re-evaluates the slider binding.
    var onVolumeStateChanged: (() -> Void)?

    /// Called on the main thread with the new volume gain whenever it changes.
    /// AudioRoutingCoordinator sets this to update `EqualiserStore.liveSystemVolumeGain`
    /// so the loudness contour preview re-renders.
    var onVolumeGainDidChange: ((Float) -> Void)?

    private let logger = Logger(subsystem: "net.knage.equaliser", category: "PipelineManager")

    // MARK: - Initialization

    init(eqConfiguration: EQConfiguration, meterStore: MeterStore, volumeService: VolumeControlling, eqStager: EQCoefficientStager) {
        self.eqConfiguration = eqConfiguration
        self.meterStore = meterStore
        self.volumeService = volumeService
        self.eqStager = eqStager
    }

    // MARK: - Pipeline Lifecycle

    /// Creates, configures, and starts the render pipeline.
    /// Returns the result indicating success or failure with details.
    func startPipeline(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        captureMode: CaptureMode,
        driverRegistry: DriverDeviceRegistry?,
        isAutomaticMode: Bool,
        driverID: AudioDeviceID?,
        driverOutputDeviceID: AudioDeviceID
    ) -> PipelineStartResult {
        let pipeline = RenderPipeline(eqConfiguration: eqConfiguration)

        switch pipeline.configure(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            captureMode: captureMode,
            driverRegistry: driverRegistry
        ) {
        case .success:
            break
        case .failure(let error):
            return .configurationFailed(error.localizedDescription)
        }

        switch pipeline.start() {
        case .success:
            renderPipeline = pipeline
            meterStore.setRenderPipeline(pipeline)
            meterStore.startMeterUpdates()

            // Store sample rate and pipeline reference for coefficient calculations
            eqStager.setCurrentSampleRate(pipeline.sampleRate)
            eqStager.setRenderPipeline(pipeline)

            // Stage initial EQ coefficients
            eqStager.reapplyConfiguration()

            // Set up volume sync (automatic mode only)
            if isAutomaticMode, let driverID = driverID {
                volumeManager = VolumeManager(volumeService: volumeService)

                // Forward VolumeManager published changes to AudioRoutingCoordinator.
                // This is the only place VolumeManager is created; the subscription
                // lifetime is tied to the pipeline lifetime and cancelled in stopPipeline().
                volumeManagerCancellable = volumeManager?.objectWillChange
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.onVolumeStateChanged?()
                    }

                if captureMode == .halInput {
                    volumeManager?.onBoostGainChanged = { [weak self] boostGain in
                        self?.renderPipeline?.updateBoostGain(linear: boostGain)
                    }
                } else {
                    volumeManager?.onVolumeGainChanged = { [weak self] volumeGain in
                        self?.renderPipeline?.updateVolumeGain(linear: volumeGain)
                        DispatchQueue.main.async {
                            self?.onVolumeGainDidChange?(volumeGain)
                        }
                    }
                }
                volumeManager?.setupVolumeSync(driverID: driverID, outputID: driverOutputDeviceID)

                // Schedule drift checks to catch macOS async volume restorations
                volumeManager?.scheduleDriftChecks()
            }

            return .success(sampleRate: pipeline.sampleRate)

        case .failure(let error):
            return .startFailed(error.localizedDescription)
        }
    }

    /// Stops the pipeline and tears down associated resources.
    func stopPipeline() {
        if let pipeline = renderPipeline {
            meterStore.stopMeterUpdates()
            meterStore.setRenderPipeline(nil)
            _ = pipeline.stop()
            renderPipeline = nil
        }

        // Clear stager's pipeline reference
        eqStager.setRenderPipeline(nil)

        // Cancel volume manager subscription
        volumeManagerCancellable?.cancel()
        volumeManagerCancellable = nil

        // Clear callbacks and tear down volume sync
        volumeManager?.onBoostGainChanged = nil
        volumeManager?.onVolumeGainChanged = nil
        volumeManager?.tearDown()
        volumeManager = nil
    }

    /// Prepares the pipeline for a graceful stop by fading output to silence.
    /// Call ~50ms before stopPipeline() to allow the fade to complete.
    func prepareForStop() {
        renderPipeline?.prepareForStop()
    }

    // MARK: - Pipeline Pass-throughs

    /// Updates the processing mode on the render pipeline.
    func updateProcessingMode(systemEQOff: Bool,
                          compareMode: CompareMode,
                          channelMode: ChannelMode) {
        renderPipeline?.updateProcessingMode(systemEQOff: systemEQOff,
                                         compareMode: compareMode,
                                         channelMode: channelMode)
    }

    /// Updates the input gain on the render pipeline.
    func updateInputGain(linear: Float) {
        renderPipeline?.updateInputGain(linear: linear)
    }

    /// Updates the output gain on the render pipeline.
    func updateOutputGain(linear: Float) {
        renderPipeline?.updateOutputGain(linear: linear)
    }

    /// Updates the boost gain on the render pipeline.
    func updateBoostGain(linear: Float) {
        renderPipeline?.updateBoostGain(linear: linear)
    }

    /// Updates the dynamics configuration (soft clipper + brickwall limiter) on the render pipeline.
    func updateDynamicsConfig(_ config: DynamicsConfig) {
        renderPipeline?.updateDynamicsConfig(config)
    }
}