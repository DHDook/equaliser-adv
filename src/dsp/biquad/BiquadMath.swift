import Foundation

/// Crossover filter type for bass management.
enum CrossoverType: Int, Codable, Equatable, Sendable {
    case linkwitzRiley = 0
    case butterworth = 1
    case bessel = 2
}

/// Pure coefficient calculation using RBJ Audio EQ Cookbook formulas.
///
/// All functions are pure — no state, no side effects, no allocations.
/// Calculations use Double precision for numerical stability (narrow filters
/// at low frequencies need this precision). Results can be converted to Float
/// when building vDSP setups.
///
/// Q (quality factor) is used uniformly for all filter types. For parametric
/// EQs, Q relates to bandwidth by: Q = 1 / (2 * sinh(ln(2)/2 * BW)).
/// Use `BandwidthConverter.bandwidthToQ()` to convert bandwidth to Q for display.
///
/// Reference: https://webaudio.github.io/Audio-EQ-Cookbook/Audio-EQ-Cookbook.txt
enum BiquadMath {

    /// Sample rates above this threshold use reference-rate coefficient decoupling when enabled.
    static let highResDecouplingThresholdHz: Double = 96_000

    /// Reference design rate for high-resolution decoupling (prevents pole crowding > 96 kHz).
    static let highResReferenceSampleRateHz: Double = 48_000

    /// Q values for Butterworth crossovers (all sections have Q = 0.7071 / sqrt(2)).
    static let butterworthQValues: [BassCrossoverSlope: [Double]] = [
        .lr2: [0.7071],
        .lr4: [0.7071, 0.7071],
        .lr8: [0.7071, 0.7071, 0.7071, 0.7071]
    ]

    /// Q values for Bessel crossovers (approximate values for 2nd, 4th, 8th order).
    static let besselQValues: [BassCrossoverSlope: [Double]] = [
        .lr2: [0.5773],
        .lr4: [0.5773, 0.6882],
        .lr8: [0.5773, 0.6882, 0.7231, 0.7356]
    ]

    /// Returns the sample rate used for biquad coefficient design.
    static func designSampleRate(actualRate: Double, coefficientDecouplingEnabled: Bool) -> Double {
        if coefficientDecouplingEnabled && actualRate > highResDecouplingThresholdHz {
            return highResReferenceSampleRateHz
        }
        return actualRate
    }

    /// Applies Tustin pre-warping to correct for bilinear transform frequency compression
    /// when the design sample rate differs from the actual sample rate.
    ///
    /// When coefficientDecoupling is active, filters are designed at `designRate` (48 kHz)
    /// but processed at `actualRate` (e.g. 192 kHz). The bilinear transform maps the
    /// continuous-frequency axis nonlinearly — pre-warping ensures the discrete-time
    /// cutoff lands exactly at the intended frequency.
    ///
    /// Formula: f_prewarped = (designRate / π) × tan(π × f / actualRate)
    ///
    /// Only applies when actualRate ≠ designRate. At unity (no decoupling), returns f unchanged.
    static func prewarpFrequency(
        frequency: Double,
        actualRate: Double,
        designRate: Double
    ) -> Double {
        guard actualRate != designRate, designRate > 0, actualRate > 0 else { return frequency }
        return (designRate / .pi) * tan(.pi * frequency / actualRate)
    }

    // MARK: - Main Entry Point (single section)

    /// Calculates biquad coefficients for the given filter parameters.
    ///
    /// - Parameters:
    ///   - type: The filter type (parametric, low-pass, high-pass, etc.)
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Centre/cutoff frequency in Hz
    ///   - q: Q factor (quality factor) for all filter types
    ///   - gain: Gain in dB (for parametric and shelf types)
    /// - Returns: Normalised biquad coefficients
    static func calculateCoefficients(
        type: FilterType,
        sampleRate: Double,
        frequency: Double,
        q: Double,
        gain: Double
    ) -> BiquadCoefficients {
        // Clamp frequency strictly below Nyquist. At or above Nyquist, the bilinear
        // transform produces degenerate or numerically unstable coefficients.
        let clampedFrequency = min(frequency, sampleRate * 0.499)
        switch type {
        case .parametric:
            return peakingEQ(sampleRate: sampleRate, frequency: clampedFrequency, q: q, gain: gain)
        case .lowPass:
            return lowPass(sampleRate: sampleRate, frequency: clampedFrequency, q: q)
        case .highPass:
            return highPass(sampleRate: sampleRate, frequency: clampedFrequency, q: q)
        case .lowShelf:
            return lowShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain, q: q)
        case .highShelf:
            return highShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain, q: q)
        case .bandPass:
            return bandPass(sampleRate: sampleRate, frequency: clampedFrequency, q: q)
        case .notch:
            return notch(sampleRate: sampleRate, frequency: clampedFrequency, q: q)
        case .allPass:
            return allPass(sampleRate: sampleRate, frequency: clampedFrequency, q: q)
        }
    }

    // MARK: - Multi-Section Entry Point (slope-aware)

    /// Calculates one or more biquad sections for the given filter parameters and slope.
    ///
    /// For LP / HP filters:
    ///   - 6 dB/oct  → 1st-order bilinear (degenerate biquad, b2=a2=0)
    ///   - 12 dB/oct → 1 section using the supplied Q
    ///   - 24 dB/oct → 2 Butterworth sections
    ///   - 48 dB/oct → 4 Butterworth sections
    ///
    /// For LS / HS filters the gain is distributed equally across sections and
    /// each section uses Q = 0.7071 (Butterworth). The 6 dB/oct case uses a
    /// 1st-order shelf bilinear section (b2=a2=0).
    ///
    /// For all other filter types slope is ignored and a single section is returned.
    ///
    /// - Parameters:
    ///   - type: The filter type
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Centre/cutoff frequency in Hz
    ///   - q: Q factor (used for 12 dB/oct LP/HP; ignored for higher-order slopes)
    ///   - gain: Gain in dB (parametric and shelf types)
    ///   - slope: Desired filter slope
    /// - Returns: Array of normalised biquad coefficients (one entry per section)
    static func calculateSections(
        type: FilterType,
        sampleRate: Double,
        frequency: Double,
        q: Double,
        gain: Double,
        slope: FilterSlope
    ) -> [BiquadCoefficients] {
        // Clamp frequency strictly below Nyquist. At or above Nyquist, the bilinear
        // transform produces degenerate or numerically unstable coefficients.
        let clampedFrequency = min(frequency, sampleRate * 0.499)
        switch type {
        case .lowPass:
            return lowPassSections(sampleRate: sampleRate, frequency: clampedFrequency, q: q, slope: slope)
        case .highPass:
            return highPassSections(sampleRate: sampleRate, frequency: clampedFrequency, q: q, slope: slope)
        case .lowShelf:
            return lowShelfSections(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain, slope: slope)
        case .highShelf:
            return highShelfSections(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain, slope: slope)
        case .allPass:
            // Allpass has no slope — return a single section
            return [calculateCoefficients(type: type, sampleRate: sampleRate, frequency: clampedFrequency, q: q, gain: gain)]
        default:
            // Slope is not applicable — return a single section
            return [calculateCoefficients(type: type, sampleRate: sampleRate, frequency: clampedFrequency, q: q, gain: gain)]
        }
    }

    // MARK: - Multi-Section LP

    private static func lowPassSections(
        sampleRate: Double,
        frequency: Double,
        q: Double,
        slope: FilterSlope
    ) -> [BiquadCoefficients] {
        // Clamp frequency strictly below Nyquist. At or above Nyquist, the bilinear
        // transform produces degenerate or numerically unstable coefficients.
        let clampedFrequency = min(frequency, sampleRate * 0.499)
        switch slope {
        case .db6:
            return [firstOrderLowPass(sampleRate: sampleRate, frequency: clampedFrequency)]
        case .db12:
            return [lowPass(sampleRate: sampleRate, frequency: clampedFrequency, q: q)]
        case .db18:
            // 3rd-order Butterworth: first-order stage + one biquad section (Q = 1.0).
            return [
                firstOrderLowPass(sampleRate: sampleRate, frequency: clampedFrequency),
                lowPass(sampleRate: sampleRate, frequency: clampedFrequency, q: 1.0)
            ]
        default:
            // All even-order slopes (db24 … db96): cascade Butterworth biquad sections.
            return slope.butterworthQValues.map { sectionQ in
                lowPass(sampleRate: sampleRate, frequency: clampedFrequency, q: sectionQ)
            }
        }
    }

    // MARK: - Multi-Section HP

    private static func highPassSections(
        sampleRate: Double,
        frequency: Double,
        q: Double,
        slope: FilterSlope
    ) -> [BiquadCoefficients] {
        // Clamp frequency strictly below Nyquist. At or above Nyquist, the bilinear
        // transform produces degenerate or numerically unstable coefficients.
        let clampedFrequency = min(frequency, sampleRate * 0.499)
        switch slope {
        case .db6:
            return [firstOrderHighPass(sampleRate: sampleRate, frequency: clampedFrequency)]
        case .db12:
            return [highPass(sampleRate: sampleRate, frequency: clampedFrequency, q: q)]
        case .db18:
            // 3rd-order Butterworth: first-order stage + one biquad section (Q = 1.0).
            return [
                firstOrderHighPass(sampleRate: sampleRate, frequency: clampedFrequency),
                highPass(sampleRate: sampleRate, frequency: clampedFrequency, q: 1.0)
            ]
        default:
            // All even-order slopes (db24 … db96): cascade Butterworth biquad sections.
            return slope.butterworthQValues.map { sectionQ in
                highPass(sampleRate: sampleRate, frequency: clampedFrequency, q: sectionQ)
            }
        }
    }

    // MARK: - Multi-Section LS

    private static func lowShelfSections(
        sampleRate: Double,
        frequency: Double,
        gain: Double,
        slope: FilterSlope
    ) -> [BiquadCoefficients] {
        // Clamp frequency strictly below Nyquist. At or above Nyquist, the bilinear
        // transform produces degenerate or numerically unstable coefficients.
        let clampedFrequency = min(frequency, sampleRate * 0.499)
        switch slope {
        case .db6:
            return [firstOrderLowShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain)]
        case .db12:
            return [lowShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain, q: 0.7071067811865476)]
        case .db18:
            // 3rd-order: split gain equally across first-order stage + one biquad section (Q = 1.0).
            let perSectionGain = gain / Double(slope.sectionCount)
            return [
                firstOrderLowShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: perSectionGain),
                lowShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: perSectionGain, q: 1.0)
            ]
        default:
            // All even-order slopes (db24 … db96): split gain equally across all sections.
            let perSectionGain = gain / Double(slope.sectionCount)
            return (0..<slope.sectionCount).map { _ in
                lowShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: perSectionGain, q: 0.7071067811865476)
            }
        }
    }

    // MARK: - Multi-Section HS

    private static func highShelfSections(
        sampleRate: Double,
        frequency: Double,
        gain: Double,
        slope: FilterSlope
    ) -> [BiquadCoefficients] {
        // Clamp frequency strictly below Nyquist. At or above Nyquist, the bilinear
        // transform produces degenerate or numerically unstable coefficients.
        let clampedFrequency = min(frequency, sampleRate * 0.499)
        switch slope {
        case .db6:
            return [firstOrderHighShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain)]
        case .db12:
            return [highShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: gain, q: 0.7071067811865476)]
        case .db18:
            // 3rd-order: split gain equally across first-order stage + one biquad section (Q = 1.0).
            let perSectionGain = gain / Double(slope.sectionCount)
            return [
                firstOrderHighShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: perSectionGain),
                highShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: perSectionGain, q: 1.0)
            ]
        default:
            // All even-order slopes (db24 … db96): split gain equally across all sections.
            let perSectionGain = gain / Double(slope.sectionCount)
            return (0..<slope.sectionCount).map { _ in
                highShelf(sampleRate: sampleRate, frequency: clampedFrequency, gain: perSectionGain, q: 0.7071067811865476)
            }
        }
    }

    // MARK: - First-Order Sections (6 dB/oct)

    /// First-order low-pass using bilinear transform.
    ///
    /// H(z) = Wc*(1 + z⁻¹) / ((1+Wc) + (Wc−1)*z⁻¹)
    /// where Wc = tan(π * f / fs).
    ///
    /// Stored as a degenerate biquad with b2 = a2 = 0.
    static func firstOrderLowPass(sampleRate: Double, frequency: Double) -> BiquadCoefficients {
        let wc = tan(.pi * frequency / sampleRate)
        let norm = 1.0 / (1.0 + wc)
        return BiquadCoefficients(
            b0: wc * norm,
            b1: wc * norm,
            b2: 0.0,
            a1: (wc - 1.0) * norm,
            a2: 0.0
        )
    }

    /// First-order high-pass using bilinear transform.
    ///
    /// H(z) = (1 − z⁻¹) / ((1+Wc) + (Wc−1)*z⁻¹)
    /// where Wc = tan(π * f / fs).
    ///
    /// Stored as a degenerate biquad with b2 = a2 = 0.
    static func firstOrderHighPass(sampleRate: Double, frequency: Double) -> BiquadCoefficients {
        let wc = tan(.pi * frequency / sampleRate)
        let norm = 1.0 / (1.0 + wc)
        return BiquadCoefficients(
            b0: norm,
            b1: -norm,
            b2: 0.0,
            a1: (wc - 1.0) * norm,
            a2: 0.0
        )
    }

    /// First-order low shelf using bilinear transform.
    ///
    /// H(s) = (s + A*wc) / (s + wc) for boost (A>1), cut (A<1).
    /// After bilinear with Wc = tan(π*f/fs):
    ///   b0 = (1 + A*Wc) / (1+Wc),  b1 = (A*Wc − 1) / (1+Wc)
    ///   a1 = (Wc − 1) / (1+Wc)
    static func firstOrderLowShelf(sampleRate: Double, frequency: Double, gain: Double) -> BiquadCoefficients {
        let A = pow(10.0, gain / 20.0)
        let wc = tan(.pi * frequency / sampleRate)
        let norm = 1.0 / (1.0 + wc)
        return BiquadCoefficients(
            b0: (1.0 + A * wc) * norm,
            b1: (A * wc - 1.0) * norm,
            b2: 0.0,
            a1: (wc - 1.0) * norm,
            a2: 0.0
        )
    }

    /// First-order high shelf using bilinear transform.
    ///
    /// H(s) = (A*s + wc) / (s + wc) for boost (A>1), cut (A<1).
    /// After bilinear with Wc = tan(π*f/fs):
    ///   b0 = (A + Wc) / (1+Wc),  b1 = (Wc − A) / (1+Wc)
    ///   a1 = (Wc − 1) / (1+Wc)
    static func firstOrderHighShelf(sampleRate: Double, frequency: Double, gain: Double) -> BiquadCoefficients {
        let A = pow(10.0, gain / 20.0)
        let wc = tan(.pi * frequency / sampleRate)
        let norm = 1.0 / (1.0 + wc)
        return BiquadCoefficients(
            b0: (A + wc) * norm,
            b1: (wc - A) * norm,
            b2: 0.0,
            a1: (wc - 1.0) * norm,
            a2: 0.0
        )
    }

    // MARK: - Peaking EQ (Parametric)

    /// Peaking EQ filter (bell curve).
    ///
    /// Boosts or cuts frequencies around the centre frequency.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Centre frequency in Hz
    ///   - q: Q factor (filter steepness)
    ///   - gain: Gain in dB (positive = boost, negative = cut)
    static func peakingEQ(
        sampleRate: Double,
        frequency: Double,
        q: Double,
        gain: Double
    ) -> BiquadCoefficients {
        let A = pow(10.0, gain / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosOmega
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha / A

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Low-Pass

    /// 2nd-order low-pass filter.
    ///
    /// Passes frequencies below cutoff, attenuates above.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Cutoff frequency in Hz
    ///   - q: Q factor (resonance), typically 0.707 for Butterworth
    static func lowPass(
        sampleRate: Double,
        frequency: Double,
        q: Double
    ) -> BiquadCoefficients {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let b0 = (1.0 - cosOmega) / 2.0
        let b1 = 1.0 - cosOmega
        let b2 = (1.0 - cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - High-Pass

    /// 2nd-order high-pass filter.
    ///
    /// Passes frequencies above cutoff, attenuates below.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Cutoff frequency in Hz
    ///   - q: Q factor (resonance), typically 0.707 for Butterworth
    static func highPass(
        sampleRate: Double,
        frequency: Double,
        q: Double
    ) -> BiquadCoefficients {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let b0 = (1.0 + cosOmega) / 2.0
        let b1 = -(1.0 + cosOmega)
        let b2 = (1.0 + cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Low Shelf

    /// Low shelf filter.
    ///
    /// Boosts or cuts frequencies below the shelf frequency.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Shelf frequency in Hz
    ///   - gain: Gain in dB (positive = boost, negative = cut)
    ///   - q: Q factor for shelf slope
    ///
    /// Coefficients follow the RBJ Audio EQ Cookbook lowShelf formula using
    /// `alpha = sin(w0)/(2*Q)`, so `2*sqrt(A)*alpha = sqrt(A)*sin(w0)/Q`.
    static func lowShelf(
        sampleRate: Double,
        frequency: Double,
        gain: Double,
        q: Double
    ) -> BiquadCoefficients {
        let A = pow(10.0, gain / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)
        let twoSqrtA_alpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) - (A - 1.0) * cosOmega + twoSqrtA_alpha)
        let b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosOmega)
        let b2 = A * ((A + 1.0) - (A - 1.0) * cosOmega - twoSqrtA_alpha)
        let a0 = (A + 1.0) + (A - 1.0) * cosOmega + twoSqrtA_alpha
        let a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosOmega)
        let a2 = (A + 1.0) + (A - 1.0) * cosOmega - twoSqrtA_alpha

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - High Shelf

    /// High shelf filter.
    ///
    /// Boosts or cuts frequencies above the shelf frequency.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Shelf frequency in Hz
    ///   - gain: Gain in dB (positive = boost, negative = cut)
    ///   - q: Q factor for shelf slope
    ///
    /// Coefficients follow the RBJ Audio EQ Cookbook highShelf formula using
    /// `alpha = sin(w0)/(2*Q)`, so `2*sqrt(A)*alpha = sqrt(A)*sin(w0)/Q`.
    static func highShelf(
        sampleRate: Double,
        frequency: Double,
        gain: Double,
        q: Double
    ) -> BiquadCoefficients {
        let A = pow(10.0, gain / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)
        let twoSqrtA_alpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) + (A - 1.0) * cosOmega + twoSqrtA_alpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosOmega)
        let b2 = A * ((A + 1.0) + (A - 1.0) * cosOmega - twoSqrtA_alpha)
        let a0 = (A + 1.0) - (A - 1.0) * cosOmega + twoSqrtA_alpha
        let a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosOmega)
        let a2 = (A + 1.0) - (A - 1.0) * cosOmega - twoSqrtA_alpha

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Band Pass

    /// Band pass filter (constant 0 dB peak gain).
    ///
    /// Passes frequencies within a band, attenuates outside.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Centre frequency in Hz
    ///   - q: Q factor (filter steepness)
    static func bandPass(
        sampleRate: Double,
        frequency: Double,
        q: Double
    ) -> BiquadCoefficients {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let b0 = alpha
        let b1 = 0.0
        let b2 = -alpha
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Notch

    /// Notch (band-reject) filter.
    ///
    /// Attenuates frequencies within a narrow band, passes everything else.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Centre frequency in Hz
    ///   - q: Q factor (filter steepness)
    static func notch(
        sampleRate: Double,
        frequency: Double,
        q: Double
    ) -> BiquadCoefficients {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)

        let b0 = 1.0
        let b1 = -2.0 * cosOmega
        let b2 = 1.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - All-Pass

    /// 2nd-order allpass filter.
    ///
    /// Unity magnitude, tunable phase. Centre of phase transition at `frequency`,
    /// sharpness controlled by `q` (higher Q = narrower phase transition).
    /// Coefficients: a1 = b1, a2 = b0, so the filter is its own inverse.
    /// - Parameters:
    ///   - sampleRate: Sample rate in Hz
    ///   - frequency: Centre frequency in Hz
    ///   - q: Q factor (phase transition sharpness)
    static func allPass(
        sampleRate: Double,
        frequency: Double,
        q: Double
    ) -> BiquadCoefficients {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * q)
        let b0 = 1.0 - alpha
        let b1 = -2.0 * cosOmega
        let b2 = 1.0 + alpha
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        return normalise(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Normalisation

    /// Normalises biquad coefficients by dividing by a0.
    ///
    /// This produces the standard form where the denominator is
    /// (1 + a1*z^-1 + a2*z^-2) rather than (a0 + a1*z^-1 + a2*z^-2).
    static func normalise(
        b0: Double,
        b1: Double,
        b2: Double,
        a0: Double,
        a1: Double,
        a2: Double
    ) -> BiquadCoefficients {
        let invA0 = 1.0 / a0
        return BiquadCoefficients(
            b0: b0 * invA0,
            b1: b1 * invA0,
            b2: b2 * invA0,
            a1: a1 * invA0,
            a2: a2 * invA0
        )
    }

    // MARK: - Magnitude Response

    /// Computes the magnitude response in dB of a biquad filter at a specific frequency.
    ///
    /// Evaluates |H(e^{jω})| from b0,b1,b2,a1,a2 in dB using the standard formula:
    /// |H(ω)|² = (b0² + b1² + b2² + 2*b0*b1*cos(ω) + 2*b0*b2*cos(2ω) + 2*b1*b2*cos(ω)) /
    ///          (1 + a1² + a2² + 2*a1*cos(ω) + 2*a2*cos(2ω) + 2*a1*a2*cos(ω))
    /// - Parameters:
    ///   - coefficients: Normalised biquad coefficients (a0 is implicitly 1.0)
    ///   - atFrequency: Frequency at which to evaluate magnitude (Hz)
    ///   - sampleRate: Sample rate in Hz
    /// - Returns: Magnitude in dB (20 * log10(|H(ω)|))
    static func magnitudeDB(
        coefficients: BiquadCoefficients,
        atFrequency frequency: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2.0 * .pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let cos2Omega = cos(2.0 * omega)

        // Numerator magnitude squared
        let num = coefficients.b0 * coefficients.b0
            + coefficients.b1 * coefficients.b1
            + coefficients.b2 * coefficients.b2
            + 2.0 * coefficients.b0 * coefficients.b1 * cosOmega
            + 2.0 * coefficients.b0 * coefficients.b2 * cos2Omega
            + 2.0 * coefficients.b1 * coefficients.b2 * cosOmega

        // Denominator magnitude squared (a0 is implicitly 1.0 for normalised coefficients)
        let den = 1.0
            + coefficients.a1 * coefficients.a1
            + coefficients.a2 * coefficients.a2
            + 2.0 * coefficients.a1 * cosOmega
            + 2.0 * coefficients.a2 * cos2Omega
            + 2.0 * coefficients.a1 * coefficients.a2 * cosOmega

        let magnitude = sqrt(num / den)
        return 20.0 * log10(max(1e-10, magnitude))  // Clamp to avoid log(0)
    }
}
