import XCTest
@testable import Equaliser

final class FactoryPresetsTests: XCTestCase {

    // MARK: - Collection Integrity

    func testAll_isNotEmpty() {
        XCTAssertFalse(FactoryPresets.all.isEmpty)
    }

    func testAll_containsExpectedCount() {
        XCTAssertEqual(FactoryPresets.all.count, 11)
    }

    func testAll_namesAreUnique() {
        let names = FactoryPresets.all.map { $0.metadata.name }
        XCTAssertEqual(Set(names).count, names.count, "Factory preset names must be unique")
    }

    func testAll_allMarkedAsFactory() {
        for preset in FactoryPresets.all {
            XCTAssertTrue(
                preset.metadata.isFactoryPreset,
                "\(preset.metadata.name) should be marked as factory preset"
            )
        }
    }

    // MARK: - Band Structure

    func testAll_haveNonEmptyBands() {
        for preset in FactoryPresets.all {
            XCTAssertFalse(
                preset.settings.leftBands.isEmpty,
                "\(preset.metadata.name) should have left bands"
            )
            XCTAssertFalse(
                preset.settings.rightBands.isEmpty,
                "\(preset.metadata.name) should have right bands"
            )
        }
    }

    func testAll_leftAndRightBandCountsMatch() {
        for preset in FactoryPresets.all {
            XCTAssertEqual(
                preset.settings.leftBands.count,
                preset.settings.rightBands.count,
                "\(preset.metadata.name) left/right band counts should match"
            )
        }
    }

    func testAll_bandsHaveValidFrequencies() {
        for preset in FactoryPresets.all {
            for band in preset.settings.leftBands {
                XCTAssertGreaterThan(
                    band.frequency, 0,
                    "\(preset.metadata.name) has band with non-positive frequency"
                )
                XCTAssertLessThanOrEqual(
                    band.frequency, 22000,
                    "\(preset.metadata.name) has band with frequency above Nyquist"
                )
            }
        }
    }

    func testAll_bandsHavePositiveQ() {
        for preset in FactoryPresets.all {
            for band in preset.settings.leftBands {
                XCTAssertGreaterThan(
                    band.q, 0,
                    "\(preset.metadata.name) has band with non-positive Q"
                )
            }
        }
    }

    // MARK: - Named Presets

    func testFlat_allGainsZero() {
        let flat = FactoryPresets.flat
        XCTAssertEqual(flat.settings.inputGain, 0)
        XCTAssertEqual(flat.settings.outputGain, 0)
        for band in flat.settings.leftBands {
            XCTAssertEqual(band.gain, 0, accuracy: 0.001, "Flat preset band should have 0 gain")
        }
    }

    func testBassBoost_hasNegativeInputGain() {
        let preset = FactoryPresets.bassBoost
        XCTAssertLessThan(preset.settings.inputGain, 0, "Bass boost uses input attenuation to prevent clipping")
    }

    func testTrebleBoost_hasNegativeInputGain() {
        let preset = FactoryPresets.trebleBoost
        XCTAssertLessThan(preset.settings.inputGain, 0, "Treble boost uses input attenuation")
    }

    // MARK: - Codable Round-Trip

    func testFactoryPresets_encodeDecode() throws {
        for preset in FactoryPresets.all {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(Preset.self, from: data)
            XCTAssertEqual(
                decoded.metadata.name,
                preset.metadata.name,
                "Round-trip failed for \(preset.metadata.name)"
            )
            XCTAssertEqual(
                decoded.settings.leftBands.count,
                preset.settings.leftBands.count,
                "Band count mismatch after decode for \(preset.metadata.name)"
            )
        }
    }
}
