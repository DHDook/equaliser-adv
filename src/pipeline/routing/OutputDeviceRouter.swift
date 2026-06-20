// OutputDeviceRouter.swift
// Analyses the OutputChannelMatrixConfig and determines the correct routing mode.
// Creates and manages the appropriate routing infrastructure.

import CoreAudio
import Foundation
import OSLog

enum MultiDeviceSyncMode: Int, Codable, Equatable, Sendable, CaseIterable {
    /// Default. CoreAudio aggregate device handles synchronisation.
    /// Adds ~12–24 ms SRC latency on slave devices. Most compatible.
    case aggregateDevice = 0
    /// Software PLL. No aggregate device. No SRC latency.
    /// Higher CPU, requires careful PLL tuning. Best phase accuracy.
    case softwarePLL = 1

    var displayName: String {
        switch self {
        case .aggregateDevice: return "Aggregate Device (recommended)"
        case .softwarePLL:     return "Software PLL"
        }
    }

    var shortName: String {
        switch self {
        case .aggregateDevice: return "Aggregate"
        case .softwarePLL:     return "Software PLL"
        }
    }
}

/// Determines routing mode and creates appropriate infrastructure.
@MainActor
final class OutputDeviceRouter {

    enum RoutingMode: CustomStringConvertible {
        case singleDevice(deviceID: AudioDeviceID, channelMap: [Int32])
        case aggregateDevice(aggregateID: AudioDeviceID, channelMap: [Int32])
        case softwarePLL(primaryDeviceID: AudioDeviceID,
                         primaryChannelMap: [Int32],
                         secondaryWriters: [PLLSRCWriter])

        var description: String {
            switch self {
            case .singleDevice(let deviceID, _):
                return "singleDevice(\(deviceID))"
            case .aggregateDevice(let aggID, _):
                return "aggregateDevice(\(aggID))"
            case .softwarePLL(let primaryID, _, let writers):
                return "softwarePLL(primary: \(primaryID), writers: \(writers.count))"
            }
        }
    }

    /// Analyses the matrix config and resolves a routing mode.
    /// Called on the main thread before pipeline start.
    /// - Parameters:
    ///   - matrix: The validated output channel matrix config.
    ///   - syncMode: User's preferred multi-device sync mode.
    ///   - deviceProvider: For resolving UIDs → AudioDeviceIDs.
    /// - Returns: The resolved routing mode, or throws on unresolvable config.
    static func resolve(
        matrix: OutputChannelMatrixConfig,
        syncMode: MultiDeviceSyncMode,
        deviceProvider: any DeviceProviding,
        aggregateManager: AggregateDeviceManager
    ) async throws -> RoutingMode {

        // Collect all unique device UIDs referenced by enabled channels
        let enabledChannels = matrix.channels.filter(\.isEnabled)
        let uniqueUIDs = Set(enabledChannels.compactMap(\.target?.deviceUID))

        // Single device: all channels target the same UID
        if uniqueUIDs.count <= 1 {
            guard let uid = uniqueUIDs.first,
                  let deviceID = deviceProvider.deviceID(forUID: uid) else {
                throw OutputRoutingError.primaryDeviceNotFound
            }
            let map = buildChannelMap(channels: enabledChannels,
                                      deviceID: deviceID,
                                      deviceProvider: deviceProvider)
            return .singleDevice(deviceID: deviceID, channelMap: map)
        }

        // Multiple devices: check sync mode preference
        switch syncMode {
        case .aggregateDevice:
            // Create or reuse aggregate device
            let aggID = try await aggregateManager.createOrUpdate(
                channels: enabledChannels,
                deviceProvider: deviceProvider
            )
            let map = buildChannelMap(channels: enabledChannels,
                                      deviceID: aggID,
                                      deviceProvider: deviceProvider)
            return .aggregateDevice(aggregateID: aggID, channelMap: map)

        case .softwarePLL:
            // Primary device: first channel's device, drives render clock
            guard let primaryUID = enabledChannels.first?.target?.deviceUID,
                  let primaryID  = deviceProvider.deviceID(forUID: primaryUID) else {
                throw OutputRoutingError.primaryDeviceNotFound
            }
            let primaryMap = buildChannelMap(
                channels: enabledChannels.filter { $0.target?.deviceUID == primaryUID },
                deviceID: primaryID,
                deviceProvider: deviceProvider
            )
            // Secondary devices: one PLLSRCWriter per unique non-primary device
            let secondaryUIDs = uniqueUIDs.subtracting([primaryUID])
            let writers: [PLLSRCWriter] = try secondaryUIDs.sorted().map { uid in
                guard let deviceID = deviceProvider.deviceID(forUID: uid) else {
                    throw OutputRoutingError.secondaryDeviceNotFound(uid: uid)
                }
                let channels = enabledChannels.filter { $0.target?.deviceUID == uid }
                let map = buildChannelMap(channels: channels, deviceID: deviceID,
                                         deviceProvider: deviceProvider)
                let config = PLLSRCWriter.Config(
                    deviceID: deviceID,
                    deviceUID: uid,
                    channelMap: map,
                    nominalSampleRate: 48000.0  // TODO: Get actual sample rate from device
                )
                return PLLSRCWriter(config: config)
            }
            return .softwarePLL(primaryDeviceID: primaryID,
                                primaryChannelMap: primaryMap,
                                secondaryWriters: writers)
        }
    }

    /// Builds a CoreAudio channel map for writing to specific device channels.
    /// Result array length = total output channel count on the device.
    /// Entry at index i = processing channel that writes to device channel i, or –1 for silence.
    private static func buildChannelMap(
        channels: [OutputChannelConfig],
        deviceID: AudioDeviceID,
        deviceProvider: any DeviceProviding
    ) -> [Int32] {
        let totalDeviceChannels = deviceProvider.outputChannelCount(deviceID: deviceID)
        var map = [Int32](repeating: -1, count: totalDeviceChannels)
        for (processingIndex, channel) in channels.enumerated() {
            guard let indices = channel.target?.channelIndices else { continue }
            for deviceChannelIndex in indices {
                guard deviceChannelIndex < totalDeviceChannels else { continue }
                map[deviceChannelIndex] = Int32(processingIndex)
            }
        }
        return map
    }
}

enum OutputRoutingError: LocalizedError {
    case primaryDeviceNotFound
    case secondaryDeviceNotFound(uid: String)
    case aggregateDeviceCreationFailed(OSStatus)
    case incompatibleSampleRates([String: Double])

    var errorDescription: String? {
        switch self {
        case .primaryDeviceNotFound:
            return "Primary output device not found"
        case .secondaryDeviceNotFound(let uid):
            return "Secondary output device not found: \(uid)"
        case .aggregateDeviceCreationFailed(let status):
            return "Failed to create aggregate device: \(status)"
        case .incompatibleSampleRates(let rates):
            return "Incompatible sample rates: \(rates)"
        }
    }
}
