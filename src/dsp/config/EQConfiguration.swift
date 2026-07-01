import Foundation
import os.log

// MARK: - Channel Editing Target

/// Which channel to edit in stereo mode.
/// In linked mode, this is ignored (both channels edited together).
enum ChannelFocus: String, Codable, Sendable {
    case left
    case right
    case mid    // active when channelMode == .midSide
    case side   // active when channelMode == .midSide
}

/// Dynamic EQ parameters stored inline on a band.
/// Only active when `EQBandConfiguration.isDynamic == true`.
struct DynamicBandParams: Codable, Sendable, Equatable {
    var thresholdDB: Float = -20.0   // dBFS, –60…0
    var ratio: Float       = 2.0     // 1.0…10.0
    var attackMs: Float    = 10.0    // ms, 1…100
    var releaseMs: Float   = 100.0   // ms, 10…1000

    // NEW — maximum attenuation this band may apply, in dB. Same purpose and
    // convention as ExpanderConfig.rangeDB and the De-Esser's rangeDB.
    // Range −24.0…0.0. Default of −24.0 keeps current behavior unchanged for
    // ratios/thresholds where 24 dB of reduction was never actually reached
    // in practice — verify this against existing presets before treating it
    // as a true no-op default; if any saved preset's ratio/threshold
    // combination could exceed 24 dB of reduction under normal program
    // material, consider defaulting to a value that provably can't bind
    // (e.g. −60.0) instead, so this Package is purely additive with zero
    // behavior change until a user actively tightens it.
    var rangeDB: Float = -24.0

    // NEW — direction of dynamic processing (stored as String to avoid circular dependency)
    var direction: String = "cutOnly"

    // NEW — boost-specific parameters (used when direction == .boostOnly or .both)
    var boostThresholdDB: Float = -40.0
    var boostRatio: Float = 2.0
    var maxBoostDB: Float = 6.0
}

/// Configuration for a single EQ band.
///
/// Q (quality factor) is stored natively. Bandwidth in octaves is a display preference
/// that can be converted to/from Q using `BandwidthConverter`. Q is the value used
/// directly by the biquad coefficient calculations.
struct EQBandConfiguration: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case frequency
        case q
        case bandwidth  // Legacy: for backward compatibility with old presets
        case gain
        case filterType
        case bypass
        case slope
        case isDynamic
        case dynamicParams
        case firKernelDisplayName
        case firKernelLeft    // large — omitted from default encode path
        case firKernelRight   // large — omitted from default encode path
        case constantQ
        case linkwitzTargetHz
    }

    init(frequency: Float, q: Float, gain: Float, filterType: FilterType, bypass: Bool, slope: FilterSlope = .db12,
         isDynamic: Bool = false,
         dynamicParams: DynamicBandParams = DynamicBandParams(),
         firKernelLeft: [Float]? = nil,
         firKernelRight: [Float]? = nil,
         firKernelDisplayName: String? = nil,
         constantQ: Bool = false,
         linkwitzTargetHz: Float? = nil) {
        self.frequency     = frequency
        self.q             = q
        self.gain          = gain
        self.filterType    = filterType
        self.bypass        = bypass
        self.slope         = slope
        self.isDynamic     = isDynamic
        self.dynamicParams = dynamicParams
        self.firKernelLeft        = firKernelLeft
        self.firKernelRight       = firKernelRight
        self.firKernelDisplayName = firKernelDisplayName
        self.constantQ            = constantQ
        self.linkwitzTargetHz     = linkwitzTargetHz
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decode(Float.self, forKey: .frequency)
        gain = try container.decode(Float.self, forKey: .gain)
        let filterTypeRaw = try container.decode(Int.self, forKey: .filterType)
        filterType = FilterType(validatedRawValue: filterTypeRaw) ?? .parametric
        bypass = try container.decode(Bool.self, forKey: .bypass)

        // New format: q field (preferred)
        // Legacy format: bandwidth field (convert to Q)
        if let q = try container.decodeIfPresent(Float.self, forKey: .q) {
            self.q = q
        } else if let bandwidth = try container.decodeIfPresent(Float.self, forKey: .bandwidth) {
            // Legacy: convert bandwidth (octaves) to Q
            self.q = BandwidthConverter.bandwidthToQ(bandwidth)
        } else {
            self.q = EQConfiguration.defaultQ
        }

        // Slope field added in a later version — default to .db12 for older state files
        if let slopeRaw = try container.decodeIfPresent(Int.self, forKey: .slope),
           let decoded = FilterSlope(rawValue: slopeRaw) {
            slope = decoded
        } else {
            slope = .db12
        }

        isDynamic     = (try container.decodeIfPresent(Bool.self,             forKey: .isDynamic))     ?? false
        dynamicParams = (try container.decodeIfPresent(DynamicBandParams.self, forKey: .dynamicParams)) ?? DynamicBandParams()
        firKernelDisplayName = try container.decodeIfPresent(String.self,  forKey: .firKernelDisplayName)
        firKernelLeft        = try container.decodeIfPresent([Float].self, forKey: .firKernelLeft)
        firKernelRight       = try container.decodeIfPresent([Float].self, forKey: .firKernelRight)
        constantQ            = (try container.decodeIfPresent(Bool.self,   forKey: .constantQ))         ?? false
        linkwitzTargetHz     = try container.decodeIfPresent(Float.self,   forKey: .linkwitzTargetHz)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(q, forKey: .q)
        try container.encode(gain, forKey: .gain)
        try container.encode(filterType.rawValue, forKey: .filterType)
        try container.encode(bypass, forKey: .bypass)
        try container.encode(slope.rawValue, forKey: .slope)
        try container.encode(isDynamic, forKey: .isDynamic)
        if isDynamic {
            try container.encode(dynamicParams, forKey: .dynamicParams)
        }
        if constantQ { try container.encode(constantQ, forKey: .constantQ) }
        try container.encodeIfPresent(linkwitzTargetHz, forKey: .linkwitzTargetHz)
        // Encode display name only — kernel arrays are large and excluded from the
        // standard path. Use encodeIncludingKernels(to:) for full persistence.
        try container.encodeIfPresent(firKernelDisplayName, forKey: .firKernelDisplayName)
        // firKernelLeft and firKernelRight intentionally omitted here.
    }

    /// Encodes this band configuration including the FIR kernel arrays.
    ///
    /// Use when saving a standalone preset file that must be self-contained
    /// (i.e. the user does not want to reload the IR from the original file).
    /// Results in a larger preset file.
    func encodeIncludingKernels(to encoder: Encoder) throws {
        // Encode everything from encode(to:) plus the kernel arrays.
        try encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(firKernelLeft,  forKey: .firKernelLeft)
        try container.encodeIfPresent(firKernelRight, forKey: .firKernelRight)
    }

    var frequency: Float
    var q: Float
    var gain: Float
    var filterType: FilterType
    var bypass: Bool
    var slope: FilterSlope

    /// When true, this band is processed as a Dynamic EQ band.
    var isDynamic: Bool = false
    /// Dynamic envelope parameters. Ignored when `isDynamic == false`.
    var dynamicParams: DynamicBandParams = DynamicBandParams()

    /// Left-channel FIR kernel samples. Non-nil only when filterType == .fir.
    /// Not encoded in the standard band serialisation path to keep preset files small.
    /// Use encodeIncludingKernels(to:) to persist kernel data.
    var firKernelLeft: [Float]? = nil

    /// Right-channel FIR kernel. When nil and filterType == .fir, the left kernel
    /// is used for both channels (mono IR).
    var firKernelRight: [Float]? = nil

    /// Display name for the loaded FIR kernel (filename without extension).
    /// Encoded in the standard path so the UI shows the name even if the kernel
    /// is not embedded in the preset.
    var firKernelDisplayName: String? = nil

    /// When true, uses constant-Q (Orfanidis) parametric formula which preserves
    /// bandwidth at all gain values. When false (default), uses RBJ proportional-Q.
    /// Only applies when filterType == .parametric.
    var constantQ: Bool = false

    /// Target frequency for Linkwitz-Transform filter (fp). Only used when filterType == .linkwitzTransform.
    /// When nil, defaults to frequency * 0.7.
    var linkwitzTargetHz: Float? = nil

    /// Default parametric band configuration.
    static func parametric(frequency: Float, q: Float = EQConfiguration.defaultQ) -> EQBandConfiguration {
        EQBandConfiguration(
            frequency: frequency,
            q: q,
            gain: 0,
            filterType: .parametric,
            bypass: false,
            slope: .db12
        )
    }
}

/// Stores EQ configuration independently of any AVAudioEngine instance.
/// This allows settings to be stored and modified without triggering
/// audio hardware initialization.
@MainActor
final class EQConfiguration: ObservableObject {
    // MARK: - Constants

    nonisolated static let maxBandCount: Int = 64
    nonisolated static let defaultBandCount: Int = 10
    /// Default Q factor for EQ bands (~1 octave bandwidth, industry standard).
    nonisolated static let defaultQ: Float = 1.41

    // MARK: - Published Properties

    /// Global bypass for all EQ bands.
    @Published var globalBypass: Bool = false

    /// Input gain applied before EQ processing (in dB).
    @Published var inputGain: Float = 0

    /// Output gain applied after EQ processing (in dB).
    @Published var outputGain: Float = 0

    /// Channel processing mode.
    /// - linked: Same EQ applied to both L and R (default)
    /// - stereo: Independent L and R EQ settings
    @Published var channelMode: ChannelMode = .linked

    /// Dynamics processing configuration (soft clipper + brickwall limiter).
    /// Applied at the absolute end of the signal chain, after all EQ and gain stages.
    @Published var dynamicsConfig: DynamicsConfig = .default

    /// Which channel is currently being edited in stereo mode.
    /// In linked mode, this is ignored.
    @Published var channelFocus: ChannelFocus = .left

    /// Current number of active bands exposed to the UI and audio engine.
    /// In linked mode, this is the band count for both channels.
    /// In stereo mode, this is the max of left and right band counts.
    @Published private(set) var activeBandCount: Int

    /// Band count for the currently focused channel.
    /// In linked mode, returns activeBandCount.
    /// In stereo mode, returns the band count of the focused channel.
    /// In midSide mode, returns the band count of the focused channel (Mid or Side).
    var focusedChannelBandCount: Int {
        switch channelMode {
        case .linked:
            return activeBandCount
        case .stereo:
            return channelFocus == .left
                ? leftState.userEQ.activeBandCount
                : rightState.userEQ.activeBandCount
        case .midSide:
            // Mid stored in leftState, Side stored in rightState
            return (channelFocus == .mid || channelFocus == .left)
                ? leftState.userEQ.activeBandCount
                : rightState.userEQ.activeBandCount
        }
    }

    /// Per-channel EQ state.
    /// Left channel state is used for linked mode.
    @Published private(set) var leftState: ChannelEQState
    @Published private(set) var rightState: ChannelEQState

    /// Configuration for all bands (always sized to `maxBandCount`).
    /// Returns bands for the currently edited channel:
    /// - In linked mode: left channel bands (both channels have same settings)
    /// - In stereo mode: bands for the channel being edited
    /// - In midSide mode: Mid stored in leftState, Side stored in rightState
    var bands: [EQBandConfiguration] {
        switch channelMode {
        case .linked:
            return leftState.userEQ.bands
        case .stereo:
            return channelFocus == .left
                ? leftState.userEQ.bands
                : rightState.userEQ.bands
        case .midSide:
            // Mid stored in leftState, Side stored in rightState
            return (channelFocus == .mid || channelFocus == .left)
                ? leftState.userEQ.bands
                : rightState.userEQ.bands
        }
    }

    // MARK: - Initialization

    init(initialBandCount: Int = EQConfiguration.defaultBandCount) {
        leftState = ChannelEQState.default(bandCount: initialBandCount)
        rightState = ChannelEQState.default(bandCount: initialBandCount)
        activeBandCount = EQConfiguration.clampBandCount(initialBandCount)
    }

    convenience init(from snapshot: AppStateSnapshot) {
        // Snapshot decoding handles legacy migration, so we can use states directly
        let bandCount = snapshot.leftState.userEQ.activeBandCount

        self.init(initialBandCount: bandCount)
        globalBypass = snapshot.globalBypass
        inputGain = snapshot.inputGain
        outputGain = snapshot.outputGain
        channelMode = snapshot.channelMode
        channelFocus = snapshot.channelFocus

        // Restore channel states directly (migration handled in AppStateSnapshot.decode)
        leftState = snapshot.leftState
        rightState = snapshot.rightState

        // Ensure active band count matches left channel
        activeBandCount = bandCount

        // Restore dynamics configuration
        dynamicsConfig = snapshot.dynamicsConfig
    }

    // MARK: - Band Count Management

    /// Sets the number of active bands, clamping to the supported range.
    /// In linked mode, sets both channels. In stereo mode, sets only the channel being edited.
    /// - Parameters:
    ///   - newValue: The desired number of bands.
    ///   - preserveConfiguredBands: If true and bands have been modified (non-zero gains),
    ///     only add/remove bands from the right side. If false, respread all bands across the spectrum.
    /// - Returns: The clamped value actually set.
    @discardableResult
    func setActiveBandCount(_ newValue: Int, preserveConfiguredBands: Bool = true) -> Int {
        let clamped = EQConfiguration.clampBandCount(newValue)

        switch channelMode {
        case .linked:
            // Linked mode: set both channels
            let oldCount = activeBandCount
            guard clamped != oldCount else { return clamped }

            if preserveConfiguredBands && hasModifiedBands(upTo: min(oldCount, clamped)) {
                // Bands have been configured - add/remove from right only
                if clamped > oldCount {
                    // Adding bands: extend frequencies to the right
                    let lastFreq = bands[oldCount - 1].frequency
                    let maxFreq: Float = 26000
                    let newBandCount = clamped - oldCount
                    let ratio = pow(maxFreq / lastFreq, 1 / Float(newBandCount + 1))

                    // Update both channels
                    for i in oldCount..<clamped {
                        let freq = lastFreq * pow(ratio, Float(i - oldCount + 1))
                        leftState.userEQ.bands[i] = EQBandConfiguration.parametric(
                            frequency: freq,
                            q: EQConfiguration.defaultQ
                        )
                        rightState.userEQ.bands[i] = EQBandConfiguration.parametric(
                            frequency: freq,
                            q: EQConfiguration.defaultQ
                        )
                    }
                }
                // Removing bands: just decrease count, existing bands preserved
            } else {
                // No modifications - respread all bands across full spectrum
                let frequencies = EQConfiguration.frequenciesForBandCount(clamped)
                for (index, frequency) in frequencies.enumerated() {
                    let band = EQBandConfiguration.parametric(
                        frequency: frequency,
                        q: EQConfiguration.defaultQ
                    )
                    leftState.userEQ.bands[index] = band
                    rightState.userEQ.bands[index] = band
                }
            }

            // Update active band count in both channels
            leftState.userEQ.activeBandCount = clamped
            rightState.userEQ.activeBandCount = clamped
            activeBandCount = clamped

        case .stereo, .midSide:
            // Stereo mode: set only the channel being edited
            // MidSide mode: Mid stored in leftState, Side stored in rightState
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                let oldCount = leftState.userEQ.activeBandCount
                guard clamped != oldCount else { return clamped }

                if preserveConfiguredBands && hasModifiedBands(upTo: min(oldCount, clamped), channel: .left) {
                    if clamped > oldCount {
                        let lastFreq = leftState.userEQ.bands[oldCount - 1].frequency
                        let maxFreq: Float = 26000
                        let newBandCount = clamped - oldCount
                        let ratio = pow(maxFreq / lastFreq, 1 / Float(newBandCount + 1))

                        for i in oldCount..<clamped {
                            let freq = lastFreq * pow(ratio, Float(i - oldCount + 1))
                            leftState.userEQ.bands[i] = EQBandConfiguration.parametric(
                                frequency: freq,
                                q: EQConfiguration.defaultQ
                            )
                        }
                    }
                } else {
                    let frequencies = EQConfiguration.frequenciesForBandCount(clamped)
                    for (index, frequency) in frequencies.enumerated() {
                        leftState.userEQ.bands[index] = EQBandConfiguration.parametric(
                            frequency: frequency,
                            q: EQConfiguration.defaultQ
                        )
                    }
                }
                leftState.userEQ.activeBandCount = clamped
            } else {
                let oldCount = rightState.userEQ.activeBandCount
                guard clamped != oldCount else { return clamped }

                if preserveConfiguredBands && hasModifiedBands(upTo: min(oldCount, clamped), channel: .right) {
                    if clamped > oldCount {
                        let lastFreq = rightState.userEQ.bands[oldCount - 1].frequency
                        let maxFreq: Float = 26000
                        let newBandCount = clamped - oldCount
                        let ratio = pow(maxFreq / lastFreq, 1 / Float(newBandCount + 1))

                        for i in oldCount..<clamped {
                            let freq = lastFreq * pow(ratio, Float(i - oldCount + 1))
                            rightState.userEQ.bands[i] = EQBandConfiguration.parametric(
                                frequency: freq,
                                q: EQConfiguration.defaultQ
                            )
                        }
                    }
                } else {
                    let frequencies = EQConfiguration.frequenciesForBandCount(clamped)
                    for (index, frequency) in frequencies.enumerated() {
                        rightState.userEQ.bands[index] = EQBandConfiguration.parametric(
                            frequency: frequency,
                            q: EQConfiguration.defaultQ
                        )
                    }
                }
                rightState.userEQ.activeBandCount = clamped
            }

            // Update published property to max of both
            activeBandCount = max(leftState.userEQ.activeBandCount, rightState.userEQ.activeBandCount)
        }

        return clamped
    }

    /// Sets the number of active bands for a specific channel (used by preset loading).
    /// In linked mode, this sets both channels. In stereo mode, sets only the specified channel.
    func setActiveBandCount(_ newValue: Int, channel: ChannelFocus) {
        let clamped = EQConfiguration.clampBandCount(newValue)

        switch channelMode {
        case .linked:
            // Linked mode: set both channels
            leftState.userEQ.activeBandCount = clamped
            rightState.userEQ.activeBandCount = clamped
        case .stereo, .midSide:
            // Stereo mode: set only the specified channel
            // MidSide mode: Mid stored in leftState, Side stored in rightState
            switch channel {
            case .left, .mid:
                leftState.userEQ.activeBandCount = clamped
            case .right, .side:
                rightState.userEQ.activeBandCount = clamped
            }
        }

        switch channelMode {
        case .linked:
            activeBandCount = leftState.userEQ.activeBandCount
        case .stereo, .midSide:
            activeBandCount = max(leftState.userEQ.activeBandCount, rightState.userEQ.activeBandCount)
        }
    }

    /// Removes the band at the given index by shifting all subsequent bands
    /// left by one position in the pre-allocated array, then decrementing
    /// activeBandCount. The freed slot at the end of the active range is reset
    /// to a default parametric band to avoid stale data.
    ///
    /// In linked mode both channels are modified.
    /// In stereo/midSide mode only the focused channel is modified.
    func removeBand(at index: Int) {
        let currentCount: Int
        switch channelMode {
        case .linked:
            currentCount = activeBandCount
        case .stereo, .midSide:
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            currentCount = editLeft
                ? leftState.userEQ.activeBandCount
                : rightState.userEQ.activeBandCount
        }

        guard currentCount > 1 else { return }  // Minimum 1 band (matches clampBandCount)
        guard index >= 0 && index < currentCount else { return }

        let newCount = currentCount - 1
        let defaultBand = EQBandConfiguration.parametric(frequency: 1000, q: EQConfiguration.defaultQ)

        switch channelMode {
        case .linked:
            for i in index..<newCount {
                leftState.userEQ.bands[i]  = leftState.userEQ.bands[i + 1]
                rightState.userEQ.bands[i] = rightState.userEQ.bands[i + 1]
            }
            leftState.userEQ.bands[newCount]  = defaultBand
            rightState.userEQ.bands[newCount] = defaultBand
            leftState.userEQ.activeBandCount  = newCount
            rightState.userEQ.activeBandCount = newCount
            activeBandCount = newCount

        case .stereo, .midSide:
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                for i in index..<newCount {
                    leftState.userEQ.bands[i] = leftState.userEQ.bands[i + 1]
                }
                leftState.userEQ.bands[newCount] = defaultBand
                leftState.userEQ.activeBandCount = newCount
            } else {
                for i in index..<newCount {
                    rightState.userEQ.bands[i] = rightState.userEQ.bands[i + 1]
                }
                rightState.userEQ.bands[newCount] = defaultBand
                rightState.userEQ.activeBandCount = newCount
            }
            activeBandCount = max(leftState.userEQ.activeBandCount,
                                  rightState.userEQ.activeBandCount)
        }

        objectWillChange.send()
    }

    /// Checks if any bands up to the given count have been modified (non-zero gain).
    private func hasModifiedBands(upTo count: Int) -> Bool {
        for i in 0..<count {
            if bands[i].gain != 0 { return true }
        }
        return false
    }

    /// Checks if any bands up to the given count have been modified (non-zero gain) for a specific channel.
    private func hasModifiedBands(upTo count: Int, channel: ChannelFocus) -> Bool {
        let targetBands = channel == .left ? leftState.userEQ.bands : rightState.userEQ.bands
        for i in 0..<count {
            if targetBands[i].gain != 0 { return true }
        }
        return false
    }

    /// Resets all bands with proper frequency spreading across the spectrum.
    func resetBandsWithFrequencySpread() {
        let frequencies = EQConfiguration.frequenciesForBandCount(activeBandCount)
        for (index, frequency) in frequencies.enumerated() {
            let band = EQBandConfiguration.parametric(
                frequency: frequency,
                q: EQConfiguration.defaultQ
            )
            leftState.userEQ.bands[index] = band
            rightState.userEQ.bands[index] = band
        }
    }

    static func clampBandCount(_ value: Int) -> Int {
        min(max(1, value), maxBandCount)
    }

    // MARK: - Default Frequencies

    /// Generates frequencies for a specific band count.
    /// For 10 bands, uses standard musical frequencies: 32, 64, 128, 256, 512, 1000, 2000, 4000, 8000, 16000
    /// For other counts, uses logarithmic spacing from 20Hz to 26000Hz.
    nonisolated static func frequenciesForBandCount(_ count: Int) -> [Float] {
        // Standard 10-band EQ frequencies (powers of 2, centered around 1kHz)
        if count == 10 {
            return [32, 64, 128, 256, 512, 1000, 2000, 4000, 8000, 16000]
        }

        // Logarithmic spacing for other band counts
        let minFrequency: Float = 20
        let maxFrequency: Float = 26000
        let steps = max(count - 1, 1)
        let ratio = pow(maxFrequency / minFrequency, 1 / Float(steps))

        return (0..<count).map { index in
            minFrequency * pow(ratio, Float(index))
        }
    }

    /// Generates logarithmically spaced default frequencies for all 64 bands.
    nonisolated private static func defaultFrequencies() -> [Float] {
        frequenciesForBandCount(maxBandCount)
    }

    /// Generates default band configurations for all bands.
    nonisolated static func defaultBands() -> [EQBandConfiguration] {
        defaultFrequencies().map { frequency in
            EQBandConfiguration.parametric(
                frequency: frequency,
                q: defaultQ
            )
        }
    }

    // MARK: - Channel Mode Management

    /// Sets the channel mode.
    /// When switching from linked to stereo, copies left channel state to right.
    /// When switching from stereo to linked, copies left channel state to right ("L always wins").
    func setChannelMode(_ newMode: ChannelMode) {
        guard newMode != channelMode else { return }

        switch (channelMode, newMode) {
        case (.linked, .stereo):
            // Give right channel a copy of linked bands as starting point
            rightState = leftState
        case (.stereo, .linked):
            // Discard independent right bands; use left as the linked config
            rightState = leftState
            channelFocus = .left
        case (.linked, .midSide):
            // Start with identical Mid and Side (flat side = unaltered stereo image)
            rightState = leftState
            channelFocus = .mid
        case (.midSide, .linked):
            // Left (Mid) state becomes the linked configuration; discard Side bands
            rightState = leftState
            channelFocus = .left
        case (.stereo, .midSide):
            // Reinterpret L as Mid and R as Side — no data change needed
            channelFocus = .mid
        case (.midSide, .stereo):
            // Reinterpret Mid as L and Side as R — no data change needed
            channelFocus = .left
        default:
            break
        }

        channelMode = newMode

        // Sync activeBandCount for the new mode
        switch channelMode {
        case .linked:
            activeBandCount = leftState.userEQ.activeBandCount
        case .stereo, .midSide:
            activeBandCount = max(leftState.userEQ.activeBandCount,
                                  rightState.userEQ.activeBandCount)
        }

        objectWillChange.send()
    }

    // MARK: - Band Updates

    private func isValidIndex(_ index: Int) -> Bool {
        index >= 0 && index < EQConfiguration.maxBandCount
    }

    /// Updates the gain for a specific band.
    /// In linked mode, updates both channels.
    /// In stereo mode, updates only the currently edited channel.
    /// In midSide mode, Mid stored in leftState, Side stored in rightState.
    func updateBandGain(index: Int, gain: Float) {
        guard isValidIndex(index) else { return }

        if channelMode == .linked {
            leftState.userEQ.bands[index].gain = gain
            rightState.userEQ.bands[index].gain = gain
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].gain = gain
            } else {
                rightState.userEQ.bands[index].gain = gain
            }
        }
        objectWillChange.send()
    }

    /// Updates the gain for a specific band on a specific channel.
    func updateBandGain(index: Int, gain: Float, channel: EQChannelTarget) {
        guard isValidIndex(index) else { return }

        let targetChannel = channelMode == .linked ? .both : channel

        if targetChannel == .both || targetChannel == .left {
            leftState.userEQ.bands[index].gain = gain
        }
        if targetChannel == .both || targetChannel == .right {
            rightState.userEQ.bands[index].gain = gain
        }
        objectWillChange.send()
    }

    /// Updates the Q factor for a specific band.
    func updateBandQ(index: Int, q: Float) {
        guard isValidIndex(index) else { return }

        if channelMode == .linked {
            leftState.userEQ.bands[index].q = q
            rightState.userEQ.bands[index].q = q
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].q = q
            } else {
                rightState.userEQ.bands[index].q = q
            }
        }
        objectWillChange.send()
    }

    /// Updates the Q factor for a specific band on a specific channel.
    func updateBandQ(index: Int, q: Float, channel: EQChannelTarget) {
        guard isValidIndex(index) else { return }

        let targetChannel = channelMode == .linked ? .both : channel

        if targetChannel == .both || targetChannel == .left {
            leftState.userEQ.bands[index].q = q
        }
        if targetChannel == .both || targetChannel == .right {
            rightState.userEQ.bands[index].q = q
        }
        objectWillChange.send()
    }

    /// Updates the frequency for a specific band.
    func updateBandFrequency(index: Int, frequency: Float) {
        guard isValidIndex(index) else { return }

        if channelMode == .linked {
            leftState.userEQ.bands[index].frequency = frequency
            rightState.userEQ.bands[index].frequency = frequency
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].frequency = frequency
            } else {
                rightState.userEQ.bands[index].frequency = frequency
            }
        }
        objectWillChange.send()
    }

    /// Updates the frequency for a specific band on a specific channel.
    func updateBandFrequency(index: Int, frequency: Float, channel: EQChannelTarget) {
        guard isValidIndex(index) else { return }

        let targetChannel = channelMode == .linked ? .both : channel

        if targetChannel == .both || targetChannel == .left {
            leftState.userEQ.bands[index].frequency = frequency
        }
        if targetChannel == .both || targetChannel == .right {
            rightState.userEQ.bands[index].frequency = frequency
        }
        objectWillChange.send()
    }

    /// Updates the bypass state for a specific band.
    func updateBandBypass(index: Int, bypass: Bool) {
        guard isValidIndex(index) else { return }

        if channelMode == .linked {
            leftState.userEQ.bands[index].bypass = bypass
            rightState.userEQ.bands[index].bypass = bypass
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].bypass = bypass
            } else {
                rightState.userEQ.bands[index].bypass = bypass
            }
        }
        objectWillChange.send()
    }

    /// Updates the bypass state for a specific band on a specific channel.
    func updateBandBypass(index: Int, bypass: Bool, channel: EQChannelTarget) {
        guard isValidIndex(index) else { return }

        let targetChannel = channelMode == .linked ? .both : channel

        if targetChannel == .both || targetChannel == .left {
            leftState.userEQ.bands[index].bypass = bypass
        }
        if targetChannel == .both || targetChannel == .right {
            rightState.userEQ.bands[index].bypass = bypass
        }
        objectWillChange.send()
    }

    /// Updates the filter type for a specific band.
    func updateBandFilterType(index: Int, filterType: FilterType) {
        guard isValidIndex(index) else { return }

        if channelMode == .linked {
            leftState.userEQ.bands[index].filterType = filterType
            rightState.userEQ.bands[index].filterType = filterType
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].filterType = filterType
            } else {
                rightState.userEQ.bands[index].filterType = filterType
            }
        }
        objectWillChange.send()
    }

    /// Updates the filter type for a specific band on a specific channel.
    func updateBandFilterType(index: Int, filterType: FilterType, channel: EQChannelTarget) {
        guard isValidIndex(index) else { return }

        let targetChannel = channelMode == .linked ? .both : channel

        if targetChannel == .both || targetChannel == .left {
            leftState.userEQ.bands[index].filterType = filterType
        }
        if targetChannel == .both || targetChannel == .right {
            rightState.userEQ.bands[index].filterType = filterType
        }
        objectWillChange.send()
    }

    /// Updates the filter slope for a specific band.
    func updateBandSlope(index: Int, slope: FilterSlope) {
        guard isValidIndex(index) else { return }

        if channelMode == .linked {
            leftState.userEQ.bands[index].slope = slope
            rightState.userEQ.bands[index].slope = slope
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].slope = slope
            } else {
                rightState.userEQ.bands[index].slope = slope
            }
        }

        objectWillChange.send()
    }

    func updateBandConstantQ(index: Int, constantQ: Bool) {
        guard isValidIndex(index) else { return }
        if channelMode == .linked {
            leftState.userEQ.bands[index].constantQ = constantQ
            rightState.userEQ.bands[index].constantQ = constantQ
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft { leftState.userEQ.bands[index].constantQ = constantQ }
            else         { rightState.userEQ.bands[index].constantQ = constantQ }
        }
        objectWillChange.send()
    }

    func updateBandLinkwitzTargetHz(index: Int, targetHz: Float?) {
        guard isValidIndex(index) else { return }
        if channelMode == .linked {
            leftState.userEQ.bands[index].linkwitzTargetHz = targetHz
            rightState.userEQ.bands[index].linkwitzTargetHz = targetHz
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft { leftState.userEQ.bands[index].linkwitzTargetHz = targetHz }
            else         { rightState.userEQ.bands[index].linkwitzTargetHz = targetHz }
        }
        objectWillChange.send()
    }

    /// Updates the filter slope for a specific band on a specific channel.
    func updateBandSlope(index: Int, slope: FilterSlope, channel: EQChannelTarget) {
        guard isValidIndex(index) else { return }

        let targetChannel = channelMode == .linked ? .both : channel

        if targetChannel == .both || targetChannel == .left {
            leftState.userEQ.bands[index].slope = slope
        }
        if targetChannel == .both || targetChannel == .right {
            rightState.userEQ.bands[index].slope = slope
        }
        objectWillChange.send()
    }

    /// Sets whether a band operates in dynamic mode.
    /// In linked mode, updates both channels.
    func updateBandDynamicMode(index: Int, isDynamic: Bool) {
        guard isValidIndex(index) else { return }
        if channelMode == .linked {
            leftState.userEQ.bands[index].isDynamic  = isDynamic
            rightState.userEQ.bands[index].isDynamic = isDynamic
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].isDynamic = isDynamic
            } else {
                rightState.userEQ.bands[index].isDynamic = isDynamic
            }
        }
        objectWillChange.send()
    }

    /// Updates the dynamic envelope parameters for a band.
    /// In linked mode, updates both channels.
    func updateBandDynamicParams(index: Int, params: DynamicBandParams) {
        guard isValidIndex(index) else { return }
        if channelMode == .linked {
            leftState.userEQ.bands[index].dynamicParams  = params
            rightState.userEQ.bands[index].dynamicParams = params
        } else {
            let editLeft = (channelFocus == .left || channelFocus == .mid)
            if editLeft {
                leftState.userEQ.bands[index].dynamicParams = params
            } else {
                rightState.userEQ.bands[index].dynamicParams = params
            }
        }
        objectWillChange.send()
    }

    /// Updates the FIR kernel data for a specific EQ band.
    ///
    /// In linked mode, the same kernels are stored on both channels (L kernel → left,
    /// R kernel → right). In stereo / midSide mode, the kernel is stored on
    /// the focused channel only; pass `nil` for the right kernel to share the left
    /// kernel on both channels (mono IR).
    func updateFIRBandKernel(
        index: Int,
        leftKernel: [Float]?,
        rightKernel: [Float]?,
        displayName: String?
    ) {
        guard isValidIndex(index) else { return }
        leftState.userEQ.bands[index].firKernelLeft        = leftKernel
        leftState.userEQ.bands[index].firKernelRight       = rightKernel
        leftState.userEQ.bands[index].firKernelDisplayName = displayName
        if channelMode == .linked {
            rightState.userEQ.bands[index].firKernelLeft        = leftKernel
            rightState.userEQ.bands[index].firKernelRight       = rightKernel
            rightState.userEQ.bands[index].firKernelDisplayName = displayName
        }
        objectWillChange.send()
    }
}

// MARK: - Dynamic EQ Bridge

extension EQConfiguration {
    /// Builds a DynamicEQConfig from whichever bands in the currently active
    /// channel(s) have isDynamic == true. Mirrors the same channel-mode logic
    /// already used by `bands` (linked / stereo / midSide) so the merged
    /// config always reflects whichever channel's bands the engine should
    /// actually be running dynamically.
    ///
    /// NOTE ON CHANNEL MODE: DynamicEQConfig has no per-channel concept of
    /// its own — it's a single flat band list consumed by DynamicsProcessor,
    /// which runs after L/R (or M/S-decoded-to-L/R) recombination. In
    /// .stereo or .midSide mode, if left/right (or mid/side) have DIFFERENT
    /// isDynamic bands or different dynamicParams at the same band index,
    /// there is no way to apply asymmetric per-channel dynamic processing
    /// with the current DynamicsProcessor API — it operates identically on
    /// all channels passed to it. For v1, resolve this by using leftState's
    /// (or Mid's) dynamic bands as the source of truth when channelMode !=
    /// .linked, and surface this constraint in the UI (see Package 0, Step 4).
    /// A true per-channel dynamic EQ would require extending
    /// DynamicsProcessor itself — out of scope here.
    func buildMergedDynamicEQConfig() -> DynamicEQConfig {
        let sourceBands: [EQBandConfiguration] = leftState.userEQ.bands
        var dynBands: [DynamicEQBand] = []
        for band in sourceBands where band.isDynamic {
            guard dynBands.count < DynamicEQConfig.maxDynamicEQBands else { break }
            let direction: DynamicBandDirection
            switch band.dynamicParams.direction {
            case "cutOnly": direction = .cutOnly
            case "boostOnly": direction = .boostOnly
            case "both": direction = .both
            default: direction = .cutOnly
            }
            dynBands.append(
                DynamicEQBand(
                    frequency: band.frequency,
                    q: band.q,
                    gain: band.gain,
                    thresholdDB: band.dynamicParams.thresholdDB,
                    ratio: band.dynamicParams.ratio,
                    attackMs: band.dynamicParams.attackMs,
                    releaseMs: band.dynamicParams.releaseMs,
                    bypass: band.bypass,
                    rangeDB: band.dynamicParams.rangeDB,
                    direction: direction,
                    boostThresholdDB: band.dynamicParams.boostThresholdDB,
                    boostRatio: band.dynamicParams.boostRatio,
                    maxBoostDB: band.dynamicParams.maxBoostDB
                )
            )
        }
        return DynamicEQConfig(enabled: !dynBands.isEmpty, bands: dynBands)
    }
}
