// DeviceProviding.swift
// Protocol for device lookup, enumeration, and fallback selection

import CoreAudio
import Foundation

/// Channel information for an audio device's output channels.
struct AudioDeviceChannelInfo: Identifiable, Sendable {
    var id: Int { channelIndex }
    let channelIndex: Int       // 0-based
    let channelLabel: String    // e.g. "Front Left", "Channel 3", or "Channel N" fallback
}

/// Protocol composing device lookup, enumeration, and fallback selection.
/// Replaces direct DeviceManager dependency in AudioRoutingCoordinator.
@MainActor
protocol DeviceProviding: AnyObject {
    /// Currently available input devices
    var inputDevices: [AudioDevice] { get }

    /// Currently available output devices
    var outputDevices: [AudioDevice] { get }

    /// Returns the device for a given UID
    func device(forUID uid: String) -> AudioDevice?

    /// Returns the device ID for a given UID
    func deviceID(forUID uid: String) -> AudioDeviceID?

    /// Enumerates input devices only.
    /// May trigger TCC permission dialog for microphone access.
    func enumerateInputDevices()

    /// Refreshes device lists from CoreAudio
    func refreshDevices()

    /// Finds the built-in audio device among output devices.
    func findBuiltInAudioDevice() -> AudioDevice?

    /// Finds a suitable fallback output device.
    /// - Parameter excludeUID: Optional UID to exclude from selection
    func selectFallbackOutputDevice(excluding excludeUID: String?) -> AudioDevice?

    /// Returns the total number of output channels on the given device.
    /// Queries kAudioDevicePropertyStreamConfiguration on kAudioDevicePropertyScopeOutput.
    func outputChannelCount(deviceID: AudioDeviceID) -> Int

    /// Returns per-channel info for the device's output channels.
    /// Channel labels from kAudioObjectPropertyElementName; falls back to "Channel N".
    func outputChannelInfo(deviceID: AudioDeviceID) -> [AudioDeviceChannelInfo]
}

extension DeviceProviding {
    /// Convenience overload for finding a fallback output device without exclusion.
    func selectFallbackOutputDevice() -> AudioDevice? {
        selectFallbackOutputDevice(excluding: nil)
    }
}
