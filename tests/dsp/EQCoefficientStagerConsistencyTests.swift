// EQCoefficientStagerConsistencyTests.swift
// Regression test for R-06: reapplyAllCoefficients (full preset reload) and
// stageBandCoefficients (incremental live edit) must compute Linkwitz-Transform
// and constant-Q band coefficients identically. Before the R-06 fix,
// reapplyAllCoefficients bypassed the special-case math entirely by calling
// BiquadMath.calculateSections directly, so a saved preset with these filter
// types would sound different after a full reload than after a live edit.
//
// This test does not require a live RenderPipeline — both stager code paths
// converge on the same computeSections(for:warpedFrequency:designRate:) helper,
// which is exercised directly here.

import XCTest
@testable import Equaliser

final class EQCoefficientStagerConsistencyTests: XCTestCase {

    private let sampleRate: Double = 48000.0

    func testComputeSectionsMatchesDirectLinkwitzTransformCall() {
        // A Linkwitz-Transform band with an explicit target frequency.
        var band = EQBandConfiguration.parametric(frequency: 50, q: 0.7)
        band.filterType = .linkwitzTransform
        band.gain = 0.577                 // Qp
        band.linkwitzTargetHz = 32.0      // fp — deliberately NOT the f0*0.7 default (35.0),
                                           // so this test fails if linkwitzTargetHz is ever ignored again.

        let eqConfig = EQConfiguration()
        let stager = EQCoefficientStager(eqConfiguration: eqConfig)

        let sections = stager.computeSections(for: band, warpedFrequency: 50.0, designRate: sampleRate)

        // Expected result: calling BiquadMath.linkwitzTransform directly with the same
        // f0/q0/fp/qp/sampleRate must match exactly.
        let expected = BiquadMath.linkwitzTransform(
            f0: 50.0, q0: 0.7, fp: 32.0, qp: 0.577, sampleRate: sampleRate
        )

        XCTAssertEqual(sections.count, 1, "Linkwitz-Transform must produce exactly one biquad section")
        XCTAssertEqual(sections[0].b0, expected.b0, accuracy: 1e-9)
        XCTAssertEqual(sections[0].b1, expected.b1, accuracy: 1e-9)
        XCTAssertEqual(sections[0].b2, expected.b2, accuracy: 1e-9)
        XCTAssertEqual(sections[0].a1, expected.a1, accuracy: 1e-9)
        XCTAssertEqual(sections[0].a2, expected.a2, accuracy: 1e-9)
    }

    func testComputeSectionsUsesLinkwitzTargetHzNotHardcodedFallback() {
        // This is the direct regression guard: if a future change accidentally routes
        // Linkwitz-Transform bands through the generic BiquadMath.calculateSections path
        // again (which uses a hardcoded fp = f0*0.7 fallback and ignores linkwitzTargetHz
        // entirely), this test fails because the two results will diverge.
        var band = EQBandConfiguration.parametric(frequency: 50, q: 0.7)
        band.filterType = .linkwitzTransform
        band.gain = 0.577
        band.linkwitzTargetHz = 32.0   // explicit fp, far from the 35.0 default fallback

        let eqConfig = EQConfiguration()
        let stager = EQCoefficientStager(eqConfiguration: eqConfig)

        let actual = stager.computeSections(for: band, warpedFrequency: 50.0, designRate: sampleRate)

        // What the OLD buggy path (generic calculateSections, ignoring linkwitzTargetHz) would produce:
        let oldPathResult = BiquadMath.calculateSections(
            type: .linkwitzTransform, sampleRate: sampleRate,
            frequency: 50.0, q: 0.7, gain: 0.577, slope: band.slope
        )

        XCTAssertFalse(
            abs(actual[0].b0 - oldPathResult[0].b0) < 1e-9 &&
            abs(actual[0].b1 - oldPathResult[0].b1) < 1e-9 &&
            abs(actual[0].b2 - oldPathResult[0].b2) < 1e-9,
            "computeSections must use linkwitzTargetHz (32.0 Hz), not the generic path's hardcoded f0*0.7 fallback (35.0 Hz) — these must differ"
        )
    }

    func testComputeSectionsMatchesDirectConstantQCall() {
        var band = EQBandConfiguration.parametric(frequency: 1000, q: 2.0)
        band.filterType = .parametric
        band.gain = 6.0
        band.constantQ = true

        let eqConfig = EQConfiguration()
        let stager = EQCoefficientStager(eqConfiguration: eqConfig)

        let sections = stager.computeSections(for: band, warpedFrequency: 1000.0, designRate: sampleRate)

        let expected = BiquadMath.peakingEQConstantQ(
            sampleRate: sampleRate, frequency: 1000.0, q: 2.0, gain: 6.0
        )

        XCTAssertEqual(sections.count, 1, "Constant-Q parametric must produce exactly one biquad section")
        XCTAssertEqual(sections[0].b0, expected.b0, accuracy: 1e-9)
        XCTAssertEqual(sections[0].b1, expected.b1, accuracy: 1e-9)
        XCTAssertEqual(sections[0].b2, expected.b2, accuracy: 1e-9)
        XCTAssertEqual(sections[0].a1, expected.a1, accuracy: 1e-9)
        XCTAssertEqual(sections[0].a2, expected.a2, accuracy: 1e-9)
    }

    func testComputeSectionsDiffersBetweenConstantQAndProportionalQ() {
        // Sanity check: constantQ = true must actually change the result relative to
        // the standard RBJ proportional-Q path — otherwise the branch could silently
        // be a no-op and this whole test file would give false confidence.
        var constantQBand = EQBandConfiguration.parametric(frequency: 1000, q: 2.0)
        constantQBand.gain = 6.0
        constantQBand.constantQ = true

        var proportionalQBand = constantQBand
        proportionalQBand.constantQ = false

        let eqConfig = EQConfiguration()
        let stager = EQCoefficientStager(eqConfiguration: eqConfig)

        let constantQResult = stager.computeSections(for: constantQBand, warpedFrequency: 1000.0, designRate: sampleRate)
        let proportionalQResult = stager.computeSections(for: proportionalQBand, warpedFrequency: 1000.0, designRate: sampleRate)

        XCTAssertFalse(
            abs(constantQResult[0].b1 - proportionalQResult[0].b1) < 1e-9,
            "constantQ=true must produce different coefficients than constantQ=false at the same gain/Q"
        )
    }

    func testComputeSectionsIsTheOnlyCoefficientPathUsedByBothStagingMethods() {
        // Documents the architectural invariant this whole test file protects:
        // stageBandCoefficients and reapplyAllCoefficients must never diverge because
        // both call this same computeSections helper. This test doesn't re-verify
        // that source-code fact (that would require parsing the file), but it does
        // confirm computeSections is deterministic and pure — calling it twice with
        // identical arguments must always produce bit-identical results, which is a
        // prerequisite for the two call sites staying in sync.
        var band = EQBandConfiguration.parametric(frequency: 80, q: 0.9)
        band.filterType = .linkwitzTransform
        band.gain = 0.65
        band.linkwitzTargetHz = 45.0

        let eqConfig = EQConfiguration()
        let stager = EQCoefficientStager(eqConfiguration: eqConfig)

        let result1 = stager.computeSections(for: band, warpedFrequency: 80.0, designRate: sampleRate)
        let result2 = stager.computeSections(for: band, warpedFrequency: 80.0, designRate: sampleRate)

        XCTAssertEqual(result1.count, result2.count)
        for i in 0..<result1.count {
            XCTAssertEqual(result1[i].b0, result2[i].b0, accuracy: 1e-12)
            XCTAssertEqual(result1[i].b1, result2[i].b1, accuracy: 1e-12)
            XCTAssertEqual(result1[i].b2, result2[i].b2, accuracy: 1e-12)
            XCTAssertEqual(result1[i].a1, result2[i].a1, accuracy: 1e-12)
            XCTAssertEqual(result1[i].a2, result2[i].a2, accuracy: 1e-12)
        }
    }
}
