// BandLevelCalibrationEngine.swift
// Acoustic band level calibration for multi-output channel matrix.
// Plays pink noise per channel, measures captured SPL, and computes
// gainTrimDB corrections to equalise all channels at the listening position.
// Main thread only — pure computation, no real-time constraints.

import Accelerate
import Foundation

enum BandLevelCalibrationEngine {

    // MARK: - Pink Noise Generation

    /// Generates a pink noise burst of the given duration.
    /// Pink noise is used because its equal energy per octave produces
    /// a perceptually flat spectrum that is representative of music.
    /// Implemented using the Voss-McCartney algorithm (16-stage).
    /// - Parameters:
    ///   - durationSeconds: Length of burst. 3–10 s recommended.
    ///   - sampleRate: Target sample rate.
    ///   - fadeInSeconds: Linear fade-in to avoid onset transients. Default 0.1 s.
    ///   - fadeOutSeconds: Linear fade-out. Default 0.1 s.
    /// - Returns: Normalised float samples, peak ≤ –6 dBFS.
    static func generatePinkNoise(
        durationSeconds: Double,
        sampleRate: Double,
        fadeInSeconds: Double = 0.1,
        fadeOutSeconds: Double = 0.1
    ) -> [Float] {
        let sampleCount = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0.0, count: sampleCount)

        // Voss-McCartney algorithm with 16 stages
        // Each stage updates at a different rate (powers of 2)
        var stages = [Float](repeating: 0.0, count: 16)
        var counters = [Int](repeating: 0, count: 16)
        let stageUpdates = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768]

        for i in 0..<sampleCount {
            var pink: Float = 0.0

            // Update each stage at its respective rate
            for stage in 0..<16 {
                counters[stage] += 1
                if counters[stage] >= stageUpdates[stage] {
                    counters[stage] = 0
                    // Generate new random value for this stage
                    stages[stage] = Float.random(in: -1.0...1.0)
                }
                pink += stages[stage]
            }

            // Normalise and scale
            samples[i] = pink / 16.0
        }

        // Apply fade-in and fade-out
        let fadeInSamples = Int(fadeInSeconds * sampleRate)
        let fadeOutSamples = Int(fadeOutSeconds * sampleRate)

        for i in 0..<min(fadeInSamples, sampleCount) {
            let fade = Float(i) / Float(fadeInSamples)
            samples[i] *= fade
        }

        for i in 0..<min(fadeOutSamples, sampleCount) {
            let startIdx = sampleCount - fadeOutSamples + i
            if startIdx >= 0 && startIdx < sampleCount {
                let fade = Float(fadeOutSamples - i) / Float(fadeOutSamples)
                samples[startIdx] *= fade
            }
        }

        // Normalise to -6 dBFS peak (0.5)
        if let maxSample = samples.max(), maxSample > 0 {
            let scale = 0.5 / maxSample
            for i in 0..<sampleCount {
                samples[i] *= scale
            }
        }

        return samples
    }

    // MARK: - SPL Measurement

    /// Measures the broadband RMS level of a captured recording.
    /// Applies optional microphone calibration before computing level.
    /// - Parameters:
    ///   - capturedSamples: Raw samples from the microphone input.
    ///   - sampleRate: Sample rate of the capture.
    ///   - micCalibration: Optional mic calibration to apply. Corrects for
    ///     mic frequency response before RMS computation.
    ///   - bandpassHz: Optional (low, high) frequency limits in Hz.
    ///     When non-nil, only energy within this band is measured.
    ///     Use to focus measurement on each channel's intended passband,
    ///     e.g. (80, 3000) for a midrange driver.
    ///   - trimLeadingSeconds: Seconds to skip at capture start (avoids
    ///     room reverb onset and relay click). Default 0.2 s.
    /// - Returns: Measured level in dBFS (relative to full scale).
    static func measureRMSLevel(
        capturedSamples: [Float],
        sampleRate: Double,
        micCalibration: MicCalibration? = nil,
        bandpassHz: (low: Double, high: Double)? = nil,
        trimLeadingSeconds: Double = 0.2
    ) -> Double {
        guard !capturedSamples.isEmpty else { return -60.0 }

        // Trim leading samples to avoid transients
        let trimSamples = Int(trimLeadingSeconds * sampleRate)
        let startIndex = min(trimSamples, capturedSamples.count)
        let samples = Array(capturedSamples[startIndex...])

        // Apply bandpass filtering if specified
        var processedSamples = samples
        if let bandpass = bandpassHz {
            processedSamples = applyBandpassFilter(samples, lowFreq: bandpass.low, highFreq: bandpass.high, sampleRate: sampleRate)
        }

        // Apply microphone calibration if provided
        if let calibration = micCalibration {
            processedSamples = applyMicCalibration(processedSamples, calibration: calibration)
        }

        // Compute RMS level
        var sum: Float = 0.0
        for sample in processedSamples {
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(processedSamples.count))

        // Convert to dBFS (20 * log10(rms))
        let dbfs = 20.0 * log10(max(rms, 1e-10))

        return Double(dbfs)
    }

    // MARK: - Helper Functions

    private static func applyBandpassFilter(_ samples: [Float], lowFreq: Double, highFreq: Double, sampleRate: Double) -> [Float] {
        // Simple IIR bandpass filter implementation
        // For production, use a more sophisticated filter design

        // Filter coefficients (simplified Butterworth bandpass)
        let q = sqrt(highFreq / lowFreq) / (highFreq / lowFreq - 1.0)
        let omega = 2.0 * .pi * sqrt(lowFreq * highFreq) / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let b0 = Float(alpha)
        let b1: Float = 0.0
        let b2 = Float(-alpha)
        let a0 = Float(1.0 + alpha)
        let a1 = Float(-2.0 * cos(omega))
        let a2 = Float(1.0 - alpha)

        var filtered = [Float](repeating: 0.0, count: samples.count)
        var x1: Float = 0.0, x2: Float = 0.0, y1: Float = 0.0, y2: Float = 0.0

        for i in 0..<samples.count {
            let x0 = samples[i]
            let term1 = b0 * x0
            let term2 = b1 * x1
            let term3 = b2 * x2
            let term4 = a1 * y1
            let term5 = a2 * y2
            let numerator = term1 + term2 + term3 - term4 - term5
            let y0 = numerator / a0
            filtered[i] = y0

            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }

        return filtered
    }

    private static func applyMicCalibration(_ samples: [Float], calibration: MicCalibration) -> [Float] {
        // Apply frequency-dependent calibration using interpolation
        // For now, apply a simple gain adjustment based on average deviation
        // In production, this would use the calibration curve to adjust frequency response
        let averageDeviation = calibration.points.reduce(0.0) { $0 + $1.deviationDB } / Double(calibration.points.count)
        let linearGain = pow(10.0, averageDeviation / 20.0)

        return samples.map { $0 * Float(linearGain) }
    }

    // MARK: - Gain Trim Computation

    /// Computes gainTrimDB values to equalise all channels to a common reference level.
    ///
    /// Strategy:
    ///   1. Find the channel with the lowest measured SPL (the reference).
    ///      (Attenuating all others to the lowest level is conservative and
    ///       preserves headroom.)
    ///   2. For each other channel, compute trim = lowestLevelDB − measuredDB.
    ///      This will be zero for the quietest channel and negative for all others.
    ///
    /// - Parameters:
    ///   - measuredLevelsDB: Dictionary mapping channel index → measured dBFS.
    ///   - existingTrimsDB: Current gainTrimDB values per channel index.
    ///     Used to compute net required trim (existing + new adjustment).
    ///   - maxTrimDB: Maximum correction magnitude to apply in a single pass.
    ///     Default 20.0 dB. Corrections beyond this are clamped and flagged.
    /// - Returns: Dictionary mapping channel index → suggested gainTrimDB.
    static func computeGainTrims(
        measuredLevelsDB: [Int: Double],
        existingTrimsDB: [Int: Float],
        maxTrimDB: Double = 20.0
    ) -> (trims: [Int: Float], warnings: [CalibrationWarning]) {
        var warnings: [CalibrationWarning] = []
        var trims: [Int: Float] = [:]

        guard !measuredLevelsDB.isEmpty else {
            return (trims, warnings)
        }

        // Find the quietest channel (reference)
        guard let quietestChannel = measuredLevelsDB.min(by: { $0.value < $1.value }) else {
            return (trims, warnings)
        }

        let quietestLevel = quietestChannel.value
        let quietestIndex = quietestChannel.key

        // Check for suspiciously quiet measurements
        if quietestLevel < Self.suspiciouslyQuietThresholdDB {
            warnings.append(.suspiciouslyQuiet(channelIndex: quietestIndex, channelLabel: "Channel \(quietestIndex)", measuredDB: quietestLevel))
        }

        // Compute trims for all channels
        for (index, measuredDB) in measuredLevelsDB {
            let existingTrim = existingTrimsDB[index] ?? 0.0
            let requiredTrim = Float(quietestLevel - measuredDB)
            let netTrim = existingTrim + requiredTrim

            // Clamp to maxTrimDB
            let appliedTrim: Float
            if abs(netTrim) > Float(maxTrimDB) {
                appliedTrim = netTrim > 0 ? Float(maxTrimDB) : -Float(maxTrimDB)
                warnings.append(.trimClamped(channelIndex: index, channelLabel: "Channel \(index)", requestedDB: netTrim, appliedDB: appliedTrim))
            } else {
                appliedTrim = netTrim
            }

            // Check for large trims
            if abs(appliedTrim) > Self.largeTrimWarningThresholdDB {
                warnings.append(.largeTrimRequired(channelIndex: index, channelLabel: "Channel \(index)", trimDB: appliedTrim))
            }

            trims[index] = appliedTrim
        }

        return (trims, warnings)
    }

    // MARK: - Warnings

    enum CalibrationWarning: Equatable, Sendable {
        /// A large DSP trim is required on this channel, suggesting the amplifier
        /// volume control is set very differently from others.
        /// Recommend the user adjust their amplifier volume control to reduce DSP correction.
        case largeTrimRequired(channelIndex: Int, channelLabel: String, trimDB: Float)
        /// The measurement for this channel was very quiet, suggesting the signal
        /// path may not be working correctly.
        case suspiciouslyQuiet(channelIndex: Int, channelLabel: String, measuredDB: Double)
        /// The measurement could not be taken for this channel (e.g. device not connected).
        case measurementFailed(channelIndex: Int, channelLabel: String)
        /// The required trim exceeds maxTrimDB — clamped.
        case trimClamped(channelIndex: Int, channelLabel: String, requestedDB: Float, appliedDB: Float)
    }

    /// Threshold above which a large-trim warning is emitted. Default: 12 dB.
    static let largeTrimWarningThresholdDB: Float = 12.0

    /// Threshold below which a suspiciously-quiet warning is emitted. Default: –60 dBFS.
    static let suspiciouslyQuietThresholdDB: Double = -60.0
}
