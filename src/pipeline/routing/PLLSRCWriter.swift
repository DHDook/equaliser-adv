// PLLSRCWriter.swift
// PLL-corrected secondary output writer for multi-device synchronisation (Mode 3).
// Writes audio to a secondary HAL device with fractional rate correction
// applied by SRCProcessor to maintain sample-accurate clock alignment.

import CoreAudio
import AudioToolbox
import Foundation
import Accelerate
import Atomics

final class PLLSRCWriter: Sendable {

    // MARK: - Configuration

    struct Config {
        var deviceID: AudioDeviceID
        var deviceUID: String
        /// Channel map: one entry per device output channel; -1 = silence.
        var channelMap: [Int32]
        var nominalSampleRate: Double
        var pllConfig: DeviceClockPLL.Config = .init()
    }

    // MARK: - Components

    nonisolated(unsafe) private var audioUnit: AudioComponentInstance?
    private let pll: DeviceClockPLL
    // TODO: SRCProcessor - add setRateRatio method
    // private let src: SRCProcessor
    // TODO: LockFreeAudioRingBuffer - may need to be created
    // private let ringBuffers: [LockFreeAudioRingBuffer]

    // Number of physical output channels this writer handles
    private let channelCount: Int

    // Atomic gain (combined gain + polarity for this device group)
    private let _gainBits = ManagedAtomic<Int32>(Int32(bitPattern: Float(1.0).bitPattern))

    private static let ringBufferCapacity = 16384  // larger than Mode 2 to absorb SRC rate variation

    // MARK: - Init

    init(config: Config) {
        channelCount = config.channelMap.filter { $0 >= 0 }.map { Int($0) }.max().map { $0 + 1 } ?? 0
        pll = DeviceClockPLL(deviceUID: config.deviceUID,
                             nominalSampleRate: config.nominalSampleRate,
                             config: config.pllConfig)
        // TODO: Initialize SRCProcessor and ring buffers
        // src = SRCProcessor(inputRate: config.nominalSampleRate,
        //                    outputRate: config.nominalSampleRate)  // correction applied dynamically
        // ringBuffers = (0..<max(channelCount, 1)).map { _ in
        //     LockFreeAudioRingBuffer(capacity: Self.ringBufferCapacity)
        // }
    }

    // MARK: - Write (Primary Render Callback Thread)

    /// Called from the PRIMARY device's render callback.
    /// Records the primary timestamp for PLL drift measurement.
    /// Applies SRC with current PLL correction factor and writes to ring buffers.
    @inline(__always)
    func writePrimary(
        channels: [(buffer: UnsafePointer<Float>, channelIndex: Int)],
        frameCount: Int,
        primaryHostTime: UInt64
    ) {
        pll.recordPrimaryTimestamp(primaryHostTime)

        // TODO: Apply SRC with current correction factor.
        // correctionFactor ≈ 1.0; typical range 0.9998–1.0002.
        // SRCProcessor.setOutputRate adjusts the output sample rate dynamically.
        let correction = pll.correctionFactor
        // src.setRateRatio(correction)   // add this method to SRCProcessor if not present

        // Apply gain
        let gain = Float(bitPattern: UInt32(bitPattern: _gainBits.load(ordering: .relaxed)))

        // TODO: Process through ring buffers
        // for (buf, chIdx) in channels {
        //     guard chIdx < ringBuffers.count else { continue }
        //     if gain == 1.0 {
        //         src.process(input: buf, inputCount: frameCount) { output, outputCount in
        //             ringBuffers[chIdx].write(output, count: outputCount)
        //         }
        //     } else {
        //         withUnsafeTemporaryAllocation(of: Float.self, capacity: frameCount) { scratch in
        //             var g = gain
        //             vDSP_vsmul(buf, 1, &g, scratch.baseAddress!, 1, vDSP_Length(frameCount))
        //             src.process(input: scratch.baseAddress!, inputCount: frameCount) { output, outputCount in
        //                 ringBuffers[chIdx].write(output, count: outputCount)
        //             }
        //         }
        //     }
        // }
    }

    // MARK: - Secondary HAL Render Callback

    /// Called by CoreAudio on the SECONDARY device's render thread.
    /// Records secondary timestamp for PLL, reads from ring buffers, writes to device.
    private static let secondaryRenderCallback: AURenderCallback = {
        inRefCon, ioActionFlags, inTimeStamp, _, frameCount, ioData -> OSStatus in
        guard let ioData = ioData else { return noErr }

        let writer = Unmanaged<PLLSRCWriter>.fromOpaque(inRefCon).takeUnretainedValue()

        // Record secondary timestamp for PLL drift measurement
        writer.pll.recordSecondaryTimestamp(inTimeStamp.pointee.mHostTime, frameCount: Int(frameCount))

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
    // Identical pattern to SecondaryOutputWriter from the previous spec.
    // HAL output unit setup: disable input, enable output, set device, set channel map,
    // set client format (float32 non-interleaved), register secondaryRenderCallback, init unit.
}
