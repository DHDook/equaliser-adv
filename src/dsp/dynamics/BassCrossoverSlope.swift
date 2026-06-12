// BassCrossoverSlope.swift
// Linkwitz-Riley crossover slope options for bass management.

import Foundation

enum BassCrossoverSlope: Int, Codable, Sendable, CaseIterable {
    case lr2 = 12   // 1 cascaded Butterworth Q=0.7071 stage  (12 dB/oct)
    case lr4 = 24   // 2 cascaded Butterworth Q=0.7071 stages (24 dB/oct)
    case lr8 = 48   // 4 cascaded Butterworth Q=0.7071 stages (48 dB/oct)

    var cascadedStageCount: Int { rawValue / 12 }
    var displayName: String { "LR\(rawValue / 12 * 2)" }  // "LR2", "LR4", "LR8"
}
