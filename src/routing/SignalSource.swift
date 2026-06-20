/// The set of named signals the DSP pipeline produces, available for output channel assignment.
///
/// Availability by active crossover band count:
///   bandCount = 1 (full-range): mainsLeft, mainsRight, subMono
///   bandCount = 2 (bi-amp):     mainsLeft*, mainsRight*, mainsLeftHigh, mainsLeftLow,
///                                mainsRightHigh, mainsRightLow, subMono
///   bandCount = 3 (tri-amp):    all of the above + mainsLeftMid, mainsRightMid
///
/// * In bi/tri-amp mode, mainsLeft and mainsRight remain available as
///   pre-crossover full-range signals (useful for recording or monitoring taps).
enum SignalSource: Int, Codable, Equatable, Sendable, CaseIterable {
    case mainsLeft      = 0
    case mainsRight     = 1
    case mainsLeftHigh  = 2
    case mainsLeftMid   = 3
    case mainsLeftLow   = 4
    case mainsRightHigh = 5
    case mainsRightMid  = 6
    case mainsRightLow  = 7
    case subMono        = 8

    var displayName: String {
        switch self {
        case .mainsLeft:      return "Mains Left"
        case .mainsRight:     return "Mains Right"
        case .mainsLeftHigh:  return "Left High"
        case .mainsLeftMid:   return "Left Mid"
        case .mainsLeftLow:   return "Left Low"
        case .mainsRightHigh: return "Right High"
        case .mainsRightMid:  return "Right Mid"
        case .mainsRightLow:  return "Right Low"
        case .subMono:        return "Sub Mono"
        }
    }

    /// True for band-split signals that require crossover to be in bi-amp or tri-amp mode.
    var requiresCrossover: Bool {
        switch self {
        case .mainsLeft, .mainsRight, .subMono:
            return false
        case .mainsLeftHigh, .mainsLeftMid, .mainsLeftLow,
             .mainsRightHigh, .mainsRightMid, .mainsRightLow:
            return true
        }
    }

    /// True for mid-band signals that require tri-amp mode specifically.
    var requiresTriAmp: Bool {
        self == .mainsLeftMid || self == .mainsRightMid
    }

    /// True when this source requires bass management to be enabled.
    var requiresBassManagement: Bool {
        self == .subMono
    }

    /// Whether this source carries a stereo pair natively.
    /// Only full-range mains sources are stereo; band signals are mono-per-side.
    var isStereoCapable: Bool {
        self == .mainsLeft || self == .mainsRight
    }
}
