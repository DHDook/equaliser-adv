// EQHeadroomCompensatorTests.swift
// Tests for EQHeadroomCompensator NaN-masking fix and ceiling enforcement (S-07, R-03, C.1).

import XCTest
@testable import Equaliser

final class EQHeadroomCompensatorTests: XCTestCase {

    // MARK: - NaN-masking regression (R-03)

    func testMalformedLinkwitzBandDoesNotReturnZero() {
        // A Linkwitz-Transform band with q = 0 previously caused silent NaN-masking:
        // NaN > x is always false, so the worst-case tracker never updated, returning "0.0 dB"
        // (falsely reassuring). After the fix, NaN bins trigger maximum caution.
        let malformedBand = PresetBand(
            frequency: 50, q: 0, gain: 0,
            filterType: .linkwitzTransform,
            bypass: false,
            slope: .db12
        )
        let result = EQHeadroomCompensator.computeStaticPreampDB(
            eqLayer: [malformedBand],
            roomCorrectionLayer: [],
            targetCurve: [],
            lowBandGainDB: 0,
            maxAttenuationDB: 12.0
        )
        XCTAssertLessThan(result, -0.5,
            "Malformed LT band must trigger headroom protection, not return 0.0 dB — got \(result)")
        XCTAssertGreaterThanOrEqual(result, -12.0,
            "Result must be clamped by maxAttenuationDB=12.0 — got \(result)")
        XCTAssertTrue(result.isFinite,
            "Result must always be finite regardless of input band validity")
    }

    func testResultIsAlwaysFiniteForAnyInput() {
        // Result must never be NaN or Inf regardless of what bands are passed.
        let weirdBands: [PresetBand] = [
            PresetBand(frequency: 0,     q: 0,   gain: 0,  filterType: .linkwitzTransform, bypass: false, slope: .db12),
            PresetBand(frequency: 50,    q: 0,   gain: 0,  filterType: .linkwitzTransform, bypass: false, slope: .db12),
            PresetBand(frequency: 1000,  q: 1.0, gain: 48, filterType: .parametric,        bypass: false, slope: .db12),
        ]
        for band in weirdBands {
            let result = EQHeadroomCompensator.computeStaticPreampDB(
                eqLayer: [band], roomCorrectionLayer: [], targetCurve: [], lowBandGainDB: 0
            )
            XCTAssertTrue(result.isFinite,
                "Result must be finite for band: \(band.filterType) freq=\(band.frequency) q=\(band.q)")
        }
    }

    // MARK: - Ceiling enforcement (C.1)

    func testCeilingClamps48dBBoost() {
        let bigBoostBand = PresetBand(
            frequency: 1000, q: 1.0, gain: 48,
            filterType: .parametric, bypass: false, slope: .db12
        )
        let result = EQHeadroomCompensator.computeStaticPreampDB(
            eqLayer: [bigBoostBand],
            roomCorrectionLayer: [],
            targetCurve: [],
            lowBandGainDB: 0,
            maxAttenuationDB: 10.0
        )
        XCTAssertGreaterThanOrEqual(result, -10.0,
            "Attenuation must be clamped to the 10 dB ceiling — got \(result)")
        XCTAssertLessThan(result, -1.0,
            "+48 dB boost must trigger meaningful attenuation — got \(result)")
    }

    func testDefaultCeilingIs12dB() {
        let bigBoostBand = PresetBand(
            frequency: 1000, q: 1.0, gain: 48,
            filterType: .parametric, bypass: false, slope: .db12
        )
        let result = EQHeadroomCompensator.computeStaticPreampDB(
            eqLayer: [bigBoostBand],
            roomCorrectionLayer: [],
            targetCurve: [],
            lowBandGainDB: 0
        )
        XCTAssertGreaterThanOrEqual(result, -12.0,
            "Default ceiling must be 12 dB — got \(result)")
        XCTAssertLessThan(result, 0.0,
            "Any boost band should produce negative (attenuating) preamp — got \(result)")
    }

    func testNoBoostedBandsProducesZeroAttenuation() {
        // Flat (0 dB gain) bands should produce 0.0 dB preamp (no attenuation needed).
        let flatBand = PresetBand(
            frequency: 1000, q: 1.0, gain: 0,
            filterType: .parametric, bypass: false, slope: .db12
        )
        let result = EQHeadroomCompensator.computeStaticPreampDB(
            eqLayer: [flatBand],
            roomCorrectionLayer: [],
            targetCurve: [],
            lowBandGainDB: 0
        )
        XCTAssertEqual(result, 0.0, accuracy: 0.1,
            "No boost should produce 0.0 dB preamp — got \(result)")
    }

    func testBypassedBandsAreIgnored() {
        // Bypassed bands must contribute 0 dB regardless of their gain setting.
        let bypassedBand = PresetBand(
            frequency: 1000, q: 1.0, gain: 20,
            filterType: .parametric, bypass: true, slope: .db12
        )
        let result = EQHeadroomCompensator.computeStaticPreampDB(
            eqLayer: [bypassedBand],
            roomCorrectionLayer: [],
            targetCurve: [],
            lowBandGainDB: 0
        )
        XCTAssertEqual(result, 0.0, accuracy: 0.1,
            "Bypassed band must not trigger any attenuation — got \(result)")
    }
}
