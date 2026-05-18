// DeviceSampleRateService.swift
// Sample rate query and observation service for audio devices

import Foundation
import CoreAudio
import os.log

/// Sample rate query and observation for audio devices.
@MainActor
final class DeviceSampleRateService: SampleRateObserving {
    
    // MARK: - Private Properties
    
    private nonisolated(unsafe) var sampleRateListenerBlocks: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private let listenerQueue = DispatchQueue(label: "net.knage.equaliser.DeviceSampleRateService.listener")
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "DeviceSampleRateService")
    
    // MARK: - Sample Rate Queries
    
    func getActualSampleRate(deviceID: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyActualSampleRate,
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
    
    func getNominalSampleRate(deviceID: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
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
    
    // MARK: - Available Sample Rates

    func getAvailableSampleRates(deviceID: AudioDeviceID) -> [AudioValueRange]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return nil
        }

        return ranges
    }

    // MARK: - Sample Rate Observation
    
    func observeSampleRateChanges(on deviceID: AudioDeviceID, handler: @escaping (Float64) -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            if let rate = self.getNominalSampleRate(deviceID: deviceID) {
                Task { @MainActor in
                    handler(rate)
                }
            }
        }
        
        sampleRateListenerBlocks[deviceID] = block
        
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            block
        )
        
        if status != noErr {
            logger.warning("Failed to observe sample rate changes on device \(deviceID): \(status)")
        }
    }
    
    func stopObservingSampleRateChanges(on deviceID: AudioDeviceID) {
        guard let block = sampleRateListenerBlocks.removeValue(forKey: deviceID) else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            block
        )
    }
}