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
