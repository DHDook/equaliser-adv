// DeviceAliveMonitor.swift
// Monitors a specific audio device for removal via kAudioDevicePropertyDeviceIsAlive

import CoreAudio
import OSLog

/// Monitors a specific audio device for removal using `kAudioDevicePropertyDeviceIsAlive`.
///
/// Unlike the full device list refresh approach (which diffs the device list after a
/// `kAudioHardwarePropertyDevices` change), this listener fires immediately when the
/// specific monitored device is removed. This gives faster, more reliable disconnect
/// handling for the active routing devices.
///
/// Usage:
/// ```swift
/// let monitor = DeviceAliveMonitor()
/// monitor.startMonitoring(deviceID: outputDeviceID) {
///     // Device was removed — stop routing immediately
/// }
/// // Later:
/// monitor.stopMonitoring()
/// ```
@MainActor
final class DeviceAliveMonitor: DeviceAliveMonitoring {

    // MARK: - State

    /// The device ID currently being monitored, if any.
    private var monitoredDeviceID: AudioDeviceID?

    /// The listener block registered with CoreAudio. Stored so we can pass it back
    /// to `AudioObjectRemovePropertyListenerBlock` for removal.
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Non-isolated copy of the listener block for access from `deinit`.
    /// `deinit` on `@MainActor` classes is nonisolated, so it cannot access
    /// MainActor-isolated properties. This mirrors the block reference so
    /// `removeListenerSync` can pass the exact block pointer to CoreAudio.
    private nonisolated(unsafe) var storedListenerBlock: AudioObjectPropertyListenerBlock?

    /// Callback to invoke when the monitored device is removed.
    private var onDeviceDied: (@MainActor () -> Void)?

    private let logger = Logger(subsystem: "net.knage.equaliser", category: "DeviceAliveMonitor")

    deinit {
        // Safety: remove listener if still active
        if let deviceID = monitoredDeviceID {
            removeListenerSync(for: deviceID)
        }
    }

    // MARK: - DeviceAliveMonitoring

    func startMonitoring(deviceID: AudioDeviceID, onDeviceDied: @escaping @MainActor () -> Void) {
        // Stop any existing monitoring first
        stopMonitoring()

        self.monitoredDeviceID = deviceID
        self.onDeviceDied = onDeviceDied

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // The listener block is dispatched to DispatchQueue.main by CoreAudio.
        // Since this class is @MainActor, capture self and dispatch via MainActor.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleDeviceAliveChange(deviceID: deviceID)
            }
        }
        self.listenerBlock = block
        self.storedListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            block
        )

        if status != noErr {
            logger.error("Failed to add DeviceIsAlive listener for device \(deviceID): \(status)")
            self.monitoredDeviceID = nil
            self.listenerBlock = nil
            self.storedListenerBlock = nil
            self.onDeviceDied = nil
        } else {
            logger.debug("Monitoring device \(deviceID) for removal")
        }
    }

    func stopMonitoring() {
        guard let deviceID = monitoredDeviceID else { return }

        removeListenerSync(for: deviceID)
        monitoredDeviceID = nil
        listenerBlock = nil
        storedListenerBlock = nil
        onDeviceDied = nil
    }

    // MARK: - Private

    /// Handles the DeviceIsAlive property change callback.
    private func handleDeviceAliveChange(deviceID: AudioDeviceID) {
        // Check if the device is actually gone (property listener can fire for other reasons)
        var isAlive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)

        if status != noErr || isAlive == 0 {
            logger.info("Device \(deviceID) removed")
            onDeviceDied?()
        }
    }

    /// Removes the property listener for the given device.
    /// Called from deinit which cannot be actor-isolated, so this is nonisolated.
    /// Uses `storedListenerBlock` (a nonisolated(unsafe) copy) so CoreAudio can
    /// match the block pointer for proper removal.
    private nonisolated func removeListenerSync(for deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Use the stored block reference so CoreAudio can match by pointer.
        // If nil (e.g. listener was never registered or already removed),
        // skip the removal call.
        guard let block = storedListenerBlock else { return }

        _ = AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            block
        )
    }
}