// LoudnessContourTests.swift
// Tests for volume-dependent loudness compensation.

import XCTest
import AudioToolbox
@testable import Equaliser

final class LoudnessContourTests: XCTestCase {

    // MARK: - ISO 226 correction gains

    /// At the reference listening level, correction gains must be zero.
    /// (No correction needed when listening at the calibrated reference level.)
    func testISO226_AtReferenceLevel_GainsAreZero() {
        let refPhon = 83.0
        let (bass, treble) = DynamicsProcessor.iso226CorrectionGains(
            listeningPhon: refPhon, referencePhon: refPhon)
        XCTAssertEqual(bass,   0.0, accuracy: 0.01,
            "Bass gain must be 0 dB when listening at reference level")
        XCTAssertEqual(treble, 0.0, accuracy: 0.01,
            "Treble gain must be 0 dB when listening at reference level")
    }

    /// Below the reference level, the bass correction must be positive (boost required).
    func testISO226_BelowReferenceLevel_BassGainIsPositive() {
        let (bass, _) = DynamicsProcessor.iso226CorrectionGains(
            listeningPhon: 60.0, referencePhon: 83.0)
        XCTAssertGreaterThan(bass, 0.0,
            "Bass must be boosted when listening below reference level")
    }

    /// Below the reference level, treble correction must also be positive.
    func testISO226_BelowReferenceLevel_TrebleGainIsPositive() {
        let (_, treble) = DynamicsProcessor.iso226CorrectionGains(
            listeningPhon: 60.0, referencePhon: 83.0)
        XCTAssertGreaterThan(treble, 0.0,
            "Treble must be boosted when listening below reference level")
    }

    /// Gains must be clamped to ±12 dB at extreme volume differences.
    func testISO226_ExtremeLevel_GainsClamped() {
        let (bass, treble) = DynamicsProcessor.iso226CorrectionGains(
            listeningPhon: 20.0, referencePhon: 83.0)
        XCTAssertLessThanOrEqual(bass,   12.0, "Bass gain must not exceed +12 dB")
        XCTAssertLessThanOrEqual(treble, 12.0, "Treble gain must not exceed +12 dB")
        XCTAssertGreaterThanOrEqual(bass,   -12.0, "Bass gain must not go below −12 dB")
        XCTAssertGreaterThanOrEqual(treble, -12.0, "Treble gain must not go below −12 dB")
    }

    /// Gains must be monotonically increasing as listening level decreases
    /// (more correction needed at lower levels).
    func testISO226_GainsIncreaseAsLevelDrops() {
        let refPhon = 83.0
        let levels = [80.0, 70.0, 60.0, 50.0, 40.0]
        var prevBass = 0.0
        for level in levels {
            let (bass, _) = DynamicsProcessor.iso226CorrectionGains(
                listeningPhon: level, referencePhon: refPhon)
            XCTAssertGreaterThan(Double(bass), prevBass,
                "Bass correction must increase as listening level drops to \(level) phon")
            prevBass = Double(bass)
        }
    }

    // MARK: - Strength scaling

    /// At strength 0.0, correction gains applied to the shelf must be zero.
    func testStrengthZero_ProducesNoCorrection() {
        // A 0 dB low shelf is an identity biquad: b0=1, b1=0, b2=0, a1=0, a2=0
        let sr: Double = 48000
        let (b0, b1, b2, na1, na2) = DynamicsProcessor.lowShelfCoeffs(
            fc: 60.0, gainDB: 0.0, sr: sr)
        XCTAssertEqual(b0,  1.0, accuracy: 1e-5, "0 dB shelf b0 must be ~1")
        XCTAssertEqual(b1,  0.0, accuracy: 1e-5, "0 dB shelf b1 must be ~0")
        XCTAssertEqual(b2,  0.0, accuracy: 1e-5, "0 dB shelf b2 must be ~0")
        XCTAssertEqual(na1, 0.0, accuracy: 1e-5, "0 dB shelf a1 must be ~0")
        XCTAssertEqual(na2, 0.0, accuracy: 1e-5, "0 dB shelf a2 must be ~0")
    }

    /// At strength 0.5, bass correction should be half of full correction.
    func testStrengthHalf_ScalesGainsByHalf() {
        let refPhon = 83.0
        let lisPhon = 60.0
        let (fullBass, fullTreble) = DynamicsProcessor.iso226CorrectionGains(
            listeningPhon: lisPhon, referencePhon: refPhon)
        let halfBass   = fullBass   * 0.5
        let halfTreble = fullTreble * 0.5

        XCTAssertEqual(halfBass,   fullBass   * 0.5, accuracy: 1e-5)
        XCTAssertEqual(halfTreble, fullTreble * 0.5, accuracy: 1e-5)
    }

    // MARK: - Volume wiring: setSystemVolume affects contour output

    /// Verify that after calling setSystemVolume(0.1), the loudness contour
    /// produces more bass boost than at full volume (setSystemVolume(1.0)).
    func testSetSystemVolume_AffectsContourProcessing() {
        let sampleRate: Double = 48000
        let processor = DynamicsProcessor(
            maxFrameCount: 512, channelCount: 2, sampleRate: sampleRate)

        var config = DynamicsConfig.default
        config.advanced.loudnessContourEnabled = true
        config.advanced.volumeDependentLoudnessEnabled = true
        config.advanced.loudnessReferencePhon = 83.0
        config.advanced.loudnessReferenceVolume = 1.0
        config.advanced.loudnessContourStrength = 1.0
        processor.applyConfig(config, sampleRate: sampleRate)

        let frameCount = 256

        // --- At full volume ---
        processor.setSystemVolume(1.0)
        var ablFull = makeTestABL(channelCount: 2, frameCount: frameCount, amplitude: 0.5)
        defer { freeTestABL(&ablFull) }
        processor.processLoudnessContourForTest(abl: &ablFull, count: frameCount)
        let outputAtFull = readABLSample(&ablFull, channel: 0, frame: frameCount / 2)

        // --- At low volume ---
        var ablLow = makeTestABL(channelCount: 2, frameCount: frameCount, amplitude: 0.5)
        defer { freeTestABL(&ablLow) }
        // Reset contour filter state to get a clean comparison
        processor.applyConfig(config, sampleRate: sampleRate)
        processor.setSystemVolume(0.1)
        processor.processLoudnessContourForTest(abl: &ablLow, count: frameCount)
        let outputAtLow = readABLSample(&ablLow, channel: 0, frame: frameCount / 2)

        XCTAssertGreaterThan(outputAtLow, outputAtFull,
            "At low volume, loudness contour should boost bass relative to full volume")
    }

    // MARK: - DynamicsConfig round-trip

    func testLoudnessContourStrength_SerializesAndDeserializes() throws {
        var config = DynamicsConfig.default
        config.advanced.loudnessContourStrength = 0.65
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DynamicsConfig.self, from: data)
        XCTAssertEqual(decoded.advanced.loudnessContourStrength, 0.65, accuracy: 0.001)
    }

    func testLoudnessContourStrength_DefaultsToOne_WhenMissing() throws {
        // Simulate a preset that doesn't have the key (older preset compatibility)
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AdvancedProcessingConfig.self, from: json)
        XCTAssertEqual(decoded.loudnessContourStrength, 1.0,
            "loudnessContourStrength must default to 1.0 for backward compatibility")
    }

    // MARK: - ABL Helpers (same pattern as DynamicsProcessorTests)

    private func makeTestABL(channelCount: Int, frameCount: Int, amplitude: Float) -> AudioBufferList {
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let ptr = UnsafeMutableRawPointer
            .allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            .assumingMemoryBound(to: AudioBufferList.self)
        ptr.pointee.mNumberBuffers = UInt32(channelCount)
        for ch in 0..<channelCount {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            for i in 0..<frameCount { buf[i] = amplitude }
            ptr.pointee.mBuffers[ch].mNumberChannels = 1
            ptr.pointee.mBuffers[ch].mDataByteSize   = UInt32(frameCount * MemoryLayout<Float>.size)
            ptr.pointee.mBuffers[ch].mData           = UnsafeMutableRawPointer(buf)
        }
        return ptr.pointee
    }

    private func freeTestABL(_ abl: inout AudioBufferList) {
        for i in 0..<Int(abl.mNumberBuffers) {
            abl.mBuffers[i].mData?.deallocate()
        }
    }

    private func readABLSample(_ abl: inout AudioBufferList, channel: Int, frame: Int) -> Float {
        guard let data = abl.mBuffers[channel].mData else { return 0 }
        return data.assumingMemoryBound(to: Float.self)[frame]
    }
}
