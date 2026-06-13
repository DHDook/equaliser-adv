// CoreAudioHelpers.swift
// Shared CoreAudio property access utilities

import Foundation
import CoreAudio

// MARK: - CoreAudio Constants
// These are defined in CoreAudio headers but not directly accessible in Swift

/// Virtual master volume property selector
let kAudioHardwareServiceDeviceProperty_VirtualMasterVolume: AudioObjectPropertySelector = 0x00006d76  // 'mvmt'

/// Virtual master mute property selector
let kAudioHardwareServiceDeviceProperty_VirtualMasterMute: AudioObjectPropertySelector = 0x00006d6d  // 'mdmt'

/// Owned objects property selector
let kAudioDevicePropertyOwnedObjects: AudioObjectPropertySelector = 0x6f6f776e  // 'oown'

/// Device volume scalar property selector
let kAudioDevicePropertyVolumeScalar: AudioObjectPropertySelector = 0x766F6C6D  // 'volm'

/// Device mute property selector
let kAudioDevicePropertyMute: AudioObjectPropertySelector = 0x6D757465  // 'mute'

/// Virtual device transport type
let kAudioDeviceTransportTypeVirtual: UInt32 = 0x76697274  // 'virt'

/// Aggregate device transport type
let kAudioDeviceTransportTypeAggregate: UInt32 = 0x61676720  // 'agg '

// MARK: - String Property Helpers

/// Fetches a string property from a CoreAudio device.
/// - Parameters:
///   - id: The device ID
///   - selector: The property selector
/// - Returns: The string value, or nil if not found
func fetchStringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr else {
        return nil
    }
    
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<UInt8>.alignment)
    defer { buffer.deallocate() }
    
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, buffer) == noErr else {
        return nil
    }
    
    let unmanaged = buffer.bindMemory(to: Unmanaged<CFString>.self, capacity: 1)
    return unmanaged.pointee.takeRetainedValue() as String
}

/// Fetches the transport type for a device.
/// - Parameter id: The device ID
/// - Returns: The transport type, or 0 if unavailable
func fetchTransportType(id: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var transportType: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transportType) == noErr else {
        return 0
    }
    
    return transportType
}

/// Checks if a device has streams for a given scope.
/// - Parameters:
///   - id: The device ID
///   - scope: The scope (input or output)
/// - Returns: True if the device has streams
func hasStreams(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var propertySize: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &propertySize) == noErr && propertySize > 0
}

// MARK: - System Device Enumeration

/// Fetches all audio device IDs from the system.
/// - Returns: Array of device IDs, or nil on failure.
func fetchAllDeviceIDs() -> [AudioDeviceID]? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
    ) == noErr else {
        return nil
    }

    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs
    ) == noErr else {
        return nil
    }

    return deviceIDs
}

// MARK: - Default Output Device

/// Gets the current system default output device ID.
/// - Returns: The device ID, or nil if unavailable.
func fetchDefaultOutputDeviceID() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &propertySize, &deviceID
    ) == noErr, deviceID != 0 else {
        return nil
    }

    return deviceID
}

/// Sets the system default output device.
/// - Parameter deviceID: The device ID to set as default.
/// - Returns: true if successful.
@discardableResult
func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var deviceIDValue = deviceID
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &deviceIDValue
    ) == noErr
}

// MARK: - Device UID Helpers

/// Fetches the UID for a CoreAudio device.
/// - Parameter id: The device ID
/// - Returns: The UID string, or nil if unavailable.
func fetchDeviceUID(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr else {
        return nil
    }

    return uid?.takeRetainedValue() as String?
}

// MARK: - Sample Rate Helpers

/// Fetches a sample rate property from a device.
/// - Parameters:
///   - deviceID: The audio device ID
///   - selector: The property selector (actual or nominal sample rate)
/// - Returns: The sample rate, or nil if unavailable.
func fetchSampleRate(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Float64? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else {
        return nil
    }

    return rate
}

// MARK: - Owned Control Objects

/// Fetches owned control objects of a specific class from a device.
/// - Parameters:
///   - deviceID: The audio device ID
///   - scope: The property scope (input or output)
///   - classID: The control class ID to filter by
/// - Returns: Array of control object IDs, or nil on failure.
func fetchOwnedControls(
    deviceID: AudioDeviceID,
    scope: AudioObjectPropertyScope,
    classID: AudioClassID
) -> [AudioObjectID]? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyOwnedObjects,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    var qualifier = classID
    var size: UInt32 = 0

    guard AudioObjectGetPropertyDataSize(
        deviceID, &address,
        UInt32(MemoryLayout<AudioClassID>.size), &qualifier, &size
    ) == noErr else {
        return nil
    }

    let controlCount = Int(size) / MemoryLayout<AudioObjectID>.size
    guard controlCount > 0 else { return nil }

    var controls = [AudioObjectID](repeating: 0, count: controlCount)
    guard AudioObjectGetPropertyData(
        deviceID, &address,
        UInt32(MemoryLayout<AudioClassID>.size), &qualifier, &size, &controls
    ) == noErr else {
        return nil
    }

    return controls
}

// MARK: - Jack Connection Helper (Intel Macs)

/// Checks if a jack (headphone/audio port) is connected for a device.
/// Used on Intel Macs to detect headphone connection on built-in audio.
/// - Parameter deviceID: The audio device ID
/// - Returns: true if connected, false if disconnected, nil if property not supported
func isJackConnected(_ deviceID: AudioDeviceID) -> Bool? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyJackIsConnected,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    
    guard AudioObjectHasProperty(deviceID, &address) else {
        return nil
    }
    
    var connected: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &connected) == noErr else {
        return nil
    }
    
    return connected != 0
}