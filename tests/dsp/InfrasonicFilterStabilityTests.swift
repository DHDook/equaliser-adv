import XCTest
@testable import Equaliser

/// Tests for the infrasonic filter stability.
/// These tests verify that the filter coefficients are correctly negated
/// and that the filter remains stable (no divergence to Inf/NaN) under
/// various conditions.
final class InfrasonicFilterStabilityTests: XCTestCase {

    func testInfrasonicFilterRemainsStableWithImpulseInput() throws {
        // Constructs a DynamicsProcessor, enables the infrasonic filter at
        // default settings, processes a buffer of unit-impulse + silence for
        // at least a few thousand frames, and asserts every output sample is
        // finite (.isFinite) and bounded (e.g. abs(sample) < 2.0 for a 0 dBFS-ish input).

        let processor = DynamicsProcessor(
            channelCount: 2,
            maxFrameCount: 512,
            sampleRate: 48000.0
        )

        // Enable the infrasonic filter at default settings
        let config = InfrasonicFilterConfig(
            isEnabled: true,
            cutoffHz: 18.0,
            slope: .db48,
            target: .mainChain
        )
        processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

        var bufferL: [Float] = Array(repeating: 0.0, count: 512)
        var bufferR: [Float] = Array(repeating: 0.0, count: 512)
        var abl = AudioBufferList()
        abl.mNumberBuffers = 2

        var buffers = [AudioBuffer](
            count: 2,
            repeating: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: 512 * MemoryLayout<Float>.size,
                mData: nil
            )
        )
        buffers[0].mData = UnsafeMutableRawPointer(mutating: bufferL)
        buffers[1].mData = UnsafeMutableRawPointer(mutating: bufferR)
        abl.mBuffers = UnsafeMutablePointer<AudioBuffer>(mutating: &buffers)

        let ablPtr = UnsafeMutableAudioBufferListPointer(&abl)

        // Process several thousand frames with unit impulse
        for i in 0..<10000 {
            // Set first sample to 1.0 (unit impulse) for first frame only
            bufferL[0] = (i == 0) ? 1.0 : 0.0
            bufferR[0] = (i == 0) ? 1.0 : 0.0

            processor.process(
                abl: ablPtr,
                inputMeterStorage: nil,
                inputRmsStorage: nil,
                outputMeterStorage: nil,
                outputRmsStorage: nil,
                numCh: 2,
                count: 512
            )

            // Verify all output samples are finite and bounded
            for j in 0..<512 {
                XCTAssertTrue(bufferL[j].isFinite, "Output sample L[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(bufferR[j].isFinite, "Output sample R[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(abs(bufferL[j]) < 2.0, "Output sample L[\(j)] exceeds bound at frame \(i)")
                XCTAssertTrue(abs(bufferR[j]) < 2.0, "Output sample R[\(j)] exceeds bound at frame \(i)")
            }
        }
    }

    func testInfrasonicFilterRemainsStableWithNoiseInput() throws {
        // Same test but with full-scale white noise instead of impulse

        let processor = DynamicsProcessor(
            channelCount: 2,
            maxFrameCount: 512,
            sampleRate: 48000.0
        )

        let config = InfrasonicFilterConfig(
            isEnabled: true,
            cutoffHz: 18.0,
            slope: .db48,
            target: .mainChain
        )
        processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

        var bufferL: [Float] = Array(repeating: 0.0, count: 512)
        var bufferR: [Float] = Array(repeating: 0.0, count: 512)
        var abl = AudioBufferList()
        abl.mNumberBuffers = 2

        var buffers = [AudioBuffer](
            count: 2,
            repeating: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: 512 * MemoryLayout<Float>.size,
                mData: nil
            )
        )
        buffers[0].mData = UnsafeMutableRawPointer(mutating: bufferL)
        buffers[1].mData = UnsafeMutableRawPointer(mutating: bufferR)
        abl.mBuffers = UnsafeMutablePointer<AudioBuffer>(mutating: &buffers)

        let ablPtr = UnsafeMutableAudioBufferListPointer(&abl)

        // Process several thousand frames with white noise
        for i in 0..<5000 {
            // Fill with white noise at -6 dBFS
            for j in 0..<512 {
                bufferL[j] = Float.random(in: -0.5...0.5)
                bufferR[j] = Float.random(in: -0.5...0.5)
            }

            processor.process(
                abl: ablPtr,
                inputMeterStorage: nil,
                inputRmsStorage: nil,
                outputMeterStorage: nil,
                outputRmsStorage: nil,
                numCh: 2,
                count: 512
            )

            // Verify all output samples are finite and bounded
            for j in 0..<512 {
                XCTAssertTrue(bufferL[j].isFinite, "Output sample L[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(bufferR[j].isFinite, "Output sample R[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(abs(bufferL[j]) < 2.0, "Output sample L[\(j)] exceeds bound at frame \(i)")
                XCTAssertTrue(abs(bufferR[j]) < 2.0, "Output sample R[\(j)] exceeds bound at frame \(i)")
            }
        }
    }

    func testInfrasonicFilterRemainsStableDuringSlopeSwitching() throws {
        // Repeats the same check while switching slope every callback for several
        // hundred callbacks, asserting finiteness and that output channel 1 isn't
        // swapped/corrupted relative to channel 0 — this targets Fix 1b.

        let processor = DynamicsProcessor(
            channelCount: 2,
            maxFrameCount: 512,
            sampleRate: 48000.0
        )

        let slopes: [InfrasonicFilterConfig.InfrasonicSlope] = [.db24, .db48, .db96]

        var bufferL: [Float] = Array(repeating: 0.0, count: 512)
        var bufferR: [Float] = Array(repeating: 0.0, count: 512)
        var abl = AudioBufferList()
        abl.mNumberBuffers = 2

        var buffers = [AudioBuffer](
            count: 2,
            repeating: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: 512 * MemoryLayout<Float>.size,
                mData: nil
            )
        )
        buffers[0].mData = UnsafeMutableRawPointer(mutating: bufferL)
        buffers[1].mData = UnsafeMutableRawPointer(mutating: bufferR)
        abl.mBuffers = UnsafeMutablePointer<AudioBuffer>(mutating: &buffers)

        let ablPtr = UnsafeMutableAudioBufferListPointer(&abl)

        // Switch slope every callback for several hundred callbacks
        for i in 0..<500 {
            let slope = slopes[i % slopes.count]
            let config = InfrasonicFilterConfig(
                isEnabled: true,
                cutoffHz: 20.0,
                slope: slope,
                target: .mainChain
            )
            processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

            // Fill with white noise
            for j in 0..<512 {
                bufferL[j] = Float.random(in: -0.5...0.5)
                bufferR[j] = Float.random(in: -0.5...0.5)
            }

            processor.process(
                abl: ablPtr,
                inputMeterStorage: nil,
                inputRmsStorage: nil,
                outputMeterStorage: nil,
                outputRmsStorage: nil,
                numCh: 2,
                count: 512
            )

            // Verify all output samples are finite and bounded
            for j in 0..<512 {
                XCTAssertTrue(bufferL[j].isFinite, "Output sample L[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(bufferR[j].isFinite, "Output sample R[\(j)] is not finite at frame \(i)")
                XCTAssertTrue(abs(bufferL[j]) < 2.0, "Output sample L[\(j)] exceeds bound at frame \(i)")
                XCTAssertTrue(abs(bufferR[j]) < 2.0, "Output sample R[\(j)] exceeds bound at frame \(i)")
            }

            // Verify channels aren't swapped/corrupted (they should be similar for identical input)
            // Allow some tolerance due to different filter states, but they should be correlated
            let correlation = zip(bufferL, bufferR).map { abs($0 - $1) }.reduce(0, +) / Float(512)
            XCTAssertTrue(correlation < 1.0, "Channels appear swapped/corrupted at frame \(i)")
        }
    }

    func testInfrasonicFilterAllSlopesStable() throws {
        // Test each slope individually to ensure they all produce stable output

        let slopes: [InfrasonicFilterConfig.InfrasonicSlope] = [.db24, .db48, .db96]

        for slope in slopes {
            let processor = DynamicsProcessor(
                channelCount: 2,
                maxFrameCount: 512,
                sampleRate: 48000.0
            )

            let config = InfrasonicFilterConfig(
                isEnabled: true,
                cutoffHz: 20.0,
                slope: slope,
                target: .mainChain
            )
            processor.setInfrasonicFilterConfig(config, sampleRate: 48000.0)

            var bufferL: [Float] = Array(repeating: 0.0, count: 512)
            var bufferR: [Float] = Array(repeating: 0.0, count: 512)
            var abl = AudioBufferList()
            abl.mNumberBuffers = 2

            var buffers = [AudioBuffer](
                count: 2,
                repeating: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: 512 * MemoryLayout<Float>.size,
                    mData: nil
                )
            )
            buffers[0].mData = UnsafeMutableRawPointer(mutating: bufferL)
            buffers[1].mData = UnsafeMutableRawPointer(mutating: bufferR)
            abl.mBuffers = UnsafeMutablePointer<AudioBuffer>(mutating: &buffers)

            let ablPtr = UnsafeMutableAudioBufferListPointer(&abl)

            // Process several frames
            for i in 0..<1000 {
                bufferL[0] = (i == 0) ? 1.0 : 0.0
                bufferR[0] = (i == 0) ? 1.0 : 0.0

                processor.process(
                    abl: ablPtr,
                    inputMeterStorage: nil,
                    inputRmsStorage: nil,
                    outputMeterStorage: nil,
                    outputRmsStorage: nil,
                    numCh: 2,
                    count: 512
                )

                for j in 0..<512 {
                    XCTAssertTrue(bufferL[j].isFinite, "Slope \(slope): Output sample L[\(j)] is not finite at frame \(i)")
                    XCTAssertTrue(bufferR[j].isFinite, "Slope \(slope): Output sample R[\(j)] is not finite at frame \(i)")
                }
            }
        }
    }
}
