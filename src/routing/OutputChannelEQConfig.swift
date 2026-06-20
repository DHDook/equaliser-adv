import Foundation

/// Which EQ features are available for an output channel.
/// Derived from the channel's SignalSource. Not user-configurable.
struct OutputChannelEQCapabilities: Sendable {
    /// Whether stereo independent and mid-side channel modes are available.
    let supportsChannelModes: Bool
    /// Whether linear-phase and mixed-phase modes are available.
    let supportsAdvancedPhase: Bool
    /// Whether delta (difference) monitoring mode is available.
    let supportsDeltaMode: Bool
    /// Maximum number of EQ bands.
    let maxBands: Int

    static func capabilities(for source: SignalSource) -> OutputChannelEQCapabilities {
        switch source {
        case .mainsLeft, .mainsRight:
            return OutputChannelEQCapabilities(
                supportsChannelModes: true,
                supportsAdvancedPhase: true,
                supportsDeltaMode: true,
                maxBands: EQConfiguration.maxBandCount   // 64
            )
        case .mainsLeftHigh, .mainsLeftMid, .mainsLeftLow,
             .mainsRightHigh, .mainsRightMid, .mainsRightLow:
            return OutputChannelEQCapabilities(
                supportsChannelModes: false,   // mono-per-side; no M-S
                supportsAdvancedPhase: true,
                supportsDeltaMode: true,
                maxBands: EQConfiguration.maxBandCount   // 64
            )
        case .subMono:
            return OutputChannelEQCapabilities(
                supportsChannelModes: false,
                supportsAdvancedPhase: false,
                supportsDeltaMode: false,
                maxBands: 16   // matches AGENT_SUB_EQ_SPEC.md
            )
        }
    }
}

/// Full per-output EQ configuration for one output channel.
/// Mirrors EqualiserStore's EQ state model exactly for stereo-capable sources.
struct OutputChannelEQConfig: Codable, Sendable {

    // MARK: - Band Configuration
    /// Active band count. Range 1...maxBands (determined by OutputChannelEQCapabilities).
    var activeBandCount: Int = 10
    /// Band definitions. Always sized to EQConfiguration.maxBandCount (64).
    /// Bands beyond activeBandCount are inactive but stored.
    var bands: [EQBandConfiguration] = EQConfiguration.defaultBands()

    // MARK: - Gain
    /// Pre-EQ input gain trim (dB). Range: –24…+24.
    var inputGainDB: Float = 0.0
    /// Post-EQ output gain trim (dB). Range: –24…+24.
    var outputGainDB: Float = 0.0

    // MARK: - Mode
    /// How L and R are processed. Restricted by OutputChannelEQCapabilities.supportsChannelModes.
    var channelMode: ChannelMode = .linked

    /// EQ processing and monitoring mode. Mirrors CompareMode exactly:
    ///   .eq         → standard IIR biquad processing
    ///   .linearEQ   → linear-phase FIR (supportsAdvancedPhase only)
    ///   .flat       → gains only; EQ bypassed for A/B comparison
    ///   .delta      → difference signal: post-EQ minus pre-EQ (supportsDeltaMode only)
    ///   .mixedPhase → IIR biquad + all-pass phase complement (supportsAdvancedPhase only)
    var compareMode: CompareMode = .eq

    // MARK: - Phase Shaping
    /// Pre-ringing blend control for linear-phase EQ mode (0.0–1.0).
    /// 0.0 = pure linear-phase (maximum pre-ringing, zero group delay error).
    /// 1.0 = pure minimum-phase (zero pre-ringing, some group delay error).
    /// 0.5 = balanced (Acourate "Natural Phase" equivalent).
    /// Only active when compareMode == .linearEQ.
    /// Ignored in all other modes (IIR, mixed phase, flat, delta).
    /// Default: 0.0 (pure linear-phase — existing behaviour preserved).
    var preRingingBlend: Float = 0.0   // Range: 0.0–1.0

    // MARK: - Bypass
    /// Global EQ bypass for this output channel. When true, equivalent to processingMode = 0.
    var isBypassed: Bool = false

    // MARK: - FIR Crossover Interaction
    /// Set by the pipeline when the output channel's crossover filter uses firLinearPhase type.
    /// NOT stored in presets — derived from ActiveCrossoverConfig at runtime.
    /// When true, the UI recommends linear-phase EQ mode and updateProcessingMode
    /// automatically defaults new channels to .linearEQ if compareMode was .eq (the factory default).
    /// The user can override this recommendation at any time.
    var firCrossoverIsActive: Bool = false

    static let `default` = OutputChannelEQConfig()

    private enum CodingKeys: String, CodingKey {
        case activeBandCount, bands
        case inputGainDB, outputGainDB
        case channelMode, compareMode
        case preRingingBlend, isBypassed
        case firCrossoverIsActive
    }

    init(
        activeBandCount: Int = 10,
        bands: [EQBandConfiguration] = EQConfiguration.defaultBands(),
        inputGainDB: Float = 0.0,
        outputGainDB: Float = 0.0,
        channelMode: ChannelMode = .linked,
        compareMode: CompareMode = .eq,
        preRingingBlend: Float = 0.0,
        isBypassed: Bool = false,
        firCrossoverIsActive: Bool = false
    ) {
        self.activeBandCount = activeBandCount
        self.bands = bands
        self.inputGainDB = inputGainDB
        self.outputGainDB = outputGainDB
        self.channelMode = channelMode
        self.compareMode = compareMode
        self.preRingingBlend = preRingingBlend
        self.isBypassed = isBypassed
        self.firCrossoverIsActive = firCrossoverIsActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeBandCount = try c.decodeIfPresent(Int.self, forKey: .activeBandCount) ?? 10
        bands = try c.decodeIfPresent([EQBandConfiguration].self, forKey: .bands) ?? EQConfiguration.defaultBands()
        inputGainDB = try c.decodeIfPresent(Float.self, forKey: .inputGainDB) ?? 0.0
        outputGainDB = try c.decodeIfPresent(Float.self, forKey: .outputGainDB) ?? 0.0
        channelMode = try c.decodeIfPresent(ChannelMode.self, forKey: .channelMode) ?? .linked
        compareMode = try c.decodeIfPresent(CompareMode.self, forKey: .compareMode) ?? .eq
        preRingingBlend = try c.decodeIfPresent(Float.self, forKey: .preRingingBlend) ?? 0.0
        isBypassed = try c.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        firCrossoverIsActive = try c.decodeIfPresent(Bool.self, forKey: .firCrossoverIsActive) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(activeBandCount, forKey: .activeBandCount)
        try c.encode(bands, forKey: .bands)
        try c.encode(inputGainDB, forKey: .inputGainDB)
        try c.encode(outputGainDB, forKey: .outputGainDB)
        try c.encode(channelMode, forKey: .channelMode)
        try c.encode(compareMode, forKey: .compareMode)
        try c.encode(preRingingBlend, forKey: .preRingingBlend)
        try c.encode(isBypassed, forKey: .isBypassed)
        try c.encode(firCrossoverIsActive, forKey: .firCrossoverIsActive)
    }
}
