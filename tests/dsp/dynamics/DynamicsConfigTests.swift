import XCTest
@testable import Equaliser

final class DynamicsConfigTests: XCTestCase {

    // MARK: - DeEsserConfig

    func testDeEsserConfig_defaultValues() {
        let config = DeEsserConfig()
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.frequencyHz, 6000.0)
        XCTAssertEqual(config.thresholdDB, -20.0)
    }

    func testDeEsserConfig_staticDefault() {
        XCTAssertEqual(DeEsserConfig.default, DeEsserConfig())
    }

    func testDeEsserConfig_codableRoundTrip() throws {
        let config = DeEsserConfig(isEnabled: true, frequencyHz: 8000.0, thresholdDB: -15.0)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DeEsserConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testDeEsserConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DeEsserConfig.self, from: json)
        XCTAssertEqual(decoded, DeEsserConfig.default)
    }

    func testDeEsserConfig_decodesPartialJSON() throws {
        let json = """
        {"isEnabled": true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DeEsserConfig.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.frequencyHz, 6000.0)
        XCTAssertEqual(decoded.thresholdDB, -20.0)
    }

    // MARK: - MultibandCompressorConfig

    func testMultibandCompressorConfig_defaultValues() {
        let config = MultibandCompressorConfig()
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.crossLowMidHz, 150.0)
        XCTAssertEqual(config.crossMidHighHz, 3000.0)
        XCTAssertEqual(config.thresholdLowDB, 0.0)
        XCTAssertEqual(config.thresholdMidDB, 0.0)
        XCTAssertEqual(config.thresholdHighDB, 0.0)
        XCTAssertEqual(config.slopeLowMid, .gentle)
        XCTAssertEqual(config.slopeMidHigh, .gentle)
    }

    func testMultibandCompressorConfig_codableRoundTrip() throws {
        let config = MultibandCompressorConfig(
            isEnabled: true,
            crossLowMidHz: 200.0,
            crossMidHighHz: 4000.0,
            thresholdLowDB: -6.0,
            thresholdMidDB: -3.0,
            thresholdHighDB: -9.0,
            slopeLowMid: .steep,
            slopeMidHigh: .gentle
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MultibandCompressorConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testMultibandCompressorConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MultibandCompressorConfig.self, from: json)
        XCTAssertEqual(decoded, MultibandCompressorConfig.default)
    }

    // MARK: - CompressorConfig

    func testCompressorConfig_defaultValues() {
        let config = CompressorConfig()
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.thresholdDB, -16.0)
        XCTAssertEqual(config.ratio, 3.5)
        XCTAssertEqual(config.attackMs, 25.0)
        XCTAssertEqual(config.releaseMs, 150.0)
        XCTAssertEqual(config.makeupGainDB, 2.5)
        XCTAssertEqual(config.kneeWidthDB, 6.0)
    }

    func testCompressorConfig_codableRoundTrip() throws {
        let config = CompressorConfig(
            isEnabled: true,
            thresholdDB: -20.0,
            ratio: 4.0,
            attackMs: 10.0,
            releaseMs: 200.0,
            makeupGainDB: 5.0,
            kneeWidthDB: 10.0
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CompressorConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testCompressorConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompressorConfig.self, from: json)
        XCTAssertEqual(decoded, CompressorConfig.default)
    }

    func testCompressorConfig_decodesPartialJSON() throws {
        let json = """
        {"isEnabled": true, "ratio": 8.0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompressorConfig.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.ratio, 8.0)
        XCTAssertEqual(decoded.thresholdDB, -16.0)
        XCTAssertEqual(decoded.attackMs, 25.0)
    }

    // MARK: - ExpanderConfig

    func testExpanderConfig_defaultValues() {
        let config = ExpanderConfig()
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.thresholdDB, -35.0)
        XCTAssertEqual(config.ratio, 1.5)
        XCTAssertEqual(config.rangeDB, -12.0)
    }

    func testExpanderConfig_codableRoundTrip() throws {
        let config = ExpanderConfig(isEnabled: true, thresholdDB: -40.0, ratio: 2.0, rangeDB: -20.0)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ExpanderConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testExpanderConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ExpanderConfig.self, from: json)
        XCTAssertEqual(decoded, ExpanderConfig.default)
    }

    // MARK: - SoftClipperConfig

    func testSoftClipperConfig_defaultValues() {
        let config = SoftClipperConfig()
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.driveDB, 0.0)
        XCTAssertEqual(config.thresholdDB, -1.5)
        XCTAssertEqual(config.kneeSmooth, 0.5)
    }

    func testSoftClipperConfig_codableRoundTrip() throws {
        var config = SoftClipperConfig()
        config.isEnabled = true
        config.driveDB = 3.0
        config.thresholdDB = -2.0
        config.kneeSmooth = 0.8
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SoftClipperConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - BrickwallLimiterConfig

    func testBrickwallLimiterConfig_defaultValues() {
        let config = BrickwallLimiterConfig()
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.ceilingDB, -0.2)
        XCTAssertEqual(config.attackMs, 0.1)
        XCTAssertEqual(config.releaseMs, 20.0)
        XCTAssertEqual(config.lookAheadMs, 2.0)
    }

    func testBrickwallLimiterConfig_codableRoundTrip() throws {
        let config = BrickwallLimiterConfig(
            isEnabled: false,
            ceilingDB: -1.0,
            attackMs: 0.5,
            releaseMs: 50.0,
            lookAheadMs: 5.0
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BrickwallLimiterConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testBrickwallLimiterConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BrickwallLimiterConfig.self, from: json)
        XCTAssertEqual(decoded, BrickwallLimiterConfig.default)
    }

    // MARK: - StereoWidenerConfig

    func testStereoWidenerConfig_defaultValues() {
        let config = StereoWidenerConfig()
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.widthFactorLow, 0.0)
        XCTAssertEqual(config.widthFactorMid, 1.4)
        XCTAssertEqual(config.widthFactorHigh, 1.25)
    }

    func testStereoWidenerConfig_codableRoundTrip() throws {
        let config = StereoWidenerConfig(
            isEnabled: true,
            widthFactorLow: 0.5,
            widthFactorMid: 1.8,
            widthFactorHigh: 2.0
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(StereoWidenerConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testStereoWidenerConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StereoWidenerConfig.self, from: json)
        XCTAssertEqual(decoded, StereoWidenerConfig.default)
    }

    // MARK: - LoudnessMatchConfig

    func testLoudnessMatchConfig_defaultValues() {
        let config = LoudnessMatchConfig()
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.targetLoudnessLUFS, -16.0)
    }

    func testLoudnessMatchConfig_codableRoundTrip() throws {
        let config = LoudnessMatchConfig(isEnabled: true, targetLoudnessLUFS: -14.0)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LoudnessMatchConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testLoudnessMatchConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoudnessMatchConfig.self, from: json)
        XCTAssertEqual(decoded, LoudnessMatchConfig.default)
    }

    // MARK: - CrossoverSlope

    func testCrossoverSlope_rawValues() {
        XCTAssertEqual(CrossoverSlope.gentle.rawValue, 0)
        XCTAssertEqual(CrossoverSlope.steep.rawValue, 1)
    }

    func testCrossoverSlope_codable() throws {
        let data = try JSONEncoder().encode(CrossoverSlope.steep)
        let decoded = try JSONDecoder().decode(CrossoverSlope.self, from: data)
        XCTAssertEqual(decoded, .steep)
    }

    // MARK: - StereoModeSelection

    func testStereoModeSelection_rawValues() {
        XCTAssertEqual(StereoModeSelection.stereo.rawValue, 0)
        XCTAssertEqual(StereoModeSelection.wideMono.rawValue, 1)
        XCTAssertEqual(StereoModeSelection.trueMono.rawValue, 2)
    }

    // MARK: - LatencyMode

    func testLatencyMode_rawValues() {
        XCTAssertEqual(LatencyMode.music.rawValue, 0)
        XCTAssertEqual(LatencyMode.movie.rawValue, 1)
    }

    // MARK: - DitherMode

    func testDitherMode_rawValues() {
        XCTAssertEqual(DitherMode.bypass.rawValue, 0)
        XCTAssertEqual(DitherMode.tpdf.rawValue, 1)
        XCTAssertEqual(DitherMode.shaped.rawValue, 2)
    }

    // MARK: - Combined DynamicsConfig

    func testDynamicsConfig_defaultValues() {
        let config = DynamicsConfig()
        XCTAssertEqual(config.stereoWidener, StereoWidenerConfig.default)
        XCTAssertEqual(config.loudnessMatch, LoudnessMatchConfig.default)
        XCTAssertEqual(config.deEsser, DeEsserConfig.default)
        XCTAssertEqual(config.multibandCompressor, MultibandCompressorConfig.default)
        XCTAssertEqual(config.compressor, CompressorConfig.default)
        XCTAssertEqual(config.expander, ExpanderConfig.default)
        XCTAssertEqual(config.softClipper, SoftClipperConfig.default)
        XCTAssertEqual(config.limiter, BrickwallLimiterConfig.default)
        XCTAssertEqual(config.advanced, AdvancedProcessingConfig.default)
    }

    func testDynamicsConfig_codableRoundTrip() throws {
        var config = DynamicsConfig()
        config.compressor = CompressorConfig(isEnabled: true, thresholdDB: -12.0)
        config.deEsser = DeEsserConfig(isEnabled: true, frequencyHz: 7500.0, thresholdDB: -18.0)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DynamicsConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testDynamicsConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DynamicsConfig.self, from: json)
        XCTAssertEqual(decoded, DynamicsConfig.default)
    }

    func testDynamicsConfig_decodesPartialJSON() throws {
        let json = """
        {"compressor": {"isEnabled": true, "ratio": 6.0}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DynamicsConfig.self, from: json)
        XCTAssertTrue(decoded.compressor.isEnabled)
        XCTAssertEqual(decoded.compressor.ratio, 6.0)
        XCTAssertEqual(decoded.deEsser, DeEsserConfig.default)
    }

    // MARK: - AdvancedProcessingConfig

    func testAdvancedProcessingConfig_defaultValues() {
        let config = AdvancedProcessingConfig()
        XCTAssertTrue(config.coefficientDecouplingEnabled)
        XCTAssertFalse(config.highResDecouplingActive)
        XCTAssertFalse(config.loudnessDialogueGateEnabled)
        XCTAssertEqual(config.clipperAsymmetryTrimDB, 0.0)
        XCTAssertFalse(config.deesserDynamicModeEnabled)
        XCTAssertFalse(config.deharshFilterEnabled)
        XCTAssertEqual(config.deharshTiltAmountDB, -1.5)
        XCTAssertEqual(config.stereoBalancePosition, 0.0)
        XCTAssertFalse(config.loudnessContourEnabled)
        XCTAssertFalse(config.limiterTruePeakGuardEnabled)
        XCTAssertEqual(config.stereoTimeDelayMS, 0.0)
        XCTAssertFalse(config.dcOffsetFilterEnabled)
        XCTAssertFalse(config.deltaSoloActive)
        XCTAssertEqual(config.latencyMode, .music)
        XCTAssertFalse(config.pauseGateEnabled)
        XCTAssertEqual(config.stereoMode, .stereo)
        XCTAssertFalse(config.hardwareSyncBufferEnabled)
        XCTAssertEqual(config.ditherMode, .bypass)
        XCTAssertFalse(config.symmetryBalanceEnabled)
        XCTAssertFalse(config.panningGainMatrixEnabled)
        XCTAssertEqual(config.panningCrossfeedAmount, 0.3)
        XCTAssertFalse(config.linearDenoisingEnabled)
        XCTAssertEqual(config.linearDenoisingThresholdDB, -60.0)
        XCTAssertFalse(config.speakerIRAlignmentEnabled)
        XCTAssertEqual(config.speakerIRDelayMs, 0.0)
        XCTAssertFalse(config.crosstalkCancellationEnabled)
        XCTAssertEqual(config.crosstalkCancellationAmount, 0.5)
        XCTAssertFalse(config.earlyReflectionCancellationEnabled)
        XCTAssertEqual(config.earlyReflectionRoomSizeMs, 20.0)
        XCTAssertFalse(config.hpfPhaseLinearizationEnabled)
        XCTAssertEqual(config.hpfPhaseLinearizationFrequencyHz, 80.0)
        XCTAssertFalse(config.multiSeatAveragingEnabled)
        XCTAssertEqual(config.multiSeatCount, 2)
        XCTAssertFalse(config.subBassPhaseAlignmentEnabled)
        XCTAssertEqual(config.subBassAlignmentFrequencyHz, 80.0)
        XCTAssertFalse(config.zlConvolutionReverbEnabled)
        XCTAssertEqual(config.zlConvolutionReverbMix, 0.1)
    }

    func testAdvancedProcessingConfig_codableRoundTrip() throws {
        var config = AdvancedProcessingConfig()
        config.deharshFilterEnabled = true
        config.deharshTiltAmountDB = -3.0
        config.stereoMode = .trueMono
        config.ditherMode = .tpdf
        config.latencyMode = .movie
        config.panningGainMatrixEnabled = true
        config.panningCrossfeedAmount = 0.6
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AdvancedProcessingConfig.self, from: data)
        XCTAssertEqual(decoded.deharshFilterEnabled, true)
        XCTAssertEqual(decoded.deharshTiltAmountDB, -3.0)
        XCTAssertEqual(decoded.stereoMode, .trueMono)
        XCTAssertEqual(decoded.ditherMode, .tpdf)
        XCTAssertEqual(decoded.latencyMode, .movie)
        XCTAssertEqual(decoded.panningGainMatrixEnabled, true)
        XCTAssertEqual(decoded.panningCrossfeedAmount, 0.6)
    }

    func testAdvancedProcessingConfig_decodesFromEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AdvancedProcessingConfig.self, from: json)
        XCTAssertEqual(decoded, AdvancedProcessingConfig.default)
    }

    func testAdvancedProcessingConfig_highResDecouplingAlwaysFalseOnDecode() throws {
        // highResDecouplingActive is runtime-only; should always decode as false
        let json = """
        {"coefficientDecouplingEnabled": true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AdvancedProcessingConfig.self, from: json)
        XCTAssertFalse(decoded.highResDecouplingActive)
    }
}
