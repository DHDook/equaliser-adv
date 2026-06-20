// MicCalibrationLoader.swift
// Equaliser
//
// Parser for microphone calibration files (UMIK-1, Earthworks, etc.)
// Format: plain-text, two columns (frequency_Hz deviation_dB)
// Comments prefixed with * or #

import Foundation

/// A single calibration data point
struct MicCalibrationPoint: Codable, Sendable {
    let frequency: Double  // Hz
    let deviationDB: Double  // dB deviation from flat response
}

/// Microphone calibration data with interpolation support
struct MicCalibration: Codable, Sendable {
    let points: [MicCalibrationPoint]
    let filename: String?

    // MARK: - Hybrid Calibration Fields (Part 2 Task AC)

    /// Free-field calibration (0° on-axis). If nil, points is used for all frequencies.
    var freeFieldPoints: [MicCalibrationPoint]?

    /// Diffuse-field calibration (random incidence). If nil, points is used for all frequencies.
    var diffuseFieldPoints: [MicCalibrationPoint]?

    /// Schroeder frequency of the listening room (Hz). Transition between diffuse
    /// and free-field correction is centred here.
    /// Default: 300 Hz (conservative estimate for typical domestic rooms).
    /// Range: 100–1000 Hz.
    var schroederFrequencyHz: Double = 300.0

    /// Width of the crossfade transition region (octaves).
    /// Default: 1.0 octave (centred on schroederFrequencyHz,
    /// so transition spans schroederHz/√2 to schroederHz×√2).
    var transitionWidthOctaves: Double = 1.0

    /// Convenience accessor for backward compatibility
    var frequencyResponseDB: [(frequency: Double, correctionDB: Double)] {
        points.map { (frequency: $0.frequency, correctionDB: $0.deviationDB) }
    }

    /// Interpolates the calibration deviation at a given frequency (linear in log-frequency space)
    func deviationAtFrequency(_ frequency: Double) -> Double {
        guard !points.isEmpty else { return 0.0 }
        guard points.count > 1 else { return points[0].deviationDB }

        // Find the two points to interpolate between
        let logFreq = log10(frequency)

        // Find the index where logFreq would be inserted
        var lowIdx = 0
        var highIdx = points.count - 1

        // Binary search for the interpolation interval
        while lowIdx < highIdx {
            let midIdx = (lowIdx + highIdx) / 2
            let midLogFreq = log10(points[midIdx].frequency)
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
        if lowIdx >= points.count {
            lowIdx = points.count - 1
        }

        let p0 = points[lowIdx - 1]
        let p1 = points[lowIdx]

        // Linear interpolation in log-frequency space
        let logFreq0 = log10(p0.frequency)
        let logFreq1 = log10(p1.frequency)
        let t = (logFreq - logFreq0) / (logFreq1 - logFreq0)
        let clampedT = max(0.0, min(1.0, t))

        return p0.deviationDB + clampedT * (p1.deviationDB - p0.deviationDB)
    }

    /// Interpolates deviation from a specific point array
    private func deviationAtFrequency(_ frequency: Double, from points: [MicCalibrationPoint]) -> Double {
        guard !points.isEmpty else { return 0.0 }
        guard points.count > 1 else { return points[0].deviationDB }

        let logFreq = log10(frequency)
        var lowIdx = 0
        var highIdx = points.count - 1

        while lowIdx < highIdx {
            let midIdx = (lowIdx + highIdx) / 2
            let midLogFreq = log10(points[midIdx].frequency)
            if logFreq < midLogFreq {
                highIdx = midIdx
            } else {
                lowIdx = midIdx + 1
            }
        }

        if lowIdx == 0 {
            lowIdx = 1
        }
        if lowIdx >= points.count {
            lowIdx = points.count - 1
        }

        let p0 = points[lowIdx - 1]
        let p1 = points[lowIdx]

        let logFreq0 = log10(p0.frequency)
        let logFreq1 = log10(p1.frequency)
        let t = (logFreq - logFreq0) / (logFreq1 - logFreq0)
        let clampedT = max(0.0, min(1.0, t))

        return p0.deviationDB + clampedT * (p1.deviationDB - p0.deviationDB)
    }

    /// Computes hybrid calibration correction at a given frequency
    /// using cosine-tapered crossfade between diffuse and free-field
    func hybridDeviationAtFrequency(_ frequency: Double) -> Double {
        // If only single-file calibration, use it directly
        guard let freeField = freeFieldPoints,
              let diffuseField = diffuseFieldPoints else {
            return deviationAtFrequency(frequency)
        }

        let schroeder = schroederFrequencyHz
        let transitionOctaves = transitionWidthOctaves

        // Compute transition boundaries
        let lowerBound = schroeder / pow(2.0, transitionOctaves / 2.0)
        let upperBound = schroeder * pow(2.0, transitionOctaves / 2.0)

        let diffuseCorrection = deviationAtFrequency(frequency, from: diffuseField)
        let freeCorrection = deviationAtFrequency(frequency, from: freeField)

        // Below lower bound: use diffuse only
        if frequency < lowerBound {
            return diffuseCorrection
        }

        // Above upper bound: use free-field only
        if frequency > upperBound {
            return freeCorrection
        }

        // In transition band: cosine-tapered crossfade
        let logLower = log2(lowerBound)
        let logUpper = log2(upperBound)
        let logFreq = log2(frequency)

        let t = (logFreq - logLower) / (logUpper - logLower)  // 0 to 1
        let blend = 0.5 * (1.0 - cos(Double.pi * t))  // Cosine taper: 0 to 1

        return (1.0 - blend) * diffuseCorrection + blend * freeCorrection
    }
}

/// Parser for microphone calibration files
enum MicCalibrationLoader {
    /// Parses a calibration file from a string
    static func parse(_ content: String, filename: String? = nil) throws -> MicCalibration {
        var points: [MicCalibrationPoint] = []

        let lines = content.components(separatedBy: .newlines)
        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("*") || trimmed.hasPrefix("#") {
                continue
            }

            // Parse frequency and deviation
            let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 2 else {
                throw MicCalibrationError.invalidFormat(lineNumber: lineIndex + 1, line: line)
            }

            guard let frequency = Double(components[0]),
                  let deviation = Double(components[1]) else {
                throw MicCalibrationError.invalidNumber(lineNumber: lineIndex + 1, line: line)
            }

            guard frequency > 0 else {
                throw MicCalibrationError.invalidFrequency(lineNumber: lineIndex + 1, frequency: frequency)
            }

            points.append(MicCalibrationPoint(frequency: frequency, deviationDB: deviation))
        }

        // Sort by frequency to ensure monotonic interpolation
        points.sort { $0.frequency < $1.frequency }

        guard !points.isEmpty else {
            throw MicCalibrationError.emptyFile
        }

        return MicCalibration(points: points, filename: filename)
    }

    /// Parses a calibration file from a URL
    static func parse(from url: URL) throws -> MicCalibration {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content, filename: url.lastPathComponent)
    }

    // MARK: - Hybrid Calibration (Part 2 Task AC)

    /// Loads a dual-file calibration: one free-field file and one diffuse-field file.
    /// Both files use the standard format already supported by MicCalibrationLoader
    /// (tab-separated frequency/gain pairs, as produced by Cross-Spectrum Labs, miniDSP UMIK, etc.)
    ///
    /// The resulting MicCalibration.frequencyResponseDB is left nil (or set to the free-field
    /// curve as a fallback). The hybrid correction is computed on demand via applyHybridCalibration.
    static func loadDual(
        freeFieldURL: URL,
        diffuseFieldURL: URL
    ) throws -> MicCalibration {
        let freeFieldCalibration = try parse(from: freeFieldURL)
        let diffuseFieldCalibration = try parse(from: diffuseFieldURL)

        var calibration = MicCalibration(
            points: freeFieldCalibration.points,
            filename: freeFieldURL.lastPathComponent
        )
        calibration.freeFieldPoints = freeFieldCalibration.points
        calibration.diffuseFieldPoints = diffuseFieldCalibration.points

        return calibration
    }

    /// Computes the hybrid calibration correction at a given frequency.
    ///
    /// Algorithm (cosine-tapered crossfade):
    ///   Below schroederHz / sqrt(2^transitionWidthOctaves):
    ///     Use diffuseFieldResponseDB correction only.
    ///   Above schroederHz × sqrt(2^transitionWidthOctaves):
    ///     Use freeFieldResponseDB correction only.
    ///   In the transition band:
    ///     blend = 0.5 × (1 - cos(π × t)) where t = log2(f / lower) / transitionWidthOctaves
    ///     hybridCorrection = (1-blend) × diffuseCorrection + blend × freeFieldCorrection
    ///
    /// When only one calibration file is provided (existing single-file mode):
    ///   hybridCorrection = frequencyResponseDB correction at that frequency.
    static func applyHybridCalibration(
        _ calibration: MicCalibration,
        to magnitudeResponseDB: [(frequency: Double, gainDB: Double)]
    ) -> [(frequency: Double, gainDB: Double)] {
        return magnitudeResponseDB.map { point in
            let correction = calibration.hybridDeviationAtFrequency(point.frequency)
            return (frequency: point.frequency, gainDB: point.gainDB - correction)
        }
    }
}

enum MicCalibrationError: Error, LocalizedError {
    case invalidFormat(lineNumber: Int, line: String)
    case invalidNumber(lineNumber: Int, line: String)
    case invalidFrequency(lineNumber: Int, frequency: Double)
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let lineNumber, let line):
            return "Invalid format at line \(lineNumber): '\(line)'"
        case .invalidNumber(let lineNumber, let line):
            return "Invalid number at line \(lineNumber): '\(line)'"
        case .invalidFrequency(let lineNumber, let frequency):
            return "Invalid frequency at line \(lineNumber): \(frequency) Hz (must be positive)"
        case .emptyFile:
            return "Calibration file is empty"
        }
    }
}
