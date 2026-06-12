// TargetCurveLibrary.swift
// Built-in reference target curves for room correction.
// All curves expressed as (frequency Hz, gain dB) pairs, log-spaced.
// Reference: Harman International listening research (Olive et al. 2013).

import Foundation

struct TargetCurve: Sendable {
    let name: String
    let curve: [(frequency: Double, gainDB: Double)]
    let appliesToSubBandOnly: Bool
}

enum TargetCurveLibrary {

    /// Flat 0 dB reference. Use when no preference is set.
    static let flat: [(frequency: Double, gainDB: Double)] = [
        (20, 0), (20_000, 0)
    ]

    /// Harman over-ear target. Shelved bass rise, flat midrange, gentle treble fall.
    /// Suitable as a room correction target for in-room speaker measurements.
    static let harmanRoom: [(frequency: Double, gainDB: Double)] = [
        (20, 6.5), (40, 5.0), (63, 4.0), (80, 3.5), (100, 3.0), (125, 2.5),
        (160, 2.0), (200, 1.5), (250, 1.0), (315, 0.5), (400, 0.0), (500, 0.0),
        (630, 0.0), (800, 0.0), (1000, 0.0), (1250, -0.3), (1600, -0.5),
        (2000, -0.8), (2500, -1.0), (3150, -1.5), (4000, -2.0), (5000, -2.5),
        (6300, -3.0), (8000, -3.5), (10000, -4.0), (12500, -4.5), (16000, -5.0),
        (20000, -6.0)
    ]

    /// B&K house curve: 3 dB/octave bass rise below 1 kHz.
    /// Commonly used in professional recording studio calibration.
    static let bkHouse: [(frequency: Double, gainDB: Double)] = [
        (20, 9.0), (63, 7.0), (200, 4.5), (630, 1.5), (1000, 0.0),
        (2000, 0.0), (5000, 0.0), (10000, 0.0), (20000, 0.0)
    ]

    /// Gentle home cinema shelf: slight bass warmth, slight air-band lift.
    static let homeTheater: [(frequency: Double, gainDB: Double)] = [
        (20, 3.0), (40, 2.5), (80, 2.0), (160, 1.0), (400, 0.0), (1000, 0.0),
        (4000, 0.0), (8000, 0.5), (12000, 1.0), (16000, 1.5), (20000, 2.0)
    ]

    /// X-Curve (SMPTE/ISO 2969 cinema reference): flat from 20 Hz–2 kHz,
    /// gentle roll-off above 2 kHz (−3 dB/octave from 2 kHz to 10 kHz region).
    static let xCurve: [(frequency: Double, gainDB: Double)] = [
        (20, 0), (40, 0), (63, 0), (80, 0), (100, 0), (125, 0),
        (160, 0), (200, 0), (250, 0), (315, 0), (400, 0), (500, 0),
        (630, 0), (800, 0), (1000, 0), (1250, 0), (1600, 0),
        (2000, 0), (2500, -1.5), (3150, -3.0), (4000, -4.5), (5000, -6.0),
        (6300, -7.5), (8000, -9.0), (10000, -10.5), (12500, -12.0), (16000, -13.5),
        (20000, -15.0)
    ]

    /// Sub-Only Target: curve defined and meaningful only below ~300 Hz.
    /// Flat with a small "room gain" rise toward 20 Hz (+3 dB at 20 Hz tapering to 0 dB at 80 Hz).
    /// Intended for use when correction is being computed/applied to the Part 2 sub band specifically.
    static let subOnly: [(frequency: Double, gainDB: Double)] = [
        (20, 3.0), (30, 2.5), (40, 2.0), (50, 1.5), (63, 1.0), (80, 0.0),
        (100, 0.0), (125, 0.0), (160, 0.0), (200, 0.0), (250, 0.0), (315, 0.0)
    ]

    static let allCurves: [TargetCurve] = [
        TargetCurve(name: "Flat", curve: flat, appliesToSubBandOnly: false),
        TargetCurve(name: "Harman room", curve: harmanRoom, appliesToSubBandOnly: false),
        TargetCurve(name: "B&K house", curve: bkHouse, appliesToSubBandOnly: false),
        TargetCurve(name: "Home theater", curve: homeTheater, appliesToSubBandOnly: false),
        TargetCurve(name: "X-Curve (cinema)", curve: xCurve, appliesToSubBandOnly: false),
        TargetCurve(name: "Sub-only", curve: subOnly, appliesToSubBandOnly: true)
    ]

    /// Helper to get curve by name (for backward compatibility).
    static func curve(named name: String) -> [(frequency: Double, gainDB: Double)]? {
        return allCurves.first(where: { $0.name == name })?.curve
    }
}
