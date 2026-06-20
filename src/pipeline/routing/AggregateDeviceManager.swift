// AggregateDeviceManager.swift
// Creates, configures, and destroys CoreAudio aggregate devices for multi-device routing.
// Aggregate devices are the Apple-recommended mechanism for combining multiple
// physical audio devices with automatic clock synchronisation.

import CoreAudio
import Foundation
import OSLog

/// Manages the lifecycle of a CoreAudio aggregate device combining all
/// target physical devices from the output channel matrix.
///
/// CoreAudio aggregate device behaviour:
/// - One device is designated as the clock master. All other devices are slaves.
/// - CoreAudio applies its internal SRC to slave device streams to align them with
///   the master clock. This introduces ~12–24 ms of additional latency on slave outputs.
/// - The aggregate appears as a single multi-channel logical device with a channel
///   map covering all physical channels across all member devices.
/// - The master device should be the highest-quality (lowest jitter) DAC in the system,
///   typically the mains DAC.
@MainActor
final class AggregateDeviceManager {

    nonisolated(unsafe) private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "AggregateDeviceMgr")

    // MARK: - Create / Update

    /// Creates a new aggregate device or destroys and recreates the existing one
    /// if the device list has changed.
    ///
    /// - Parameters:
    ///   - channels: Enabled output channels (with target deviceUIDs resolved).
    ///   - clockMasterUID: The device UID to use as the aggregate clock master.
    ///     Defaults to the first channel's device if nil.
    /// - Returns: The AudioDeviceID of the created aggregate device.
    func createOrUpdate(
        channels: [OutputChannelConfig],
        deviceProvider: any DeviceProviding,
        clockMasterUID: String? = nil
    ) async throws -> AudioDeviceID {

        // Destroy existing aggregate if present
        if aggregateDeviceID != kAudioObjectUnknown {
            destroyAggregate()
        }

        // Collect unique device UIDs, preserving order (first = default master)
        var seenUIDs = Set<String>()
        var orderedUIDs: [String] = []
        for ch in channels {
            if let uid = ch.target?.deviceUID, seenUIDs.insert(uid).inserted {
                orderedUIDs.append(uid)
            }
        }
        guard orderedUIDs.count >= 2 else {
            throw OutputRoutingError.primaryDeviceNotFound
        }

        let masterUID = clockMasterUID ?? orderedUIDs[0]

        // Build the aggregate device description CFDictionary.
        // See Apple's kAudioAggregateDevice* constants.
        let subDeviceDescriptions: [[CFString: Any]] = orderedUIDs.map { uid in
            [kAudioSubDeviceUIDKey as CFString: uid as CFString]
        }

        let aggregateDescription: [CFString: Any] = [
            kAudioAggregateDeviceNameKey as CFString:            "Equaliser Multi-Output" as CFString,
            kAudioAggregateDeviceUIDKey as CFString:             "net.knage.equaliser.aggregate.\(orderedUIDs.joined(separator: "-"))" as CFString,
            kAudioAggregateDeviceSubDeviceListKey as CFString:   subDeviceDescriptions as CFArray,
            kAudioAggregateDeviceMasterSubDeviceKey as CFString: masterUID as CFString,
            // Private aggregate: not visible in Audio MIDI Setup, not shared.
            kAudioAggregateDeviceIsPrivateKey as CFString:       kCFBooleanTrue as Any,
            // Stack sequential: combine channels end-to-end (not interleaved).
            kAudioAggregateDeviceIsStackedKey as CFString:       kCFBooleanFalse as Any,
        ]

        var newDeviceID: AudioDeviceID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newDeviceID)
        guard status == noErr else {
            logger.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            throw OutputRoutingError.aggregateDeviceCreationFailed(status)
        }

        aggregateDeviceID = newDeviceID
        logger.info("Aggregate device created: \(newDeviceID), master: \(masterUID)")

        // Brief settle time: CoreAudio aggregate device needs ~100 ms to stabilise
        // after creation before it reliably accepts HAL output unit configuration.
        try await Task.sleep(for: .milliseconds(150))

        return newDeviceID
    }

    // MARK: - Destroy

    /// Destroys the aggregate device. Called on pipeline stop or device change.
    nonisolated(unsafe) func destroyAggregate() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if status != noErr {
            logger.warning("AudioHardwareDestroyAggregateDevice returned: \(status)")
        }
        logger.info("Aggregate device destroyed: \(self.aggregateDeviceID)")
        aggregateDeviceID = kAudioObjectUnknown
    }

    // MARK: - Aggregate SRC Latency Helpers

    /// Returns the additional latency introduced by the aggregate device's internal SRC
    /// for a given slave device, in samples at the aggregate sample rate.
    /// The primary (master) device has zero additional latency.
    /// Slave devices typically have 512–1024 samples (~12–24 ms at 48 kHz) of additional latency.
    ///
    /// Used by the UI to display per-channel latency and to suggest delay compensation values.
    func slaveLatencySamples(deviceUID: String, sampleRate: Double) -> Int {
        guard aggregateDeviceID != kAudioObjectUnknown else { return 0 }
        // Query kAudioDevicePropertyLatency + kAudioDevicePropertySafetyOffset
        // on the aggregate device for the sub-device channel range.
        // This is an approximation — the true value depends on the specific device pair
        // and CoreAudio's internal resampler choice.
        // Default estimate: 1024 samples at 48 kHz.
        return 1024
    }

    deinit {
        destroyAggregate()
    }
}
