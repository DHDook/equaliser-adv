import Foundation

/// Identifies diaphragm resonance peaks in a measured frequency response.
enum DiaphragmResonanceDetector {

    struct ResonanceCandidate: Identifiable, Sendable {
        var id: UUID = UUID()
        /// Centre frequency of the resonance (Hz).
        var frequencyHz: Double
        /// Estimated peak height above the surrounding response (dB).
        /// This is the prominence of the peak, not its absolute level.
        var prominenceDB: Double
        /// Estimated Q factor of the resonance.
        /// Computed as: Q = frequencyHz / bandwidthHz,
        /// where bandwidthHz is the –3 dB width of the prominence peak.
        var estimatedQ: Double
        /// Suggested notch filter configuration for this resonance.
        var suggestedNotch: EQBandConfiguration
        /// Confidence in the detection (0.0–1.0).
        /// Low confidence when peak is broad (Q < 3) or prominence < minimumProminenceDB.
        var confidence: Double
    }

    struct DetectionParameters: Sendable {
        /// Frequency range to search for resonances (Hz).
        /// Typical woofer breakup: 800–5000 Hz.
        /// Typical tweeter breakup: 5000–20000 Hz.
        /// Default: full range of the passband.
        var searchRangeHz: (low: Double, high: Double) = (200.0, 20000.0)

        /// Minimum peak prominence to report (dB above surrounding response).
        /// Default: 3.0 dB — avoids flagging gentle response variations.
        var minimumProminenceDB: Double = 3.0

        /// Minimum Q for a peak to be classified as a resonance (not a broad hump).
        /// Default: 3.0.
        var minimumQ: Double = 3.0

        /// Maximum number of candidates to return, ranked by prominence.
        var maxCandidates: Int = 5

        /// Smoothing octaves applied to the response before peak detection.
        /// Must be narrower than the expected resonance bandwidth.
        /// Default: 1/24 octave (very narrow — preserves sharp peaks).
        var backgroundSmoothingOctaves: Double = 1.0 / 24.0
    }

    /// Detects resonance peaks in a measured magnitude response.
    ///
    /// Algorithm:
    ///   1. Apply `backgroundSmoothingOctaves` smoothing to produce a
    ///      "background" response that follows broad trends but not narrow peaks.
    ///   2. Compute residual = raw response − background response.
    ///      Sharp peaks appear as positive spikes in the residual.
    ///   3. Find local maxima in the residual above minimumProminenceDB.
    ///   4. For each maximum, estimate Q by measuring the −3 dB width of
    ///      the residual peak. Q = frequency / bandwidth.
    ///   5. Filter by minimumQ and minimumProminenceDB.
    ///   6. Rank by prominence (highest first). Return top maxCandidates.
    ///   7. For each candidate, build a suggested EQBandConfiguration:
    ///      filterType = .notch,
    ///      frequency = candidateHz,
    ///      q = min(estimatedQ × 0.8, 20.0)    (slightly narrower than detected),
    ///      gain = -prominenceDB × 0.8          (slightly under-corrected notch depth).
    ///
    /// - Parameters:
    ///   - magnitudeResponseDB: From ChannelTransferFunctionData.averagedMagnitudeDB.
    ///   - params: Detection parameters.
    /// - Returns: Sorted array of resonance candidates (highest prominence first).
    static func detect(
        magnitudeResponseDB: [(frequency: Double, gainDB: Double)],
        params: DetectionParameters = DetectionParameters()
    ) -> [ResonanceCandidate] {
        guard !magnitudeResponseDB.isEmpty else { return [] }

        // Step 1: Apply background smoothing
        let backgroundResponse = applySmoothing(
            magnitudeResponseDB: magnitudeResponseDB,
            smoothingOctaves: params.backgroundSmoothingOctaves
        )

        // Step 2: Compute residual
        var residual: [(frequency: Double, gainDB: Double)] = []
        for i in 0..<magnitudeResponseDB.count {
            let residualDB = magnitudeResponseDB[i].gainDB - backgroundResponse[i].gainDB
            residual.append((frequency: magnitudeResponseDB[i].frequency, gainDB: residualDB))
        }

        // Step 3: Find local maxima in residual above minimumProminenceDB
        var candidates: [ResonanceCandidate] = []

        for i in 1..<(residual.count - 1) {
            let current = residual[i]
            let prev = residual[i - 1]
            let next = residual[i + 1]

            // Check if this is a local maximum
            guard current.gainDB > prev.gainDB && current.gainDB > next.gainDB else { continue }

            // Check if within search range
            guard current.frequency >= params.searchRangeHz.low &&
                  current.frequency <= params.searchRangeHz.high else { continue }

            // Check minimum prominence
            guard current.gainDB >= params.minimumProminenceDB else { continue }

            // Step 4: Estimate Q by measuring -3 dB bandwidth
            let bandwidthHz = estimateBandwidth(
                residual: residual,
                peakIndex: i,
                peakDB: current.gainDB
            )

            guard bandwidthHz > 0 else { continue }

            let estimatedQ = current.frequency / bandwidthHz

            // Step 5: Filter by minimum Q
            guard estimatedQ >= params.minimumQ else { continue }

            // Step 7: Build suggested notch filter
            let suggestedQ = min(estimatedQ * 0.8, 20.0)
            // Notch depth: negative of peak prominence, scaled by 0.8 to avoid
            // over-correction (slight under-correction is preferable for resonance
            // peaks where the true amplitude may vary with measurement position).
            let suggestedGainDB = Float(-current.gainDB * 0.8)
            let suggestedNotch = EQBandConfiguration(
                frequency: Float(current.frequency),
                q: Float(suggestedQ),
                gain: suggestedGainDB,
                filterType: .notch,
                bypass: false
            )

            // Compute confidence (0.0–1.0)
            let qScore = min((estimatedQ - params.minimumQ) / 10.0, 1.0)
            let prominenceScore = min((current.gainDB - params.minimumProminenceDB) / 10.0, 1.0)
            let confidence = (qScore + prominenceScore) / 2.0

            let candidate = ResonanceCandidate(
                frequencyHz: current.frequency,
                prominenceDB: current.gainDB,
                estimatedQ: estimatedQ,
                suggestedNotch: suggestedNotch,
                confidence: confidence
            )

            candidates.append(candidate)
        }

        // Step 6: Rank by prominence (highest first) and return top maxCandidates
        candidates.sort { $0.prominenceDB > $1.prominenceDB }
        return Array(candidates.prefix(params.maxCandidates))
    }

    // MARK: - Helper Methods

    /// Applies fractional-octave smoothing to the magnitude response.
    private static func applySmoothing(
        magnitudeResponseDB: [(frequency: Double, gainDB: Double)],
        smoothingOctaves: Double
    ) -> [(frequency: Double, gainDB: Double)] {
        var smoothed: [(frequency: Double, gainDB: Double)] = []

        for i in 0..<magnitudeResponseDB.count {
            let centerFreq = magnitudeResponseDB[i].frequency
            let lowerFreq = centerFreq / pow(2.0, smoothingOctaves / 2.0)
            let upperFreq = centerFreq * pow(2.0, smoothingOctaves / 2.0)

            var sum: Double = 0
            var count: Double = 0

            for j in 0..<magnitudeResponseDB.count {
                let freq = magnitudeResponseDB[j].frequency
                if freq >= lowerFreq && freq <= upperFreq {
                    sum += magnitudeResponseDB[j].gainDB
                    count += 1
                }
            }

            let avgGain = count > 0 ? sum / count : magnitudeResponseDB[i].gainDB
            smoothed.append((frequency: centerFreq, gainDB: avgGain))
        }

        return smoothed
    }

    /// Estimates the -3 dB bandwidth of a peak in the residual.
    private static func estimateBandwidth(
        residual: [(frequency: Double, gainDB: Double)],
        peakIndex: Int,
        peakDB: Double
    ) -> Double {
        let peakFreq = residual[peakIndex].frequency
        let targetDB = peakDB - 3.0

        // Find lower -3 dB point
        var lowerFreq = peakFreq
        var i = peakIndex
        while i > 0 && residual[i].gainDB > targetDB {
            i -= 1
            lowerFreq = residual[i].frequency
        }

        // Find upper -3 dB point
        var upperFreq = peakFreq
        i = peakIndex
        while i < residual.count - 1 && residual[i].gainDB > targetDB {
            i += 1
            upperFreq = residual[i].frequency
        }

        return upperFreq - lowerFreq
    }
}
