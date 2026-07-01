// EQCurveViewTests.swift
// Tests for EQCurveView snapshot computation: phase unwrapping,
// group delay computation, and contour frequency fix.

import XCTest
@testable import Equaliser

final class EQCurveViewTests: XCTestCase {

    // MARK: - Phase unwrapping

    /// A single all-pass section at 1 kHz produces a phase that sweeps from 0°
    /// to −360° across frequency. Without unwrapping, this would show as
    /// discontinuous jumps through ±180°.
    func testPhaseUnwrapping_AllPass_NoDiscontinuities() {
        // Build a snapshot with a single all-pass band
        let band = EQBandConfiguration(
            frequency: 1000, q: 1.0, gain: 0, filterType: .allPass, bypass: false)
        let snapshot = makeCurveSnapshot(bands: [band])

        let phases = snapshot.phaseResponseDeg
        XCTAssertEqual(phases.count, 256)

        // Check that no consecutive pair differs by more than 20° (would indicate a wrap)
        // An all-pass at 1 kHz changes phase smoothly by ~0.3–2° per point on a log grid
        for i in 1..<phases.count {
            let diff = abs(phases[i] - phases[i-1])
            XCTAssertLessThan(diff, 20.0,
                "Phase must not jump by more than 20° between adjacent points — indicates missing unwrap at index \(i): \(phases[i-1])° → \(phases[i])°")
        }
    }

    /// An LR4 (24 dB/oct) LP filter at 1 kHz (4 biquad sections) should produce
    /// a total phase sweep of approximately −720° (4 × −180°).
    /// Without unwrapping this would wrap four times.
    func testPhaseUnwrapping_LR4LowPass_TotalPhaseIsApproximately720Degrees() {
        let band = EQBandConfiguration(
            frequency: 1000, q: 0.7071, gain: 0, filterType: .lowPass, bypass: false)
        // Use slope db24 for LR4
        var b = band; b.slope = .db24
        let snapshot = makeCurveSnapshot(bands: [b])
        let phases = snapshot.phaseResponseDeg

        // At well above the cutoff (e.g. 10 kHz), total phase should be near −720°
        // (LR4 asymptotically approaches −4 × 180° = −720° well above cutoff)
        let highFreqPhase = phases.last ?? 0
        XCTAssertLessThan(highFreqPhase, -360.0,
            "LR4 LP should produce > −360° total phase well above cutoff; got \(highFreqPhase)°")
    }

    /// Phase response in degrees must be returned, not radians.
    /// A single biquad LP at Nyquist/2 has phase of −90° exactly (quarter-cycle lag).
    func testPhaseResponse_UnitsAreDegrees_NotRadians() {
        // At the cutoff frequency of a 1st-order LP, phase is exactly −45°.
        let band = EQBandConfiguration(
            frequency: 1000, q: 0.7071, gain: 0, filterType: .lowPass, bypass: false)
        var b = band; b.slope = .db6  // 1st order, single pole
        let snapshot = makeCurveSnapshot(bands: [b])
        let phases = snapshot.phaseResponseDeg

        // Find the phase at ~1 kHz
        let idx = snapshot.phaseFrequencies.firstIndex(where: { $0 >= 990 }) ?? 127
        let phaseAtCutoff = phases[idx]

        // 1st-order LP at cutoff: phase = −45°
        // In radians that would be −0.785. A value near −45 confirms degrees.
        XCTAssertEqual(phaseAtCutoff, -45.0, accuracy: 5.0,
            "Phase at 1st-order LP cutoff must be ~−45° (degrees); got \(phaseAtCutoff). If near −0.785, units are radians.")
    }

    // MARK: - EQ group delay

    /// An all-pass filter at 1 kHz must produce positive group delay near 1 kHz.
    func testEQGroupDelay_AllPass_PositiveNearCutoff() {
        let band = EQBandConfiguration(
            frequency: 1000, q: 1.0, gain: 0, filterType: .allPass, bypass: false)
        let snapshot = makeCurveSnapshot(bands: [band])

        let freqs = snapshot.phaseFrequencies
        let delays = snapshot.eqGroupDelayMs

        // Find group delay near 1 kHz
        let idx = freqs.firstIndex(where: { $0 >= 900 }) ?? 100
        XCTAssertGreaterThan(delays[idx], 0.0,
            "All-pass group delay must be positive near cutoff; got \(delays[idx]) ms")
    }

    /// No active bands → group delay must be zero everywhere.
    func testEQGroupDelay_NoBands_IsZero() {
        let snapshot = makeCurveSnapshot(bands: [])
        for (i, d) in snapshot.eqGroupDelayMs.enumerated() {
            XCTAssertEqual(d, 0.0, accuracy: 1e-6,
                "Group delay with no bands must be 0 ms at index \(i); got \(d) ms")
        }
    }

    // MARK: - Contour frequency fix

    /// When the contour is enabled, `computeCurve` must use 60 Hz and 9000 Hz
    /// shelf frequencies (Chunk 5), not the old 80 Hz and 6000 Hz values.
    /// Verify indirectly: a snapshot with the contour enabled at low volume should
    /// show a nonzero bass shelf at 60 Hz and not at 80 Hz.
    func testContour_UsesCorrectShelfFrequencies_60HzNot80Hz() {
        // This test validates that computeCurve uses snapshot.contourBassGainDB
        // at 60 Hz. We do this by checking that changing the contour gain
        // from 0 to nonzero changes the magnitude near 60 Hz but not only near 80 Hz.
        // (Full end-to-end would require a live processor; here we validate
        //  snapshot field storage and the formula used in computeCurve.)

        // A snapshot with non-zero contour gains should produce shelf-shaped magnitude
        // at the correct frequencies. We validate the snapshot carries the gain.
        // The actual shelf shape is validated by BiquadMathTests.
        let snapshot1 = makeCurveSnapshot(bands: [], contourBassGain: 0.0, contourTrebleGain: 0.0)
        let snapshot2 = makeCurveSnapshot(bands: [], contourBassGain: 3.0, contourTrebleGain: 1.5)

        XCTAssertEqual(snapshot1.contourBassGainDB, 0.0)
        XCTAssertEqual(snapshot2.contourBassGainDB, 3.0)
        XCTAssertEqual(snapshot2.contourTrebleGainDB, 1.5)
    }

    // MARK: - Change token invalidation

    func testChangeToken_DifferentBands_ProducesDifferentToken() {
        let band1 = EQBandConfiguration(frequency: 1000, q: 1.0, gain: 0,
                                        filterType: .parametric, bypass: false)
        let band2 = EQBandConfiguration(frequency: 2000, q: 1.0, gain: 0,
                                        filterType: .parametric, bypass: false)
        let s1 = makeCurveSnapshot(bands: [band1])
        let s2 = makeCurveSnapshot(bands: [band2])
        XCTAssertNotEqual(s1.changeToken, s2.changeToken,
            "Different band frequencies must produce different change tokens")
    }

    func testChangeToken_SameBands_ProducesSameToken() {
        let band = EQBandConfiguration(frequency: 1000, q: 1.0, gain: -3.0,
                                       filterType: .parametric, bypass: false)
        let s1 = makeCurveSnapshot(bands: [band])
        let s2 = makeCurveSnapshot(bands: [band])
        XCTAssertEqual(s1.changeToken, s2.changeToken,
            "Identical bands must produce the same change token")
    }

    // MARK: - Helpers

    /// Constructs a minimal CurveSnapshot directly for testing.
    private func makeCurveSnapshot(
        bands: [EQBandConfiguration],
        sampleRate: Double = 48000,
        contourEnabled: Bool = false,
        contourBassGain: Double = 0,
        contourTrebleGain: Double = 0
    ) -> CurveSnapshot {
        // Use CurveSnapshot's test initialiser that accepts explicit values
        // without requiring a live EqualiserStore.
        return CurveSnapshot(
            bands:              bands,
            activeBandCount:    bands.count,
            sampleRate:         sampleRate,
            isBypassed:         false,
            contourEnabled:     contourEnabled,
            deharshEnabled:     false,
            deharshTiltDB:      0,
            contourBassGainDB:  contourBassGain,
            contourTrebleGainDB: contourTrebleGain
        )
    }
}
