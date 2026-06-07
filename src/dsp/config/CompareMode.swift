import Foundation

/// Compare mode for EQ vs Flat vs Delta comparison.
enum CompareMode: Int, Codable, Sendable {
    case eq = 0
    case linearEQ = 1
    case flat = 2
    case delta = 3
    case mixedPhase = 4
}
