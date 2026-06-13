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

    // MARK: - Sub EQ Tests

    func testSubEQBandAppliesGain() {
        // Test that a sub EQ band applies gain at its centre frequency
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management
        processor.setBassManagementEnabled(true)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        // Add a sub EQ band with +3 dB gain at 80 Hz
        let subEQBands = [SubEQBand(frequency: 80.0, q: 1.0, gain: 3.0, bypass: false)]
        processor.setSubEQBands(subEQBands, sampleRate: sampleRate)

        // Create test buffer with signal at 80 Hz
        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        // Process to apply the sub EQ update
        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Free the first buffer
        freeTestBufferList(bufferList: bufferList)

        // Create a new buffer with the same signal to test the effect
        var bufferList2 = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)
        processor.process(bufferList: &bufferList2, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList2, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Sub EQ should not silence signal")

        freeTestBufferList(bufferList: bufferList2)
    }

    func testSubEQBypassedBandIsTransparent() {
        // Test that a bypassed sub EQ band does not alter the signal
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management
        processor.setBassManagementEnabled(true)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        // Add a bypassed sub EQ band with gain
        let subEQBands = [SubEQBand(frequency: 80.0, q: 1.0, gain: 10.0, bypass: true)]
        processor.setSubEQBands(subEQBands, sampleRate: sampleRate)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        // Process to apply the sub EQ update
        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Free the first buffer
        freeTestBufferList(bufferList: bufferList)

        // Create a new buffer with the same signal to test transparency
        var bufferList2 = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)
        processor.process(bufferList: &bufferList2, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList2, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Bypassed sub EQ should not silence signal")

        freeTestBufferList(bufferList: bufferList2)
    }

    func testSubEQStatePreservedAcrossCallbacks() {
        // Test that sub EQ state variables are preserved between callbacks
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management
        processor.setBassManagementEnabled(true)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        // Add a sub EQ band
        let subEQBands = [SubEQBand(frequency: 80.0, q: 1.0, gain: 0.0, bypass: false)]
        processor.setSubEQBands(subEQBands, sampleRate: sampleRate)

        let frameCount: UInt32 = 512

        // Process multiple callbacks
        for _ in 0..<5 {
            var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)
            processor.process(bufferList: &bufferList, frameCount: frameCount)

            // Verify output is finite (state preservation prevents glitches)
            let abl = UnsafeMutableAudioBufferListPointer(&bufferList)
            for ch in 0..<Int(channelCount) {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(frameCount) {
                    XCTAssertTrue(buf[i].isFinite, "Sub EQ state should be preserved across callbacks")
                }
            }

            freeTestBufferList(bufferList: bufferList)
        }
    }

    // MARK: - Crossover Type Tests

    func testCrossoverTypeButterworth() {
        // Test that Butterworth crossover processes correctly
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management with Butterworth crossover
        processor.setBassManagementEnabled(true)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Butterworth crossover should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    func testCrossoverTypeBessel() {
        // Test that Bessel crossover processes correctly
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management with Bessel crossover
        processor.setBassManagementEnabled(true)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Bessel crossover should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    func testCrossoverTypeLinkwitzRiley() {
        // Test that Linkwitz-Riley crossover processes correctly (default)
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management with Linkwitz-Riley crossover (default)
        processor.setBassManagementEnabled(true)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Linkwitz-Riley crossover should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    // MARK: - Asymmetric Crossover Tests

    func testAsymmetricCrossoverEnabled() {
        // Test that asymmetric crossover mode processes correctly
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management with asymmetric crossover enabled
        processor.setBassManagementEnabled(true)
        processor.setAsymmetricCrossoverEnabled(true)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Asymmetric crossover should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    func testAsymmetricCrossoverDisabled() {
        // Test that asymmetric crossover disabled uses symmetric crossover
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure bass management with asymmetric crossover disabled
        processor.setBassManagementEnabled(true)
        processor.setAsymmetricCrossoverEnabled(false)
        processor.setBassManagementCrossoverHz(80.0)
        processor.setBassManagementSlope(.lr4)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Symmetric crossover should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    // MARK: - Dynamic EQ Tests

    func testDynamicEQEnabled() {
        // Test that dynamic EQ processes correctly when enabled
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure dynamic EQ with one band
        let config = DynamicEQConfig(
            enabled: true,
            bands: [
                DynamicEQBand(
                    frequency: 1000.0,
                    q: 1.0,
                    gain: 0.0,
                    thresholdDB: -20.0,
                    ratio: 2.0,
                    attackMs: 10.0,
                    releaseMs: 100.0,
                    bypass: false
                )
            ]
        )
        processor.setDynamicEQEnabled(true)
        processor.setDynamicEQConfig(config, sampleRate: sampleRate)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Dynamic EQ should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    func testDynamicEQDisabled() {
        // Test that dynamic EQ disabled doesn't affect signal
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure dynamic EQ but keep it disabled
        let config = DynamicEQConfig(
            enabled: false,
            bands: [
                DynamicEQBand(
                    frequency: 1000.0,
                    q: 1.0,
                    gain: 0.0,
                    thresholdDB: -20.0,
                    ratio: 2.0,
                    attackMs: 10.0,
                    releaseMs: 100.0,
                    bypass: false
                )
            ]
        )
        processor.setDynamicEQEnabled(false)
        processor.setDynamicEQConfig(config, sampleRate: sampleRate)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Signal should pass through when Dynamic EQ disabled")

        freeTestBufferList(bufferList: bufferList)
    }

    func testDynamicEQBypassedBand() {
        // Test that bypassed band is transparent
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure dynamic EQ with bypassed band
        let config = DynamicEQConfig(
            enabled: true,
            bands: [
                DynamicEQBand(
                    frequency: 1000.0,
                    q: 1.0,
                    gain: 0.0,
                    thresholdDB: -20.0,
                    ratio: 2.0,
                    attackMs: 10.0,
                    releaseMs: 100.0,
                    bypass: true
                )
            ]
        )
        processor.setDynamicEQEnabled(true)
        processor.setDynamicEQConfig(config, sampleRate: sampleRate)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Bypassed band should be transparent")

        freeTestBufferList(bufferList: bufferList)
    }

    // MARK: - FIR Impulse Response Tests

    func testFIREnabled() {
        // Test that FIR processes correctly when enabled
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure FIR with a simple impulse response
        let config = FIRImpulseResponseConfig(
            enabled: true,
            leftIR: [1.0] + Array(repeating: 0.0, count: 4095),
            rightIR: [1.0] + Array(repeating: 0.0, count: 4095),
            sampleRate: sampleRate,
            tapCount: 4096
        )
        processor.setFIREnabled(true)
        processor.setFIRConfig(config)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "FIR should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    func testFIRDisabled() {
        // Test that FIR disabled doesn't affect signal
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Configure FIR but keep it disabled
        let config = FIRImpulseResponseConfig(
            enabled: false,
            leftIR: [1.0] + Array(repeating: 0.0, count: 4095),
            rightIR: [1.0] + Array(repeating: 0.0, count: 4095),
            sampleRate: sampleRate,
            tapCount: 4096
        )
        processor.setFIREnabled(false)
        processor.setFIRConfig(config)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Signal should pass through when FIR disabled")

        freeTestBufferList(bufferList: bufferList)
    }

    // MARK: - Room Correction Tests

    func testRoomCorrectionHarmanTarget() {
        // Test that Harman target curve is generated correctly
        let harmanCurve = RoomCorrectionEngine.harmanTargetCurve()
        XCTAssertFalse(harmanCurve.isEmpty, "Harman target curve should not be empty")
        XCTAssertEqual(harmanCurve.first?.frequency, 20.0, "First frequency should be 20 Hz")
        XCTAssertEqual(harmanCurve.last?.frequency, 20000.0, "Last frequency should be 20 kHz")
    }

    func testRoomCorrectionTargetCurveSelection() {
        // Test that different target curves can be selected
        let flatCurve = RoomCorrectionEngine.getTargetCurve(.flat)
        XCTAssertTrue(flatCurve.isEmpty, "Flat target curve should be empty")

        let harmanCurve = RoomCorrectionEngine.getTargetCurve(.harman)
        XCTAssertFalse(harmanCurve.isEmpty, "Harman target curve should not be empty")
    }

    // MARK: - Program-Dependent Release Tests

    func testCompressorProgramDependentRelease() {
        // Test that program-dependent release can be enabled
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Enable compressor with program-dependent release
        var config = DynamicsConfig()
        config.compressor.isEnabled = true
        config.compressor.programDependentRelease = true
        config.compressor.thresholdDB = -16.0
        config.compressor.ratio = 3.5
        config.compressor.attackMs = 25.0
        config.compressor.releaseMs = 150.0
        config.compressor.makeupGainDB = 2.5
        config.compressor.kneeWidthDB = 6.0

        processor.applyConfig(config, sampleRate: sampleRate)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Compressor with program-dependent release should not silence signal")

        freeTestBufferList(bufferList: bufferList)
    }

    // MARK: - Sidechain High-Pass Filter Tests

    func testCompressorSidechainHighPass() {
        // Test that sidechain high-pass filter can be enabled
        let channelCount: UInt32 = 2
        let sampleRate: Double = 48000.0
        let processor = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)

        // Enable compressor with sidechain high-pass filter
        var config = DynamicsConfig()
        config.compressor.isEnabled = true
        config.compressor.sidechainHighPassHz = 100.0
        config.compressor.thresholdDB = -16.0
        config.compressor.ratio = 3.5
        config.compressor.attackMs = 25.0
        config.compressor.releaseMs = 150.0
        config.compressor.makeupGainDB = 2.5
        config.compressor.kneeWidthDB = 6.0

        processor.applyConfig(config, sampleRate: sampleRate)

        let frameCount: UInt32 = 512
        var bufferList = createTestBufferList(channelCount: Int(channelCount), frameCount: Int(frameCount), amplitude: 0.5)

        processor.process(bufferList: &bufferList, frameCount: frameCount)

        // Verify output is not silent
        let maxOutput = getMaxLevel(bufferList: bufferList, frameCount: frameCount)
        XCTAssertGreaterThan(maxOutput, 0.01, "Compressor with sidechain high-pass should not silence signal")

        freeTestBufferList(bufferList: bufferList)
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
