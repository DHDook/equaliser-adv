// BiquadValidator.swift
// Validates biquad filter parameters and coefficient stability

import Foundation

/// Validates biquad filter parameters and coefficient stability.
///
/// Pure type — no I/O, no dependencies. All methods are static.
///
/// Parameter validation catches user errors early with descriptive messages
/// rather than silently producing passthrough or unstable filters.
/// Coefficient stability checks verify that poles are inside the unit circle,
/// which is essential for preventing runaway output that could damage speakers.
enum BiquadValidator {

    // MARK: - Validation Result

    /// Result of validating biquad filter parameters.
    enum ValidationResult: Equatable {
        /// Parameters are valid and should produce a stable filter.
        case valid
        /// Parameters are usable but may produce undesirable results (e.g. near Nyquist).
        case warning(String)
        /// Parameters are invalid and will not produce a usable filter.
        case invalid(String)
    }

    // MARK: - Parameter Validation

    /// Validates filter parameters before coefficient calculation.
    ///
    /// Checks that parameters are within physically meaningful ranges.
    /// Invalid parameters are clamped by the caller; this validator reports
    /// what's wrong so the caller can decide how to handle it.
    ///
    /// - Parameters:
    ///   - type: The filter type.
    ///   - sampleRate: Sample rate in Hz.
    ///   - frequency: Centre/cutoff frequency in Hz.
    ///   - q: Q factor (quality factor).
    ///   - gain: Gain in dB (for parametric and shelf types).
    /// - Returns: Validation result indicating whether parameters are valid.
    static func validate(
        type: FilterType,
        sampleRate: Double,
        frequency: Double,
        q: Double,
        gain: Double
    ) -> ValidationResult {
        var issues: [String] = []

        // Sample rate must be positive
        if sampleRate <= 0 {
            return .invalid("Sample rate must be positive (got \(sampleRate))")
        }

        let nyquist = sampleRate / 2.0

        // Frequency must be positive and below Nyquist
        if frequency <= 0 {
            return .invalid("Frequency must be positive (got \(frequency))")
        }
        if frequency >= nyquist {
            return .invalid("Frequency \(frequency) Hz is at or above Nyquist (\(nyquist) Hz)")
        }

        // Q must be positive
        if q <= 0 {
            return .invalid("Q factor must be positive (got \(q))")
        }

        // Frequency should be within the audible range
        if frequency < Double(AudioConstants.minEQFrequency) {
            issues.append("Frequency \(frequency) Hz is below audible range")
        }
        if frequency > Double(AudioConstants.maxEQFrequency) {
            issues.append("Frequency \(frequency) Hz is above audible range")
        }

        // Gain must be within the allowed range
        if gain < Double(AudioConstants.minGain) {
            issues.append("Gain \(gain) dB is below minimum (\(AudioConstants.minGain) dB)")
        }
        if gain > Double(AudioConstants.maxGain) {
            issues.append("Gain \(gain) dB is above maximum (\(AudioConstants.maxGain) dB)")
        }

        // Extremely high Q can produce near-unstable filters
        if q > 30.0 {
            issues.append("Q factor \(q) is very high — may produce narrow resonant peaks")
        }

        // Frequency very close to Nyquist produces unreliable coefficients
        if frequency > nyquist * 0.95 {
            issues.append("Frequency \(frequency) Hz is close to Nyquist — coefficients may be unreliable")
        }

        if !issues.isEmpty {
            return .warning(issues.joined(separator: "; "))
        }

        return .valid
    }

    // MARK: - Coefficient Stability

    /// Checks whether biquad coefficients produce a stable filter.
    ///
    /// A biquad filter is stable when its poles are inside the unit circle.
    /// For normalised coefficients (a0 = 1), this requires:
    /// - `|a2| < 1`
    /// - `|a1| < 1 + a2`
    ///
    /// Unstable filters produce runaway output that can damage speakers.
    ///
    /// - Parameter coefficients: The normalised biquad coefficients to check.
    /// - Returns: `true` if the filter is stable, `false` if unstable.
    static func isStable(_ coefficients: BiquadCoefficients) -> Bool {
        // Stability condition for normalised biquad:
        // poles inside unit circle: |a2| < 1 AND |a1| < 1 + a2
        let a1 = coefficients.a1
        let a2 = coefficients.a2

        guard abs(a2) < 1.0 else { return false }
        guard abs(a1) < 1.0 + a2 else { return false }

        return true
    }

    /// Checks whether biquad coefficients contain NaN or infinity values.
    ///
    /// This can happen when parameters are at extreme values (e.g. frequency
    /// at Nyquist, zero sample rate, or very high Q). Such coefficients would
    /// produce garbage output.
    ///
    /// - Parameter coefficients: The biquad coefficients to check.
    /// - Returns: `true` if all coefficients are finite, `false` if any are NaN/Inf.
    static func isFinite(_ coefficients: BiquadCoefficients) -> Bool {
        return coefficients.b0.isFinite
            && coefficients.b1.isFinite
            && coefficients.b2.isFinite
            && coefficients.a1.isFinite
            && coefficients.a2.isFinite
    }
}