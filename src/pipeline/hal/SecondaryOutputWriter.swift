// SecondaryOutputWriter.swift
// Fallback secondary output writer for multi-device routing (Mode 3).
// Used when PLLSRCWriter configuration fails (e.g. device in exclusive use).
// Writes audio to a secondary HAL device without PLL correction.

import CoreAudio
import AudioToolbox
import Foundation
import Accelerate
import Atomics

/// Fallback secondary output writer for Mode 3 when PLLSRCWriter is unavailable.
/// Uses ring buffers without clock correction. Status display shows "PLL unavailable — using ring buffer (drift not corrected)".
final class SecondaryOutputWriter: Sendable {

    // MARK: - Configuration

    struct Config {
        var deviceID: AudioDeviceID
        var deviceUID: String
        /// Channel map: one entry per device output channel; -1 = silence.
        var channelMap: [Int32]
        var nominalSampleRate: Double
    }

    // MARK: - Components

    nonisolated(unsafe) private var audioUnit: AudioComponentInstance?
    // TODO: LockFreeAudioRingBuffer - may need to be created
    // private let ringBuffers: [LockFreeAudioRingBuffer]

    // Number of physical output channels this writer handles
    private let channelCount: Int

    // Atomic gain (combined gain + polarity for this device group)
    private let _gainBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))

    private static let ringBufferCapacity = 8192

    // MARK: - Init

    init(config: Config) {
        channelCount = config.channelMap.filter { $0 >= 0 }.map { Int($0) }.max().map { $0 + 1 } ?? 0
        // TODO: Initialize ring buffers
        // ringBuffers = (0..<max(channelCount, 1)).map { _ in
        //     LockFreeAudioRingBuffer(capacity: Self.ringBufferCapacity)
        // }
    }

    // MARK: - Write (Primary Render Callback Thread)

    /// Called from the PRIMARY device's render callback.
    /// Writes audio to ring buffers without PLL correction.
    @inline(__always)
    func write(
        channels: [(buffer: UnsafePointer<Float>, channelIndex: Int)],
        frameCount: Int
    ) {
        // Apply gain
        let gain = Float(bitPattern: UInt32(bitPattern: _gainBits.load(ordering: .relaxed)))

        // TODO: Write to ring buffers
        // for (buf, chIdx) in channels {
        //     guard chIdx < ringBuffers.count else { continue }
        //     if gain == 1.0 {
        //         ringBuffers[chIdx].write(buf, count: frameCount)
        //     } else {
        //         withUnsafeTemporaryAllocation(of: Float.self, capacity: frameCount) { scratch in
        //             var g = gain
        //             vDSP_vsmul(buf, 1, &g, scratch.baseAddress!, 1, vDSP_Length(frameCount))
        //             ringBuffers[chIdx].write(scratch.baseAddress!, count: frameCount)
        //         }
        //     }
        // }
    }

    // MARK: - Secondary HAL Render Callback

    /// Called by CoreAudio on the SECONDARY device's render thread.
    /// Reads from ring buffers, writes to device.
    private static let secondaryRenderCallback: AURenderCallback = {
        inRefCon, ioActionFlags, inTimeStamp, _, frameCount, ioData -> OSStatus in
        guard let ioData = ioData else { return noErr }

        let writer = Unmanaged<SecondaryOutputWriter>.fromOpaque(inRefCon).takeUnretainedValue()

        // TODO: Read from ring buffers and write to device
        // let abl = UnsafeMutableAudioBufferListPointer(ioData)
        // let frames = Int(frameCount)
        // 
        // return withUnsafeTemporaryAllocation(of: Float.self, capacity: frames) { scratch in
        //     for (chIdx, buf) in abl.enumerated() {
        //         guard chIdx < writer.ringBuffers.count else { continue }
        //         guard let dest = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        //         let read = writer.ringBuffers[chIdx].read(scratch.baseAddress!, count: frames)
        //         memcpy(dest, scratch.baseAddress!, read * MemoryLayout<Float>.size)
        //         if read < frames {
        //             memset(dest + read, 0, (frames - read) * MemoryLayout<Float>.size)
        //         }
        //     }
        //     return noErr
        // }

        return noErr
    }

    // MARK: - Gain

    func setGain(_ gainLinear: Float) {
        _gainBits.store(Int32(bitPattern: gainLinear.bitPattern), ordering: .releasing)
    }

    // MARK: - Lifecycle (configure / start / stop)
    // TODO: Implement HAL output unit setup
    // Identical pattern to PLLSRCWriter but without PLL components.
    // HAL output unit setup: disable input, enable output, set device, set channel map,
    // set client format (float32 non-interleaved), register secondaryRenderCallback, init unit.
}
