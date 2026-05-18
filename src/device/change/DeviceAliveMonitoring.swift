// DeviceAliveMonitoring.swift
// Protocol for monitoring device liveness

import CoreAudio

/// Monitors whether a specific audio device is still present.
/// Uses `kAudioDevicePropertyDeviceIsAlive` for immediate, direct notification
/// when a device is removed — faster than relying on the full device list refresh.
@MainActor
protocol DeviceAliveMonitoring: AnyObject {
    /// Starts monitoring a specific device for removal.
    /// When the device is removed, `onDeviceDied` is called on the main actor.
    /// - Parameters:
    ///   - deviceID: The CoreAudio device ID to monitor.
    ///   - onDeviceDied: Called on the main actor when the device is removed.
    func startMonitoring(deviceID: AudioDeviceID, onDeviceDied: @escaping @MainActor () -> Void)

    /// Stops monitoring the current device.
    func stopMonitoring()
}