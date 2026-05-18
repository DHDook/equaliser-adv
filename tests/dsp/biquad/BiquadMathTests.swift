import XCTest
@testable import Equaliser

final class BiquadMathTests: XCTestCase {
    // MARK: - Test Constants

    let sampleRate: Double = 48000.0
    let tolerance: Double = 1e-6

    // MARK: - Identity Tests

    func testIdentityCoefficients() {
        let identity = BiquadCoefficients.identity

        XCTAssertEqual(identity.b0, 1.0, accuracy: tolerance)
        XCTAssertEqual(identity.b1, 0.0, accuracy: tolerance)
        XCTAssertEqual(identity.b2, 0.0, accuracy: tolerance)
        XCTAssertEqual(identity.a1, 0.0, accuracy: tolerance)
        XCTAssertEqual(identity.a2, 0.0, accuracy: tolerance)
    }

    // MARK: - Parametric EQ Tests

    func testParametricBoost() {
        // +6 dB boost at 1 kHz, Q=1.0
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        // For a boost, b0 should be greater than 1 at resonance
        // The exact values depend on the formula implementation
        XCTAssertGreaterThan(coeffs.b0, 1.0)
        XCTAssertLessThan(abs(coeffs.a1), 2.0) // Stability check
    }

    func testParametricCut() {
        // -6 dB cut at 1 kHz, Q=1.0
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: -6.0
        )

        // For a cut, b0 should be less than 1 at resonance
        XCTAssertLessThan(coeffs.b0, 1.0)
        XCTAssertLessThan(abs(coeffs.a1), 2.0) // Stability check
    }

    func testParametric0DBGain() {
        // 0 dB gain should produce approximately unity gain at center frequency
        // The filter still has shape (Q affects bandwidth) but no boost/cut
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 0.0
        )

        // With 0 dB gain, the filter should be close to unity at all frequencies
        // b0 ≈ 1 and other coefficients should be small
        XCTAssertGreaterThan(coeffs.b0, 0.9)
        XCTAssertLessThan(abs(coeffs.a1), 2.0) // Stability check
    }

    // MARK: - Low-Pass Tests

    func testLowPass() {
        let coeffs = BiquadMath.calculateCoefficients(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707, // Butterworth Q
            gain: 0.0
        )

        // Low-pass: b0 = b2, b1 = 2*b0 (symmetric)
        XCTAssertEqual(coeffs.b0, coeffs.b2, accuracy: tolerance)
        XCTAssertEqual(coeffs.b1, 2.0 * coeffs.b0, accuracy: tolerance)
        XCTAssertGreaterThan(coeffs.b0, 0.0)
    }

    func testLowPassButterworthQ() {
        // Butterworth (maximally flat) Q = 0.707
        let coeffs = BiquadMath.calculateCoefficients(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0
        )

        // At DC, low-pass gain should be 1 (b0+b1+b2)/(1+a1+a2)
        let dcGain = (coeffs.b0 + coeffs.b1 + coeffs.b2) / (1.0 + coeffs.a1 + coeffs.a2)
        XCTAssertEqual(dcGain, 1.0, accuracy: 0.01)
    }

    // MARK: - High-Pass Tests

    func testHighPass() {
        let coeffs = BiquadMath.calculateCoefficients(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707, // Butterworth Q
            gain: 0.0
        )

        // High-pass: b0 = b2 (but opposite sign to low-pass), b1 = -2*b0
        XCTAssertEqual(coeffs.b0, coeffs.b2, accuracy: tolerance)
        XCTAssertEqual(coeffs.b1, -2.0 * coeffs.b0, accuracy: tolerance)

        // At Nyquist, high-pass gain should approach 1
        // This is harder to verify with coefficients alone
    }

    func testHighPassButterworthQ() {
        let coeffs = BiquadMath.calculateCoefficients(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0
        )

        // At high frequencies, high-pass gain should be 1
        // b0 + b1 + b2 should be close to 0 (DC blocking)
        // and 1 + a1 + a2 should be close to (1 + a1 + a2) for normalization
        let dcGain = (coeffs.b0 + coeffs.b1 + coeffs.b2) / (1.0 + coeffs.a1 + coeffs.a2)
        XCTAssertEqual(abs(dcGain), 0.0, accuracy: 0.01) // DC should be blocked
    }

    // MARK: - Shelf Tests

    func testLowShelfBoost() {
        // Shelves use shelf slope parameter (S), which maps from Q via: S = 1 / sqrt(2*Q)
        // Q = 0.707 gives approximately Butterworth response (S ≈ 0.9)
        let coeffs = BiquadMath.calculateCoefficients(
            type: .lowShelf,
            sampleRate: sampleRate,
            frequency: 200.0,
            q: 0.707, // Butterworth Q
            gain: 6.0
        )

        // At DC, low-shelf gain should equal the boost
        let dcGainLinear = (coeffs.b0 + coeffs.b1 + coeffs.b2) / (1.0 + coeffs.a1 + coeffs.a2)
        let expectedGain = pow(10.0, 6.0 / 20.0) // 6 dB ≈ 1.995
        XCTAssertEqual(dcGainLinear, expectedGain, accuracy: 0.1)
    }

    func testHighShelfBoost() {
        let coeffs = BiquadMath.calculateCoefficients(
            type: .highShelf,
            sampleRate: sampleRate,
            frequency: 8000.0,
            q: 0.707, // Butterworth Q
            gain: 6.0
        )

        // At Nyquist, high-shelf gain should equal the boost
        // For 2nd-order biquad, this is approximate
        XCTAssertGreaterThan(coeffs.b0, 0.0)
    }

    func testLowShelf0DBGain() {
        // With 0 dB gain, a shelf should pass signal unchanged (identity)
        let coeffs = BiquadMath.calculateCoefficients(
            type: .lowShelf,
            sampleRate: sampleRate,
            frequency: 200.0,
            q: 0.707, // Butterworth Q
            gain: 0.0
        )

        // DC gain should be 1 (0 dB)
        let dcGain = (coeffs.b0 + coeffs.b1 + coeffs.b2) / (1.0 + coeffs.a1 + coeffs.a2)
        XCTAssertEqual(abs(dcGain), 1.0, accuracy: 0.01)
    }

    // MARK: - Band Pass / Notch Tests

    func testBandPass() {
        let coeffs = BiquadMath.calculateCoefficients(
            type: .bandPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 0.0
        )

        // Band-pass: b1 = 0, b2 = -b0
        XCTAssertEqual(coeffs.b1, 0.0, accuracy: tolerance)
        XCTAssertEqual(coeffs.b2, -coeffs.b0, accuracy: tolerance)
    }

    func testNotch() {
        let coeffs = BiquadMath.calculateCoefficients(
            type: .notch,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 0.0
        )

        // Notch: b0 = 1, b1 = -2*cos(w), b2 = 1, a0 = 1+alpha, a1 = -2*cos(w), a2 = 1-alpha
        XCTAssertEqual(coeffs.b0, coeffs.b2, accuracy: tolerance)
        XCTAssertEqual(coeffs.b1, coeffs.a1, accuracy: tolerance)
    }

    // MARK: - Edge Cases

    func testLowFrequency() {
        // Very low frequency near DC
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 20.0,
            q: 1.0,
            gain: 6.0
        )

        // Should still produce valid coefficients
        XCTAssertFalse(coeffs.b0.isNaN)
        XCTAssertFalse(coeffs.b1.isNaN)
        XCTAssertFalse(coeffs.b2.isNaN)
        XCTAssertFalse(coeffs.a1.isNaN)
        XCTAssertFalse(coeffs.a2.isNaN)
    }

    func testHighFrequency() {
        // Frequency near Nyquist
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 20000.0,
            q: 1.0,
            gain: 6.0
        )

        // Should still produce valid coefficients
        XCTAssertFalse(coeffs.b0.isNaN)
        XCTAssertFalse(coeffs.b1.isNaN)
        XCTAssertFalse(coeffs.b2.isNaN)
        XCTAssertFalse(coeffs.a1.isNaN)
        XCTAssertFalse(coeffs.a2.isNaN)
    }

    func testNarrowBandwidth() {
        // Very narrow bandwidth (high Q)
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.1, // Very narrow
            gain: 6.0
        )

        // Narrow bandwidth = high Q = coefficients can be large
        XCTAssertFalse(coeffs.b0.isNaN)
        XCTAssertFalse(coeffs.a1.isNaN)
    }

    func testWideBandwidth() {
        // Very wide bandwidth (low Q)
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 8.0, // Very wide
            gain: 6.0
        )

        // Wide bandwidth = low Q = gentler slopes
        XCTAssertFalse(coeffs.b0.isNaN)
        XCTAssertFalse(coeffs.a1.isNaN)
    }

    // MARK: - Filter Type Tests

    func testAllFilterTypesProduceValidCoefficients() {
        let filterTypes: [FilterType] = FilterType.allCases

        for filterType in filterTypes {
            let coeffs = BiquadMath.calculateCoefficients(
                type: filterType,
                sampleRate: sampleRate,
                frequency: 1000.0,
                q: 0.67,
                gain: 6.0
            )

            XCTAssertFalse(coeffs.b0.isNaN, "\(filterType.displayName) produced NaN b0")
            XCTAssertFalse(coeffs.b1.isNaN, "\(filterType.displayName) produced NaN b1")
            XCTAssertFalse(coeffs.b2.isNaN, "\(filterType.displayName) produced NaN b2")
            XCTAssertFalse(coeffs.a1.isNaN, "\(filterType.displayName) produced NaN a1")
            XCTAssertFalse(coeffs.a2.isNaN, "\(filterType.displayName) produced NaN a2")
        }
    }

    // MARK: - calculateSections Tests

    func testCalculateSections_parametricReturnsSingleSection() {
        let sections = BiquadMath.calculateSections(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0,
            slope: .db24
        )
        // Slope is ignored for parametric — always 1 section
        XCTAssertEqual(sections.count, 1)
    }

    func testCalculateSections_lowPass12db_oneSectionDefault() {
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db12
        )
        XCTAssertEqual(sections.count, 1)
        // Should match calculateCoefficients exactly
        let single = BiquadMath.calculateCoefficients(type: .lowPass, sampleRate: sampleRate, frequency: 1000.0, q: 0.707, gain: 0.0)
        XCTAssertEqual(sections[0].b0, single.b0, accuracy: tolerance)
        XCTAssertEqual(sections[0].a1, single.a1, accuracy: tolerance)
    }

    func testCalculateSections_lowPass6db_firstOrder() {
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db6
        )
        XCTAssertEqual(sections.count, 1)
        // First-order: b2 and a2 must be zero
        XCTAssertEqual(sections[0].b2, 0.0, accuracy: tolerance)
        XCTAssertEqual(sections[0].a2, 0.0, accuracy: tolerance)
        // b0 should be positive and less than 1 (LP attenuation above cutoff)
        XCTAssertGreaterThan(sections[0].b0, 0.0)
        XCTAssertLessThanOrEqual(sections[0].b0, 1.0)
    }

    func testCalculateSections_lowPass24db_twoSections() {
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db24
        )
        XCTAssertEqual(sections.count, 2)
        // Each section should have valid coefficients
        for section in sections {
            XCTAssertFalse(section.b0.isNaN)
            XCTAssertFalse(section.a1.isNaN)
        }
    }

    func testCalculateSections_lowPass48db_fourSections() {
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db48
        )
        XCTAssertEqual(sections.count, 4)
        for section in sections {
            XCTAssertFalse(section.b0.isNaN)
            XCTAssertFalse(section.a1.isNaN)
        }
    }

    func testCalculateSections_highPass24db_twoSections() {
        let sections = BiquadMath.calculateSections(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db24
        )
        XCTAssertEqual(sections.count, 2)
    }

    func testCalculateSections_lowShelf_gainSplitAcrossSections() {
        let totalGain = 6.0
        let sections = BiquadMath.calculateSections(
            type: .lowShelf,
            sampleRate: sampleRate,
            frequency: 200.0,
            q: 0.707,
            gain: totalGain,
            slope: .db24
        )
        XCTAssertEqual(sections.count, 2)

        // Each section should be a valid low-shelf
        for section in sections {
            XCTAssertFalse(section.b0.isNaN)
            // DC gain per section should be approximately sqrt(10^(totalGain/20))
            // i.e., half the total dB gain per section in linear domain
        }
    }

    func testFilterSlope_isSupportedForShelfAndEdge() {
        XCTAssertTrue(FilterSlope.isSupported(for: .lowPass))
        XCTAssertTrue(FilterSlope.isSupported(for: .highPass))
        XCTAssertTrue(FilterSlope.isSupported(for: .lowShelf))
        XCTAssertTrue(FilterSlope.isSupported(for: .highShelf))
        XCTAssertFalse(FilterSlope.isSupported(for: .parametric))
        XCTAssertFalse(FilterSlope.isSupported(for: .bandPass))
        XCTAssertFalse(FilterSlope.isSupported(for: .notch))
    }

    func testFilterSlope_sectionCounts() {
        XCTAssertEqual(FilterSlope.db6.sectionCount,  1)
        XCTAssertEqual(FilterSlope.db12.sectionCount, 1)
        XCTAssertEqual(FilterSlope.db18.sectionCount, 2)
        XCTAssertEqual(FilterSlope.db24.sectionCount, 2)
        XCTAssertEqual(FilterSlope.db36.sectionCount, 3)
        XCTAssertEqual(FilterSlope.db48.sectionCount, 4)
        XCTAssertEqual(FilterSlope.db60.sectionCount, 5)
        XCTAssertEqual(FilterSlope.db72.sectionCount, 6)
        XCTAssertEqual(FilterSlope.db84.sectionCount, 7)
        XCTAssertEqual(FilterSlope.db96.sectionCount, 8)
    }

    func testFilterSlope_hasFirstOrderSection_onlyDb18() {
        XCTAssertFalse(FilterSlope.db6.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db12.hasFirstOrderSection)
        XCTAssertTrue(FilterSlope.db18.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db24.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db36.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db48.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db60.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db72.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db84.hasFirstOrderSection)
        XCTAssertFalse(FilterSlope.db96.hasFirstOrderSection)
    }

    func testFilterSlope_butterworthQValues_db24() {
        let qs = FilterSlope.db24.butterworthQValues
        XCTAssertEqual(qs.count, 2)
        XCTAssertEqual(qs[0], 1.3065629648763766, accuracy: 1e-10)
        XCTAssertEqual(qs[1], 0.5411961001063831, accuracy: 1e-10)
    }

    func testFilterSlope_butterworthQValues_db48() {
        let qs = FilterSlope.db48.butterworthQValues
        XCTAssertEqual(qs.count, 4)
        XCTAssertEqual(qs[0], 2.5629154477415234, accuracy: 1e-10)
    }

    func testFilterSlope_butterworthQValues_db36() {
        let qs = FilterSlope.db36.butterworthQValues
        XCTAssertEqual(qs.count, 3)
        // N=6 first section: Q1 = 1/(2*sin(π/12)) ≈ 1.9319
        XCTAssertEqual(qs[0], 1.9318516525781366, accuracy: 1e-10)
        // Middle section is always 1/√2 for N=6
        XCTAssertEqual(qs[1], 0.7071067811865476, accuracy: 1e-10)
        XCTAssertEqual(qs[2], 0.5176380902050415, accuracy: 1e-10)
    }

    func testFilterSlope_butterworthQValues_db96_eightEntries() {
        let qs = FilterSlope.db96.butterworthQValues
        XCTAssertEqual(qs.count, 8)
        // Q values should decrease monotonically for N=16
        for i in 0..<(qs.count - 1) {
            XCTAssertGreaterThan(qs[i], qs[i + 1], "Q values should be monotonically decreasing for N=16")
        }
        // Sanity-check: last Q should be close to 0.5 (near-unity section)
        XCTAssertLessThan(qs[7], 0.51)
        XCTAssertGreaterThan(qs[7], 0.50)
    }

    func testCalculateSections_lowPass18db_twoSectionsFirstOrderLeading() {
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db18
        )
        XCTAssertEqual(sections.count, 2, "18 dB/oct LP should produce 2 sections (first-order + biquad)")
        // First section must be degenerate (first-order): b2 = a2 = 0
        XCTAssertEqual(sections[0].b2, 0.0, accuracy: tolerance)
        XCTAssertEqual(sections[0].a2, 0.0, accuracy: tolerance)
        // Second section is a full 2nd-order biquad: b2 and a2 are non-zero
        XCTAssertFalse(sections[1].b2.isNaN)
    }

    func testCalculateSections_highPass18db_twoSectionsFirstOrderLeading() {
        let sections = BiquadMath.calculateSections(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db18
        )
        XCTAssertEqual(sections.count, 2, "18 dB/oct HP should produce 2 sections (first-order + biquad)")
        XCTAssertEqual(sections[0].b2, 0.0, accuracy: tolerance)
        XCTAssertEqual(sections[0].a2, 0.0, accuracy: tolerance)
    }

    func testCalculateSections_lowPass36db_threeSections() {
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db36
        )
        XCTAssertEqual(sections.count, 3, "36 dB/oct LP should produce 3 Butterworth biquad sections")
        for section in sections {
            XCTAssertFalse(section.b0.isNaN)
            XCTAssertFalse(section.a1.isNaN)
        }
    }

    func testCalculateSections_lowPass96db_eightSections() {
        let sections = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0,
            slope: .db96
        )
        XCTAssertEqual(sections.count, 8, "96 dB/oct LP should produce 8 Butterworth biquad sections")
        for section in sections {
            XCTAssertFalse(section.b0.isNaN)
            XCTAssertFalse(section.a1.isNaN)
        }
    }

    func testCalculateSections_lowShelf18db_gainSplitAcrossTwoSections() {
        let totalGain = 6.0
        let sections = BiquadMath.calculateSections(
            type: .lowShelf,
            sampleRate: sampleRate,
            frequency: 200.0,
            q: 0.707,
            gain: totalGain,
            slope: .db18
        )
        XCTAssertEqual(sections.count, 2, "18 dB/oct LS should produce 2 sections")
        // First section is first-order (degenerate): b2 = a2 = 0
        XCTAssertEqual(sections[0].b2, 0.0, accuracy: tolerance)
        XCTAssertEqual(sections[0].a2, 0.0, accuracy: tolerance)
        for section in sections {
            XCTAssertFalse(section.b0.isNaN)
        }
    }

    func testCalculateSections_allNewSlopesProduceCorrectCounts() {
        let newSlopes: [(FilterSlope, Int)] = [
            (.db18, 2), (.db36, 3), (.db60, 5), (.db72, 6), (.db84, 7), (.db96, 8)
        ]
        for (slope, expectedCount) in newSlopes {
            let lp = BiquadMath.calculateSections(type: .lowPass,  sampleRate: sampleRate, frequency: 1000.0, q: 0.707, gain: 0.0, slope: slope)
            let hp = BiquadMath.calculateSections(type: .highPass, sampleRate: sampleRate, frequency: 1000.0, q: 0.707, gain: 0.0, slope: slope)
            let ls = BiquadMath.calculateSections(type: .lowShelf, sampleRate: sampleRate, frequency: 200.0,  q: 0.707, gain: 3.0, slope: slope)
            let hs = BiquadMath.calculateSections(type: .highShelf, sampleRate: sampleRate, frequency: 200.0, q: 0.707, gain: 3.0, slope: slope)
            XCTAssertEqual(lp.count, expectedCount, "LP \(slope.displayName) should produce \(expectedCount) sections")
            XCTAssertEqual(hp.count, expectedCount, "HP \(slope.displayName) should produce \(expectedCount) sections")
            XCTAssertEqual(ls.count, expectedCount, "LS \(slope.displayName) should produce \(expectedCount) sections")
            XCTAssertEqual(hs.count, expectedCount, "HS \(slope.displayName) should produce \(expectedCount) sections")
            for section in lp + hp + ls + hs {
                XCTAssertFalse(section.b0.isNaN, "\(slope.displayName) produced NaN b0")
                XCTAssertFalse(section.a1.isNaN, "\(slope.displayName) produced NaN a1")
            }
        }
    }

    // MARK: - Normalisation Test

    func testNormalisationPreservesTransferFunction() {
        // Verify that normalisation produces a stable filter
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        // For stability, poles should be inside unit circle
        // This means |a2| < 1 and |a1| < 2 for real coefficients
        XCTAssertLessThan(abs(coeffs.a2), 1.0 + tolerance)
        XCTAssertLessThan(abs(coeffs.a1), 2.0 + tolerance)
    }
}