import Foundation

// MARK: - Crossover Slope

/// Linkwitz-Riley crossover slope for the multiband compressor.
enum CrossoverSlope: Int, Codable, Equatable, Sendable {
    /// 4th-order LR (24 dB/oct) — two cascaded 2nd-order Butterworth stages.
    case gentle = 0
    /// 8th-order LR (48 dB/oct) — four cascaded 2nd-order Butterworth stages.
    case steep  = 1
}

// MARK: - De-Esser Configuration

/// Configuration for the frequency-selective de-esser.
struct DeEsserConfig: Codable, Equatable, Sendable {
    var isEnabled:   Bool  = false
    var frequencyHz: Float = 6000.0
    var thresholdDB: Float = -20.0

    static let `default` = DeEsserConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, frequencyHz, thresholdDB
    }

    init(isEnabled: Bool = false, frequencyHz: Float = 6000.0, thresholdDB: Float = -20.0) {
        self.isEnabled   = isEnabled
        self.frequencyHz = frequencyHz
        self.thresholdDB = thresholdDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)   ?? false
        frequencyHz = try c.decodeIfPresent(Float.self, forKey: .frequencyHz) ?? 6000.0
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -20.0
    }
}

// MARK: - Multiband Compressor Configuration

/// Configuration for the three-band Linkwitz-Riley multiband compressor.
struct MultibandCompressorConfig: Codable, Equatable, Sendable {
    var isEnabled:       Bool            = false
    var crossLowMidHz:   Float           = 150.0
    var crossMidHighHz:  Float           = 3000.0
    var thresholdLowDB:  Float           = 0.0
    var thresholdMidDB:  Float           = 0.0
    var thresholdHighDB: Float           = 0.0
    /// Slope for the Low/Mid crossover. Default: gentle (LR4, 24 dB/oct).
    var slopeLowMid:     CrossoverSlope  = .gentle
    /// Slope for the Mid/High crossover. Default: gentle (LR4, 24 dB/oct).
    var slopeMidHigh:    CrossoverSlope  = .gentle

    static let `default` = MultibandCompressorConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, crossLowMidHz, crossMidHighHz
        case thresholdLowDB, thresholdMidDB, thresholdHighDB
        case slopeLowMid, slopeMidHigh
    }

    init(
        isEnabled: Bool = false,
        crossLowMidHz: Float = 150.0,
        crossMidHighHz: Float = 3000.0,
        thresholdLowDB: Float = 0.0,
        thresholdMidDB: Float = 0.0,
        thresholdHighDB: Float = 0.0,
        slopeLowMid: CrossoverSlope = .gentle,
        slopeMidHigh: CrossoverSlope = .gentle
    ) {
        self.isEnabled       = isEnabled
        self.crossLowMidHz   = crossLowMidHz
        self.crossMidHighHz  = crossMidHighHz
        self.thresholdLowDB  = thresholdLowDB
        self.thresholdMidDB  = thresholdMidDB
        self.thresholdHighDB = thresholdHighDB
        self.slopeLowMid     = slopeLowMid
        self.slopeMidHigh    = slopeMidHigh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled       = try c.decodeIfPresent(Bool.self,           forKey: .isEnabled)       ?? false
        crossLowMidHz   = try c.decodeIfPresent(Float.self,          forKey: .crossLowMidHz)   ?? 150.0
        crossMidHighHz  = try c.decodeIfPresent(Float.self,          forKey: .crossMidHighHz)  ?? 3000.0
        thresholdLowDB  = try c.decodeIfPresent(Float.self,          forKey: .thresholdLowDB)  ?? 0.0
        thresholdMidDB  = try c.decodeIfPresent(Float.self,          forKey: .thresholdMidDB)  ?? 0.0
        thresholdHighDB = try c.decodeIfPresent(Float.self,          forKey: .thresholdHighDB) ?? 0.0
        slopeLowMid     = try c.decodeIfPresent(CrossoverSlope.self, forKey: .slopeLowMid)     ?? .gentle
        slopeMidHigh    = try c.decodeIfPresent(CrossoverSlope.self, forKey: .slopeMidHigh)    ?? .gentle
    }
}

// MARK: - Compressor Configuration

/// Configuration for the wideband feed-forward compressor.
struct CompressorConfig: Codable, Equatable, Sendable {
    var isEnabled:      Bool  = false
    var thresholdDB:    Float = -16.0
    var ratio:          Float = 3.5
    var attackMs:       Float = 25.0
    var releaseMs:      Float = 150.0
    var makeupGainDB:   Float = 2.5
    /// Soft-knee transition width in dB. 0 = hard knee, 20 = maximum soft-knee.
    /// Default: 6.0 dB.
    var kneeWidthDB:    Float = 6.0

    static let `default` = CompressorConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, thresholdDB, ratio, attackMs, releaseMs, makeupGainDB, kneeWidthDB
    }

    init(
        isEnabled: Bool = false,
        thresholdDB: Float = -16.0,
        ratio: Float = 3.5,
        attackMs: Float = 25.0,
        releaseMs: Float = 150.0,
        makeupGainDB: Float = 2.5,
        kneeWidthDB: Float = 6.0
    ) {
        self.isEnabled    = isEnabled
        self.thresholdDB  = thresholdDB
        self.ratio        = ratio
        self.attackMs     = attackMs
        self.releaseMs    = releaseMs
        self.makeupGainDB = makeupGainDB
        self.kneeWidthDB  = kneeWidthDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled    = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)    ?? false
        thresholdDB  = try c.decodeIfPresent(Float.self, forKey: .thresholdDB)  ?? -16.0
        ratio        = try c.decodeIfPresent(Float.self, forKey: .ratio)        ?? 3.5
        attackMs     = try c.decodeIfPresent(Float.self, forKey: .attackMs)     ?? 25.0
        releaseMs    = try c.decodeIfPresent(Float.self, forKey: .releaseMs)    ?? 150.0
        makeupGainDB = try c.decodeIfPresent(Float.self, forKey: .makeupGainDB) ?? 2.5
        kneeWidthDB  = try c.decodeIfPresent(Float.self, forKey: .kneeWidthDB)  ?? 6.0
    }
}

// MARK: - Expander Configuration

/// Configuration for the downward dynamic-range expander.
struct ExpanderConfig: Codable, Equatable, Sendable {
    var isEnabled:   Bool  = false
    var thresholdDB: Float = -35.0
    var ratio:       Float = 1.5
    var rangeDB:     Float = -12.0

    static let `default` = ExpanderConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, thresholdDB, ratio, rangeDB
    }

    init(isEnabled: Bool = false, thresholdDB: Float = -35.0, ratio: Float = 1.5, rangeDB: Float = -12.0) {
        self.isEnabled   = isEnabled
        self.thresholdDB = thresholdDB
        self.ratio       = ratio
        self.rangeDB     = rangeDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)   ?? false
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -35.0
        ratio       = try c.decodeIfPresent(Float.self, forKey: .ratio)       ?? 1.5
        rangeDB     = try c.decodeIfPresent(Float.self, forKey: .rangeDB)     ?? -12.0
    }
}

// MARK: - Soft Clipper Configuration

/// Configuration for the soft clipper wave-shaper stage.
struct SoftClipperConfig: Codable, Equatable, Sendable {
    var isEnabled:   Bool  = false
    var driveDB:     Float = 0.0
    var thresholdDB: Float = -1.5
    var kneeSmooth:  Float = 0.5

    static let `default` = SoftClipperConfig()
}

// MARK: - Brickwall Limiter Configuration

/// Configuration for the look-ahead brickwall limiter.
struct BrickwallLimiterConfig: Codable, Equatable, Sendable {
    var isEnabled:   Bool  = true
    var ceilingDB:   Float = -0.2
    var attackMs:    Float = 0.1
    var releaseMs:   Float = 20.0
    var lookAheadMs: Float = 2.0

    init(
        isEnabled: Bool = true,
        ceilingDB: Float = -0.2,
        attackMs: Float = 0.1,
        releaseMs: Float = 20.0,
        lookAheadMs: Float = 2.0
    ) {
        self.isEnabled   = isEnabled
        self.ceilingDB   = ceilingDB
        self.attackMs    = attackMs
        self.releaseMs   = releaseMs
        self.lookAheadMs = lookAheadMs
    }

    static let `default` = BrickwallLimiterConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, ceilingDB, attackMs, releaseMs, lookAheadMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)   ?? true
        ceilingDB   = try c.decodeIfPresent(Float.self, forKey: .ceilingDB)   ?? -0.2
        attackMs    = try c.decodeIfPresent(Float.self, forKey: .attackMs)    ?? 0.1
        releaseMs   = try c.decodeIfPresent(Float.self, forKey: .releaseMs)   ?? 20.0
        lookAheadMs = try c.decodeIfPresent(Float.self, forKey: .lookAheadMs) ?? 2.0
    }
}

// MARK: - Stereo Widener Configuration

/// Configuration for the three-band frequency-dependent stereo widener.
///
/// Uses hardcoded crossover frequencies of 200 Hz (Low/Mid) and 4000 Hz (Mid/High).
/// Width factors: 0 = pure mono, 1.0 = original stereo, 2.0 = maximum expansion.
struct StereoWidenerConfig: Codable, Equatable, Sendable {
    /// Whether the stereo widener is active. Default OFF.
    var isEnabled:      Bool  = false
    /// Low-band (< 200 Hz) width. Range: 0.0 (mono) – 1.0 (stereo). Default: 0.0 (mono bass).
    var widthFactorLow: Float = 0.0
    /// Mid-band (200 Hz – 4 kHz) width. Range: 1.0 – 2.0. Default: 1.4.
    var widthFactorMid: Float = 1.4
    /// High-band (> 4 kHz) width. Range: 1.0 – 2.0. Default: 1.25.
    var widthFactorHigh: Float = 1.25

    static let `default` = StereoWidenerConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, widthFactorLow, widthFactorMid, widthFactorHigh
    }

    init(
        isEnabled: Bool = false,
        widthFactorLow: Float = 0.0,
        widthFactorMid: Float = 1.4,
        widthFactorHigh: Float = 1.25
    ) {
        self.isEnabled      = isEnabled
        self.widthFactorLow  = widthFactorLow
        self.widthFactorMid  = widthFactorMid
        self.widthFactorHigh = widthFactorHigh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled       = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)       ?? false
        widthFactorLow  = try c.decodeIfPresent(Float.self, forKey: .widthFactorLow)  ?? 0.0
        widthFactorMid  = try c.decodeIfPresent(Float.self, forKey: .widthFactorMid)  ?? 1.4
        widthFactorHigh = try c.decodeIfPresent(Float.self, forKey: .widthFactorHigh) ?? 1.25
    }
}

// MARK: - Loudness Match Configuration

/// Configuration for real-time LUFS loudness matching.
struct LoudnessMatchConfig: Codable, Equatable, Sendable {
    /// Whether loudness matching is active. Default OFF.
    var isEnabled:        Bool  = false
    /// Target integrated loudness in LUFS. Range: −24 to −10 LUFS. Default: −16 LUFS.
    var targetLoudnessLUFS: Float = -16.0

    static let `default` = LoudnessMatchConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, targetLoudnessLUFS
    }

    init(isEnabled: Bool = false, targetLoudnessLUFS: Float = -16.0) {
        self.isEnabled          = isEnabled
        self.targetLoudnessLUFS = targetLoudnessLUFS
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled          = try c.decodeIfPresent(Bool.self,  forKey: .isEnabled)          ?? false
        targetLoudnessLUFS = try c.decodeIfPresent(Float.self, forKey: .targetLoudnessLUFS) ?? -16.0
    }
}

// MARK: - Stereo Mode Selection

/// Stereo fold-down mode applied before all other processing stages.
enum StereoModeSelection: Int, Codable, Equatable, Sendable {
    /// Full stereo signal passes through unchanged. Default.
    case stereo   = 0
    /// Mid-only signal sent to both channels (narrow / wide-mono).
    case wideMono = 1
    /// True mono: sum L+R halved, output identical on both channels.
    case trueMono = 2
}

// MARK: - Latency Mode

/// Optimisation target for audio processing latency.
enum LatencyMode: Int, Codable, Equatable, Sendable {
    /// Prioritise lowest possible latency (music production, monitoring).
    case music = 0
    /// Prioritise audio/video synchronisation (film, broadcast, streaming).
    case movie = 1
}

// MARK: - Dither Mode

/// Output dither algorithm applied as the final processing stage.
enum DitherMode: Int, Codable, Equatable, Sendable {
    /// No dither applied. Default.
    case bypass = 0
    /// Triangle PDF dither — minimum bias, 24-bit LSB noise floor.
    case tpdf   = 1
    /// Noise-shaped dither — perceptually weighted for 44.1 / 48 kHz.
    case shaped = 2
    /// 5th-order Wannamaker/Lipshitz psychoacoustic noise shaping — optimal for 44.1/48 kHz.
    case highOrder = 3
}

// MARK: - Target Curve Type

/// Target curve type for room correction EQ.
enum TargetCurveType: Int, Codable, Equatable, Sendable {
    case flat = 0
    case houseCurve = 1
    case customREW = 2
}

// MARK: - Bass Management Configuration

/// Unified bass management configuration for subwoofer integration.
/// Replaces the separate monoBassEnabled/mainsHighPassEnabled flags with a single coherent module.
struct BassManagementConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var crossoverHz: Float = 80.0  // Range: 40–200 Hz (allow down to 20 Hz for full-range mains)
    var slope: BassCrossoverSlope = .lr4
    var lowBandGainDB: Float = 0.0  // Sub trim — range ±12 dB
    var lowBandPolarityInverted: Bool = false
    var lowBandDelaySamples: Float = 0.0  // Fractional sample delay for subwoofer alignment
    var lowBandLowShelfEnabled: Bool = false  // Room-gain compensation shelf
    var lowBandLowShelfFreqHz: Float = 30.0  // Room-gain shelf frequency
    var lowBandLowShelfGainDB: Float = 0.0  // Room-gain shelf gain

    // Speaker/subwoofer distances for time alignment (Part 3)
    var leftSpeakerDistanceM: Float = 2.5
    var rightSpeakerDistanceM: Float = 2.5
    var subwooferDistanceM: Float = 2.5

    static let `default` = BassManagementConfig()

    private enum CodingKeys: String, CodingKey {
        case enabled, crossoverHz, slope, lowBandGainDB, lowBandPolarityInverted
        case lowBandDelaySamples, lowBandLowShelfEnabled, lowBandLowShelfFreqHz, lowBandLowShelfGainDB
        case leftSpeakerDistanceM, rightSpeakerDistanceM, subwooferDistanceM
    }

    init(
        enabled: Bool = false,
        crossoverHz: Float = 80.0,
        slope: BassCrossoverSlope = .lr4,
        lowBandGainDB: Float = 0.0,
        lowBandPolarityInverted: Bool = false,
        lowBandDelaySamples: Float = 0.0,
        lowBandLowShelfEnabled: Bool = false,
        lowBandLowShelfFreqHz: Float = 30.0,
        lowBandLowShelfGainDB: Float = 0.0,
        leftSpeakerDistanceM: Float = 2.5,
        rightSpeakerDistanceM: Float = 2.5,
        subwooferDistanceM: Float = 2.5
    ) {
        self.enabled = enabled
        self.crossoverHz = crossoverHz
        self.slope = slope
        self.lowBandGainDB = lowBandGainDB
        self.lowBandPolarityInverted = lowBandPolarityInverted
        self.lowBandDelaySamples = lowBandDelaySamples
        self.lowBandLowShelfEnabled = lowBandLowShelfEnabled
        self.lowBandLowShelfFreqHz = lowBandLowShelfFreqHz
        self.lowBandLowShelfGainDB = lowBandLowShelfGainDB
        self.leftSpeakerDistanceM = leftSpeakerDistanceM
        self.rightSpeakerDistanceM = rightSpeakerDistanceM
        self.subwooferDistanceM = subwooferDistanceM
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        crossoverHz = try c.decodeIfPresent(Float.self, forKey: .crossoverHz) ?? 80.0
        slope = try c.decodeIfPresent(BassCrossoverSlope.self, forKey: .slope) ?? .lr4
        lowBandGainDB = try c.decodeIfPresent(Float.self, forKey: .lowBandGainDB) ?? 0.0
        lowBandPolarityInverted = try c.decodeIfPresent(Bool.self, forKey: .lowBandPolarityInverted) ?? false
        lowBandDelaySamples = try c.decodeIfPresent(Float.self, forKey: .lowBandDelaySamples) ?? 0.0
        lowBandLowShelfEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowBandLowShelfEnabled) ?? false
        lowBandLowShelfFreqHz = try c.decodeIfPresent(Float.self, forKey: .lowBandLowShelfFreqHz) ?? 30.0
        lowBandLowShelfGainDB = try c.decodeIfPresent(Float.self, forKey: .lowBandLowShelfGainDB) ?? 0.0
        leftSpeakerDistanceM = try c.decodeIfPresent(Float.self, forKey: .leftSpeakerDistanceM) ?? 2.5
        rightSpeakerDistanceM = try c.decodeIfPresent(Float.self, forKey: .rightSpeakerDistanceM) ?? 2.5
        subwooferDistanceM = try c.decodeIfPresent(Float.self, forKey: .subwooferDistanceM) ?? 2.5
    }
}

// MARK: - Advanced Processing Configuration

/// Extended processing parameters covering spatial, spectral, system, and LTI features.
///
/// All parameters default to neutral / bypassed values and use `decodeIfPresent`
/// so presets saved before this struct existed load cleanly.
///
/// Live metrics (`highResDecouplingActive`) are computed at runtime and not persisted.

// MARK: - Pause Gate Preset

/// Named presets for the pause gate. Each preset supplies a complete set of parameter
/// values; selecting a preset overwrites the individual sliders.
enum PauseGatePreset: String, Codable, Equatable, Sendable, CaseIterable {
    /// Balanced default — suitable for most amplifiers and listening environments.
    case amplifierHiss = "Amplifier Hiss"
    /// Faster level detection and shorter hold — good for content with short silences.
    case sensitive     = "Sensitive"
    /// Slow response — minimises false triggers during very quiet passages.
    case relaxed       = "Relaxed"
    /// Quick open/close — intended for broadcast or voice-over monitoring.
    case broadcast     = "Broadcast"
    /// All controls set manually; preset picker shows Custom when values diverge.
    case custom        = "Custom"

    /// Returns the parameter bundle for this preset.
    /// `custom` returns nil — callers must read individual config fields instead.
    var parameters: PauseGateParameters? {
        switch self {
        case .amplifierHiss: return PauseGateParameters(
            thresholdDBFS: -60, holdMs: 500,  attackMs: 10,  releaseMs: 200, hysteresisDB: 3.0)
        case .sensitive:     return PauseGateParameters(
            thresholdDBFS: -50, holdMs: 300,  attackMs:  5,  releaseMs: 150, hysteresisDB: 2.0)
        case .relaxed:       return PauseGateParameters(
            thresholdDBFS: -70, holdMs: 1000, attackMs: 20,  releaseMs: 400, hysteresisDB: 4.0)
        case .broadcast:     return PauseGateParameters(
            thresholdDBFS: -55, holdMs: 200,  attackMs:  2,  releaseMs: 300, hysteresisDB: 6.0)
        case .custom:        return nil
        }
    }
}

/// Plain-value bundle used by `PauseGatePreset` and `AdvancedProcessingConfig`.
struct PauseGateParameters: Equatable, Sendable {
    var thresholdDBFS: Float  // −80 … −40 dBFS (RMS power reference)
    var holdMs:        Float  // 100 … 2000 ms — level-detector smoothing window
    var attackMs:      Float  //   1 … 100  ms — gain-envelope open speed (resume speed)
    var releaseMs:     Float  //  10 … 500  ms — gain-envelope close speed
    var hysteresisDB:  Float  //   0 …   6  dB — open/close threshold separation
}

// MARK: - Auto-Headroom Speed

/// Sets the time constant for the auto-headroom gain rider.
/// Governs how quickly the rider responds to changes in sustained limiting activity.
enum AutoHeadroomSpeed: String, Codable, Equatable, Sendable, CaseIterable {
    case fast   = "Fast"    // ~3 s time constant
    case medium = "Medium"  // ~10 s time constant
    case slow   = "Slow"    // ~30 s time constant

    /// Time constant in seconds used for both the GR accumulator and the gain smoother.
    var timeConstantSeconds: Double {
        switch self {
        case .fast:   return 3.0
        case .medium: return 10.0
        case .slow:   return 30.0
        }
    }
}

// MARK: - Denoiser Preset

/// Named noise-reduction operating points for the spectral denoiser.
/// Each preset encodes a paired noise-floor threshold and Wiener gain floor
/// so users choose by intent rather than by raw DSP parameters.
enum DenoiserPreset: String, Codable, Equatable, Sendable, CaseIterable {
    /// Minimal processing — passes almost all signal energy, only attenuates
    /// bins well below the noise floor. Best for clean sources or subtle hiss.
    case natural    = "Natural"
    /// Balanced default — effective hiss removal with no audible artefacts
    /// on music and speech. Matches the original fix defaults.
    case standard   = "Standard"
    /// Maximum suppression — pushes the noise floor lower and allows bins
    /// to be attenuated more deeply. May introduce slight residual smoothing
    /// on very transient material; best for heavily noise-contaminated sources.
    case aggressive = "Aggressive"

    /// Returns the `(noiseFloorDB, wienerFloor)` pair for this preset.
    /// `noiseFloorDB` feeds `setNoiseFloorDB(_:)` on the denoiser.
    /// `wienerFloor` feeds `setWienerFloor(_:)` on the denoiser.
    var parameters: (noiseFloorDB: Float, wienerFloor: Float) {
        switch self {
        case .natural:    return (noiseFloorDB: -55.0, wienerFloor: 0.05)
        case .standard:   return (noiseFloorDB: -60.0, wienerFloor: 0.01)
        case .aggressive: return (noiseFloorDB: -65.0, wienerFloor: 0.002)
        }
    }
}

struct AdvancedProcessingConfig: Codable, Equatable, Sendable {

    // ── A. High-Resolution Coefficient Decoupling ───────────────────────
    /// When enabled and sample rate exceeds 96 kHz, EQ coefficients are designed
    /// at a reference rate to avoid pole crowding. `highResDecouplingActive` reflects
    /// whether that path is currently engaged (runtime only).
    var coefficientDecouplingEnabled: Bool = true
    var highResDecouplingActive: Bool = false

    // ── B. Loudness Dialogue Gate ─────────────────────────────────────
    var loudnessDialogueGateEnabled: Bool = false

    // ── C. Clipper Phase Asymmetry Trim ───────────────────────────────
    var clipperAsymmetryTrimDB: Float = 0.0

    // ── D. Dynamic EQ Mode (De-Esser) ─────────────────────────────────
    var deesserDynamicModeEnabled: Bool = false

    // ── D. De-Harsh Tilt Filter ───────────────────────────────────────
    var deharshFilterEnabled: Bool = false
    var deharshTiltAmountDB: Float = -1.5

    // ── D. Stereo Balance Matrix ───────────────────────────────────────
    var stereoBalancePosition: Float = 0.0

    // ── E. Loudness Contouring ────────────────────────────────────────
    var loudnessContourEnabled: Bool = false

    // ── E. True-Peak Auto-Guard ───────────────────────────────────────
    var limiterTruePeakGuardEnabled: Bool = false

    // ── E. Auto-Headroom Gain Rider ───────────────────────────────────
    /// When enabled, slowly reduces the input to the soft clipper/limiter stage to keep
    /// sustained limiter gain reduction near `autoHeadroomTargetGRDB`.
    var autoHeadroomEnabled:      Bool              = false
    /// Target sustained limiter GR in dB. Range: 0.5 … 6.0. Default: 3.0.
    var autoHeadroomTargetGRDB:   Float             = 3.0
    /// Maximum gain reduction the rider may apply. Range: 3.0 … 12.0 dB. Default: 6.0.
    var autoHeadroomMaxReductionDB: Float           = 6.0
    /// Response time constant. Default: medium (10 s).
    var autoHeadroomSpeed:        AutoHeadroomSpeed = .medium

    // ── E. Inter-Channel Time Delay ───────────────────────────────────
    /// Signed delay in milliseconds: positive = delay R relative to L, negative = delay L relative to R.
    /// Range: ±20 ms (≈6.8 m / 22.4 ft of path difference at 343 m/s).
    var interChannelDelayMs: Float = 0.0

    // ── F. DC Offset Filter ───────────────────────────────────────────
    var dcOffsetFilterEnabled: Bool = false

    // ── F. Delta Solo Monitoring ──────────────────────────────────────
    var deltaSoloActive: Bool = false

    // ── F. Latency Mode ───────────────────────────────────────────────
    var latencyMode: LatencyMode = .music

    // ── G. Dynamic Pause Gate ─────────────────────────────────────────
    var pauseGateEnabled:        Bool             = false
    /// Active preset selection. Stored to disk; UI reads this to keep the picker in sync.
    var pauseGatePreset:         PauseGatePreset  = .amplifierHiss
    /// Silence threshold in dBFS (RMS power reference). Range: −80 … −40. Default: −60.
    var pauseGateThresholdDBFS:  Float            = -60.0
    /// Level-detector smoothing window in milliseconds. Range: 100 … 2000. Default: 500.
    var pauseGateHoldMs:         Float            = 500.0
    /// Gain-envelope open speed in milliseconds (resume speed). Range: 1 … 100. Default: 10.
    var pauseGateAttackMs:       Float            = 10.0
    /// Gain-envelope close speed in milliseconds. Range: 10 … 500. Default: 200.
    var pauseGateReleaseMs:      Float            = 200.0
    /// Open/close threshold separation in dB (prevents chatter). Range: 0 … 6. Default: 3.
    var pauseGateHysteresisDB:   Float            = 3.0

    // ── G. Stereo Mode Fold-Down ──────────────────────────────────────
    var stereoMode: StereoModeSelection = .stereo

    // ── H. Hardware Sync / Pre-Buffer Engine ──────────────────────────
    var hardwareSyncBufferEnabled: Bool = false

    // ── I. TPDF Dither Matrix ─────────────────────────────────────────
    var ditherMode: DitherMode = .bypass

    // ── J. LTI Processing Suite ──────────────────────────────────────
    /// Symmetry Balance — applies relative gain offsets to correct asymmetric
    /// listening positions. Uses the stereoBalancePosition slider for control.
    var symmetryBalanceEnabled: Bool = false

    /// Panning Gain Matrix — crossfeed matrix blending left/right channels
    /// by a configurable amount to simulate speaker crosstalk.
    var panningGainMatrixEnabled: Bool = false
    /// Crossfeed blend amount. Range: 0.0 (none) – 1.0 (full blend). Default: 0.3.
    var panningCrossfeedAmount: Float = 0.3

    /// Linear Denoising Engine — spectral subtraction noise floor reduction
    /// using a running estimate of the noise power spectrum.
    var linearDenoisingEnabled: Bool = false
    /// Noise floor threshold in dBFS. Range: −80 to −40. Default: −60 dB.
    var linearDenoisingThresholdDB: Float = -60.0
    /// Active denoiser operating-point preset.
    /// Seeds the noiseFloorDB and wienerFloor on the SpectralDenoiser.
    var linearDenoisingPreset: DenoiserPreset = .standard
    /// Noise reduction amount. Range: 0.0 (transparent) – 1.0 (maximum). Default: 0.5.
    var denoiserReductionAmount: Float = 0.5
    /// Denoiser FFT resolution mode. Default: .high.
    var denoiserMode: DenoiserMode = .high
    /// Whether a noise profile has been captured (vs adaptive mode).
    var denoiserHasCapturedProfile: Bool = false

    /// Speaker Impulse Response Alignment — applies fractional-sample delay
    /// compensation to time-align the acoustic centres of multi-driver systems.
    var speakerIRAlignmentEnabled: Bool = false
    /// Fine-delay offset in milliseconds. Range: 0 – 5 ms. Default: 0 ms.
    var speakerIRDelayMs: Float = 0.0

    /// Recursive Crosstalk Cancellation Matrix — iterative binaural inversion
    /// filter reducing inter-channel acoustic leakage.
    var crosstalkCancellationEnabled: Bool = false
    /// Cancellation depth. Range: 0.0 – 1.0. Default: 0.5.
    var crosstalkCancellationAmount: Float = 0.5

    /// Multi-Seat Complex Averaging — combines head-related transfer function
    /// estimates from multiple listening positions into a composite correction.
    var multiSeatAveragingEnabled: Bool = false
    /// Number of listening positions to average. Range: 1 – 8. Default: 2.
    var multiSeatCount: Int = 2

    /// Sub-Bass Phase Alignment — all-pass filter network that phase-aligns
    /// the sub-bass frequency region with the main speaker bandwidth.
    var subBassPhaseAlignmentEnabled: Bool = false
    /// Sub-bass crossover target. Range: 40 – 120 Hz. Default: 80 Hz.
    var subBassAlignmentFrequencyHz: Float = 80.0

    /// 4x Oversampling — upsamples audio by 4x before EQ and downsamples after EQ.
    /// Improves high-frequency response and reduces aliasing artifacts.
    var oversamplingEnabled: Bool = false

    /// Linear-Phase EQ Mode — uses FIR filters instead of IIR biquads for zero-phase distortion.
    /// Increases latency but eliminates phase warping from EQ bands.
    var linearPhaseEQEnabled: Bool = false

    /// Room Correction / Target Curve EQ — applies inverse filter to match a target response curve.
    /// Requires REW measurement import for accurate room correction.
    var roomCorrectionEnabled: Bool = false
    /// Target curve type: flat, house curve, or custom imported from REW.
    var targetCurveType: TargetCurveType = .flat

    /// Bass Management — unified subwoofer integration module.
    var bassManagement: BassManagementConfig = BassManagementConfig()

    /// Excess-Phase Correction — linear-phase FIR filter flattening group delay in modal region.
    var excessPhaseConfig: ExcessPhaseConfig = ExcessPhaseConfig()

    /// Mono Bass Summing — sums L+R below crossover frequency for subwoofer output.
    /// DEPRECATED: Migrated to bassManagement.enabled. Kept for backward compatibility only.
    var monoBassEnabled: Bool = false
    /// Mono bass crossover frequency in Hz. Range: 40 – 200 Hz. Default: 80 Hz.
    /// DEPRECATED: Migrated to bassManagement.crossoverHz. Kept for backward compatibility only.
    var monoBassCrossover: Float = 80.0

    /// Mains High-Pass Filter — removes sub-bass from main speakers when using subwoofer.
    /// DEPRECATED: Migrated to bassManagement.enabled. Kept for backward compatibility only.
    var mainsHighPassEnabled: Bool = false
    /// Mains high-pass crossover frequency in Hz. Range: 40 – 200 Hz. Default: 80 Hz.
    /// DEPRECATED: Migrated to bassManagement.crossoverHz. Kept for backward compatibility only.
    var mainsHighPassFrequency: Float = 80.0

    /// Volume-Dependent Loudness — adjusts loudness contour based on system volume.
    var volumeDependentLoudnessEnabled: Bool = false
    /// Listening level in phons at which system calibration was performed.
    /// At this volume, zero correction is applied. Range: 60–95 phons. Default: 83.
    var loudnessReferencePhon: Float = 83.0
    /// Volume scalar (0.0–1.0) that corresponds to the reference phon level.
    var loudnessReferenceVolume: Float = 0.85

    // MARK: - Codable

    static let `default` = AdvancedProcessingConfig()

    private enum CodingKeys: String, CodingKey {
        case loudnessDialogueGateEnabled
        case clipperAsymmetryTrimDB
        case deesserDynamicModeEnabled
        case coefficientDecouplingEnabled
        case deharshFilterEnabled, deharshTiltAmountDB
        case stereoBalancePosition
        case loudnessContourEnabled
        case limiterTruePeakGuardEnabled
        case autoHeadroomEnabled
        case autoHeadroomTargetGRDB
        case autoHeadroomMaxReductionDB
        case autoHeadroomSpeed
        case interChannelDelayMs
        case dcOffsetFilterEnabled
        case deltaSoloActive
        case latencyMode
        case pauseGateEnabled
        case pauseGatePreset
        case pauseGateThresholdDBFS
        case pauseGateHoldMs
        case pauseGateAttackMs
        case pauseGateReleaseMs
        case pauseGateHysteresisDB
        case stereoMode
        case hardwareSyncBufferEnabled
        case ditherMode
        case oversamplingEnabled
        case linearPhaseEQEnabled
        case roomCorrectionEnabled
        case targetCurveType
        case bassManagement
        case excessPhaseConfig
        case monoBassEnabled, monoBassCrossover
        case mainsHighPassEnabled, mainsHighPassFrequency
        case volumeDependentLoudnessEnabled, loudnessReferencePhon, loudnessReferenceVolume
        // LTI Suite
        case symmetryBalanceEnabled
        case panningGainMatrixEnabled, panningCrossfeedAmount
        case linearDenoisingEnabled, linearDenoisingThresholdDB, linearDenoisingPreset
        case denoiserReductionAmount, denoiserMode, denoiserHasCapturedProfile
        case speakerIRAlignmentEnabled, speakerIRDelayMs
        case crosstalkCancellationEnabled, crosstalkCancellationAmount
        case multiSeatAveragingEnabled, multiSeatCount
        case subBassPhaseAlignmentEnabled, subBassAlignmentFrequencyHz
        // highResDecouplingActive is not persisted (runtime-computed)
    }

    init(
        highResDecouplingActive: Bool = false,
        loudnessDialogueGateEnabled: Bool = false,
        clipperAsymmetryTrimDB: Float = 0.0,
        deesserDynamicModeEnabled: Bool = false,
        coefficientDecouplingEnabled: Bool = true,
        deharshFilterEnabled: Bool = false,
        deharshTiltAmountDB: Float = -1.5,
        stereoBalancePosition: Float = 0.0,
        loudnessContourEnabled: Bool = false,
        limiterTruePeakGuardEnabled:  Bool              = false,
        autoHeadroomEnabled:          Bool              = false,
        autoHeadroomTargetGRDB:       Float             = 3.0,
        autoHeadroomMaxReductionDB:   Float             = 6.0,
        autoHeadroomSpeed:            AutoHeadroomSpeed = .medium,
        interChannelDelayMs: Float = 0.0,
        dcOffsetFilterEnabled: Bool = false,
        deltaSoloActive: Bool = false,
        latencyMode: LatencyMode = .music,
        pauseGateEnabled:       Bool            = false,
        pauseGatePreset:        PauseGatePreset = .amplifierHiss,
        pauseGateThresholdDBFS: Float           = -60.0,
        pauseGateHoldMs:        Float           = 500.0,
        pauseGateAttackMs:      Float           = 10.0,
        pauseGateReleaseMs:     Float           = 200.0,
        pauseGateHysteresisDB:  Float           = 3.0,
        stereoMode: StereoModeSelection = .stereo,
        hardwareSyncBufferEnabled: Bool = false,
        ditherMode: DitherMode = .bypass,
        symmetryBalanceEnabled: Bool = false,
        panningGainMatrixEnabled: Bool = false,
        panningCrossfeedAmount: Float = 0.3,
        linearDenoisingEnabled: Bool = false,
        linearDenoisingThresholdDB: Float = -60.0,
        linearDenoisingPreset: DenoiserPreset = .standard,
        denoiserReductionAmount: Float = 0.5,
        denoiserMode: DenoiserMode = .high,
        denoiserHasCapturedProfile: Bool = false,
        speakerIRAlignmentEnabled: Bool = false,
        speakerIRDelayMs: Float = 0.0,
        crosstalkCancellationEnabled: Bool = false,
        crosstalkCancellationAmount: Float = 0.5,
        multiSeatAveragingEnabled: Bool = false,
        multiSeatCount: Int = 2,
        subBassPhaseAlignmentEnabled: Bool = false,
        subBassAlignmentFrequencyHz: Float = 80.0,
        oversamplingEnabled: Bool = false,
        linearPhaseEQEnabled: Bool = false,
        roomCorrectionEnabled: Bool = false,
        targetCurveType: TargetCurveType = .flat,
        bassManagement: BassManagementConfig = BassManagementConfig(),
        excessPhaseConfig: ExcessPhaseConfig = ExcessPhaseConfig(),
        monoBassEnabled: Bool = false,
        monoBassCrossover: Float = 80.0,
        mainsHighPassEnabled: Bool = false,
        mainsHighPassFrequency: Float = 80.0,
        volumeDependentLoudnessEnabled: Bool = false,
        loudnessReferencePhon: Float = 83.0,
        loudnessReferenceVolume: Float = 0.85
    ) {
        self.highResDecouplingActive          = highResDecouplingActive
        self.loudnessDialogueGateEnabled      = loudnessDialogueGateEnabled
        self.clipperAsymmetryTrimDB           = clipperAsymmetryTrimDB
        self.deesserDynamicModeEnabled        = deesserDynamicModeEnabled
        self.coefficientDecouplingEnabled     = coefficientDecouplingEnabled
        self.deharshFilterEnabled             = deharshFilterEnabled
        self.deharshTiltAmountDB              = deharshTiltAmountDB
        self.stereoBalancePosition            = stereoBalancePosition
        self.loudnessContourEnabled           = loudnessContourEnabled
        self.limiterTruePeakGuardEnabled      = limiterTruePeakGuardEnabled
        self.autoHeadroomEnabled              = autoHeadroomEnabled
        self.autoHeadroomTargetGRDB           = autoHeadroomTargetGRDB
        self.autoHeadroomMaxReductionDB       = autoHeadroomMaxReductionDB
        self.autoHeadroomSpeed                = autoHeadroomSpeed
        self.interChannelDelayMs              = interChannelDelayMs
        self.dcOffsetFilterEnabled            = dcOffsetFilterEnabled
        self.deltaSoloActive                  = deltaSoloActive
        self.latencyMode                      = latencyMode
        self.pauseGateEnabled                 = pauseGateEnabled
        self.pauseGatePreset                  = pauseGatePreset
        self.pauseGateThresholdDBFS           = pauseGateThresholdDBFS
        self.pauseGateHoldMs                  = pauseGateHoldMs
        self.pauseGateAttackMs                = pauseGateAttackMs
        self.pauseGateReleaseMs               = pauseGateReleaseMs
        self.pauseGateHysteresisDB            = pauseGateHysteresisDB
        self.stereoMode                       = stereoMode
        self.hardwareSyncBufferEnabled        = hardwareSyncBufferEnabled
        self.ditherMode                       = ditherMode
        self.symmetryBalanceEnabled           = symmetryBalanceEnabled
        self.panningGainMatrixEnabled         = panningGainMatrixEnabled
        self.panningCrossfeedAmount           = panningCrossfeedAmount
        self.linearDenoisingEnabled           = linearDenoisingEnabled
        self.linearDenoisingThresholdDB       = linearDenoisingThresholdDB
        self.linearDenoisingPreset           = linearDenoisingPreset
        self.denoiserReductionAmount          = denoiserReductionAmount
        self.denoiserMode                    = denoiserMode
        self.denoiserHasCapturedProfile      = denoiserHasCapturedProfile
        self.speakerIRAlignmentEnabled        = speakerIRAlignmentEnabled
        self.speakerIRDelayMs                 = speakerIRDelayMs
        self.crosstalkCancellationEnabled     = crosstalkCancellationEnabled
        self.crosstalkCancellationAmount      = crosstalkCancellationAmount
        self.multiSeatAveragingEnabled        = multiSeatAveragingEnabled
        self.multiSeatCount                   = multiSeatCount
        self.subBassPhaseAlignmentEnabled     = subBassPhaseAlignmentEnabled
        self.subBassAlignmentFrequencyHz      = subBassAlignmentFrequencyHz
        self.oversamplingEnabled              = oversamplingEnabled
        self.linearPhaseEQEnabled             = linearPhaseEQEnabled
        self.roomCorrectionEnabled            = roomCorrectionEnabled
        self.targetCurveType                  = targetCurveType
        self.bassManagement                   = bassManagement
        self.excessPhaseConfig               = excessPhaseConfig
        self.monoBassEnabled                  = monoBassEnabled
        self.monoBassCrossover                = monoBassCrossover
        self.mainsHighPassEnabled             = mainsHighPassEnabled
        self.mainsHighPassFrequency           = mainsHighPassFrequency
        self.volumeDependentLoudnessEnabled   = volumeDependentLoudnessEnabled
        self.loudnessReferencePhon            = loudnessReferencePhon
        self.loudnessReferenceVolume          = loudnessReferenceVolume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loudnessDialogueGateEnabled      = try c.decodeIfPresent(Bool.self,                  forKey: .loudnessDialogueGateEnabled)      ?? false
        clipperAsymmetryTrimDB           = try c.decodeIfPresent(Float.self,                 forKey: .clipperAsymmetryTrimDB)           ?? 0.0
        deesserDynamicModeEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .deesserDynamicModeEnabled)        ?? false
        coefficientDecouplingEnabled     = try c.decodeIfPresent(Bool.self,                  forKey: .coefficientDecouplingEnabled)     ?? true
        deharshFilterEnabled             = try c.decodeIfPresent(Bool.self,                  forKey: .deharshFilterEnabled)             ?? false
        deharshTiltAmountDB              = try c.decodeIfPresent(Float.self,                 forKey: .deharshTiltAmountDB)              ?? -1.5
        stereoBalancePosition            = try c.decodeIfPresent(Float.self,                 forKey: .stereoBalancePosition)            ?? 0.0
        loudnessContourEnabled           = try c.decodeIfPresent(Bool.self,                  forKey: .loudnessContourEnabled)           ?? false
        limiterTruePeakGuardEnabled      = try c.decodeIfPresent(Bool.self,                  forKey: .limiterTruePeakGuardEnabled)      ?? false
        autoHeadroomEnabled              = try c.decodeIfPresent(Bool.self,                  forKey: .autoHeadroomEnabled)              ?? false
        autoHeadroomTargetGRDB           = try c.decodeIfPresent(Float.self,                 forKey: .autoHeadroomTargetGRDB)           ?? 3.0
        autoHeadroomMaxReductionDB       = try c.decodeIfPresent(Float.self,                 forKey: .autoHeadroomMaxReductionDB)       ?? 6.0
        autoHeadroomSpeed                = try c.decodeIfPresent(AutoHeadroomSpeed.self,     forKey: .autoHeadroomSpeed)                ?? .medium
        interChannelDelayMs              = try c.decodeIfPresent(Float.self,                 forKey: .interChannelDelayMs)              ?? 0.0
        dcOffsetFilterEnabled            = try c.decodeIfPresent(Bool.self,                  forKey: .dcOffsetFilterEnabled)            ?? false
        deltaSoloActive                  = try c.decodeIfPresent(Bool.self,                  forKey: .deltaSoloActive)                  ?? false
        latencyMode                      = try c.decodeIfPresent(LatencyMode.self,           forKey: .latencyMode)                      ?? .music
        pauseGateEnabled                 = try c.decodeIfPresent(Bool.self,                  forKey: .pauseGateEnabled)                 ?? false
        pauseGatePreset                  = try c.decodeIfPresent(PauseGatePreset.self,        forKey: .pauseGatePreset)                  ?? .amplifierHiss
        pauseGateThresholdDBFS           = try c.decodeIfPresent(Float.self,                  forKey: .pauseGateThresholdDBFS)           ?? -60.0
        pauseGateHoldMs                  = try c.decodeIfPresent(Float.self,                  forKey: .pauseGateHoldMs)                  ?? 500.0
        pauseGateAttackMs                = try c.decodeIfPresent(Float.self,                  forKey: .pauseGateAttackMs)                ?? 10.0
        pauseGateReleaseMs               = try c.decodeIfPresent(Float.self,                  forKey: .pauseGateReleaseMs)               ?? 200.0
        pauseGateHysteresisDB            = try c.decodeIfPresent(Float.self,                  forKey: .pauseGateHysteresisDB)            ?? 3.0
        stereoMode                       = try c.decodeIfPresent(StereoModeSelection.self,   forKey: .stereoMode)                       ?? .stereo
        hardwareSyncBufferEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .hardwareSyncBufferEnabled)        ?? false
        ditherMode                       = try c.decodeIfPresent(DitherMode.self,            forKey: .ditherMode)                       ?? .bypass
        symmetryBalanceEnabled           = try c.decodeIfPresent(Bool.self,                  forKey: .symmetryBalanceEnabled)           ?? false
        panningGainMatrixEnabled         = try c.decodeIfPresent(Bool.self,                  forKey: .panningGainMatrixEnabled)         ?? false
        panningCrossfeedAmount           = try c.decodeIfPresent(Float.self,                 forKey: .panningCrossfeedAmount)           ?? 0.3
        linearDenoisingEnabled           = try c.decodeIfPresent(Bool.self,                  forKey: .linearDenoisingEnabled)           ?? false
        linearDenoisingThresholdDB       = try c.decodeIfPresent(Float.self,                 forKey: .linearDenoisingThresholdDB)       ?? -60.0
        linearDenoisingPreset           = try c.decodeIfPresent(DenoiserPreset.self,     forKey: .linearDenoisingPreset)           ?? .standard
        denoiserReductionAmount          = try c.decodeIfPresent(Float.self,                 forKey: .denoiserReductionAmount)          ?? 0.5
        denoiserMode                    = try c.decodeIfPresent(DenoiserMode.self,         forKey: .denoiserMode)                    ?? .high
        denoiserHasCapturedProfile      = try c.decodeIfPresent(Bool.self,                  forKey: .denoiserHasCapturedProfile)      ?? false
        speakerIRAlignmentEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .speakerIRAlignmentEnabled)        ?? false
        speakerIRDelayMs                 = try c.decodeIfPresent(Float.self,                 forKey: .speakerIRDelayMs)                 ?? 0.0
        crosstalkCancellationEnabled     = try c.decodeIfPresent(Bool.self,                  forKey: .crosstalkCancellationEnabled)     ?? false
        crosstalkCancellationAmount      = try c.decodeIfPresent(Float.self,                 forKey: .crosstalkCancellationAmount)      ?? 0.5
        multiSeatAveragingEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .multiSeatAveragingEnabled)        ?? false
        multiSeatCount                   = try c.decodeIfPresent(Int.self,                   forKey: .multiSeatCount)                   ?? 2
        subBassPhaseAlignmentEnabled     = try c.decodeIfPresent(Bool.self,                  forKey: .subBassPhaseAlignmentEnabled)     ?? false
        subBassAlignmentFrequencyHz      = try c.decodeIfPresent(Float.self,                 forKey: .subBassAlignmentFrequencyHz)      ?? 80.0
        oversamplingEnabled              = try c.decodeIfPresent(Bool.self,                  forKey: .oversamplingEnabled)              ?? false
        linearPhaseEQEnabled             = try c.decodeIfPresent(Bool.self,                  forKey: .linearPhaseEQEnabled)             ?? false
        roomCorrectionEnabled            = try c.decodeIfPresent(Bool.self,                  forKey: .roomCorrectionEnabled)            ?? false
        targetCurveType                  = try c.decodeIfPresent(TargetCurveType.self,       forKey: .targetCurveType)                  ?? .flat

        // Decode bassManagement first, then migrate legacy fields if present
        bassManagement                   = try c.decodeIfPresent(BassManagementConfig.self, forKey: .bassManagement) ?? BassManagementConfig()
        excessPhaseConfig               = try c.decodeIfPresent(ExcessPhaseConfig.self,    forKey: .excessPhaseConfig) ?? ExcessPhaseConfig()

        // Decode legacy fields for backward compatibility
        let legacyMonoBassEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .monoBassEnabled)                  ?? false
        let legacyMonoBassCrossover      = try c.decodeIfPresent(Float.self,                 forKey: .monoBassCrossover)                ?? 80.0
        let legacyMainsHighPassEnabled   = try c.decodeIfPresent(Bool.self,                  forKey: .mainsHighPassEnabled)             ?? false
        let legacyMainsHighPassFrequency = try c.decodeIfPresent(Float.self,                 forKey: .mainsHighPassFrequency)           ?? 80.0

        // Migration: if legacy fields are present and bassManagement is at default, migrate them
        if (legacyMonoBassEnabled || legacyMainsHighPassEnabled) && bassManagement.enabled == false {
            bassManagement.enabled = true
            // Prefer monoBassCrossover if both were set, otherwise use mainsHighPassFrequency
            bassManagement.crossoverHz = legacyMonoBassEnabled ? legacyMonoBassCrossover : legacyMainsHighPassFrequency
            bassManagement.slope = .lr4  // Default slope for migrated presets
        }

        // Store legacy fields for decode-only (not used by DynamicsProcessor)
        monoBassEnabled                  = legacyMonoBassEnabled
        monoBassCrossover                = legacyMonoBassCrossover
        mainsHighPassEnabled             = legacyMainsHighPassEnabled
        mainsHighPassFrequency           = legacyMainsHighPassFrequency

        volumeDependentLoudnessEnabled   = try c.decodeIfPresent(Bool.self,                  forKey: .volumeDependentLoudnessEnabled)   ?? false
        loudnessReferencePhon            = try c.decodeIfPresent(Float.self,                 forKey: .loudnessReferencePhon)            ?? 83.0
        loudnessReferenceVolume          = try c.decodeIfPresent(Float.self,                 forKey: .loudnessReferenceVolume)          ?? 0.85
        highResDecouplingActive          = false  // always computed at runtime
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(loudnessDialogueGateEnabled,        forKey: .loudnessDialogueGateEnabled)
        try c.encode(clipperAsymmetryTrimDB,             forKey: .clipperAsymmetryTrimDB)
        try c.encode(deesserDynamicModeEnabled,          forKey: .deesserDynamicModeEnabled)
        try c.encode(coefficientDecouplingEnabled,       forKey: .coefficientDecouplingEnabled)
        try c.encode(deharshFilterEnabled,               forKey: .deharshFilterEnabled)
        try c.encode(deharshTiltAmountDB,                forKey: .deharshTiltAmountDB)
        try c.encode(stereoBalancePosition,              forKey: .stereoBalancePosition)
        try c.encode(loudnessContourEnabled,             forKey: .loudnessContourEnabled)
        try c.encode(limiterTruePeakGuardEnabled,        forKey: .limiterTruePeakGuardEnabled)
        try c.encode(autoHeadroomEnabled,                forKey: .autoHeadroomEnabled)
        try c.encode(autoHeadroomTargetGRDB,             forKey: .autoHeadroomTargetGRDB)
        try c.encode(autoHeadroomMaxReductionDB,         forKey: .autoHeadroomMaxReductionDB)
        try c.encode(autoHeadroomSpeed,                  forKey: .autoHeadroomSpeed)
        try c.encode(interChannelDelayMs,                forKey: .interChannelDelayMs)
        try c.encode(dcOffsetFilterEnabled,              forKey: .dcOffsetFilterEnabled)
        try c.encode(deltaSoloActive,                    forKey: .deltaSoloActive)
        try c.encode(latencyMode,                        forKey: .latencyMode)
        try c.encode(pauseGateEnabled,                   forKey: .pauseGateEnabled)
        try c.encode(pauseGatePreset,                    forKey: .pauseGatePreset)
        try c.encode(pauseGateThresholdDBFS,             forKey: .pauseGateThresholdDBFS)
        try c.encode(pauseGateHoldMs,                    forKey: .pauseGateHoldMs)
        try c.encode(pauseGateAttackMs,                  forKey: .pauseGateAttackMs)
        try c.encode(pauseGateReleaseMs,                 forKey: .pauseGateReleaseMs)
        try c.encode(pauseGateHysteresisDB,              forKey: .pauseGateHysteresisDB)
        try c.encode(stereoMode,                         forKey: .stereoMode)
        try c.encode(hardwareSyncBufferEnabled,          forKey: .hardwareSyncBufferEnabled)
        try c.encode(ditherMode,                         forKey: .ditherMode)
        try c.encode(symmetryBalanceEnabled,             forKey: .symmetryBalanceEnabled)
        try c.encode(panningGainMatrixEnabled,           forKey: .panningGainMatrixEnabled)
        try c.encode(panningCrossfeedAmount,             forKey: .panningCrossfeedAmount)
        try c.encode(linearDenoisingEnabled,             forKey: .linearDenoisingEnabled)
        try c.encode(linearDenoisingThresholdDB,         forKey: .linearDenoisingThresholdDB)
        try c.encode(linearDenoisingPreset,             forKey: .linearDenoisingPreset)
        try c.encode(denoiserReductionAmount,            forKey: .denoiserReductionAmount)
        try c.encode(denoiserMode,                     forKey: .denoiserMode)
        try c.encode(denoiserHasCapturedProfile,       forKey: .denoiserHasCapturedProfile)
        try c.encode(speakerIRAlignmentEnabled,          forKey: .speakerIRAlignmentEnabled)
        try c.encode(speakerIRDelayMs,                   forKey: .speakerIRDelayMs)
        try c.encode(crosstalkCancellationEnabled,       forKey: .crosstalkCancellationEnabled)
        try c.encode(crosstalkCancellationAmount,        forKey: .crosstalkCancellationAmount)
        try c.encode(multiSeatAveragingEnabled,          forKey: .multiSeatAveragingEnabled)
        try c.encode(multiSeatCount,                     forKey: .multiSeatCount)
        try c.encode(subBassPhaseAlignmentEnabled,       forKey: .subBassPhaseAlignmentEnabled)
        try c.encode(subBassAlignmentFrequencyHz,        forKey: .subBassAlignmentFrequencyHz)
        try c.encode(oversamplingEnabled,                forKey: .oversamplingEnabled)
        try c.encode(linearPhaseEQEnabled,               forKey: .linearPhaseEQEnabled)
        try c.encode(roomCorrectionEnabled,              forKey: .roomCorrectionEnabled)
        try c.encode(targetCurveType,                    forKey: .targetCurveType)
        try c.encode(bassManagement,                     forKey: .bassManagement)
        try c.encode(excessPhaseConfig,                  forKey: .excessPhaseConfig)
        // Legacy fields (monoBassEnabled, monoBassCrossover, mainsHighPassEnabled, mainsHighPassFrequency)
        // are NOT encoded - they are decode-only for backward compatibility
        try c.encode(volumeDependentLoudnessEnabled,     forKey: .volumeDependentLoudnessEnabled)
        try c.encode(loudnessReferencePhon,              forKey: .loudnessReferencePhon)
        try c.encode(loudnessReferenceVolume,            forKey: .loudnessReferenceVolume)
    }
}

// MARK: - Combined Dynamics Configuration

/// Full dynamics configuration covering all processing stages.
///
/// Extended signal chain:
/// [Stereo Fold-Down] → [DC Offset Filter] → Stereo Widener → Loudness Match
/// → [Loudness Contour] → De-Esser → Multiband Compressor → Compressor
/// → Expander → Soft Clipper → [De-Harsh] → Brickwall Limiter
/// → [Balance + Time Delay] → [Pause Gate] → [TPDF Dither] → [Delta Solo]
/// → [LTI Suite: Symmetry Balance | Panning Matrix | Denoiser | IR Alignment
///    | Crosstalk Cancellation | Early Reflection | HPF Linearisation
///    | Multi-Seat Averaging | Sub-Bass Alignment | ZL Convolution Reverb].
///
/// All fields use `decodeIfPresent` so presets saved before a field was introduced
/// load cleanly and fall back to the safe neutral default for that stage.
struct DynamicsConfig: Codable, Equatable, Sendable {
    var stereoWidener:       StereoWidenerConfig       = .default
    var loudnessMatch:       LoudnessMatchConfig        = .default
    var deEsser:             DeEsserConfig              = .default
    var multibandCompressor: MultibandCompressorConfig  = .default
    var compressor:          CompressorConfig           = .default
    var expander:            ExpanderConfig             = .default
    var softClipper:         SoftClipperConfig          = .default
    var limiter:             BrickwallLimiterConfig      = .default
    /// L/R channel balance. Range: −1.0 (full left) … 0.0 (centre) … +1.0 (full right).
    /// At centre both channels output at 100%. Moving left fades right to 0%; moving right fades left to 0%.
    var channelBalance:      Float                      = 0.0
    /// Advanced / extended processing parameters (sections A–J including LTI suite).
    var advanced:            AdvancedProcessingConfig   = .default

    static let `default` = DynamicsConfig()

    private enum CodingKeys: String, CodingKey {
        case stereoWidener, loudnessMatch, deEsser, multibandCompressor
        case compressor, expander, softClipper, limiter, channelBalance, advanced
    }

    init(
        stereoWidener: StereoWidenerConfig = .default,
        loudnessMatch: LoudnessMatchConfig = .default,
        deEsser: DeEsserConfig = .default,
        multibandCompressor: MultibandCompressorConfig = .default,
        compressor: CompressorConfig = .default,
        expander: ExpanderConfig = .default,
        softClipper: SoftClipperConfig = .default,
        limiter: BrickwallLimiterConfig = .default,
        channelBalance: Float = 0.0,
        advanced: AdvancedProcessingConfig = .default
    ) {
        self.stereoWidener       = stereoWidener
        self.loudnessMatch       = loudnessMatch
        self.deEsser             = deEsser
        self.multibandCompressor = multibandCompressor
        self.compressor          = compressor
        self.expander            = expander
        self.softClipper         = softClipper
        self.limiter             = limiter
        self.channelBalance      = channelBalance
        self.advanced            = advanced
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stereoWidener       = try c.decodeIfPresent(StereoWidenerConfig.self,       forKey: .stereoWidener)       ?? .default
        loudnessMatch       = try c.decodeIfPresent(LoudnessMatchConfig.self,       forKey: .loudnessMatch)       ?? .default
        deEsser             = try c.decodeIfPresent(DeEsserConfig.self,             forKey: .deEsser)             ?? .default
        multibandCompressor = try c.decodeIfPresent(MultibandCompressorConfig.self, forKey: .multibandCompressor) ?? .default
        compressor          = try c.decodeIfPresent(CompressorConfig.self,          forKey: .compressor)          ?? .default
        expander            = try c.decodeIfPresent(ExpanderConfig.self,            forKey: .expander)            ?? .default
        softClipper         = try c.decodeIfPresent(SoftClipperConfig.self,         forKey: .softClipper)         ?? .default
        limiter             = try c.decodeIfPresent(BrickwallLimiterConfig.self,    forKey: .limiter)             ?? .default
        channelBalance      = try c.decodeIfPresent(Float.self,                    forKey: .channelBalance)      ?? 0.0
        advanced            = try c.decodeIfPresent(AdvancedProcessingConfig.self,  forKey: .advanced)            ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stereoWidener,       forKey: .stereoWidener)
        try c.encode(loudnessMatch,       forKey: .loudnessMatch)
        try c.encode(deEsser,             forKey: .deEsser)
        try c.encode(multibandCompressor, forKey: .multibandCompressor)
        try c.encode(compressor,          forKey: .compressor)
        try c.encode(expander,            forKey: .expander)
        try c.encode(softClipper,         forKey: .softClipper)
        try c.encode(limiter,             forKey: .limiter)
        try c.encode(channelBalance,      forKey: .channelBalance)
        try c.encode(advanced,            forKey: .advanced)
    }
}
