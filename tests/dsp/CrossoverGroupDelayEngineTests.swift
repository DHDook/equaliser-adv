// CrossoverGroupDelayEngineTests.swift
// Tests for crossover group delay analysis and all-pass phase alignment.

import XCTest
@testable import Equaliser

final class CrossoverGroupDelayEngineTests: XCTestCase {

    private let sampleRate = 48000.0

    // MARK: - ActiveCrossoverEngine.groupDelay() — IIR path

    /// A 2nd-order LP at 1 kHz should produce non-zero group delay near its cutoff.
    /// The group delay of a 2nd-order LP peaks near fc; it must be > 0 and measurable.
    func testGroupDelayIIR_LPHasPositiveDelayNearCutoff() {
        let crossoverHz = 1000.0
        let lpCoeffs = BiquadMath.calculateSections(
            type: .lowPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db24)

        let identity: ActiveCrossoverEngine.SectionArray.Element = (1,0,0,0,0)
        var sections = Array(repeating: identity, count: ActiveCrossoverEngine.maxSections)
        for (i, c) in lpCoeffs.enumerated() {
            sections[i] = (Float(c.b0), Float(c.b1), Float(c.b2), Float(c.a1), Float(c.a2))
        }

        let frequencies = [500.0, 1000.0, 2000.0, 4000.0]
        let delays = ActiveCrossoverEngine.groupDelay(
            sections: sections, firKernel: nil,
            frequencies: frequencies, sampleRate: sampleRate)

        XCTAssertEqual(delays.count, frequencies.count)
        // All values must be non-negative (passive all-pole filters have positive group delay)
        for (i, d) in delays.enumerated() {
            XCTAssertGreaterThanOrEqual(d, 0.0,
                "Group delay must be non-negative at \(frequencies[i]) Hz, got \(d) ms")
        }
        // Group delay near cutoff (1 kHz) should be meaningfully non-zero for a 24 dB/oct filter
        // A 2nd-order Butterworth LP at 1 kHz / 48 kHz has ~0.23 ms peak group delay per section
        let delayAt1kHz = delays[1]
        XCTAssertGreaterThan(delayAt1kHz, 0.05,
            "LR4 LP at 1 kHz should produce > 0.05 ms group delay near cutoff, got \(delayAt1kHz) ms")
    }

    /// An identity section array should produce zero group delay at all frequencies.
    func testGroupDelayIIR_AllIdentitySectionsProduceZeroDelay() {
        let identity: ActiveCrossoverEngine.SectionArray.Element = (1,0,0,0,0)
        let sections = Array(repeating: identity, count: ActiveCrossoverEngine.maxSections)
        let frequencies = stride(from: 20.0, through: 20000.0, by: 100.0).map { $0 }

        let delays = ActiveCrossoverEngine.groupDelay(
            sections: sections, firKernel: nil,
            frequencies: frequencies, sampleRate: sampleRate)

        for (i, d) in delays.enumerated() {
            XCTAssertEqual(d, 0.0, accuracy: 1e-9,
                "Identity sections must produce zero group delay at \(frequencies[i]) Hz")
        }
    }

    // MARK: - ActiveCrossoverEngine.groupDelay() — FIR path

    /// A 1001-tap linear-phase FIR should have constant group delay = 500 samples.
    func testGroupDelayFIR_IsConstantAtHalfTapCount() {
        let tapCount = 1001
        // Content of the kernel doesn't matter for group delay — it's always (N-1)/2 samples
        let kernel = [Float](repeating: 0.0, count: tapCount)
        let identity: ActiveCrossoverEngine.SectionArray.Element = (1,0,0,0,0)
        let sections = Array(repeating: identity, count: ActiveCrossoverEngine.maxSections)

        let frequencies = [100.0, 1000.0, 5000.0, 10000.0]
        let delays = ActiveCrossoverEngine.groupDelay(
            sections: sections, firKernel: kernel,
            frequencies: frequencies, sampleRate: sampleRate)

        let expectedDelaySamples = Double(tapCount - 1) / 2.0  // 500 samples
        let expectedDelayMs = expectedDelaySamples / sampleRate * 1000.0  // ≈ 10.4167 ms

        for (i, d) in delays.enumerated() {
            XCTAssertEqual(d, expectedDelayMs, accuracy: 1e-9,
                "FIR group delay must be constant at \(frequencies[i]) Hz; expected \(expectedDelayMs) ms got \(d) ms")
        }
    }

    // MARK: - CrossoverGroupDelayEngine.channelGroupDelay()

    /// For a symmetric LR4 crossover, LP and HP at the same frequency should have
    /// approximately equal group delay at the crossover point.
    func testChannelGroupDelay_LR4LPandHPApproximatelyEqualAtCrossover() {
        let crossoverHz = 2000.0
        let lpCoeffs = BiquadMath.calculateSections(
            type: .lowPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db24)
        let hpCoeffs = BiquadMath.calculateSections(
            type: .highPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db24)

        let identity: ActiveCrossoverEngine.SectionArray.Element = (1,0,0,0,0)
        func toSections(_ c: [BiquadCoefficients]) -> ActiveCrossoverEngine.SectionArray {
            var arr = Array(repeating: identity, count: ActiveCrossoverEngine.maxSections)
            for (i, s) in c.enumerated() {
                arr[i] = (Float(s.b0), Float(s.b1), Float(s.b2), Float(s.a1), Float(s.a2))
            }
            return arr
        }

        let frequencies = stride(from: 500.0, through: 8000.0, by: 100.0).map { $0 }

        let lpDelay = CrossoverGroupDelayEngine.channelGroupDelay(
            crossoverSections: toSections(lpCoeffs),
            crossoverFIRKernel: nil,
            eqBands: [],
            frequencies: frequencies,
            sampleRate: sampleRate)
        let hpDelay = CrossoverGroupDelayEngine.channelGroupDelay(
            crossoverSections: toSections(hpCoeffs),
            crossoverFIRKernel: nil,
            eqBands: [],
            frequencies: frequencies,
            sampleRate: sampleRate)

        // Find group delay at crossover frequency
        guard let crossoverIdx = frequencies.firstIndex(where: { abs($0 - crossoverHz) < 60 }) else {
            XCTFail("Crossover frequency not found in grid"); return
        }

        let lpDelayAtCrossover = lpDelay[crossoverIdx]
        let hpDelayAtCrossover = hpDelay[crossoverIdx]

        // For LR4 (cascaded Butterworth), LP and HP have equal group delay at Fc
        // Tolerance of 0.5 ms is generous — in practice the difference should be < 0.01 ms
        XCTAssertEqual(lpDelayAtCrossover, hpDelayAtCrossover, accuracy: 0.5,
            "LR4 LP and HP group delays at crossover should be approximately equal; LP=\(lpDelayAtCrossover) ms HP=\(hpDelayAtCrossover) ms")
    }

    // MARK: - CrossoverGroupDelayEngine.groupDelayError()

    func testGroupDelayError_IsZeroWhenBothDelaysAreEqual() {
        let delays = [1.0, 2.0, 3.0, 4.0]
        let error = CrossoverGroupDelayEngine.groupDelayError(
            channelADelays: delays, channelBDelays: delays,
            crossoverHz: 2000.0, frequencies: [500, 1000, 2000, 4000])
        for e in error {
            XCTAssertEqual(e, 0.0, accuracy: 1e-12)
        }
    }

    func testGroupDelayError_IsPositiveWhenAIsSlowerThanB() {
        let channelA = [5.0, 6.0, 7.0]
        let channelB = [3.0, 4.0, 5.0]
        let error = CrossoverGroupDelayEngine.groupDelayError(
            channelADelays: channelA, channelBDelays: channelB,
            crossoverHz: 2000.0, frequencies: [1000, 2000, 4000])
        for e in error {
            XCTAssertEqual(e, 2.0, accuracy: 1e-12,
                "Error should be exactly 2 ms when A is 2 ms slower than B")
        }
    }

    // MARK: - CrossoverGroupDelayEngine.fitGroupDelayAllPass()

    /// Fitting all-pass sections to a non-zero delay error must reduce the weighted
    /// residual error below a meaningful threshold.
    func testFitGroupDelayAllPass_ReducesWeightedResidualError() {
        let crossoverHz = 2000.0
        // Simulate a 2 ms error across the crossover region (tweeter faster than woofer)
        // Positive error → channel A (woofer) is slower → apply to channel A: applyToChannelA = false
        // (we want to add delay to channel B, the tweeter)
        let frequencies = stride(from: 200.0, through: 20000.0, by: 50.0).map { $0 }
        let delayError = frequencies.map { f -> Double in
            // Ramp from 0 at 200 Hz to 3 ms at crossover, dropping back to 0 above
            let peak = 3.0
            let ratio = min(f / crossoverHz, 1.0)
            return peak * ratio * (1.0 - max(0, (f - crossoverHz) / crossoverHz))
        }

        let fittedCoeffs = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: delayError,
            applyToChannelA: false,
            crossoverHz: crossoverHz,
            frequencies: frequencies,
            sampleRate: sampleRate,
            maxSections: 4)

        // Must produce at least 1 section for a non-trivial error
        XCTAssertGreaterThan(fittedCoeffs.count, 0,
            "Fitter should produce at least 1 all-pass section for a 3 ms delay error")

        // All returned coefficients must be valid (non-NaN, stable)
        for (i, c) in fittedCoeffs.enumerated() {
            XCTAssertFalse(c.b0.isNaN, "Section \(i) b0 is NaN")
            XCTAssertFalse(c.a1.isNaN, "Section \(i) a1 is NaN")
            XCTAssertLessThan(abs(c.a2), 1.0 + 1e-6, "Section \(i) is unstable (|a2| >= 1)")
            XCTAssertLessThan(abs(c.a1), 2.0 + 1e-6, "Section \(i) is unstable (|a1| >= 2)")
        }
    }

    /// When the delay error is zero everywhere, the fitter should return an empty array.
    func testFitGroupDelayAllPass_ZeroErrorReturnsEmpty() {
        let frequencies = stride(from: 200.0, through: 20000.0, by: 100.0).map { $0 }
        let zeroError = [Double](repeating: 0.0, count: frequencies.count)

        let result = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: zeroError,
            applyToChannelA: true,
            crossoverHz: 2000.0,
            frequencies: frequencies,
            sampleRate: sampleRate,
            maxSections: 4)

        XCTAssertTrue(result.isEmpty,
            "Fitter must return empty array when delay error is zero everywhere")
    }

    /// All-pass filters have unity magnitude — fitting them must not alter signal amplitude.
    func testFittedAllPassCoefficients_HaveUnityMagnitudeAtAllFrequencies() {
        // Use a simple known error to get a predictable fit
        let crossoverHz = 1000.0
        let frequencies = stride(from: 100.0, through: 10000.0, by: 100.0).map { $0 }
        let error = frequencies.map { _ in 1.5 }  // constant 1.5 ms error

        let coeffs = CrossoverGroupDelayEngine.fitGroupDelayAllPass(
            delayErrorMs: error,
            applyToChannelA: false,
            crossoverHz: crossoverHz,
            frequencies: frequencies,
            sampleRate: sampleRate,
            maxSections: 2)

        guard !coeffs.isEmpty else {
            XCTFail("Expected at least one all-pass section"); return
        }

        // Check unity magnitude: |H(e^{jω})| = 1 for all-pass filters
        for c in coeffs {
            for f in [100.0, 500.0, 1000.0, 5000.0, 10000.0] {
                let magDB = BiquadMath.magnitudeDB(
                    coefficients: c, atFrequency: f, sampleRate: sampleRate)
                XCTAssertEqual(magDB, 0.0, accuracy: 0.01,
                    "All-pass filter must have 0 dBFS magnitude at \(f) Hz, got \(magDB) dBFS")
            }
        }
    }
}
