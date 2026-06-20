import Foundation

enum ValidationError: LocalizedError {
    case channelCountOutOfRange
    case duplicateChannelIDs
    case sourceRequiresCrossoverNotEnabled(activeCrossoverEnabled: Bool, source: SignalSource)
    case sourceRequiresBassManagementNotEnabled(bassManagementEnabled: Bool, source: SignalSource)
    case sourceRequiresTriAmpNotEnabled(bandCount: Int, source: SignalSource)
    case targetDeviceNotFound(deviceUID: String)
    case targetChannelIndicesInvalid(channelIndices: [Int])
    case gainTrimOutOfRange(min: Float, max: Float, actual: Float)
    case delayOutOfRange(min: Float, max: Float, actual: Float)
    case limiterCeilingOutOfRange(min: Float, max: Float, actual: Float)
    case limiterAttackOutOfRange(min: Float, max: Float, actual: Float)
    case limiterReleaseOutOfRange(min: Float, max: Float, actual: Float)
    case limiterLookAheadOutOfRange(min: Float, max: Float, actual: Float)

    var errorDescription: String? {
        switch self {
        case .channelCountOutOfRange:
            return "Channel count must be between \(OutputChannelMatrixConfig.minChannels) and \(OutputChannelMatrixConfig.maxChannels)"
        case .duplicateChannelIDs:
            return "Output channels must have unique IDs"
        case .sourceRequiresCrossoverNotEnabled(let enabled, let source):
            return "Source \(source.displayName) requires active crossover to be enabled (currently \(enabled))"
        case .sourceRequiresBassManagementNotEnabled(let enabled, let source):
            return "Source \(source.displayName) requires bass management to be enabled (currently \(enabled))"
        case .sourceRequiresTriAmpNotEnabled(let bandCount, let source):
            return "Source \(source.displayName) requires tri-amp mode (currently \(bandCount) bands)"
        case .targetDeviceNotFound(let deviceUID):
            return "Target device not found: \(deviceUID)"
        case .targetChannelIndicesInvalid(let channelIndices):
            return "Invalid channel indices: \(channelIndices)"
        case .gainTrimOutOfRange(let min, let max, let actual):
            return "Gain trim must be between \(min) and \(max) dB (actual: \(actual))"
        case .delayOutOfRange(let min, let max, let actual):
            return "Delay must be between \(min) and \(max) ms (actual: \(actual))"
        case .limiterCeilingOutOfRange(let min, let max, let actual):
            return "Limiter ceiling must be between \(min) and \(max) dB (actual: \(actual))"
        case .limiterAttackOutOfRange(let min, let max, let actual):
            return "Limiter attack must be between \(min) and \(max) ms (actual: \(actual))"
        case .limiterReleaseOutOfRange(let min, let max, let actual):
            return "Limiter release must be between \(min) and \(max) ms (actual: \(actual))"
        case .limiterLookAheadOutOfRange(let min, let max, let actual):
            return "Limiter look-ahead must be between \(min) and \(max) ms (actual: \(actual))"
        }
    }
}

struct OutputTarget: Codable, Equatable, Sendable {
    var deviceUID: String
    /// 1 or 2 channel indices (0-based) on the device.
    var channelIndices: [Int]
    var displayLabel: String

    private enum CodingKeys: String, CodingKey {
        case deviceUID, channelIndices, displayLabel
    }

    init(deviceUID: String = "", channelIndices: [Int] = [], displayLabel: String = "") {
        self.deviceUID = deviceUID
        self.channelIndices = channelIndices
        self.displayLabel = displayLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID) ?? ""
        channelIndices = try c.decodeIfPresent([Int].self, forKey: .channelIndices) ?? []
        displayLabel = try c.decodeIfPresent(String.self, forKey: .displayLabel) ?? ""
    }
}

struct OutputChannelLimiterConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool  = true
    var ceilingDB: Float = -0.2
    var attackMs: Float  = 0.1
    var releaseMs: Float = 20.0
    var lookAheadMs: Float = 2.0

    static let `default` = OutputChannelLimiterConfig()

    // Validation ranges
    static let minCeilingDB: Float = -60.0
    static let maxCeilingDB: Float = 0.0
    static let minAttackMs: Float = 0.01
    static let maxAttackMs: Float = 100.0
    static let minReleaseMs: Float = 1.0
    static let maxReleaseMs: Float = 1000.0
    static let minLookAheadMs: Float = 0.0
    static let maxLookAheadMs: Float = 10.0

    private enum CodingKeys: String, CodingKey {
        case isEnabled, ceilingDB, attackMs, releaseMs, lookAheadMs
    }

    init(isEnabled: Bool = true, ceilingDB: Float = -0.2, attackMs: Float = 0.1, releaseMs: Float = 20.0, lookAheadMs: Float = 2.0) {
        self.isEnabled = isEnabled
        self.ceilingDB = ceilingDB
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.lookAheadMs = lookAheadMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        ceilingDB = try c.decodeIfPresent(Float.self, forKey: .ceilingDB) ?? -0.2
        attackMs = try c.decodeIfPresent(Float.self, forKey: .attackMs) ?? 0.1
        releaseMs = try c.decodeIfPresent(Float.self, forKey: .releaseMs) ?? 20.0
        lookAheadMs = try c.decodeIfPresent(Float.self, forKey: .lookAheadMs) ?? 2.0
    }

    func validate() -> ValidationError? {
        if ceilingDB < Self.minCeilingDB || ceilingDB > Self.maxCeilingDB {
            return .limiterCeilingOutOfRange(min: Self.minCeilingDB, max: Self.maxCeilingDB, actual: ceilingDB)
        }
        if attackMs < Self.minAttackMs || attackMs > Self.maxAttackMs {
            return .limiterAttackOutOfRange(min: Self.minAttackMs, max: Self.maxAttackMs, actual: attackMs)
        }
        if releaseMs < Self.minReleaseMs || releaseMs > Self.maxReleaseMs {
            return .limiterReleaseOutOfRange(min: Self.minReleaseMs, max: Self.maxReleaseMs, actual: releaseMs)
        }
        if lookAheadMs < Self.minLookAheadMs || lookAheadMs > Self.maxLookAheadMs {
            return .limiterLookAheadOutOfRange(min: Self.minLookAheadMs, max: Self.maxLookAheadMs, actual: lookAheadMs)
        }
        return nil
    }
}

struct OutputChannelConfig: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var label: String = "Output"
    var source: SignalSource = .mainsLeft
    var target: OutputTarget? = nil
    var isEnabled: Bool = true
    var eq: OutputChannelEQConfig = .default
    /// Pre-EQ calibration gain trim (dB). Range: –24…+24.
    /// Set by Band Level Calibration to normalise channel SPL at the listening position.
    /// Applied before the EQ chain so the EQ always operates on the calibrated-level signal.
    var gainTrimDB: Float = 0.0
    var polarityInverted: Bool = false
    /// Time delay for speaker time alignment (ms). Range: 0–100 ms.
    var delayMs: Float = 0.0
    var limiter: OutputChannelLimiterConfig = .default
    /// Group delay all-pass coefficients for crossover phase alignment.
    /// Fitted by CrossoverGroupDelayEngine to minimise group delay error at crossover points.
    var groupDelayAllPassCoefficients: [BiquadCoefficients] = []

    // Validation ranges
    static let minGainTrimDB: Float = -24.0
    static let maxGainTrimDB: Float = 24.0
    static let minDelayMs: Float = 0.0
    static let maxDelayMs: Float = 100.0

    private enum CodingKeys: String, CodingKey {
        case id, label, source, target, isEnabled, eq
        case gainTrimDB, polarityInverted, delayMs, limiter, groupDelayAllPassCoefficients
    }

    init(
        id: UUID = UUID(),
        label: String = "Output",
        source: SignalSource = .mainsLeft,
        target: OutputTarget? = nil,
        isEnabled: Bool = true,
        eq: OutputChannelEQConfig = .default,
        gainTrimDB: Float = 0.0,
        polarityInverted: Bool = false,
        delayMs: Float = 0.0,
        limiter: OutputChannelLimiterConfig = .default,
        groupDelayAllPassCoefficients: [BiquadCoefficients] = []
    ) {
        self.id = id
        self.label = label
        self.source = source
        self.target = target
        self.isEnabled = isEnabled
        self.eq = eq
        self.gainTrimDB = gainTrimDB
        self.polarityInverted = polarityInverted
        self.delayMs = delayMs
        self.limiter = limiter
        self.groupDelayAllPassCoefficients = groupDelayAllPassCoefficients
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Output"
        source = try c.decodeIfPresent(SignalSource.self, forKey: .source) ?? .mainsLeft
        target = try c.decodeIfPresent(OutputTarget.self, forKey: .target)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        eq = try c.decodeIfPresent(OutputChannelEQConfig.self, forKey: .eq) ?? .default
        gainTrimDB = try c.decodeIfPresent(Float.self, forKey: .gainTrimDB) ?? 0.0
        polarityInverted = try c.decodeIfPresent(Bool.self, forKey: .polarityInverted) ?? false
        delayMs = try c.decodeIfPresent(Float.self, forKey: .delayMs) ?? 0.0
        limiter = try c.decodeIfPresent(OutputChannelLimiterConfig.self, forKey: .limiter) ?? .default
        groupDelayAllPassCoefficients = try c.decodeIfPresent([BiquadCoefficients].self, forKey: .groupDelayAllPassCoefficients) ?? []
    }

    func validate() -> ValidationError? {
        if gainTrimDB < Self.minGainTrimDB || gainTrimDB > Self.maxGainTrimDB {
            return .gainTrimOutOfRange(min: Self.minGainTrimDB, max: Self.maxGainTrimDB, actual: gainTrimDB)
        }
        if delayMs < Self.minDelayMs || delayMs > Self.maxDelayMs {
            return .delayOutOfRange(min: Self.minDelayMs, max: Self.maxDelayMs, actual: delayMs)
        }
        if let limiterError = limiter.validate() {
            return limiterError
        }
        return nil
    }
}

struct OutputChannelMatrixConfig: Codable, Sendable {
    var isEnabled: Bool = false
    var channels: [OutputChannelConfig] = []
    static let minChannels = 2
    static let maxChannels = 8
    static let `default` = OutputChannelMatrixConfig()

    private enum CodingKeys: String, CodingKey {
        case isEnabled, channels
    }

    init(isEnabled: Bool = false, channels: [OutputChannelConfig] = []) {
        self.isEnabled = isEnabled
        self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        channels = try c.decodeIfPresent([OutputChannelConfig].self, forKey: .channels) ?? []
    }

    func validate(activeCrossoverEnabled: Bool, activeCrossoverBandCount: Int, bassManagementEnabled: Bool) -> ValidationError? {
        if channels.count < OutputChannelMatrixConfig.minChannels || channels.count > OutputChannelMatrixConfig.maxChannels {
            return .channelCountOutOfRange
        }

        let ids = channels.map { $0.id }
        if Set(ids).count != ids.count {
            return .duplicateChannelIDs
        }

        for channel in channels {
            // Validate channel-level parameters
            if let channelError = channel.validate() {
                return channelError
            }

            // Validate source requirements
            if channel.source.requiresCrossover && !activeCrossoverEnabled {
                return .sourceRequiresCrossoverNotEnabled(activeCrossoverEnabled: activeCrossoverEnabled, source: channel.source)
            }
            if channel.source.requiresBassManagement && !bassManagementEnabled {
                return .sourceRequiresBassManagementNotEnabled(bassManagementEnabled: bassManagementEnabled, source: channel.source)
            }
            if channel.source.requiresTriAmp && activeCrossoverBandCount != 3 {
                return .sourceRequiresTriAmpNotEnabled(bandCount: activeCrossoverBandCount, source: channel.source)
            }
        }

        return nil
    }
}
