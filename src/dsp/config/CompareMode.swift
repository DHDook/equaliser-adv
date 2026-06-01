import Foundation

/// Compare mode for EQ vs Flat vs Delta comparison.
enum CompareMode: Int, Codable, Sendable {
    case eq = 0
    case flat = 1
    case delta = 2
}
