// EQHeadroomCompensator.swift
// Static EQ/Correction preamp for gain staging (Part 8)
//
// Computes a static preamp gain to prevent EQ and correction boosts from causing clipping.
// This is a predictive, control-thread computation based on filter design data,
// complementary to the existing Dynamic Gain Rider (Auto-Headroom).

import Foundation

/// EQ Headroom Compensator for static gain staging (Part 8).
enum EQHeadroomCompensator {

    /// Computes the static preamp gain in dB to prevent clipping from EQ/correction boosts.
    /// - Parameters:
    ///   - eqLayer: Main EQ layer bands
    ///   - roomCorrectionLayer: Room correction bands
    ///   - subEQLayer: Subwoofer EQ layer bands
    ///   - targetCurve: Target curve for room correction
    ///   - lowBandGainDB: Low band (subwoofer) gain from bass management
    /// - Returns: Static preamp gain in dB (always ≤ 0, never positive)
    static func computeStaticPreampDB(
        eqLayer: [PresetBand],
        roomCorrectionLayer: [PresetBand],
        subEQLayer: [PresetBand],
        targetCurve: [(frequency: Double, gainDB: Double)],
        lowBandGainDB: Float
    ) -> Float {
        // Compute magnitude response for each layer across audible band
        let frequencies = generateFrequencyBins()
        var totalBoostDB: [Float] = Array(repeating: 0.0, count: frequencies.count)

        // Add EQ layer contribution
        for (i, freq) in frequencies.enumerated() {
            let gain = computeLayerGain(at: Float(freq), bands: eqLayer)
            totalBoostDB[i] += gain
        }

        // Add room correction layer contribution
        for (i, freq) in frequencies.enumerated() {
            let gain = computeLayerGain(at: Float(freq), bands: roomCorrectionLayer)
            totalBoostDB[i] += gain
        }

        // Add sub EQ layer contribution (only affects low frequencies)
        for (i, freq) in frequencies.enumerated() {
            if freq < 300.0 {  // Sub EQ only affects low frequencies
                let gain = computeLayerGain(at: Float(freq), bands: subEQLayer)
                totalBoostDB[i] += gain
            }
        }

        // Add target curve contribution
        for (i, freq) in frequencies.enumerated() {
            let gain = interpolateTargetCurve(at: freq, curve: targetCurve)
            totalBoostDB[i] += Float(gain)
        }

        // Add low band gain from bass management (affects low frequencies)
        for (i, freq) in frequencies.enumerated() {
            if freq < 300.0 {
                totalBoostDB[i] += lowBandGainDB
            }
        }

        // Find worst-case boost (maximum across all frequency bins)
        let worstCaseBoostDB = totalBoostDB.max() ?? 0.0

        // Static preamp is the negative of the worst-case boost (never positive)
        let staticPreampDB = -max(0.0, worstCaseBoostDB)

        return staticPreampDB
    }

    /// Generates frequency bins for analysis (20 Hz - 20 kHz, log-spaced).
    private static func generateFrequencyBins() -> [Double] {
        var frequencies: [Double] = []
        let minFreq = 20.0
        let maxFreq = 20000.0
        let bins = 100  // Number of frequency bins

        for i in 0..<bins {
            let logFreq = log10(minFreq) + Double(i) / Double(bins - 1) * (log10(maxFreq) - log10(minFreq))
            frequencies.append(pow(10.0, logFreq))
        }

        return frequencies
    }

    /// Computes the gain of a filter layer at a specific frequency.
    private static func computeLayerGain(at frequency: Float, bands: [PresetBand]) -> Float {
        var totalGain: Float = 0.0

        for band in bands {
            if band.bypass { continue }

            let bandGain = computeBandGain(at: frequency, band: band)
            totalGain += bandGain
        }

        return totalGain
    }

    /// Computes the gain of a single band at a specific frequency.
    private static func computeBandGain(at frequency: Float, band: PresetBand) -> Float {
        // Simplified biquad magnitude response calculation
        // Full implementation would use the actual biquad coefficients
        let freqRatio = frequency / band.frequency
        let q = band.q

        switch band.filterType {
        case .parametric:
            // Peaking EQ magnitude response
            let numerator = 1.0 + band.gain * q * freqRatio
            let denominator = 1.0 + q * freqRatio
            return 20.0 * log10(abs(numerator / denominator))
        case .lowShelf:
            // Low shelf (simplified)
            if frequency < band.frequency {
                return band.gain
            } else {
                return 0.0
            }
        case .highShelf:
            // High shelf (simplified)
            if frequency > band.frequency {
                return band.gain
            } else {
                return 0.0
            }
        default:
            return 0.0
        }
    }

    /// Interpolates the target curve at a specific frequency.
    private static func interpolateTargetCurve(at frequency: Double, curve: [(frequency: Double, gainDB: Double)]) -> Double {
        guard !curve.isEmpty else { return 0.0 }
        guard curve.count > 1 else { return curve[0].gainDB }

        // Find the two points to interpolate between (linear in log-frequency space)
        let logFreq = log10(frequency)

        var lowIdx = 0
        var highIdx = curve.count - 1

        // Binary search for the interpolation interval
        while lowIdx < highIdx {
            let midIdx = (lowIdx + highIdx) / 2
            let midLogFreq = log10(curve[midIdx].frequency)
            if logFreq < midLogFreq {
                highIdx = midIdx
            } else {
                lowIdx = midIdx + 1
            }
        }

        // Clamp to valid range
        if lowIdx == 0 {
            lowIdx = 1
        }
        if lowIdx >= curve.count {
            lowIdx = curve.count - 1
        }

        let p0 = curve[lowIdx - 1]
        let p1 = curve[lowIdx]

        // Linear interpolation in log-frequency space
        let logFreq0 = log10(p0.frequency)
        let logFreq1 = log10(p1.frequency)
        let t = (logFreq - logFreq0) / (logFreq1 - logFreq0)
        let clampedT = max(0.0, min(1.0, t))

        return p0.gainDB + clampedT * (p1.gainDB - p0.gainDB)
    }
}
