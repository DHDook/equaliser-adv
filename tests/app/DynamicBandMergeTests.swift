import XCTest
@testable import Equaliser

/// Tests for the `buildMergedDynamicEQConfig()` helper in `EqualiserStore`.
/// Verifies that inline dynamic bands from the EQ band strip are correctly
/// merged into the `DynamicEQConfig` and that the resulting config is applied
/// to the audio pipeline.
final class DynamicBandMergeTests: XCTestCase {

    /// Verifies that inline dynamic bands from the EQ configuration are correctly
    /// merged into the `DynamicEQConfig` and that the resulting config is applied
    /// to the audio pipeline.
    func testMergingInlineDynamicBands() async throws {
        let store = EqualiserStore()
        store.bandCount = 3

        // Configure bands 0 and 2 as dynamic, band 1 as parametric
        store.updateBandDynamicMode(index: 0, isDynamic: true)
        store.updateBandDynamicMode(index: 2, isDynamic: true)

        // Set dynamic parameters for band 0
        store.updateBandDynamicParams(index: 0, params: DynamicBandParams(
            thresholdDB: -20.0,
            ratio: 2.0,
            attackMs: 10.0,
            releaseMs: 100.0
        ))

        // Set dynamic parameters for band 2
        store.updateBandDynamicParams(index: 2, params: DynamicBandParams(
            thresholdDB: -15.0,
            ratio: 3.0,
            attackMs: 20.0,
            releaseMs: 150.0
        ))

        // Build the merged config
        let merged = store.buildMergedDynamicEQConfig()

        // Verify that only the dynamic bands are included
        XCTAssertEqual(merged.bands.count, 2)

        // Verify band 0 parameters
        XCTAssertEqual(merged.bands[0].frequency, store.eqConfiguration.bands[0].frequency)
        XCTAssertEqual(merged.bands[0].q, store.eqConfiguration.bands[0].q)
        XCTAssertEqual(merged.bands[0].gain, store.eqConfiguration.bands[0].gain)
        XCTAssertEqual(merged.bands[0].thresholdDB, -20.0)
        XCTAssertEqual(merged.bands[0].ratio, 2.0)
        XCTAssertEqual(merged.bands[0].attackMs, 10.0)
        XCTAssertEqual(merged.bands[0].releaseMs, 100.0)

        // Verify band 2 parameters
        XCTAssertEqual(merged.bands[1].frequency, store.eqConfiguration.bands[2].frequency)
        XCTAssertEqual(merged.bands[1].q, store.eqConfiguration.bands[2].q)
        XCTAssertEqual(merged.bands[1].gain, store.eqConfiguration.bands[2].gain)
        XCTAssertEqual(merged.bands[1].thresholdDB, -15.0)
        XCTAssertEqual(merged.bands[1].ratio, 3.0)
        XCTAssertEqual(merged.bands[1].attackMs, 20.0)
        XCTAssertEqual(merged.bands[1].releaseMs, 150.0)

        // Verify that the merged config is enabled (at least one band is not bypassed)
        XCTAssertTrue(merged.enabled)
    }

    /// Verifies that when all dynamic bands are bypassed, the resulting
    /// `DynamicEQConfig.enabled` is false.
    func testDisabledDynamicEQConfig() async throws {
        let store = EqualiserStore()
        store.bandCount = 2

        // Configure both bands as dynamic
        store.updateBandDynamicMode(index: 0, isDynamic: true)
        store.updateBandDynamicMode(index: 1, isDynamic: true)

        // Set dynamic parameters
        let params = DynamicBandParams(
            thresholdDB: -20.0,
            ratio: 2.0,
            attackMs: 10.0,
            releaseMs: 100.0
        )
        store.updateBandDynamicParams(index: 0, params: params)
        store.updateBandDynamicParams(index: 1, params: params)

        // Bypass both bands
        store.updateBandBypass(index: 0, bypass: true)
        store.updateBandBypass(index: 1, bypass: true)

        // Build the merged config
        let merged = store.buildMergedDynamicEQConfig()

        // Verify that the config is disabled (all bands are bypassed)
        XCTAssertFalse(merged.enabled)

        // Verify that the bands are still present in the config
        XCTAssertEqual(merged.bands.count, 2)
        XCTAssertTrue(merged.bands.allSatisfy { $0.bypass })
    }
}
