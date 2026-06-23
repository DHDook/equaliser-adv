import XCTest
@testable import Equaliser

/// Regression tests for preset serialisation bugs found in QA audit.
///
/// Bug 1 – subBassPhaseAlignmentQ not persisted.
/// Bug 2 – applyPreset omits slope, isDynamic, dynamicParams from band loops.
/// Bug 3 – globalBypass must NOT be stored in presets (transient A/B tool).
final class PresetSerializationRegressionTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Bug 3: globalBypass must NOT be encoded

    func test_globalBypass_isNotEncoded() throws {
        let settings = PresetSettings(
            globalBypass: true,
            inputGain: 0,
            outputGain: 0,
            leftBands: [],
            rightBands: []
        )

        let data = try encoder.encode(settings)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertFalse(
            json.contains("globalBypass"),
            "globalBypass must not appear in encoded preset JSON — it is a transient A/B state"
        )
    }

    func test_globalBypass_alwaysDecodesAsFalse() throws {
        // Verifies backward compatibility: old presets that do contain the key
        // must load cleanly and always produce false.
        let jsonWithBypass = """
        {
            "inputGain": 0,
            "outputGain": 0,
            "channelMode": "linked",
            "leftBands": [],
            "rightBands": [],
            "globalBypass": true
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(PresetSettings.self, from: jsonWithBypass)
        XCTAssertFalse(decoded.globalBypass,
            "globalBypass must always load as false regardless of what is stored on disk")
    }

    // MARK: - Bug 2a: applyPreset must restore band slope

    @MainActor
    func test_applyPreset_restoresBandSlope() {
        let nonDefaultSlope = FilterSlope.db48   // default is .db12
        let band = PresetBand(
            frequency: 80,
            q: 0.707,
            gain: 0,
            filterType: .highPass,
            bypass: false,
            slope: nonDefaultSlope
        )
        let settings = PresetSettings(
            globalBypass: false,
            inputGain: 0,
            outputGain: 0,
            leftBands: [band],
            rightBands: [band]
        )
        let preset = Preset(metadata: PresetMetadata(name: "SlopeTest"), settings: settings)

        let config = EQConfiguration(initialBandCount: 1)
        PresetManager().applyPreset(preset, to: config)

        XCTAssertEqual(
            config.leftState.userEQ.bands[0].slope,
            nonDefaultSlope,
            "Band slope must be restored by applyPreset"
        )
    }

    @MainActor
    func test_applyPreset_restoresBandSlope_allValues() {
        for slope in FilterSlope.allCases {
            let band = PresetBand(
                frequency: 1000,
                q: 0.707,
                gain: 0,
                filterType: .lowPass,
                bypass: false,
                slope: slope
            )
            let settings = PresetSettings(
                globalBypass: false,
                inputGain: 0,
                outputGain: 0,
                leftBands: [band],
                rightBands: [band]
            )
            let preset = Preset(metadata: PresetMetadata(name: "Slope_\(slope.rawValue)"), settings: settings)

            let config = EQConfiguration(initialBandCount: 1)
            PresetManager().applyPreset(preset, to: config)

            XCTAssertEqual(
                config.leftState.userEQ.bands[0].slope,
                slope,
                "Slope \(slope.displayName) must survive applyPreset"
            )
        }
    }

    @MainActor
    func test_applyPreset_restoresBandSlope_rightChannel() {
        let slope = FilterSlope.db96
        let band = PresetBand(
            frequency: 50,
            q: 0.5,
            gain: 0,
            filterType: .highPass,
            bypass: false,
            slope: slope
        )
        let settings = PresetSettings(
            globalBypass: false,
            inputGain: 0,
            outputGain: 0,
            leftBands: [band],
            rightBands: [band]
        )
        let preset = Preset(metadata: PresetMetadata(name: "RightSlopeTest"), settings: settings)

        let config = EQConfiguration(initialBandCount: 1)
        config.setChannelMode(.stereo)
        PresetManager().applyPreset(preset, to: config)

        XCTAssertEqual(
            config.rightState.userEQ.bands[0].slope,
            slope,
            "Right-channel band slope must be restored by applyPreset"
        )
    }

    // MARK: - Bug 2b: applyPreset must restore isDynamic / dynamicParams

    @MainActor
    func test_applyPreset_restoresDynamicBandFlag() {
        var band = PresetBand(
            frequency: 3000,
            q: 2.0,
            gain: -6.0,
            filterType: .parametric,
            bypass: false,
            slope: .db12
        )
        band.isDynamic = true
        band.dynamicParams = DynamicBandParams(
            thresholdDB: -18.0,
            ratio: 3.0,
            attackMs: 5.0,
            releaseMs: 80.0
        )

        let settings = PresetSettings(
            globalBypass: false,
            inputGain: 0,
            outputGain: 0,
            leftBands: [band],
            rightBands: [band]
        )
        let preset = Preset(metadata: PresetMetadata(name: "DynamicBandTest"), settings: settings)

        let config = EQConfiguration(initialBandCount: 1)
        PresetManager().applyPreset(preset, to: config)

        let restoredBand = config.leftState.userEQ.bands[0]
        XCTAssertTrue(restoredBand.isDynamic,
            "isDynamic flag must be restored by applyPreset")
        XCTAssertEqual(restoredBand.dynamicParams.thresholdDB, -18.0, accuracy: 0.001)
        XCTAssertEqual(restoredBand.dynamicParams.ratio, 3.0, accuracy: 0.001)
        XCTAssertEqual(restoredBand.dynamicParams.attackMs, 5.0, accuracy: 0.001)
        XCTAssertEqual(restoredBand.dynamicParams.releaseMs, 80.0, accuracy: 0.001)
    }

    @MainActor
    func test_applyPreset_nonDynamicBandRemainsFalse() {
        let band = PresetBand(
            frequency: 1000,
            q: 1.41,
            gain: 2.0,
            filterType: .parametric,
            bypass: false,
            slope: .db12
        )
        let settings = PresetSettings(
            globalBypass: false,
            inputGain: 0,
            outputGain: 0,
            leftBands: [band],
            rightBands: [band]
        )
        let preset = Preset(metadata: PresetMetadata(name: "StaticBandTest"), settings: settings)

        let config = EQConfiguration(initialBandCount: 1)
        PresetManager().applyPreset(preset, to: config)

        XCTAssertFalse(config.leftState.userEQ.bands[0].isDynamic,
            "A non-dynamic band must remain non-dynamic after applyPreset")
    }

    // MARK: - Bug 1: subBassPhaseAlignmentQ must be persisted

    func test_subBassPhaseAlignmentQ_isEncoded() throws {
        var adv = AdvancedProcessingConfig()
        adv.subBassPhaseAlignmentQ = 1.2

        let data = try encoder.encode(adv)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("subBassPhaseAlignmentQ"),
            "subBassPhaseAlignmentQ must be present in encoded JSON")
    }

    func test_subBassPhaseAlignmentQ_roundTrip() throws {
        var adv = AdvancedProcessingConfig()
        adv.subBassPhaseAlignmentQ = 1.414

        let data = try encoder.encode(adv)
        let decoded = try decoder.decode(AdvancedProcessingConfig.self, from: data)

        XCTAssertEqual(decoded.subBassPhaseAlignmentQ, 1.414, accuracy: 0.001)
    }

    func test_subBassPhaseAlignmentQ_defaultWhenAbsent() throws {
        let decoded = try decoder.decode(AdvancedProcessingConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(decoded.subBassPhaseAlignmentQ, 0.7, accuracy: 0.001,
            "Missing field must default to 0.7 for backward compatibility")
    }

    func test_subBassPhaseAlignmentQ_roundTrip_viaFullPreset() throws {
        var dynamics = DynamicsConfig()
        dynamics.advanced.subBassPhaseAlignmentQ = 1.5
        dynamics.advanced.subBassPhaseAlignmentEnabled = true

        let settings = PresetSettings(
            globalBypass: false,
            inputGain: 0,
            outputGain: 0,
            leftBands: [],
            rightBands: [],
            dynamicsConfig: dynamics
        )
        let preset = Preset(metadata: PresetMetadata(name: "SubBassQTest"), settings: settings)

        let data = try encoder.encode(preset)
        let decoded = try decoder.decode(Preset.self, from: data)

        XCTAssertEqual(decoded.settings.dynamicsConfig.advanced.subBassPhaseAlignmentQ,
                       1.5, accuracy: 0.001)
        XCTAssertTrue(decoded.settings.dynamicsConfig.advanced.subBassPhaseAlignmentEnabled)
    }

    // MARK: - Infrasonic filter (originally reported regression)

    func test_infrasonicFilter_roundTrip_viaPreset() throws {
        var dynamics = DynamicsConfig()
        dynamics.advanced.infrasonicFilter.isEnabled = true
        dynamics.advanced.infrasonicFilter.cutoffHz = 22.0
        dynamics.advanced.infrasonicFilter.slope = .db96

        let settings = PresetSettings(
            globalBypass: false,
            inputGain: 0,
            outputGain: 0,
            leftBands: [],
            rightBands: [],
            dynamicsConfig: dynamics
        )
        let preset = Preset(metadata: PresetMetadata(name: "InfrasonicTest"), settings: settings)

        let data = try encoder.encode(preset)
        let decoded = try decoder.decode(Preset.self, from: data)

        let filter = decoded.settings.dynamicsConfig.advanced.infrasonicFilter
        XCTAssertTrue(filter.isEnabled)
        XCTAssertEqual(filter.cutoffHz, 22.0, accuracy: 0.001)
        XCTAssertEqual(filter.slope, .db96)
    }

    func test_infrasonicFilter_defaultsToDisabled_forLegacyPresets() throws {
        let decoded = try decoder.decode(AdvancedProcessingConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertFalse(decoded.infrasonicFilter.isEnabled,
            "Legacy presets without infrasonicFilter must default to isEnabled:false")
    }
}
