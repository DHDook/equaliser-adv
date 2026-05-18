/// Filter slope in dB per octave.
///
/// Applies to Low Pass, High Pass, Low Shelf, and High Shelf filter types only.
/// For other filter types the slope setting is hidden and has no effect.
///
/// Slopes map to filter orders and vDSP section counts:
///
///    6 dB/oct →  1st-order  (1 degenerate biquad,  b2=a2=0)
///   12 dB/oct →  2nd-order  (1 biquad section)  ← default
///   18 dB/oct →  3rd-order  (1 degenerate + 1 biquad = 2 sections)
///   24 dB/oct →  4th-order  (2 Butterworth biquad sections)
///   36 dB/oct →  6th-order  (3 Butterworth biquad sections)
///   48 dB/oct →  8th-order  (4 Butterworth biquad sections)
///   60 dB/oct → 10th-order  (5 Butterworth biquad sections)
///   72 dB/oct → 12th-order  (6 Butterworth biquad sections)
///   84 dB/oct → 14th-order  (7 Butterworth biquad sections)
///   96 dB/oct → 16th-order  (8 Butterworth biquad sections)
///
/// For 18 dB/oct the first vDSP section is a first-order bilinear stage (b2=a2=0).
/// All other even-order slopes use cascaded 2nd-order Butterworth sections.
enum FilterSlope: Int, Codable, Sendable, CaseIterable {
    case db6  =  6
    case db12 = 12
    case db18 = 18
    case db24 = 24
    case db36 = 36
    case db48 = 48
    case db60 = 60
    case db72 = 72
    case db84 = 84
    case db96 = 96

    // MARK: - Display

    var displayName: String {
        switch self {
        case .db6:  return "6 dB/oct"
        case .db12: return "12 dB/oct"
        case .db18: return "18 dB/oct"
        case .db24: return "24 dB/oct"
        case .db36: return "36 dB/oct"
        case .db48: return "48 dB/oct"
        case .db60: return "60 dB/oct"
        case .db72: return "72 dB/oct"
        case .db84: return "84 dB/oct"
        case .db96: return "96 dB/oct"
        }
    }

    // MARK: - Section Count

    /// Number of vDSP biquad sections required to implement this slope.
    ///
    /// For 18 dB/oct this is 2 (one degenerate first-order biquad plus one full biquad).
    /// For all other slopes every section is a full 2nd-order biquad section.
    var sectionCount: Int {
        switch self {
        case .db6:  return 1
        case .db12: return 1
        case .db18: return 2
        case .db24: return 2
        case .db36: return 3
        case .db48: return 4
        case .db60: return 5
        case .db72: return 6
        case .db84: return 7
        case .db96: return 8
        }
    }

    // MARK: - First-Order Stage Flag

    /// Whether this slope requires a first-order (degenerate) leading biquad section.
    ///
    /// Only true for 18 dB/oct (3rd-order Butterworth = 1 real pole + 1 complex pair).
    var hasFirstOrderSection: Bool { self == .db18 }

    // MARK: - Butterworth Q Values

    /// Per-section Butterworth Q values for the full (2nd-order) biquad sections.
    ///
    /// For an N-th order even Butterworth filter the Q for the k-th section is:
    ///   Q_k = 1 / (2 * sin((2k − 1) * π / (2N)))   for k = 1 … N/2
    ///
    /// For 18 dB/oct (N=3, odd) only the single 2nd-order biquad section Q is listed;
    /// the real pole at s = −1 is handled separately as a first-order stage.
    ///
    /// For 6 dB/oct and 12 dB/oct the coefficient generation does not use this array;
    /// it is provided solely for documentation purposes.
    var butterworthQValues: [Double] {
        switch self {
        case .db6:
            // 1st-order bilinear — Q concept not applicable.
            return []
        case .db12:
            // N=2: Q = 1/(2*sin(π/4)) = 1/√2
            return [0.7071067811865476]
        case .db18:
            // N=3 (odd): one 2nd-order section with Q = 1/(2*sin(π/6)) = 1.0
            // The real pole (s = −1) is handled as a separate first-order stage.
            return [1.0]
        case .db24:
            // N=4: Q1 = 1/(2*sin(π/8)) ≈ 1.3066, Q2 = 1/(2*sin(3π/8)) ≈ 0.5412
            return [1.3065629648763766, 0.5411961001063831]
        case .db36:
            // N=6: Qk = 1/(2*sin((2k-1)*π/12)) for k=1,2,3
            return [1.9318516525781366, 0.7071067811865476, 0.5176380902050415]
        case .db48:
            // N=8: Qk = 1/(2*sin((2k-1)*π/16)) for k=1..4
            return [2.5629154477415234, 0.8999762281654536, 0.6013439465698173, 0.5097955791041592]
        case .db60:
            // N=10: Qk = 1/(2*sin((2k-1)*π/20)) for k=1..5
            return [3.1962259073287085, 1.1013449070539657, 0.7071067811865476, 0.5612999964025339, 0.5062298069082916]
        case .db72:
            // N=12: Qk = 1/(2*sin((2k-1)*π/24)) for k=1..6
            return [3.8306484547982773, 1.3065629648763766, 0.8212919696742839, 0.6302496339381047, 0.5411961001063831, 0.5043220319939120]
        case .db84:
            // N=14: Qk = 1/(2*sin((2k-1)*π/28)) for k=1..7
            return [4.4659891128666992, 1.5136360096692250, 0.9398, 0.7071067811865476, 0.5905050432339680, 0.5297009572778681, 0.5031853805751070]
        case .db96:
            // N=16: Qk = 1/(2*sin((2k-1)*π/32)) for k=1..8
            return [5.1011486098630017, 1.7220969783732432, 1.0606776859903474, 0.7882050745097978, 0.6470562023040590, 0.5666704095975735, 0.5224556713627717, 0.5024192098842882]
        }
    }

    // MARK: - Support Check

    /// Whether slope control is meaningful for a given filter type.
    static func isSupported(for filterType: FilterType) -> Bool {
        switch filterType {
        case .lowPass, .highPass, .lowShelf, .highShelf:
            return true
        default:
            return false
        }
    }
}
