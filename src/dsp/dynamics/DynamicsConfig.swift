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
}

// MARK: - Advanced Processing Configuration

/// Extended processing parameters covering spatial, spectral, system, and LTI features.
///
/// All parameters default to neutral / bypassed values and use `decodeIfPresent`
/// so presets saved before this struct existed load cleanly.
///
/// Live metrics (`highResDecouplingActive`) are computed at runtime and not persisted.
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

    // ── E. Inter-Channel Time Delay ───────────────────────────────────
    var stereoTimeDelayMS: Float = 0.0

    // ── F. DC Offset Filter ───────────────────────────────────────────
    var dcOffsetFilterEnabled: Bool = false

    // ── F. Delta Solo Monitoring ──────────────────────────────────────
    var deltaSoloActive: Bool = false

    // ── F. Latency Mode ───────────────────────────────────────────────
    var latencyMode: LatencyMode = .music

    // ── G. Dynamic Pause Gate ─────────────────────────────────────────
    var pauseGateEnabled: Bool = false

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

    /// Automatic Room Boundary Early Reflection Cancellation — FIR comb filter
    /// targeting the first-order floor/ceiling/wall reflection group.
    var earlyReflectionCancellationEnabled: Bool = false
    /// Estimated first reflection arrival time in milliseconds. Range: 5 – 50 ms. Default: 20 ms.
    var earlyReflectionRoomSizeMs: Float = 20.0

    /// HPF Phase Linearisation — all-pass FIR compensation network that linearises
    /// the group delay introduced by high-pass filter networks.
    var hpfPhaseLinearizationEnabled: Bool = false
    /// Target cutoff frequency for phase correction. Range: 20 – 200 Hz. Default: 80 Hz.
    var hpfPhaseLinearizationFrequencyHz: Float = 80.0

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

    /// Zero-Latency Convolution Reverb Engine — uniformly-partitioned FFT convolution
    /// applying a room impulse response with zero added latency.
    var zlConvolutionReverbEnabled: Bool = false
    /// Dry/wet mix ratio. Range: 0.0 (dry) – 1.0 (full wet). Default: 0.1.
    var zlConvolutionReverbMix: Float = 0.1

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
        case stereoTimeDelayMS
        case dcOffsetFilterEnabled
        case deltaSoloActive
        case latencyMode
        case pauseGateEnabled
        case stereoMode
        case hardwareSyncBufferEnabled
        case ditherMode
        // LTI Suite
        case symmetryBalanceEnabled
        case panningGainMatrixEnabled, panningCrossfeedAmount
        case linearDenoisingEnabled, linearDenoisingThresholdDB
        case speakerIRAlignmentEnabled, speakerIRDelayMs
        case crosstalkCancellationEnabled, crosstalkCancellationAmount
        case earlyReflectionCancellationEnabled, earlyReflectionRoomSizeMs
        case hpfPhaseLinearizationEnabled, hpfPhaseLinearizationFrequencyHz
        case multiSeatAveragingEnabled, multiSeatCount
        case subBassPhaseAlignmentEnabled, subBassAlignmentFrequencyHz
        case zlConvolutionReverbEnabled, zlConvolutionReverbMix
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
        limiterTruePeakGuardEnabled: Bool = false,
        stereoTimeDelayMS: Float = 0.0,
        dcOffsetFilterEnabled: Bool = false,
        deltaSoloActive: Bool = false,
        latencyMode: LatencyMode = .music,
        pauseGateEnabled: Bool = false,
        stereoMode: StereoModeSelection = .stereo,
        hardwareSyncBufferEnabled: Bool = false,
        ditherMode: DitherMode = .bypass,
        symmetryBalanceEnabled: Bool = false,
        panningGainMatrixEnabled: Bool = false,
        panningCrossfeedAmount: Float = 0.3,
        linearDenoisingEnabled: Bool = false,
        linearDenoisingThresholdDB: Float = -60.0,
        speakerIRAlignmentEnabled: Bool = false,
        speakerIRDelayMs: Float = 0.0,
        crosstalkCancellationEnabled: Bool = false,
        crosstalkCancellationAmount: Float = 0.5,
        earlyReflectionCancellationEnabled: Bool = false,
        earlyReflectionRoomSizeMs: Float = 20.0,
        hpfPhaseLinearizationEnabled: Bool = false,
        hpfPhaseLinearizationFrequencyHz: Float = 80.0,
        multiSeatAveragingEnabled: Bool = false,
        multiSeatCount: Int = 2,
        subBassPhaseAlignmentEnabled: Bool = false,
        subBassAlignmentFrequencyHz: Float = 80.0,
        zlConvolutionReverbEnabled: Bool = false,
        zlConvolutionReverbMix: Float = 0.1
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
        self.stereoTimeDelayMS                = stereoTimeDelayMS
        self.dcOffsetFilterEnabled            = dcOffsetFilterEnabled
        self.deltaSoloActive                  = deltaSoloActive
        self.latencyMode                      = latencyMode
        self.pauseGateEnabled                 = pauseGateEnabled
        self.stereoMode                       = stereoMode
        self.hardwareSyncBufferEnabled        = hardwareSyncBufferEnabled
        self.ditherMode                       = ditherMode
        self.symmetryBalanceEnabled           = symmetryBalanceEnabled
        self.panningGainMatrixEnabled         = panningGainMatrixEnabled
        self.panningCrossfeedAmount           = panningCrossfeedAmount
        self.linearDenoisingEnabled           = linearDenoisingEnabled
        self.linearDenoisingThresholdDB       = linearDenoisingThresholdDB
        self.speakerIRAlignmentEnabled        = speakerIRAlignmentEnabled
        self.speakerIRDelayMs                 = speakerIRDelayMs
        self.crosstalkCancellationEnabled     = crosstalkCancellationEnabled
        self.crosstalkCancellationAmount      = crosstalkCancellationAmount
        self.earlyReflectionCancellationEnabled = earlyReflectionCancellationEnabled
        self.earlyReflectionRoomSizeMs        = earlyReflectionRoomSizeMs
        self.hpfPhaseLinearizationEnabled     = hpfPhaseLinearizationEnabled
        self.hpfPhaseLinearizationFrequencyHz = hpfPhaseLinearizationFrequencyHz
        self.multiSeatAveragingEnabled        = multiSeatAveragingEnabled
        self.multiSeatCount                   = multiSeatCount
        self.subBassPhaseAlignmentEnabled     = subBassPhaseAlignmentEnabled
        self.subBassAlignmentFrequencyHz      = subBassAlignmentFrequencyHz
        self.zlConvolutionReverbEnabled       = zlConvolutionReverbEnabled
        self.zlConvolutionReverbMix           = zlConvolutionReverbMix
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
        stereoTimeDelayMS                = try c.decodeIfPresent(Float.self,                 forKey: .stereoTimeDelayMS)                ?? 0.0
        dcOffsetFilterEnabled            = try c.decodeIfPresent(Bool.self,                  forKey: .dcOffsetFilterEnabled)            ?? false
        deltaSoloActive                  = try c.decodeIfPresent(Bool.self,                  forKey: .deltaSoloActive)                  ?? false
        latencyMode                      = try c.decodeIfPresent(LatencyMode.self,           forKey: .latencyMode)                      ?? .music
        pauseGateEnabled                 = try c.decodeIfPresent(Bool.self,                  forKey: .pauseGateEnabled)                 ?? false
        stereoMode                       = try c.decodeIfPresent(StereoModeSelection.self,   forKey: .stereoMode)                       ?? .stereo
        hardwareSyncBufferEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .hardwareSyncBufferEnabled)        ?? false
        ditherMode                       = try c.decodeIfPresent(DitherMode.self,            forKey: .ditherMode)                       ?? .bypass
        symmetryBalanceEnabled           = try c.decodeIfPresent(Bool.self,                  forKey: .symmetryBalanceEnabled)           ?? false
        panningGainMatrixEnabled         = try c.decodeIfPresent(Bool.self,                  forKey: .panningGainMatrixEnabled)         ?? false
        panningCrossfeedAmount           = try c.decodeIfPresent(Float.self,                 forKey: .panningCrossfeedAmount)           ?? 0.3
        linearDenoisingEnabled           = try c.decodeIfPresent(Bool.self,                  forKey: .linearDenoisingEnabled)           ?? false
        linearDenoisingThresholdDB       = try c.decodeIfPresent(Float.self,                 forKey: .linearDenoisingThresholdDB)       ?? -60.0
        speakerIRAlignmentEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .speakerIRAlignmentEnabled)        ?? false
        speakerIRDelayMs                 = try c.decodeIfPresent(Float.self,                 forKey: .speakerIRDelayMs)                 ?? 0.0
        crosstalkCancellationEnabled     = try c.decodeIfPresent(Bool.self,                  forKey: .crosstalkCancellationEnabled)     ?? false
        crosstalkCancellationAmount      = try c.decodeIfPresent(Float.self,                 forKey: .crosstalkCancellationAmount)      ?? 0.5
        earlyReflectionCancellationEnabled = try c.decodeIfPresent(Bool.self,                forKey: .earlyReflectionCancellationEnabled) ?? false
        earlyReflectionRoomSizeMs        = try c.decodeIfPresent(Float.self,                 forKey: .earlyReflectionRoomSizeMs)        ?? 20.0
        hpfPhaseLinearizationEnabled     = try c.decodeIfPresent(Bool.self,                  forKey: .hpfPhaseLinearizationEnabled)     ?? false
        hpfPhaseLinearizationFrequencyHz = try c.decodeIfPresent(Float.self,                 forKey: .hpfPhaseLinearizationFrequencyHz) ?? 80.0
        multiSeatAveragingEnabled        = try c.decodeIfPresent(Bool.self,                  forKey: .multiSeatAveragingEnabled)        ?? false
        multiSeatCount                   = try c.decodeIfPresent(Int.self,                   forKey: .multiSeatCount)                   ?? 2
        subBassPhaseAlignmentEnabled     = try c.decodeIfPresent(Bool.self,                  forKey: .subBassPhaseAlignmentEnabled)     ?? false
        subBassAlignmentFrequencyHz      = try c.decodeIfPresent(Float.self,                 forKey: .subBassAlignmentFrequencyHz)      ?? 80.0
        zlConvolutionReverbEnabled       = try c.decodeIfPresent(Bool.self,                  forKey: .zlConvolutionReverbEnabled)       ?? false
        zlConvolutionReverbMix           = try c.decodeIfPresent(Float.self,                 forKey: .zlConvolutionReverbMix)           ?? 0.1
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
        try c.encode(stereoTimeDelayMS,                  forKey: .stereoTimeDelayMS)
        try c.encode(dcOffsetFilterEnabled,              forKey: .dcOffsetFilterEnabled)
        try c.encode(deltaSoloActive,                    forKey: .deltaSoloActive)
        try c.encode(latencyMode,                        forKey: .latencyMode)
        try c.encode(pauseGateEnabled,                   forKey: .pauseGateEnabled)
        try c.encode(stereoMode,                         forKey: .stereoMode)
        try c.encode(hardwareSyncBufferEnabled,          forKey: .hardwareSyncBufferEnabled)
        try c.encode(ditherMode,                         forKey: .ditherMode)
        try c.encode(symmetryBalanceEnabled,             forKey: .symmetryBalanceEnabled)
        try c.encode(panningGainMatrixEnabled,           forKey: .panningGainMatrixEnabled)
        try c.encode(panningCrossfeedAmount,             forKey: .panningCrossfeedAmount)
        try c.encode(linearDenoisingEnabled,             forKey: .linearDenoisingEnabled)
        try c.encode(linearDenoisingThresholdDB,         forKey: .linearDenoisingThresholdDB)
        try c.encode(speakerIRAlignmentEnabled,          forKey: .speakerIRAlignmentEnabled)
        try c.encode(speakerIRDelayMs,                   forKey: .speakerIRDelayMs)
        try c.encode(crosstalkCancellationEnabled,       forKey: .crosstalkCancellationEnabled)
        try c.encode(crosstalkCancellationAmount,        forKey: .crosstalkCancellationAmount)
        try c.encode(earlyReflectionCancellationEnabled, forKey: .earlyReflectionCancellationEnabled)
        try c.encode(earlyReflectionRoomSizeMs,          forKey: .earlyReflectionRoomSizeMs)
        try c.encode(hpfPhaseLinearizationEnabled,       forKey: .hpfPhaseLinearizationEnabled)
        try c.encode(hpfPhaseLinearizationFrequencyHz,   forKey: .hpfPhaseLinearizationFrequencyHz)
        try c.encode(multiSeatAveragingEnabled,          forKey: .multiSeatAveragingEnabled)
        try c.encode(multiSeatCount,                     forKey: .multiSeatCount)
        try c.encode(subBassPhaseAlignmentEnabled,       forKey: .subBassPhaseAlignmentEnabled)
        try c.encode(subBassAlignmentFrequencyHz,        forKey: .subBassAlignmentFrequencyHz)
        try c.encode(zlConvolutionReverbEnabled,         forKey: .zlConvolutionReverbEnabled)
        try c.encode(zlConvolutionReverbMix,             forKey: .zlConvolutionReverbMix)
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
    /// Advanced / extended processing parameters (sections A–J including LTI suite).
    var advanced:            AdvancedProcessingConfig   = .default

    static let `default` = DynamicsConfig()

    private enum CodingKeys: String, CodingKey {
        case stereoWidener, loudnessMatch, deEsser, multibandCompressor
        case compressor, expander, softClipper, limiter, advanced
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
        try c.encode(advanced,            forKey: .advanced)
    }
}
