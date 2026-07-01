// BiquadMathLinkwitzTests.swift
// Regression tests for BiquadMath.linkwitzTransform safety guards (S-07).
// These tests verify the fix for the total-audio-silence bug caused by
// zero Q values producing NaN coefficients that poisoned the audio thread.

import XCTest
@testable import Equaliser

final class BiquadMathLinkwitzTests: XCTestCase {

    func testLinkwitzTransformRejectsZeroQ0() {
        // q0 = 0 must return identity — guards against division-by-zero in 1/(q0*2*pi*f0)
        let c = BiquadMath.linkwitzTransform(f0: 50, q0: 0.0, fp: 35, qp: 0.577, sampleRate: 48000)
        XCTAssertEqual(c.b0, 1.0, accuracy: 1e-10)
        XCTAssertEqual(c.b1, 0.0, accuracy: 1e-10)
        XCTAssertEqual(c.b2, 0.0, accuracy: 1e-10)
        XCTAssertEqual(c.a1, 0.0, accuracy: 1e-10)
        XCTAssertEqual(c.a2, 0.0, accuracy: 1e-10)
    }

    func testLinkwitzTransformRejectsZeroQp() {
        // qp = 0 must return identity — this is the exact parameter that was silencing audio
        let c = BiquadMath.linkwitzTransform(f0: 50, q0: 0.7, fp: 35, qp: 0.0, sampleRate: 48000)
        XCTAssertEqual(c.b0, 1.0, accuracy: 1e-10)
        XCTAssertEqual(c.b1, 0.0, accuracy: 1e-10)
        XCTAssertEqual(c.b2, 0.0, accuracy: 1e-10)
        XCTAssertEqual(c.a1, 0.0, accuracy: 1e-10)
        XCTAssertEqual(c.a2, 0.0, accuracy: 1e-10)
    }

    func testLinkwitzTransformRejectsBelowFloorQ() {
        // Q values below the 0.01 guard floor also return identity
        let c = BiquadMath.linkwitzTransform(f0: 50, q0: 0.005, fp: 35, qp: 0.577, sampleRate: 48000)
        XCTAssertEqual(c.b0, 1.0, accuracy: 1e-10)
        XCTAssertEqual(c.b1, 0.0, accuracy: 1e-10)
    }

    func testLinkwitzTransformRejectsNegativeFrequency() {
        let c = BiquadMath.linkwitzTransform(f0: -50, q0: 0.7, fp: 35, qp: 0.577, sampleRate: 48000)
        XCTAssertEqual(c.b0, 1.0, accuracy: 1e-10)
    }

    func testLinkwitzTransformRejectsFrequencyAboveNyquist() {
        let c = BiquadMath.linkwitzTransform(f0: 25000, q0: 0.7, fp: 20000, qp: 0.577, sampleRate: 48000)
        XCTAssertEqual(c.b0, 1.0, accuracy: 1e-10)
    }

    func testLinkwitzTransformProducesFiniteCoefficientsAcrossParameterSweep() {
        // Every valid parameter combination must produce finite (non-NaN, non-Inf) coefficients.
        let f0Values:    [Double] = [20, 35, 50, 80, 100, 150, 200]
        let q0Values:    [Double] = [0.1, 0.3, 0.5, 0.707, 1.0, 2.0, 5.0]
        let fpValues:    [Double] = [10, 20, 35, 60, 80, 120]
        let qpValues:    [Double] = [0.1, 0.3, 0.5, 0.577, 0.707, 1.0, 2.0]
        let sampleRates: [Double] = [44100, 48000, 88200, 96000, 192000]

        for sr in sampleRates {
            for f0 in f0Values {
                for q0 in q0Values {
                    for fp in fpValues where fp < f0 {
                        for qp in qpValues {
                            let c = BiquadMath.linkwitzTransform(f0: f0, q0: q0, fp: fp, qp: qp, sampleRate: sr)
                            XCTAssertTrue(c.b0.isFinite, "b0 non-finite: f0=\(f0) q0=\(q0) fp=\(fp) qp=\(qp) sr=\(sr)")
                            XCTAssertTrue(c.b1.isFinite, "b1 non-finite: f0=\(f0) q0=\(q0) fp=\(fp) qp=\(qp) sr=\(sr)")
                            XCTAssertTrue(c.b2.isFinite, "b2 non-finite: f0=\(f0) q0=\(q0) fp=\(fp) qp=\(qp) sr=\(sr)")
                            XCTAssertTrue(c.a1.isFinite, "a1 non-finite: f0=\(f0) q0=\(q0) fp=\(fp) qp=\(qp) sr=\(sr)")
                            XCTAssertTrue(c.a2.isFinite, "a2 non-finite: f0=\(f0) q0=\(q0) fp=\(fp) qp=\(qp) sr=\(sr)")
                        }
                    }
                }
            }
        }
    }

    func testLinkwitzTransformValidParamsProduceNonIdentity() {
        // A valid LT config should NOT produce identity — it actually transforms the response.
        let c = BiquadMath.linkwitzTransform(f0: 50, q0: 0.7, fp: 35, qp: 0.577, sampleRate: 48000)
        // At least one coefficient must differ from the identity filter
        let isIdentity = abs(c.b0 - 1.0) < 1e-6 && abs(c.b1) < 1e-6 && abs(c.b2) < 1e-6
        XCTAssertFalse(isIdentity, "Valid LT parameters should produce a non-identity filter")
    }
}
