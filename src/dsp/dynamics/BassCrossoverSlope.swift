// BassCrossoverSlope.swift
// Linkwitz-Riley crossover slope options for bass management.

import Foundation

enum BassCrossoverSlope: Int, Codable, Sendable, CaseIterable {
    case lr2 = 12   // 2 cascaded 1st-order Butterworth sections (12 dB/oct)
    case lr4 = 24   // 2 cascaded 2nd-order Butterworth sections (24 dB/oct)
    case lr8 = 48   // 4 cascaded 2nd-order Butterworth sections (48 dB/oct)

    var cascadedStageCount: Int {
        switch self {
        case .lr2: return 2   // Two cascaded 1st-order Butterworth sections
        case .lr4: return 2   // Two cascaded 2nd-order Butterworth sections
        case .lr8: return 4   // Four cascaded 2nd-order Butterworth sections
        }
    }
    var displayName: String { "LR\(rawValue / 12 * 2)" }  // "LR2", "LR4", "LR8"
}
