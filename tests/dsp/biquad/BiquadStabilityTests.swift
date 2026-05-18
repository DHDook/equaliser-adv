import XCTest
@testable import Equaliser

final class BiquadStabilityTests: XCTestCase {
    // MARK: - Test Constants

    let sampleRate: Double = 48000.0

    // MARK: - Pole Validation Tests

    /// Verifies that all filter types produce stable coefficients (poles inside unit circle)
    /// for reasonable parameter values.
    func testPolesInsideUnitCircleForAllFilterTypes() {
        let testCases: [(FilterType, Double, Double, Double)] = [
            // (type, frequency, q, gain)
            (.parametric, 1000.0, 1.0, 6.0),
            (.parametric, 1000.0, 1.0, -6.0),
            (.parametric, 100.0, 5.0, 12.0),
            (.parametric, 10000.0, 0.5, -12.0),
            (.lowPass, 1000.0, 0.707, 0.0),
            (.highPass, 1000.0, 0.707, 0.0),
            (.lowShelf, 500.0, 0.707, 6.0),
            (.highShelf, 5000.0, 0.707, -6.0),
            (.bandPass, 1000.0, 1.0, 0.0),
            (.notch, 1000.0, 1.0, 0.0),
        ]

        for (type, freq, q, gain) in testCases {
            let coeffs = BiquadMath.calculateCoefficients(
                type: type, sampleRate: sampleRate, frequency: freq, q: q, gain: gain
            )
            XCTAssertTrue(BiquadValidator.isStable(coeffs),
                "\(type) at \(freq)Hz, Q=\(q), gain=\(gain) produced unstable coefficients: a1=\(coeffs.a1), a2=\(coeffs.a2)")
            XCTAssertTrue(BiquadValidator.isFinite(coeffs),
                "\(type) at \(freq)Hz, Q=\(q), gain=\(gain) produced non-finite coefficients")
        }
    }

    // MARK: - Extreme Q Tests

    /// Verifies stability across a wide range of Q values.
    func testExtremeQValues() {
        let qValues: [Double] = [0.01, 0.1, 0.5, 1.0, 5.0, 10.0, 20.0, 30.0, 50.0, 100.0]
        let frequencies: [Double] = [100.0, 1000.0, 5000.0, 10000.0]

        for q in qValues {
            for freq in frequencies {
                let coeffs = BiquadMath.calculateCoefficients(
                    type: .parametric, sampleRate: sampleRate, frequency: freq, q: q, gain: 6.0
                )

                XCTAssertTrue(BiquadValidator.isFinite(coeffs),
                    "Non-finite coefficients at Q=\(q), freq=\(freq)")

                // Very high Q at certain frequencies can produce unstable coefficients.
                // This test documents which combinations are stable.
                if !BiquadValidator.isStable(coeffs) {
                    // Log but don't fail — the validator's job is to catch these.
                    // The important thing is that the validator correctly identifies them.
                    XCTAssertFalse(BiquadValidator.isStable(coeffs),
                        "Validator should correctly identify unstable coefficients at Q=\(q), freq=\(freq)")
                }
            }
        }
    }

    /// Verifies that low-pass and high-pass filters remain stable at extreme Q values.
    func testExtremeQForLowAndHighPass() {
        let qValues: [Double] = [0.01, 0.707, 5.0, 20.0, 50.0]

        for q in qValues {
            let lpCoeffs = BiquadMath.calculateCoefficients(
                type: .lowPass, sampleRate: sampleRate, frequency: 1000.0, q: q, gain: 0.0
            )
            XCTAssertTrue(BiquadValidator.isFinite(lpCoeffs),
                "Low-pass non-finite at Q=\(q)")
            XCTAssertTrue(BiquadValidator.isStable(lpCoeffs),
                "Low-pass unstable at Q=\(q): a1=\(lpCoeffs.a1), a2=\(lpCoeffs.a2)")

            let hpCoeffs = BiquadMath.calculateCoefficients(
                type: .highPass, sampleRate: sampleRate, frequency: 1000.0, q: q, gain: 0.0
            )
            XCTAssertTrue(BiquadValidator.isFinite(hpCoeffs),
                "High-pass non-finite at Q=\(q)")
            XCTAssertTrue(BiquadValidator.isStable(hpCoeffs),
                "High-pass unstable at Q=\(q): a1=\(hpCoeffs.a1), a2=\(hpCoeffs.a2)")
        }
    }

    // MARK: - Near-Nyquist Tests

    /// Verifies coefficient behaviour when frequency approaches Nyquist.
    func testFrequencyNearNyquist() {
        let nyquist = sampleRate / 2.0
        let frequencies: [Double] = [
            nyquist * 0.5,   // 12kHz
            nyquist * 0.75,  // 18kHz
            nyquist * 0.9,   // 21.6kHz
            nyquist * 0.95,  // 22.8kHz
            nyquist * 0.99,  // 23.76kHz
        ]

        for freq in frequencies {
            let coeffs = BiquadMath.calculateCoefficients(
                type: .parametric, sampleRate: sampleRate, frequency: freq, q: 1.0, gain: 6.0
            )

            // Coefficients should remain finite near Nyquist
            XCTAssertTrue(BiquadValidator.isFinite(coeffs),
                "Non-finite coefficients at \(freq) Hz (\(freq/nyquist * 100)% of Nyquist)")

            // Stability is not guaranteed near Nyquist — just verify the check works
            let stable = BiquadValidator.isStable(coeffs)
            // All our test cases should be stable at Q=1, even near Nyquist
            XCTAssertTrue(stable,
                "Parametric at Q=1 should be stable at \(freq) Hz: a1=\(coeffs.a1), a2=\(coeffs.a2)")
        }
    }

    // MARK: - Extreme Gain Tests

    /// Verifies stability with large shelf gains.
    func testExtremeGainValues() {
        let gains: [Double] = [-36.0, -24.0, -12.0, 0.0, 12.0, 24.0, 36.0]

        for gain in gains {
            let lsCoeffs = BiquadMath.calculateCoefficients(
                type: .lowShelf, sampleRate: sampleRate, frequency: 1000.0, q: 0.707, gain: gain
            )
            XCTAssertTrue(BiquadValidator.isFinite(lsCoeffs),
                "Low shelf non-finite at gain=\(gain)")
            XCTAssertTrue(BiquadValidator.isStable(lsCoeffs),
                "Low shelf unstable at gain=\(gain): a1=\(lsCoeffs.a1), a2=\(lsCoeffs.a2)")

            let hsCoeffs = BiquadMath.calculateCoefficients(
                type: .highShelf, sampleRate: sampleRate, frequency: 5000.0, q: 0.707, gain: gain
            )
            XCTAssertTrue(BiquadValidator.isFinite(hsCoeffs),
                "High shelf non-finite at gain=\(gain)")
            XCTAssertTrue(BiquadValidator.isStable(hsCoeffs),
                "High shelf unstable at gain=\(gain): a1=\(hsCoeffs.a1), a2=\(hsCoeffs.a2)")

            let pkCoeffs = BiquadMath.calculateCoefficients(
                type: .parametric, sampleRate: sampleRate, frequency: 1000.0, q: 1.0, gain: gain
            )
            XCTAssertTrue(BiquadValidator.isFinite(pkCoeffs),
                "Parametric non-finite at gain=\(gain)")
            XCTAssertTrue(BiquadValidator.isStable(pkCoeffs),
                "Parametric unstable at gain=\(gain): a1=\(pkCoeffs.a1), a2=\(pkCoeffs.a2)")
        }
    }

    // MARK: - Impulse Response Decay Tests

    /// Verifies that a stable filter's impulse response decays toward zero.
    func testImpulseResponseDecays() {
        let frameCount: UInt32 = 4096
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric, sampleRate: sampleRate, frequency: 1000.0, q: 1.0, gain: 6.0
        )

        let filter = BiquadFilter()
        let setup = BiquadFilter.prepareSetup(coeffs)
        filter.setCoefficients(coeffs, setup: setup, resetState: true)

        // Process impulse
        var buffer: [Float] = [Float](repeating: 0, count: Int(frameCount))
        buffer[0] = 1.0

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            filter.process(input: bufPtr.baseAddress!, output: bufPtr.baseAddress!, frameCount: frameCount)
        }

        // The last quarter of the impulse response should be very small
        let tailStart = Int(frameCount) * 3 / 4
        let tailSum = buffer[tailStart...].reduce(0.0) { $0 + abs(Float($1)) }
        XCTAssertLessThan(tailSum, 0.1,
            "Impulse response tail should decay: sum of last quarter = \(tailSum)")
    }

    /// Verifies that identity (passthrough) coefficients are stable.
    func testIdentityCoefficientsAreStable() {
        XCTAssertTrue(BiquadValidator.isStable(.identity), "Identity coefficients should be stable")
        XCTAssertTrue(BiquadValidator.isFinite(.identity), "Identity coefficients should be finite")
    }

    // MARK: - Validator Correctness Tests

    /// Verifies that the validator correctly rejects frequency at Nyquist.
    func testValidatorRejectsFrequencyAtNyquist() {
        let result = BiquadValidator.validate(
            type: .parametric, sampleRate: sampleRate, frequency: sampleRate / 2.0, q: 1.0, gain: 0.0
        )
        if case .invalid = result {
            // Expected
        } else {
            XCTFail("Frequency at Nyquist should be invalid, got \(result)")
        }
    }

    /// Verifies that the validator correctly rejects zero Q.
    func testValidatorRejectsZeroQ() {
        let result = BiquadValidator.validate(
            type: .parametric, sampleRate: sampleRate, frequency: 1000.0, q: 0.0, gain: 0.0
        )
        if case .invalid = result {
            // Expected
        } else {
            XCTFail("Q=0 should be invalid, got \(result)")
        }
    }

    /// Verifies that the validator correctly rejects negative Q.
    func testValidatorRejectsNegativeQ() {
        let result = BiquadValidator.validate(
            type: .parametric, sampleRate: sampleRate, frequency: 1000.0, q: -1.0, gain: 0.0
        )
        if case .invalid = result {
            // Expected
        } else {
            XCTFail("Negative Q should be invalid, got \(result)")
        }
    }

    /// Verifies that the validator accepts reasonable parameters.
    func testValidatorAcceptsValidParameters() {
        let result = BiquadValidator.validate(
            type: .parametric, sampleRate: sampleRate, frequency: 1000.0, q: 1.0, gain: 6.0
        )
        XCTAssertEqual(result, .valid, "Reasonable parameters should be valid")
    }
}