// DynamicsProcessorTests.swift
// Tests for dynamics processor expander behavior

import XCTest
@testable import Equaliser

final class DynamicsProcessorTests: XCTestCase {

    func testExpanderRatio1_5() {
        // Test expander with ratio 1.5
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure expander
        processor.setExpanderEnabled(true)
        processor.setExpanderThresholdDB(-20.0)
        processor.setExpanderRatio(1.5)
        processor.setExpanderRangeDB(-12.0)

        // Create test buffer with signal above threshold
        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Expander should not silence signal above threshold")

        // Verify gain reduction is within expected range
        let gr = processor.expanderGainReductionDB
        XCTAssertGreaterThanOrEqual(gr, -12.0, "Gain reduction should not exceed range")
        XCTAssertLessThanOrEqual(gr, 0.0, "Gain reduction should be <= 0 dB")

        freeTestBufferList(bufferList: bufferList)
    }

    func testExpanderRatio2() {
        // Test expander with ratio 2.0
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        processor.setExpanderEnabled(true)
        processor.setExpanderThresholdDB(-20.0)
        processor.setExpanderRatio(2.0)
        processor.setExpanderRangeDB(-12.0)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Expander should not silence signal above threshold")

        let gr = processor.expanderGainReductionDB
        XCTAssertGreaterThanOrEqual(gr, -12.0, "Gain reduction should not exceed range")
        XCTAssertLessThanOrEqual(gr, 0.0, "Gain reduction should be <= 0 dB")

        freeTestBufferList(bufferList: bufferList)
    }

    func testExpanderRatio4() {
        // Test expander with ratio 4.0
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        processor.setExpanderEnabled(true)
        processor.setExpanderThresholdDB(-20.0)
        processor.setExpanderRatio(4.0)
        processor.setExpanderRangeDB(-12.0)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Expander should not silence signal above threshold")

        let gr = processor.expanderGainReductionDB
        XCTAssertGreaterThanOrEqual(gr, -12.0, "Gain reduction should not exceed range")
        XCTAssertLessThanOrEqual(gr, 0.0, "Gain reduction should be <= 0 dB")

        freeTestBufferList(bufferList: bufferList)
    }

    func testExpanderRatio8() {
        // Test expander with ratio 8.0
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        processor.setExpanderEnabled(true)
        processor.setExpanderThresholdDB(-20.0)
        processor.setExpanderRatio(8.0)
        processor.setExpanderRangeDB(-12.0)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Expander should not silence signal above threshold")

        let gr = processor.expanderGainReductionDB
        XCTAssertGreaterThanOrEqual(gr, -12.0, "Gain reduction should not exceed range")
        XCTAssertLessThanOrEqual(gr, 0.0, "Gain reduction should be <= 0 dB")

        freeTestBufferList(bufferList: bufferList)
    }

    func testExpanderBelowThreshold() {
        // Test expander with signal below threshold (should attenuate)
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        processor.setExpanderEnabled(true)
        processor.setExpanderThresholdDB(-20.0)
        processor.setExpanderRatio(2.0)
        processor.setExpanderRangeDB(-12.0)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.001) // Well below threshold

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify signal is attenuated but not completely silenced
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertLessThan(maxOutput, 0.01, "Expander should attenuate signal below threshold")
        XCTAssertGreaterThan(maxOutput, 0.0, "Expander should not produce complete silence")

        freeTestBufferList(bufferList: bufferList)
    }

    func testExpanderNumericalStability() {
        // Test expander with extreme input levels
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        processor.setExpanderEnabled(true)
        processor.setExpanderThresholdDB(-20.0)
        processor.setExpanderRatio(2.0)
        processor.setExpanderRangeDB(-12.0)

        let frameCount: UInt32 = 512
        let testAmplitudes: [Float] = [0.0, 1e-9, 1e-6, 0.001, 0.1, 0.5, 0.9, 1.0]

        for amplitude in testAmplitudes {
            var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: amplitude)

            processor.process(bufferList: &bufferList, frameCount: frameCount)

            // Verify all samples are finite
            let abl = UnsafeMutableAudioBufferListPointer(&bufferList)
            for ch in 0..<Int(channelCount) {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(frameCount) {
                    XCTAssertTrue(buf[i].isFinite, "Expander output should be finite for amplitude \(amplitude)")
                }
            }

            freeTestBufferList(bufferList: bufferList)
        }
    }

    // MARK: - Helper Methods

    private func createTestBufferList(channelCount: Int, frameCount: Int, amplitude: Float) -> AudioBufferList {
        let bufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)

        bufferList.pointee.mNumberBuffers = UInt32(channelCount)

        for ch in 0..<channelCount {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            for i in 0..<frameCount {
                buffer[i] = amplitude
            }
            bufferList.pointee.mBuffers[ch].mNumberChannels = 1
            bufferList.pointee.mBuffers[ch].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
            bufferList.pointee.mBuffers[ch].mData = UnsafeMutableRawPointer(buffer)
        }

        return bufferList.pointee
    }

    private func freeTestBufferList(bufferList: AudioBufferList) {
        for i in 0..<Int(bufferList.mNumberBuffers) {
            if let mData = bufferList.mBuffers[i].mData {
                mData.deallocate()
            }
        }
    }

    private func getMaxLevel(bufferList: AudioBufferList, frameCount: UInt32) -> Float {
        var maxLevel: Float = 0.0
        let abl = UnsafeMutableAudioBufferListPointer(&bufferList)

        for ch in 0..<Int(bufferList.mNumberBuffers) {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(frameCount) {
                let absVal = abs(buf[i])
                if absVal > maxLevel {
                    maxLevel = absVal
                }
            }
        }

        return maxLevel
    }
}
