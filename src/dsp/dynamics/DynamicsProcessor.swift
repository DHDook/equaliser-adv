import Accelerate
import Atomics
import AudioToolbox
import CoreAudio
import Foundation

/// Real-time dynamics processor.
///
/// Signal chain (per buffer):
/// ```
/// Input
///   → [Stereo Widener]           (optional, Section C)
///   → [LUFS Loudness Match]      (optional, Section D)
///   → [De-Esser]
///   → [Multiband Compressor]     (LR4 gentle 24 dB/oct or LR8 steep 48 dB/oct)
///   → [Compressor]               (soft-knee)
///   → [Expander]
///   → [Soft Clipper]
///   → [Look-Ahead Ring Buffer]
///   → [Brickwall Limiter]
///   → Output
/// ```
///
/// Thread safety: atomic parameters are written by the main thread and read by the audio
/// thread. All filter/envelope state is accessed exclusively from the audio thread and is
/// marked `nonisolated(unsafe)`.
final class DynamicsProcessor: @unchecked Sendable {

    // MARK: - Constants

    static let maxLookAheadSamples: Int = 8192  // Raised for oversampling + high sample rates
    static let maxIRAlignSamples:   Int = 12000  // 5 ms at 192 kHz
    static let maxLowBandDelaySamples: Int = 19200 + 10  // 100 ms at 192 kHz, + safety margin

    // Bass management and mains high-pass filter state buffer sizes
    private static let maxBassManagementStatePerChannel: Int = 64  // 4 sections × 4 states, with headroom
    private static let maxBassManagementStateTotal: Int = maxBassManagementStatePerChannel * 2  // stereo

    // Dynamic EQ and Sub-EQ state buffer sizes
    private static let maxDynamicEQStateFloats: Int = DynamicEQConfig.maxDynamicEQBands * 5  // 5 coeffs per band
    private static let maxDynamicEQParamsFloats: Int = DynamicEQConfig.maxDynamicEQBands * 4  // 4 params per band
    private static let maxSubEQStateFloats: Int = BassManagementConfig.maxSubEQBands * 5  // 5 coeffs per band

    // MARK: - Audio-Thread State

    private let channelCount: Int

    /// Current sample rate. Written by the main thread before audio starts (or on
    /// quiescent reconfigure). Read only on the audio thread during processing.
    nonisolated(unsafe) var storedSampleRate: Double
    /// Maximum frame count for per-callback scratch buffers.
    nonisolated(unsafe) var storedMaxFrameCount: Int = 4096
    /// Effective sample rate for clipper/limiter (accounts for oversampling).
    nonisolated(unsafe) var clipperLimiterSampleRate: Double = 48000.0
    /// Current limiter attack/release/lookahead values for oversampling recompute.
    nonisolated(unsafe) var currentLimiterAttackMs: Float = 0.0001
    nonisolated(unsafe) var currentLimiterReleaseMs: Float = 0.020
    nonisolated(unsafe) var currentLimiterLookAheadMs: Float = 2.0

    // ── Look-ahead (limiter) ──────────────────────────────────────────────
    private let lookAheadBufs: [UnsafeMutablePointer<Float>]
    nonisolated(unsafe) var lookAheadSize: Int
    nonisolated(unsafe) var lookAheadWriteIndex: Int = 0
    nonisolated(unsafe) var limiterGainCurrent: Float = 1.0

    // ── De-esser ─────────────────────────────────────────────────────────
    /// Biquad state per channel: [ch * 2 + stateVar] (w1, w2).
    nonisolated(unsafe) var deEsserFilterState: [Float]
    /// Smoothed gain-reduction dB (≤ 0). Audio thread only.
    nonisolated(unsafe) var deEsserEnvDB: Float = 0.0

    // ── Multiband compressor ──────────────────────────────────────────────
    /// LR4 biquad states (gentle mode): 4 chains × 2 stages × 2 state vars = 16 floats per channel.
    /// Layout: ch*16 + chainIdx*4 + stageIdx*2 + stateVar
    nonisolated(unsafe) var mbFilterState: [Float]
    /// Extra LR4 stages for steep (LR8) mode: same layout, represents stages 2 & 3 per chain.
    nonisolated(unsafe) var mbFilterStateSteep: [Float]
    /// Smoothed linear gains per band (audio thread only). Start at unity.
    nonisolated(unsafe) var mbGainLow: Float  = 1.0
    nonisolated(unsafe) var mbGainMid: Float  = 1.0
    nonisolated(unsafe) var mbGainHigh: Float = 1.0
    /// Pre-allocated per-band temp buffers [bandIdx 0-2][chIdx].
    private let mbBandBufs: [[UnsafeMutablePointer<Float>]]

    // ── Compressor ────────────────────────────────────────────────────────
    /// Smoothed gain-reduction dB (≤ 0). Audio thread only.
    nonisolated(unsafe) var compEnvDB: Float = 0.0

    // ── Expander ──────────────────────────────────────────────────────────
    /// Smoothed gain-reduction dB (≤ 0). Audio thread only.
    nonisolated(unsafe) var expEnvDB: Float = 0.0
    /// Fixed time-constant alphas for expander (5 ms attack, 200 ms release).
    nonisolated(unsafe) var expanderAlphaAttack:  Float = 0.0
    nonisolated(unsafe) var expanderAlphaRelease: Float = 0.0

    // ── Denoiser mode tracking ─────────────────────────────────────────────
    /// Tracks the last denoiser mode and sample rate passed to setMode(),
    /// so we only call setMode() (which blocks the main thread) when something actually changed.
    private var denoisersConfiguredMode: DenoiserMode = .high
    private var denoisersConfiguredSampleRate: Double = 0.0  // 0 forces update on first applyConfig

    // ── Stereo Widener + LUFS ─────────────────────────────────────────────
    let stereoWidener:  StereoWidener
    let lufsProcessor:  LoudnessMatchProcessor

    // ── Look-ahead limiter (extracted from inline implementation) ─────────────
    private let mainLimiter: LookAheadLimiter

    // ── Lightweight PRNG for dither ─────────────────────────────────────────
    private let ditherRNG: DSPRNG

    // MARK: - Advanced DSP State (audio thread only)

    /// DC offset blocker: x_prev and y_prev per channel (1-pole HP at ≈ 0.5 Hz).
    nonisolated(unsafe) var dcOffsetState:   [Float]
    /// De-harsh tilt filter DF2T state: w1, w2 per channel.
    nonisolated(unsafe) var deharshState:    [Float]
    /// Loudness contour biquad state: 4 floats per channel (2 biquad stages × w1/w2).
    nonisolated(unsafe) var contourState:    [Float]
    /// Crest factor: running peak and RMS power envelopes.
    nonisolated(unsafe) var crestPeakEnv:   Float = 0.0
    nonisolated(unsafe) var crestRmsEnv:    Float = 0.0
    /// Right-channel time-delay circular buffer; one pointer per channel.
    private let timeDelayBufs: [UnsafeMutablePointer<Float>]
    private static let maxDelaySamples: Int = 8192
    nonisolated(unsafe) var timeDelayWriteIdx: Int  = 0
    nonisolated(unsafe) var timeDelaySamples:  Int  = 0
    /// Pre-processing signal capture for delta solo; one pointer per channel.
    private let deltaBufs: [UnsafeMutablePointer<Float>]
    /// Pause gate: smoothed RMS envelope and gate state.
    nonisolated(unsafe) var pauseGateLevel:  Float = 0.0
    nonisolated(unsafe) var pauseGateIsOpen: Bool  = true
    /// Slow-averaged limiter GR in dB (≤ 0). Updated once per callback by processAutoHeadroom.
    nonisolated(unsafe) var autoHeadroomGRAccumDB:  Float = 0.0
    /// Current auto-headroom gain in dB (≤ 0). Applied before soft clipper each callback.
    nonisolated(unsafe) var autoHeadroomGainDB:     Float = 0.0
    /// TPDF dither: previous random value to form triangle-PDF noise.
    nonisolated(unsafe) var ditherPrevRand:  Float = 0.0
    /// 5-tap feedback delay for Wannamaker 5th-order noise shaper. Length = channelCount * 5.
    nonisolated(unsafe) var noiseShapeState: [Float]
    /// 4th-order allpass cascade (2 biquad sections) for sub-bass phase alignment.
    /// Layout: [ch * 4 + 0] = section 1 w1, [ch * 4 + 1] = section 1 w2,
    ///         [ch * 4 + 2] = section 2 w1, [ch * 4 + 3] = section 2 w2.
    nonisolated(unsafe) var subBassPhaseState: [Float]
    /// 2nd-order Butterworth lowpass biquad state for mono bass extraction (per channel).
    /// Layout: [ch * 2 + 0] = w1, [ch * 2 + 1] = w2.
    nonisolated(unsafe) var monoBassLowpassState: [Float]
    /// Mono bass lowpass filters (left and right channels).
    nonisolated(unsafe) var monoBassLowpassL: BiquadFilter
    nonisolated(unsafe) var monoBassLowpassR: BiquadFilter
    /// Mono bass highpass filters (left and right channels) for LP/HP split.
    nonisolated(unsafe) var monoBassHighpassL: BiquadFilter
    nonisolated(unsafe) var monoBassHighpassR: BiquadFilter
    /// Mains high-pass filters (left and right channels).
    nonisolated(unsafe) var mainsHighPassL: BiquadFilter
    nonisolated(unsafe) var mainsHighPassR: BiquadFilter

    // ── Infrasonic High-Pass Filter State ─────────────────────────────────────
    /// Infrasonic HPF state — runs early in the signal chain, before main EQ.
    /// Sized for worst case: 16th-order (8 sections) × 2 channels × 2 state vars = 32 Floats.
    nonisolated(unsafe) var infrasonicState: [Float]
    /// Infrasonic HPF state for sub path (mono channel).
    /// Sized for worst case: 16th-order (8 sections) × 1 channel × 2 state vars = 16 Floats.
    nonisolated(unsafe) var infrasonicSubState: [Float]
    /// Active coefficients — pre-allocated fixed-size buffers, never reassigned.
    nonisolated(unsafe) var infrasonicCoeffB0:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicCoeffB1:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicCoeffB2:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicCoeffNA1: UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicCoeffNA2: UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicActiveSectionCount: Int = 0
    /// Pending coefficients — separate buffers for main thread writes.
    nonisolated(unsafe) var infrasonicPendingCoeffB0:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicPendingCoeffB1:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicPendingCoeffB2:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicPendingCoeffNA1: UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicPendingCoeffNA2: UnsafeMutablePointer<Float>
    nonisolated(unsafe) var infrasonicPendingSectionCount: Int = 0
    private let hasInfrasonicUpdate = ManagedAtomic<Bool>(false)
    private let _infrasonicEnabled  = ManagedAtomic<Int32>(0)
    private let _infrasonicTarget   = ManagedAtomic<Int32>(0)  // InfrasonicFilterConfig.ApplicationTarget rawValue
    private static let maxInfrasonicSections = 8   // matches FilterSlope.db96.sectionCount

    /// Bass Management crossover instance.
    nonisolated(unsafe) var bassManagementCrossover: BassManagementCrossover
    /// Bass Management crossover state (per channel).
    /// Layout: [ch * stateSizePerChannel] where stateSizePerChannel = sectionCount * 4
    private let bassManagementStateBuf: UnsafeMutablePointer<Float>   // active, audio-thread-only
    private let pendingBassManagementStateBuf: UnsafeMutablePointer<Float> // staged on main thread
    nonisolated(unsafe) var bassManagementStateSize: Int = 0  // active state size per channel
    nonisolated(unsafe) var pendingBassManagementStateSize: Int = 0
    /// Pending bass management crossover for thread-safe updates.
    nonisolated(unsafe) var pendingBassCrossover: BassManagementCrossover
    /// Flag indicating pending bass management crossover update.
    private let hasBassCrossoverUpdate: ManagedAtomic<Bool>
    /// Mains high-pass crossover instance (for asymmetric mode).
    nonisolated(unsafe) var mainsHighPassCrossover: BassManagementCrossover
    private let mainsHighPassStateBuf: UnsafeMutablePointer<Float>
    private let pendingMainsHighPassStateBuf: UnsafeMutablePointer<Float>
    nonisolated(unsafe) var mainsHighPassStateSize: Int = 0
    nonisolated(unsafe) var pendingMainsHighPassStateSize: Int = 0
    /// Bass management scratch buffers (pre-allocated to maxFrameCount to avoid per-callback allocations)
    private let bmLowL: UnsafeMutablePointer<Float>
    private let bmLowR: UnsafeMutablePointer<Float>
    private let bmHighL: UnsafeMutablePointer<Float>
    private let bmHighR: UnsafeMutablePointer<Float>
    private let bmMonoLow: UnsafeMutablePointer<Float>
    /// Pending mains high-pass crossover for thread-safe updates.
    nonisolated(unsafe) var pendingMainsHighPassCrossover: BassManagementCrossover
    /// Flag indicating pending mains high-pass crossover update.
    private let hasMainsHighPassUpdate: ManagedAtomic<Bool>
    /// Last applied bass management crossover frequency (for change detection).
    private var lastBassCrossoverHz: Float = 80.0
    /// Last applied bass management slope (for change detection).
    private var lastBassCrossoverSlope: BassCrossoverSlope = .lr4
    /// Last applied bass management crossover type (for change detection).
    private var lastBassCrossoverType: CrossoverType = .linkwitzRiley
    /// Last applied mains high-pass frequency (for change detection).
    private var lastMainsHighPassHz: Float = 80.0
    /// Last applied infrasonic filter config (for change detection).
    private var previousInfrasonicFilter: InfrasonicFilterConfig?
    /// Bass Management enabled flag (atomic).
    private let _bassManagementEnabled: ManagedAtomic<Int32>
    /// Asymmetric crossover enabled flag (atomic).
    private let _asymmetricCrossoverEnabled: ManagedAtomic<Int32>
    /// Dynamic EQ enabled flag (atomic).
    private let _dynamicEQEnabled: ManagedAtomic<Int32>
    /// Bass Management crossover frequency in Hz (atomic, stored as float bits).
    private let _bassManagementCrossoverHzBits: ManagedAtomic<Int32>
    /// Bass Management slope (atomic, stored as raw Int32).
    private let _bassManagementSlopeBits: ManagedAtomic<Int32>
    /// Bass Management low band gain in dB (atomic, stored as float bits).
    private let _lowBandGainDBBits: ManagedAtomic<Int32>
    /// Bass Management low band polarity inverted flag (atomic).
    private let _lowBandPolarityInverted: ManagedAtomic<Int32>
    /// Bass Management low band shelf enabled flag (atomic).
    private let _lowBandLowShelfEnabled: ManagedAtomic<Int32>
    /// Bass Management low band shelf frequency in Hz (atomic, stored as float bits).
    private let _lowBandLowShelfFreqBits: ManagedAtomic<Int32>
    /// Bass Management low band shelf gain in dB (atomic, stored as float bits).
    private let _lowBandLowShelfGainBits: ManagedAtomic<Int32>
    /// Bass Management low band shelf filter state (2 state variables).
    nonisolated(unsafe) var lowBandLowShelfState: [Float]
    /// Bass Management low band delay ring buffer (single channel for mono low signal).
    private let lowBandDelayBuf: UnsafeMutablePointer<Float>
    nonisolated(unsafe) var lowBandDelayWriteIdx: Int = 0
    /// Bass Management low band delay in samples (atomic, stored as float bits).
    private let _lowBandDelaySamplesBits: ManagedAtomic<Int32>
    /// Lagrange 4th-order (5-tap) fractional delay FIR state for low band.
    nonisolated(unsafe) var lowBandDelayApState: [Float]

    // Sub EQ — runs on low-band signal after crossover, before gain/polarity/delay
    nonisolated(unsafe) var subEQState: [Float]  // 2 × maxSubEQBands state vars (w1, w2 per band)
    // Pending sub EQ — staged on main thread, consumed at start of processBassManagement (pre-allocated buffers)
    private let subEQCoeffsBuf: UnsafeMutablePointer<Float>  // active, 5 floats × maxBands
    private let pendingSubEQCoeffsBuf: UnsafeMutablePointer<Float>
    private let subEQBypassBuf: UnsafeMutablePointer<Int32>  // 1 per band (0/1)
    private let pendingSubEQBypassBuf: UnsafeMutablePointer<Int32>
    nonisolated(unsafe) var activeSubEQBandCount: Int = 0
    nonisolated(unsafe) var pendingSubEQBandCount: Int = 0
    private var hasSubEQUpdate = ManagedAtomic<Bool>(false)

    // Dynamic EQ — runs on full-band signal before other processing
    nonisolated(unsafe) var dynamicEQFilterState: [Float]  // 2 × maxDynamicEQBands state vars (w1, w2 per band)
    nonisolated(unsafe) var dynamicEQEnvelopeState: [Float]  // maxDynamicEQBands envelope follower state
    nonisolated(unsafe) var dynamicEQGainReductionDB: [Float]  // maxDynamicEQBands current GR in dB
    // Cached per-callback attack/release coefficients for Dynamic EQ (pre-allocated buffers)
    private let dynamicEQAttackCoeffsBuf: UnsafeMutablePointer<Float>  // maxBands
    private let dynamicEQReleaseCoeffsBuf: UnsafeMutablePointer<Float>  // maxBands
    // Pending dynamic EQ — staged on main thread, consumed at start of processDynamicEQ (pre-allocated buffers)
    private let dynamicEQCoeffsBuf: UnsafeMutablePointer<Float>  // active, 5 floats × maxBands
    private let pendingDynEQCoeffsBuf: UnsafeMutablePointer<Float>
    private let dynamicEQBypassBuf: UnsafeMutablePointer<Int32>  // 1 per band (0/1)
    private let pendingDynEQBypassBuf: UnsafeMutablePointer<Int32>
    // Params: store as 4 floats × maxBands (thresholdDB, ratio, attackMs, releaseMs)
    private let dynamicEQParamsBuf: UnsafeMutablePointer<Float>
    private let pendingDynEQParamsBuf: UnsafeMutablePointer<Float>
    nonisolated(unsafe) var activeDynamicEQBandCount: Int = 0
    nonisolated(unsafe) var pendingDynamicEQBandCount: Int = 0
    private var hasDynamicEQUpdate = ManagedAtomic<Bool>(false)

    // FIR Impulse Response — runs on full-band signal
    // Uses ConvolutionEngine for FFT-based partitioned convolution
    private let firConvolutionEngine: ConvolutionEngine
    private let _firEnabled: ManagedAtomic<Int32>

    // Speaker IR alignment per-channel ring buffers (same pattern as timeDelayBufs)
    private let irAlignBufs: [UnsafeMutablePointer<Float>]
    nonisolated(unsafe) var irAlignWriteIdx: Int = 0
    nonisolated(unsafe) var irAlignSamples:  Int = 0
    // Lagrange 4th-order (5-tap) fractional delay FIR state: [ch * 5 + 0..4] = tap0..tap4
    nonisolated(unsafe) var irAlignApState: [Float]

    // Crosstalk cancellation filter state (one LP filter state per channel)
    nonisolated(unsafe) var crosstalkFilterState: [Float]

    // Linear denoising (one SpectralDenoiser per channel)
    private let denoisers: [SpectralDenoiser]

    // MARK: - Atomic Parameters (main thread → audio thread)

    // De-esser
    private let _deEsserEnabled:    ManagedAtomic<Int32>
    private let _deEsserFreqBits:   ManagedAtomic<Int32>   // Hz as Float bits
    private let _deEsserThreshBits: ManagedAtomic<Int32>   // dB as Float bits

    // Multiband compressor
    private let _mbEnabled:        ManagedAtomic<Int32>
    private let _mbCrossLMBits:    ManagedAtomic<Int32>    // crossLowMid Hz
    private let _mbCrossMHBits:    ManagedAtomic<Int32>    // crossMidHigh Hz
    private let _mbThreshLowBits:  ManagedAtomic<Int32>    // dB
    private let _mbThreshMidBits:  ManagedAtomic<Int32>    // dB
    private let _mbThreshHighBits: ManagedAtomic<Int32>    // dB
    /// 0 = gentle (LR4, 24 dB/oct), 1 = steep (LR8, 48 dB/oct).
    private let _mbSlopeLMBits:    ManagedAtomic<Int32>
    private let _mbSlopeMHBits:    ManagedAtomic<Int32>

    // Compressor
    private let _compEnabled:        ManagedAtomic<Int32>
    private let _compThreshBits:     ManagedAtomic<Int32>  // dB
    private let _compRatioBits:      ManagedAtomic<Int32>  // ratio
    private let _compAlphaAttack:    ManagedAtomic<Int32>  // precomputed alpha
    private let _compAlphaRelease:   ManagedAtomic<Int32>  // precomputed alpha
    private let _compMakeupBits:     ManagedAtomic<Int32>  // linear gain
    /// Soft-knee width in dB. 0 = hard knee.
    private let _compKneeWidthBits:  ManagedAtomic<Int32>
    /// Program-dependent release time adaptation.
    private let _compProgramDependentRelease: ManagedAtomic<Int32>
    /// Sidechain high-pass filter frequency in Hz.
    private let _compSidechainHighPassBits: ManagedAtomic<Int32>
    /// Per-channel sidechain high-pass filter state for the compressor.
    /// Layout: [ch * 2 + 0] = w1,  [ch * 2 + 1] = w2.
    nonisolated(unsafe) private var compSidechainHPState: [Float]

    // Cached per-callback coefficients (recomputed when sample rate or parameters change)
    nonisolated(unsafe) private var compSidechainHPCoeffs: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) = (1.0, 0.0, 0.0, 0.0, 0.0)

    // Expander
    private let _expEnabled:    ManagedAtomic<Int32>
    private let _expThreshBits: ManagedAtomic<Int32>       // dB
    private let _expRatioBits:  ManagedAtomic<Int32>       // expansion factor
    private let _expRangeDBBits: ManagedAtomic<Int32>      // dB ceiling (negative)

    // Soft clipper
    private let _softClipperEnabled:   ManagedAtomic<Int32>
    private let _softClipperDrive:     ManagedAtomic<Int32>
    private let _softClipperThreshold: ManagedAtomic<Int32>
    private let _softClipperKnee:      ManagedAtomic<Int32>

    // Brickwall limiter
    private let _limiterEnabled:      ManagedAtomic<Int32>
    private let _limiterCeiling:      ManagedAtomic<Int32>
    private let _limiterAlphaAttack:  ManagedAtomic<Int32>
    private let _limiterAlphaRelease: ManagedAtomic<Int32>

    // MARK: - Gain Reduction Reporting (audio thread → main thread)
    //
    // Per-stage GR in dB (≤ 0). Positive values are clamped to 0.
    // Reported at the end of each process() call.

    private let _gainReductionBits: ManagedAtomic<Int32>   // limiter (alias: limiterGRBits)
    private let _clipperActiveBits: ManagedAtomic<Int32>   // clipper peak flag

    private let _deEsserGRBits: ManagedAtomic<Int32>       // de-esser GR dB
    private let _mbLowGRBits:   ManagedAtomic<Int32>       // MB low band GR dB
    private let _mbMidGRBits:   ManagedAtomic<Int32>       // MB mid band GR dB
    private let _mbHighGRBits:  ManagedAtomic<Int32>       // MB high band GR dB
    private let _compGRBits:    ManagedAtomic<Int32>       // compressor GR dB
    private let _expGRBits:     ManagedAtomic<Int32>       // expander GR dB
    private let _clipperGRBits: ManagedAtomic<Int32>       // clipper GR dB (–6 when engaged)

    // MARK: - Advanced Processing Atomics (main → audio)

    private let _stereoMode:             ManagedAtomic<Int32>  // StereoModeSelection.rawValue
    private let _dcOffsetEnabled:        ManagedAtomic<Int32>
    private let _dialogueGateEnabled:    ManagedAtomic<Int32>
    private let _loudnessContourEnabled: ManagedAtomic<Int32>
    private let _loudnessRefPhonBits:    ManagedAtomic<Int32>  // Float bits, phons
    private let _loudnessRefVolBits:     ManagedAtomic<Int32>  // Float bits, 0–1
    private let _volumeDependentBits:    ManagedAtomic<Int32>
    private let _deesserDynModeEnabled:  ManagedAtomic<Int32>
    private let _asymmetryTrimBits:      ManagedAtomic<Int32>  // Float bits, dB
    private let _deharshEnabled:         ManagedAtomic<Int32>
    private let _deharshTiltBits:        ManagedAtomic<Int32>  // Float bits, dB
    private let _balanceBits:            ManagedAtomic<Int32>  // Float bits, −1 to +1
    private let _symmetryBalanceEnabled: ManagedAtomic<Int32>
    private let _channelBalanceBits:     ManagedAtomic<Int32>  // Float bits, −1 to +1 (linear L/R)
    private let _tpGuardEnabled:              ManagedAtomic<Int32>

    // Panning Gain Matrix atomics
    private let _panningEnabled:       ManagedAtomic<Int32>
    private let _panningCrossfeedBits: ManagedAtomic<Int32>  // Float bits, 0.0–0.5

    // Speaker IR Alignment atomics
    private let _irAlignEnabled:  ManagedAtomic<Int32>
    private let _irAlignDelayBits: ManagedAtomic<Int32>  // Float bits, ms

    // Crosstalk cancellation atomics
    private let _crosstalkEnabled:    ManagedAtomic<Int32>
    private let _crosstalkAmountBits: ManagedAtomic<Int32>  // Float bits, 0.0–0.5

    // Linear denoising atomics
    private let _denoisingEnabled:      ManagedAtomic<Int32>
    private let _denoisingThresholdBits: ManagedAtomic<Int32>  // Float bits, dB
    private let _denoisingWienerFloorBits: ManagedAtomic<Int32>  // Float bits, 0.0–1.0

    // Auto-headroom atomics (main thread → audio thread)
    private let _autoHeadroomEnabled:         ManagedAtomic<Int32>
    /// Alpha coefficient for both the GR accumulator and the gain smoother.
    /// Pre-baked from the speed time constant and current sample rate.
    private let _autoHeadroomAlphaBits:       ManagedAtomic<Int32>
    /// Target sustained GR threshold in dB (positive value, e.g. 3.0 means tolerate 3 dB GR).
    private let _autoHeadroomTargetGRBits:    ManagedAtomic<Int32>
    /// Maximum gain reduction the rider may apply, in dB (positive value, e.g. 6.0).
    private let _autoHeadroomMaxReductBits:   ManagedAtomic<Int32>

    private let _timeDelayBits:          ManagedAtomic<Int32>  // Float bits, ms
    private let _deltaSoloEnabled:       ManagedAtomic<Int32>
    private let _latencyModeBits:        ManagedAtomic<Int32>  // LatencyMode.rawValue
    private let _pauseGateEnabled:          ManagedAtomic<Int32>
    /// Threshold as linear RMS power value, stored as Float bits. Default: 1e-6 (= −60 dBFS power).
    private let _pauseGateThresholdBits:    ManagedAtomic<Int32>
    /// Hold/smoothing time constant, stored as Float bits of the alpha coefficient.
    private let _pauseGateHoldAlphaBits:    ManagedAtomic<Int32>
    /// Attack (open) time constant, stored as Float bits of the alpha coefficient.
    private let _pauseGateAttackAlphaBits:  ManagedAtomic<Int32>
    /// Release (close) time constant, stored as Float bits of the alpha coefficient.
    private let _pauseGateReleaseAlphaBits: ManagedAtomic<Int32>
    /// Hysteresis factor (linear amplitude ratio), stored as Float bits.
    private let _pauseGateHysteresisBits:   ManagedAtomic<Int32>
    private let _syncBufferEnabled:      ManagedAtomic<Int32>
    private let _ditherModeBits:         ManagedAtomic<Int32>  // DitherMode.rawValue
    private let _subBassPhaseEnabled:  ManagedAtomic<Int32>
    private let _subBassPhaseFreqBits: ManagedAtomic<Int32>   // Float bits, Hz
    private let _subBassPhaseQBits:    ManagedAtomic<Int32>   // Float bits, Q factor
    private let _oversamplingEnabled: ManagedAtomic<Int32>

    // Mono bass atomics
    private let _monoBassEnabled:     ManagedAtomic<Int32>
    private let _monoBassCrossoverBits: ManagedAtomic<Int32>  // Float bits, Hz

    // Mains high-pass atomics
    private let _mainsHighPassEnabled:     ManagedAtomic<Int32>
    private let _mainsHighPassFrequencyBits: ManagedAtomic<Int32>  // Float bits, Hz

    // System volume feed atomics
    private let _systemVolumeBits: ManagedAtomic<Int32>  // Float bits, 0.0–1.0

    // MARK: - Advanced Metrics (audio → main)

    private let _phaseCorrelationBits:   ManagedAtomic<Int32>  // Float bits, −1 to +1
    private let _crestFactorBits:        ManagedAtomic<Int32>  // Float bits, dB
    private let _balanceMeterBits:       ManagedAtomic<Int32>  // Float bits, −1 to +1
    private let _truePeakClipperTripped: ManagedAtomic<Int32>  // sticky 0 / 1
    private let _truePeakLimiterTripped: ManagedAtomic<Int32>  // sticky 0 / 1

    // MARK: - Public GR Accessors

    var gainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _gainReductionBits.load(ordering: .relaxed)))
    }
    var clipperEngaged: Bool {
        _clipperActiveBits.load(ordering: .relaxed) != 0
    }
    var deEsserGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _deEsserGRBits.load(ordering: .relaxed)))
    }
    var mbLowGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbLowGRBits.load(ordering: .relaxed)))
    }
    var mbMidGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbMidGRBits.load(ordering: .relaxed)))
    }
    var mbHighGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _mbHighGRBits.load(ordering: .relaxed)))
    }
    var compressorGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _compGRBits.load(ordering: .relaxed)))
    }
    var expanderGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _expGRBits.load(ordering: .relaxed)))
    }
    var clipperGainReductionDB: Float {
        Float(bitPattern: UInt32(bitPattern: _clipperGRBits.load(ordering: .relaxed)))
    }

    // MARK: - Advanced Metric Accessors

    /// Smoothed Pearson L/R phase correlation (−1.0 anti-phase … +1.0 in-phase).
    var livePhaseCorrelation: Float {
        Float(bitPattern: UInt32(bitPattern: _phaseCorrelationBits.load(ordering: .relaxed)))
    }
    /// Peak-to-RMS crest factor in dB measured after the compressor stage.
    var liveCrestFactorDB: Float {
        Float(bitPattern: UInt32(bitPattern: _crestFactorBits.load(ordering: .relaxed)))
    }
    /// Instantaneous balance meter (−1.0 = full left, 0.0 = centre, +1.0 = full right).
    var liveBalanceMeter: Float {
        Float(bitPattern: UInt32(bitPattern: _balanceMeterBits.load(ordering: .relaxed)))
    }
    /// True if the soft clipper output exceeded 0 dBFS since the last `clearTruePeakFlags()`.
    var truePeakClipperTripped: Bool {
        _truePeakClipperTripped.load(ordering: .relaxed) != 0
    }
    /// True if the brickwall limiter ceiling was breached since the last `clearTruePeakFlags()`.
    var truePeakLimiterTripped: Bool {
        _truePeakLimiterTripped.load(ordering: .relaxed) != 0
    }
    /// Resets the sticky true-peak trip flags. Call from the main thread after showing the indicator.
    func clearTruePeakFlags() {
        _truePeakClipperTripped.store(0, ordering: .relaxed)
        _truePeakLimiterTripped.store(0, ordering: .relaxed)
        mainLimiter.clearTruePeakTripped()
    }

    // MARK: - Initialization

    init(channelCount: UInt32, sampleRate: Double, maxFrameCount: Int = 4096) {
        let ch = Int(channelCount)
        self.channelCount    = ch
        self.storedSampleRate = sampleRate
        self.storedMaxFrameCount = maxFrameCount
        self.clipperLimiterSampleRate = sampleRate
        self.currentLimiterAttackMs = 0.0001
        self.currentLimiterReleaseMs = 0.020
        self.currentLimiterLookAheadMs = 2.0

        // Look-ahead ring buffers
        var labufs: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<ch {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLookAheadSamples)
            p.initialize(repeating: 0, count: Self.maxLookAheadSamples)
            labufs.append(p)
        }
        self.lookAheadBufs = labufs
        self.lookAheadSize = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: 2.0)

        // De-esser: 2 state vars per channel
        self.deEsserFilterState = Array(repeating: 0.0, count: ch * 2)

        // Multiband: 16 state vars per channel (gentle stages 0-1)
        self.mbFilterState      = Array(repeating: 0.0, count: ch * 16)
        // Steep extra stages: 16 state vars per channel (steep stages 2-3)
        self.mbFilterStateSteep = Array(repeating: 0.0, count: ch * 16)

        // Multiband temp band buffers: [3 bands][channelCount]
        var bandBufs: [[UnsafeMutablePointer<Float>]] = []
        for _ in 0..<3 {
            var chBufs: [UnsafeMutablePointer<Float>] = []
            for _ in 0..<ch {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
                p.initialize(repeating: 0, count: maxFrameCount)
                chBufs.append(p)
            }
            bandBufs.append(chBufs)
        }
        self.mbBandBufs = bandBufs

        // Expander fixed alphas
        self.expanderAlphaAttack  = Self.computeAlpha(tauSeconds: 0.005, sampleRate: sampleRate)
        self.expanderAlphaRelease = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sampleRate)

        // Precomputed compressor alphas from default settings
        let compAlphaAtt = Self.computeAlpha(tauSeconds: 0.025, sampleRate: sampleRate)
        let compAlphaRel = Self.computeAlpha(tauSeconds: 0.150, sampleRate: sampleRate)

        // Limiter defaults
        let defCeiling   = Self.dbToLinear(-0.2)
        let limAlphaAtt  = Self.computeAlpha(tauSeconds: 0.0001, sampleRate: sampleRate)
        let limAlphaRel  = Self.computeAlpha(tauSeconds: 0.020,  sampleRate: sampleRate)

        // Stereo widener + LUFS processor
        self.stereoWidener = StereoWidener(maxFrameCount: maxFrameCount)
        self.lufsProcessor = LoudnessMatchProcessor()

        // Look-ahead limiter (extracted from inline implementation)
        self.mainLimiter = LookAheadLimiter(channelCount: ch, sampleRate: sampleRate, lookAheadMs: 2.0)

        // Lightweight PRNG for dither (seeded with sample rate for determinism)
        self.ditherRNG = DSPRNG(seed: UInt64(sampleRate * 1000))

        // Atomics — de-esser
        _deEsserEnabled    = ManagedAtomic(0)
        _deEsserFreqBits   = ManagedAtomic(floatBits(6000.0))
        _deEsserThreshBits = ManagedAtomic(floatBits(-20.0))

        // Atomics — multiband
        _mbEnabled        = ManagedAtomic(0)
        _mbCrossLMBits    = ManagedAtomic(floatBits(150.0))
        _mbCrossMHBits    = ManagedAtomic(floatBits(3000.0))
        _mbThreshLowBits  = ManagedAtomic(floatBits(0.0))
        _mbThreshMidBits  = ManagedAtomic(floatBits(0.0))
        _mbThreshHighBits = ManagedAtomic(floatBits(0.0))
        _mbSlopeLMBits    = ManagedAtomic(0)  // gentle
        _mbSlopeMHBits    = ManagedAtomic(0)  // gentle

        // Atomics — compressor
        _compEnabled      = ManagedAtomic(0)
        _compThreshBits   = ManagedAtomic(floatBits(-16.0))
        _compRatioBits    = ManagedAtomic(floatBits(3.5))
        _compAlphaAttack  = ManagedAtomic(floatBits(compAlphaAtt))
        _compAlphaRelease = ManagedAtomic(floatBits(compAlphaRel))
        _compMakeupBits   = ManagedAtomic(floatBits(Self.dbToLinear(2.5)))
        _compKneeWidthBits = ManagedAtomic(floatBits(6.0))
        _compProgramDependentRelease = ManagedAtomic(0)
        _compSidechainHighPassBits = ManagedAtomic(floatBits(0.0))
        self.compSidechainHPState = Array(repeating: 0.0, count: Int(channelCount) * 2)

        // Atomics — expander
        _expEnabled     = ManagedAtomic(0)
        _expThreshBits  = ManagedAtomic(floatBits(-50.0))  // Lower threshold for less aggressive expansion
        _expRatioBits   = ManagedAtomic(floatBits(2.0))   // Higher ratio for more effective noise reduction
        _expRangeDBBits = ManagedAtomic(floatBits(-24.0)) // Wider range for more dynamic range

        // Atomics — soft clipper
        _softClipperEnabled   = ManagedAtomic(0)
        _softClipperDrive     = ManagedAtomic(floatBits(Self.dbToLinear(0.0)))
        _softClipperThreshold = ManagedAtomic(floatBits(Self.dbToLinear(-1.5)))
        _softClipperKnee      = ManagedAtomic(floatBits(0.5))

        // Atomics — limiter
        _limiterEnabled      = ManagedAtomic(1)
        _limiterCeiling      = ManagedAtomic(floatBits(defCeiling))
        _limiterAlphaAttack  = ManagedAtomic(floatBits(limAlphaAtt))
        _limiterAlphaRelease = ManagedAtomic(floatBits(limAlphaRel))

        // GR reporting
        _gainReductionBits = ManagedAtomic(floatBits(0.0))
        _clipperActiveBits = ManagedAtomic(0)
        _deEsserGRBits     = ManagedAtomic(floatBits(0.0))
        _mbLowGRBits       = ManagedAtomic(floatBits(0.0))
        _mbMidGRBits       = ManagedAtomic(floatBits(0.0))
        _mbHighGRBits      = ManagedAtomic(floatBits(0.0))
        _compGRBits        = ManagedAtomic(floatBits(0.0))
        _expGRBits         = ManagedAtomic(floatBits(0.0))
        _clipperGRBits     = ManagedAtomic(floatBits(0.0))

        // Advanced DSP buffers
        var delays: [UnsafeMutablePointer<Float>] = []
        var deltas: [UnsafeMutablePointer<Float>] = []
        var irBufs: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<ch {
            let dBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDelaySamples)
            dBuf.initialize(repeating: 0, count: Self.maxDelaySamples)
            delays.append(dBuf)
            let dtBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
            dtBuf.initialize(repeating: 0, count: maxFrameCount)
            deltas.append(dtBuf)
            let irBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxIRAlignSamples)
            irBuf.initialize(repeating: 0, count: Self.maxIRAlignSamples)
            irBufs.append(irBuf)
        }
        // Low band delay buffer (single channel for mono low signal)
        // Fixed maximum size for 100 ms at 192 kHz
        let lowBandBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLowBandDelaySamples)
        lowBandBuf.initialize(repeating: 0, count: Self.maxLowBandDelaySamples)
        self.lowBandDelayBuf = lowBandBuf
        self.timeDelayBufs = delays
        self.deltaBufs     = deltas
        self.irAlignBufs   = irBufs

        // Advanced DSP state arrays (initialised to zero = neutral)
        self.dcOffsetState = Array(repeating: 0.0, count: 2 * ch)
        self.deharshState  = Array(repeating: 0.0, count: 2 * ch)
        self.contourState  = Array(repeating: 0.0, count: 4 * ch)
        self.noiseShapeState = Array(repeating: 0.0, count: ch * 5)
        self.subBassPhaseState = Array(repeating: 0.0, count: ch * 4)
        self.monoBassLowpassState = Array(repeating: 0.0, count: ch * 2)
        self.irAlignApState = Array(repeating: 0.0, count: ch * 5)
        self.crosstalkFilterState = Array(repeating: 0.0, count: ch)
        self.denoisers = (0..<ch).map { _ in SpectralDenoiser() }

        // Bass Management state (pre-allocated buffers to avoid audio-thread heap allocation)
        self.bassManagementStateBuf = UnsafeMutablePointer<Float>
            .allocate(capacity: Self.maxBassManagementStateTotal)
        self.bassManagementStateBuf.initialize(repeating: 0, count: Self.maxBassManagementStateTotal)

        self.pendingBassManagementStateBuf = UnsafeMutablePointer<Float>
            .allocate(capacity: Self.maxBassManagementStateTotal)
        self.pendingBassManagementStateBuf.initialize(repeating: 0, count: Self.maxBassManagementStateTotal)

        let defaultSlope = BassCrossoverSlope.lr4
        let defaultSectionCount = defaultSlope.cascadedStageCount
        let defaultStateSize = defaultSectionCount * 4  // 2 state vars * 2 paths per section
        self.bassManagementStateSize = defaultStateSize
        self.pendingBassManagementStateSize = defaultStateSize
        self.bassManagementCrossover = BassManagementCrossover(
            crossoverHz: 80.0,
            slope: defaultSlope,
            sampleRate: sampleRate,
            crossoverType: .linkwitzRiley
        )
        self.pendingBassCrossover = self.bassManagementCrossover
        self.hasBassCrossoverUpdate = ManagedAtomic(false)

        // Mains high-pass crossover (for asymmetric mode) - pre-allocated buffers
        self.mainsHighPassStateBuf = UnsafeMutablePointer<Float>
            .allocate(capacity: Self.maxBassManagementStateTotal)
        self.mainsHighPassStateBuf.initialize(repeating: 0, count: Self.maxBassManagementStateTotal)

        self.pendingMainsHighPassStateBuf = UnsafeMutablePointer<Float>
            .allocate(capacity: Self.maxBassManagementStateTotal)
        self.pendingMainsHighPassStateBuf.initialize(repeating: 0, count: Self.maxBassManagementStateTotal)

        self.mainsHighPassStateSize = defaultStateSize
        self.pendingMainsHighPassStateSize = defaultStateSize
        self.mainsHighPassCrossover = BassManagementCrossover(
            crossoverHz: 80.0,
            slope: defaultSlope,
            sampleRate: sampleRate,
            crossoverType: .linkwitzRiley
        )
        self.pendingMainsHighPassCrossover = self.mainsHighPassCrossover
        self.hasMainsHighPassUpdate = ManagedAtomic(false)

        // Bass management scratch buffers (pre-allocated to maxFrameCount)
        self.bmLowL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        self.bmLowL.initialize(repeating: 0, count: maxFrameCount)
        self.bmLowR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        self.bmLowR.initialize(repeating: 0, count: maxFrameCount)
        self.bmHighL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        self.bmHighL.initialize(repeating: 0, count: maxFrameCount)
        self.bmHighR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        self.bmHighR.initialize(repeating: 0, count: maxFrameCount)
        self.bmMonoLow = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        self.bmMonoLow.initialize(repeating: 0, count: maxFrameCount)

        self.lowBandLowShelfState = Array(repeating: 0.0, count: 2)
        self.lowBandDelayApState = Array(repeating: 0.0, count: 5)

        // Sub EQ state (2 state vars per band)
        self.subEQState = Array(repeating: 0.0, count: 2 * BassManagementConfig.maxSubEQBands)

        // Allocate Sub EQ coefficient and bypass buffers (pre-allocated to avoid audio-thread heap allocation)
        let maxSubBands = BassManagementConfig.maxSubEQBands
        self.subEQCoeffsBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxSubEQStateFloats)
        self.subEQCoeffsBuf.initialize(repeating: 0, count: Self.maxSubEQStateFloats)

        self.pendingSubEQCoeffsBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxSubEQStateFloats)
        self.pendingSubEQCoeffsBuf.initialize(repeating: 0, count: Self.maxSubEQStateFloats)

        self.subEQBypassBuf = UnsafeMutablePointer<Int32>.allocate(capacity: maxSubBands)
        self.subEQBypassBuf.initialize(repeating: 0, count: maxSubBands)

        self.pendingSubEQBypassBuf = UnsafeMutablePointer<Int32>.allocate(capacity: maxSubBands)
        self.pendingSubEQBypassBuf.initialize(repeating: 0, count: maxSubBands)

        self.hasSubEQUpdate = ManagedAtomic(false)

        // Dynamic EQ state (2 state vars per band for filter, 1 for envelope, 1 for GR)
        // State arrays are indexed [ch * maxBands * 2 + band * 2 + {0,1}] for filter,
        // and [ch * maxBands + band] for envelope / gain-reduction.
        let maxCh = Int(channelCount)
        let maxBands = DynamicEQConfig.maxDynamicEQBands
        self.dynamicEQFilterState = Array(repeating: 0.0, count: maxCh * maxBands * 2)
        self.dynamicEQEnvelopeState = Array(repeating: 0.0, count: maxCh * maxBands)
        self.dynamicEQGainReductionDB = Array(repeating: 0.0, count: maxCh * maxBands)

        // Allocate Dynamic EQ coefficient and parameter buffers (pre-allocated to avoid audio-thread heap allocation)
        self.dynamicEQCoeffsBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDynamicEQStateFloats)
        self.dynamicEQCoeffsBuf.initialize(repeating: 0, count: Self.maxDynamicEQStateFloats)

        self.pendingDynEQCoeffsBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDynamicEQStateFloats)
        self.pendingDynEQCoeffsBuf.initialize(repeating: 0, count: Self.maxDynamicEQStateFloats)

        self.dynamicEQBypassBuf = UnsafeMutablePointer<Int32>.allocate(capacity: maxBands)
        self.dynamicEQBypassBuf.initialize(repeating: 0, count: maxBands)

        self.pendingDynEQBypassBuf = UnsafeMutablePointer<Int32>.allocate(capacity: maxBands)
        self.pendingDynEQBypassBuf.initialize(repeating: 0, count: maxBands)

        self.dynamicEQParamsBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDynamicEQParamsFloats)
        self.dynamicEQParamsBuf.initialize(repeating: 0, count: Self.maxDynamicEQParamsFloats)

        self.pendingDynEQParamsBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDynamicEQParamsFloats)
        self.pendingDynEQParamsBuf.initialize(repeating: 0, count: Self.maxDynamicEQParamsFloats)

        self.dynamicEQAttackCoeffsBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxBands)
        self.dynamicEQAttackCoeffsBuf.initialize(repeating: 0, count: maxBands)

        self.dynamicEQReleaseCoeffsBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxBands)
        self.dynamicEQReleaseCoeffsBuf.initialize(repeating: 0, count: maxBands)

        self.hasDynamicEQUpdate = ManagedAtomic(false)

        // FIR Impulse Response — ConvolutionEngine for FFT-based partitioned convolution
        self.firConvolutionEngine = ConvolutionEngine()
        self._firEnabled = ManagedAtomic(0)

        // Advanced processing atomics (main → audio)
        _stereoMode             = ManagedAtomic(Int32(StereoModeSelection.stereo.rawValue))
        _dcOffsetEnabled        = ManagedAtomic(0)
        _dialogueGateEnabled    = ManagedAtomic(0)
        _loudnessContourEnabled = ManagedAtomic(0)
        _loudnessRefPhonBits    = ManagedAtomic(floatBits(83.0))
        _loudnessRefVolBits     = ManagedAtomic(floatBits(0.85))
        _volumeDependentBits    = ManagedAtomic(0)
        _deesserDynModeEnabled  = ManagedAtomic(0)
        _asymmetryTrimBits      = ManagedAtomic(floatBits(0.0))
        _deharshEnabled         = ManagedAtomic(0)
        _deharshTiltBits        = ManagedAtomic(floatBits(-1.5))
        _balanceBits            = ManagedAtomic(floatBits(0.0))
        _symmetryBalanceEnabled = ManagedAtomic(0)
        _channelBalanceBits     = ManagedAtomic(floatBits(0.0))
        _tpGuardEnabled               = ManagedAtomic(0)
        _panningEnabled       = ManagedAtomic(0)
        _panningCrossfeedBits = ManagedAtomic(floatBits(0.3))
        _irAlignEnabled       = ManagedAtomic(0)
        _irAlignDelayBits     = ManagedAtomic(floatBits(0.0))
        _crosstalkEnabled     = ManagedAtomic(0)
        _crosstalkAmountBits  = ManagedAtomic(floatBits(0.5))
        _denoisingEnabled       = ManagedAtomic(0)
        _denoisingThresholdBits = ManagedAtomic(floatBits(-60.0))
        _denoisingWienerFloorBits = ManagedAtomic(floatBits(0.01))
        _autoHeadroomEnabled          = ManagedAtomic(0)
        _autoHeadroomAlphaBits        = ManagedAtomic(floatBits(
            Float(exp(-Double(512) / (10.0 * sampleRate)))))
        _autoHeadroomTargetGRBits     = ManagedAtomic(floatBits(3.0))
        _autoHeadroomMaxReductBits    = ManagedAtomic(floatBits(6.0))
        _timeDelayBits          = ManagedAtomic(floatBits(0.0))
        _deltaSoloEnabled       = ManagedAtomic(0)
        _latencyModeBits        = ManagedAtomic(Int32(LatencyMode.music.rawValue))
        _pauseGateEnabled            = ManagedAtomic(0)
        _pauseGateThresholdBits      = ManagedAtomic(floatBits(1e-6))
        _pauseGateHoldAlphaBits      = ManagedAtomic(floatBits(Float(exp(-1.0 / (sampleRate * 0.500)))))
        _pauseGateAttackAlphaBits    = ManagedAtomic(floatBits(Float(exp(-1.0 / (sampleRate * 0.010)))))
        _pauseGateReleaseAlphaBits   = ManagedAtomic(floatBits(Float(exp(-1.0 / (sampleRate * 0.200)))))
        _pauseGateHysteresisBits     = ManagedAtomic(floatBits(pow(10.0, 3.0 / 20.0)))
        _syncBufferEnabled      = ManagedAtomic(0)
        _ditherModeBits         = ManagedAtomic(Int32(DitherMode.bypass.rawValue))
        _subBassPhaseEnabled  = ManagedAtomic(0)
        _subBassPhaseFreqBits = ManagedAtomic(floatBits(80.0))
        _subBassPhaseQBits    = ManagedAtomic(floatBits(0.7))
        _oversamplingEnabled = ManagedAtomic(0)

        // Mono bass atomics
        _monoBassEnabled = ManagedAtomic(0)
        _monoBassCrossoverBits = ManagedAtomic(floatBits(80.0))

        // Mains high-pass atomics
        _mainsHighPassEnabled = ManagedAtomic(0)
        _mainsHighPassFrequencyBits = ManagedAtomic(floatBits(80.0))

        // Bass Management atomics
        _bassManagementEnabled = ManagedAtomic(0)
        _asymmetricCrossoverEnabled = ManagedAtomic(0)
        _dynamicEQEnabled = ManagedAtomic(0)
        _bassManagementCrossoverHzBits = ManagedAtomic(floatBits(80.0))
        _bassManagementSlopeBits = ManagedAtomic(Int32(BassCrossoverSlope.lr4.rawValue))
        _lowBandGainDBBits = ManagedAtomic(floatBits(0.0))
        _lowBandPolarityInverted = ManagedAtomic(0)
        _lowBandLowShelfEnabled = ManagedAtomic(0)
        _lowBandLowShelfFreqBits = ManagedAtomic(floatBits(30.0))
        _lowBandLowShelfGainBits = ManagedAtomic(floatBits(0.0))
        _lowBandDelaySamplesBits = ManagedAtomic(floatBits(0.0))

        // Infrasonic filter state arrays (32 floats for stereo, 16 for sub)
        self.infrasonicState = Array(repeating: 0.0, count: 32)
        self.infrasonicSubState = Array(repeating: 0.0, count: 16)

        // Pre-allocate infrasonic coefficient buffers (fixed-size, never reassigned)
        self.infrasonicCoeffB0 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicCoeffB1 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicCoeffB2 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicCoeffNA1 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicCoeffNA2 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffB0 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffB1 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffB2 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffNA1 = .allocate(capacity: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffNA2 = .allocate(capacity: Self.maxInfrasonicSections)

        // Initialize all coefficient buffers to zero
        self.infrasonicCoeffB0.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicCoeffB1.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicCoeffB2.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicCoeffNA1.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicCoeffNA2.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffB0.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffB1.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffB2.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffNA1.initialize(repeating: 0, count: Self.maxInfrasonicSections)
        self.infrasonicPendingCoeffNA2.initialize(repeating: 0, count: Self.maxInfrasonicSections)

        // System volume feed atomics
        _systemVolumeBits = ManagedAtomic(floatBits(1.0))

        // Mono bass lowpass filters (2nd-order Butterworth at 80 Hz)
        monoBassLowpassL = BiquadFilter()
        monoBassLowpassR = BiquadFilter()
        let monoBassCoeffs = BiquadMath.calculateCoefficients(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 80.0,
            q: 0.7071,  // Butterworth Q
            gain: 0.0
        )
        monoBassLowpassL.setCoefficients(monoBassCoeffs, resetState: true)
        monoBassLowpassR.setCoefficients(monoBassCoeffs, resetState: true)

        // Mono bass highpass filters (2nd-order Butterworth at 80 Hz) for LP/HP split
        monoBassHighpassL = BiquadFilter()
        monoBassHighpassR = BiquadFilter()
        let monoBassHighpassCoeffs = BiquadMath.calculateCoefficients(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 80.0,
            q: 0.7071,  // Butterworth Q
            gain: 0.0
        )
        monoBassHighpassL.setCoefficients(monoBassHighpassCoeffs, resetState: true)
        monoBassHighpassR.setCoefficients(monoBassHighpassCoeffs, resetState: true)

        // Mains high-pass filters (2nd-order Butterworth at 80 Hz)
        mainsHighPassL = BiquadFilter()
        mainsHighPassR = BiquadFilter()
        let mainsHighPassCoeffs = BiquadMath.calculateCoefficients(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 80.0,
            q: 0.7071,  // Butterworth Q
            gain: 0.0
        )
        mainsHighPassL.setCoefficients(mainsHighPassCoeffs, resetState: true)
        mainsHighPassR.setCoefficients(mainsHighPassCoeffs, resetState: true)

        // Advanced metric atomics (audio → main)
        _phaseCorrelationBits   = ManagedAtomic(floatBits(0.0))
        _crestFactorBits        = ManagedAtomic(floatBits(0.0))
        _balanceMeterBits       = ManagedAtomic(floatBits(0.0))
        _truePeakClipperTripped = ManagedAtomic(0)
        _truePeakLimiterTripped = ManagedAtomic(0)

        // Initialize cached coefficients after all properties are set
        recomputeCompSidechainHPCoeffs()
    }

    deinit {
        for p in lookAheadBufs {
            p.deinitialize(count: Self.maxLookAheadSamples)
            p.deallocate()
        }
        for band in mbBandBufs {
            for p in band {
                p.deinitialize(count: storedMaxFrameCount)
                p.deallocate()
            }
        }
        for p in timeDelayBufs {
            p.deinitialize(count: Self.maxDelaySamples)
            p.deallocate()
        }
        for p in deltaBufs {
            p.deinitialize(count: storedMaxFrameCount)
            p.deallocate()
        }
        for p in irAlignBufs {
            p.deinitialize(count: Self.maxIRAlignSamples)
            p.deallocate()
        }
        lowBandDelayBuf.deinitialize(count: Self.maxLowBandDelaySamples)
        lowBandDelayBuf.deallocate()
        
        // Deallocate bass management scratch buffers
        bmLowL.deinitialize(count: storedMaxFrameCount)
        bmLowL.deallocate()
        bmLowR.deinitialize(count: storedMaxFrameCount)
        bmLowR.deallocate()
        bmHighL.deinitialize(count: storedMaxFrameCount)
        bmHighL.deallocate()
        bmHighR.deinitialize(count: storedMaxFrameCount)
        bmHighR.deallocate()
        bmMonoLow.deinitialize(count: storedMaxFrameCount)
        bmMonoLow.deallocate()

        // Deallocate bass management and mains high-pass state buffers
        bassManagementStateBuf.deinitialize(count: Self.maxBassManagementStateTotal)
        bassManagementStateBuf.deallocate()
        pendingBassManagementStateBuf.deinitialize(count: Self.maxBassManagementStateTotal)
        pendingBassManagementStateBuf.deallocate()
        mainsHighPassStateBuf.deinitialize(count: Self.maxBassManagementStateTotal)
        mainsHighPassStateBuf.deallocate()
        pendingMainsHighPassStateBuf.deinitialize(count: Self.maxBassManagementStateTotal)
        pendingMainsHighPassStateBuf.deallocate()

        // Deallocate Dynamic EQ coefficient and parameter buffers
        dynamicEQCoeffsBuf.deinitialize(count: Self.maxDynamicEQStateFloats)
        dynamicEQCoeffsBuf.deallocate()
        pendingDynEQCoeffsBuf.deinitialize(count: Self.maxDynamicEQStateFloats)
        pendingDynEQCoeffsBuf.deallocate()
        dynamicEQBypassBuf.deinitialize(count: DynamicEQConfig.maxDynamicEQBands)
        dynamicEQBypassBuf.deallocate()
        pendingDynEQBypassBuf.deinitialize(count: DynamicEQConfig.maxDynamicEQBands)
        pendingDynEQBypassBuf.deallocate()
        dynamicEQParamsBuf.deinitialize(count: Self.maxDynamicEQParamsFloats)
        dynamicEQParamsBuf.deallocate()
        pendingDynEQParamsBuf.deinitialize(count: Self.maxDynamicEQParamsFloats)
        pendingDynEQParamsBuf.deallocate()
        dynamicEQAttackCoeffsBuf.deinitialize(count: DynamicEQConfig.maxDynamicEQBands)
        dynamicEQAttackCoeffsBuf.deallocate()
        dynamicEQReleaseCoeffsBuf.deinitialize(count: DynamicEQConfig.maxDynamicEQBands)
        dynamicEQReleaseCoeffsBuf.deallocate()

        // Deallocate Sub EQ coefficient and bypass buffers
        subEQCoeffsBuf.deinitialize(count: Self.maxSubEQStateFloats)
        subEQCoeffsBuf.deallocate()
        pendingSubEQCoeffsBuf.deinitialize(count: Self.maxSubEQStateFloats)
        pendingSubEQCoeffsBuf.deallocate()
        subEQBypassBuf.deinitialize(count: BassManagementConfig.maxSubEQBands)
        subEQBypassBuf.deallocate()
        pendingSubEQBypassBuf.deinitialize(count: BassManagementConfig.maxSubEQBands)
        pendingSubEQBypassBuf.deallocate()

        // Deallocate infrasonic coefficient buffers
        infrasonicCoeffB0.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicCoeffB0.deallocate()
        infrasonicCoeffB1.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicCoeffB1.deallocate()
        infrasonicCoeffB2.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicCoeffB2.deallocate()
        infrasonicCoeffNA1.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicCoeffNA1.deallocate()
        infrasonicCoeffNA2.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicCoeffNA2.deallocate()
        infrasonicPendingCoeffB0.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicPendingCoeffB0.deallocate()
        infrasonicPendingCoeffB1.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicPendingCoeffB1.deallocate()
        infrasonicPendingCoeffB2.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicPendingCoeffB2.deallocate()
        infrasonicPendingCoeffNA1.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicPendingCoeffNA1.deallocate()
        infrasonicPendingCoeffNA2.deinitialize(count: Self.maxInfrasonicSections)
        infrasonicPendingCoeffNA2.deallocate()
    }

    // MARK: - Parameter Update API (main thread)

    func setDeEsserEnabled(_ v: Bool)        { _deEsserEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setDeEsserFrequencyHz(_ hz: Float)  { _deEsserFreqBits.store(floatBits(max(20.0, hz)), ordering: .relaxed) }
    func setDeEsserThresholdDB(_ db: Float)  { _deEsserThreshBits.store(floatBits(db), ordering: .relaxed) }

    func setMBEnabled(_ v: Bool)             { _mbEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setMBCrossLowMidHz(_ hz: Float)     { _mbCrossLMBits.store(floatBits(max(20.0, hz)), ordering: .relaxed) }
    func setMBCrossMidHighHz(_ hz: Float)    { _mbCrossMHBits.store(floatBits(max(20.0, hz)), ordering: .relaxed) }
    func setMBThresholdLowDB(_ db: Float)    { _mbThreshLowBits.store(floatBits(db),  ordering: .relaxed) }
    func setMBThresholdMidDB(_ db: Float)    { _mbThreshMidBits.store(floatBits(db),  ordering: .relaxed) }
    func setMBThresholdHighDB(_ db: Float)   { _mbThreshHighBits.store(floatBits(db), ordering: .relaxed) }
    func setMBSlopeLowMid(_ slope: CrossoverSlope)  { _mbSlopeLMBits.store(Int32(slope.rawValue), ordering: .relaxed) }
    func setMBSlopeMidHigh(_ slope: CrossoverSlope) { _mbSlopeMHBits.store(Int32(slope.rawValue), ordering: .relaxed) }

    func setCompressorEnabled(_ v: Bool)     { _compEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setCompressorThresholdDB(_ db: Float) { _compThreshBits.store(floatBits(db), ordering: .relaxed) }
    func setCompressorRatio(_ r: Float)      { _compRatioBits.store(floatBits(max(1.0, r)), ordering: .relaxed) }
    func setCompressorAttackMs(_ ms: Float, sampleRate: Double) {
        let tau = Double(max(ms, 0.1)) / 1000.0
        _compAlphaAttack.store(floatBits(Self.computeAlpha(tauSeconds: Float(tau), sampleRate: sampleRate)), ordering: .relaxed)
    }
    func setCompressorReleaseMs(_ ms: Float, sampleRate: Double) {
        let tau = Double(max(ms, 5.0)) / 1000.0
        _compAlphaRelease.store(floatBits(Self.computeAlpha(tauSeconds: Float(tau), sampleRate: sampleRate)), ordering: .relaxed)
    }
    func setCompressorProgramDependentRelease(_ v: Bool) {
        _compProgramDependentRelease.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setCompressorSidechainHighPassHz(_ hz: Float, sampleRate: Double) {
        _compSidechainHighPassBits.store(floatBits(hz), ordering: .relaxed)
        recomputeCompSidechainHPCoeffs()
    }

    private func recomputeCompSidechainHPCoeffs() {
        let sidechainHPHz = bitsToFloat(_compSidechainHighPassBits.load(ordering: .relaxed))
        if sidechainHPHz > 0.0 {
            let sampleRate = storedSampleRate
            let w = 2.0 * Float.pi * sidechainHPHz / Float(sampleRate)
            let q: Float = 0.7071 // Butterworth Q
            let k = tan(w * 0.5)
            let kDivQ = k / q
            let kSquared = k * k
            let denominator = 1.0 + kDivQ + kSquared
            let norm = 1.0 / denominator
            compSidechainHPCoeffs = (
                b0: 1.0 * norm,
                b1: -2.0 * norm,
                b2: 1.0 * norm,
                a1: 2.0 * (kSquared - 1.0) * norm,
                a2: (1.0 - kDivQ + kSquared) * norm
            )
        } else {
            compSidechainHPCoeffs = (1.0, 0.0, 0.0, 0.0, 0.0)
        }
    }
    func setCompressorMakeupGainDB(_ db: Float) {
        _compMakeupBits.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }
    func setCompressorKneeWidthDB(_ db: Float) {
        _compKneeWidthBits.store(floatBits(max(0.0, min(20.0, db))), ordering: .relaxed)
    }

    func setExpanderEnabled(_ v: Bool)       { _expEnabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setExpanderThresholdDB(_ db: Float) { _expThreshBits.store(floatBits(db), ordering: .relaxed) }
    func setExpanderRatio(_ r: Float)        { _expRatioBits.store(floatBits(max(1.0, r)), ordering: .relaxed) }
    func setExpanderRangeDB(_ db: Float)     { _expRangeDBBits.store(floatBits(min(0.0, db)), ordering: .relaxed) }

    func setSoftClipperEnabled(_ enabled: Bool) { _softClipperEnabled.store(enabled ? 1 : 0, ordering: .relaxed) }
    func setSoftClipperDriveDB(_ db: Float) {
        _softClipperDrive.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }
    func setSoftClipperThresholdDB(_ db: Float) {
        _softClipperThreshold.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }
    func setSoftClipperKnee(_ knee: Float) {
        _softClipperKnee.store(floatBits(max(0.001, min(1.0, knee))), ordering: .relaxed)
    }

    func setLimiterEnabled(_ enabled: Bool) {
        _limiterEnabled.store(enabled ? 1 : 0, ordering: .relaxed)
        mainLimiter.setEnabled(enabled)
    }
    func setLimiterCeilingDB(_ db: Float) {
        _limiterCeiling.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
        mainLimiter.setCeilingDB(db)
    }
    func setLimiterAttackMs(_ ms: Float, sampleRate: Double) {
        let tau = max(ms, 0.0) / 1000.0
        let alpha: Float = tau < 1e-7 ? 0.0 : Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)
        _limiterAlphaAttack.store(floatBits(alpha), ordering: .relaxed)
        currentLimiterAttackMs = ms
        mainLimiter.setAttackMs(ms, sampleRate: sampleRate)
    }
    func setLimiterReleaseMs(_ ms: Float, sampleRate: Double) {
        let tau = ms / 1000.0
        _limiterAlphaRelease.store(floatBits(Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)), ordering: .relaxed)
        currentLimiterReleaseMs = ms
        mainLimiter.setReleaseMs(ms, sampleRate: sampleRate)
    }
    func setLimiterLookAheadMs(_ ms: Float, sampleRate: Double) {
        let newSize = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: ms)
        guard newSize != lookAheadSize else { return }
        for p in lookAheadBufs { p.initialize(repeating: 0, count: Self.maxLookAheadSamples) }
        lookAheadWriteIndex = 0
        limiterGainCurrent  = 1.0
        lookAheadSize = newSize
        currentLimiterLookAheadMs = ms
        mainLimiter.setLookAheadMs(ms, sampleRate: sampleRate)
    }
    func setOversamplingActive(_ active: Bool, factor: Int) {
        clipperLimiterSampleRate = active ? storedSampleRate * Double(factor) : storedSampleRate
        // Recompute limiter alphas + lookahead at the new effective rate
        setLimiterAttackMs(currentLimiterAttackMs, sampleRate: clipperLimiterSampleRate)
        setLimiterReleaseMs(currentLimiterReleaseMs, sampleRate: clipperLimiterSampleRate)
        setLimiterLookAheadMs(currentLimiterLookAheadMs, sampleRate: clipperLimiterSampleRate)
    }

    func setSystemVolume(_ volume: Float) {
        _systemVolumeBits.store(floatBits(max(0.0, min(1.0, volume))), ordering: .relaxed)
    }

    // MARK: - Advanced Processing Setters (main thread)

    func setStereoMode(_ mode: StereoModeSelection) {
        _stereoMode.store(Int32(mode.rawValue), ordering: .relaxed)
    }
    func setDCOffsetFilterEnabled(_ v: Bool) {
        _dcOffsetEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setDialogueGateEnabled(_ v: Bool) {
        _dialogueGateEnabled.store(v ? 1 : 0, ordering: .relaxed)
        lufsProcessor.setDialogueGateEnabled(v)
    }
    func setLoudnessContourEnabled(_ v: Bool) {
        _loudnessContourEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setLoudnessReferencePhon(_ v: Float) {
        _loudnessRefPhonBits.store(floatBits(v), ordering: .relaxed)
    }
    func setLoudnessReferenceVolume(_ v: Float) {
        _loudnessRefVolBits.store(floatBits(v), ordering: .relaxed)
    }
    func setVolumeDependentLoudnessEnabled(_ v: Bool) {
        _volumeDependentBits.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setDeesserDynamicModeEnabled(_ v: Bool) {
        _deesserDynModeEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setClipperAsymmetryTrimDB(_ db: Float) {
        _asymmetryTrimBits.store(floatBits(max(-3.0, min(3.0, db))), ordering: .relaxed)
    }
    func setDeharshFilterEnabled(_ v: Bool) {
        _deharshEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setDeharshTiltAmountDB(_ db: Float) {
        _deharshTiltBits.store(floatBits(max(-6.0, min(0.0, db))), ordering: .relaxed)
    }
    func setStereoBalancePosition(_ balance: Float) {
        _balanceBits.store(floatBits(max(-1.0, min(1.0, balance))), ordering: .relaxed)
    }
    func setSymmetryBalanceEnabled(_ v: Bool) {
        _symmetryBalanceEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setPanningEnabled(_ v: Bool) {
        _panningEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setPanningCrossfeedAmount(_ amount: Float) {
        _panningCrossfeedBits.store(floatBits(max(0.0, min(0.5, amount))), ordering: .relaxed)
    }
    func setIRAlignmentEnabled(_ v: Bool) {
        _irAlignEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setIRAlignmentDelayMs(_ ms: Float) {
        _irAlignDelayBits.store(floatBits(max(0.0, min(5.0, ms))), ordering: .relaxed)
    }
    func setCrosstalkEnabled(_ v: Bool) {
        _crosstalkEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setCrosstalkAmount(_ amount: Float) {
        _crosstalkAmountBits.store(floatBits(max(0.0, min(0.5, amount))), ordering: .relaxed)
    }
    func setDenoisingEnabled(_ v: Bool) {
        _denoisingEnabled.store(v ? 1 : 0, ordering: .relaxed)
        if !v { denoisers.forEach { $0.reset() } }
    }
    func setDenoisingThresholdDB(_ db: Float) {
        _denoisingThresholdBits.store(floatBits(max(-80.0, min(-40.0, db))), ordering: .relaxed)
        let linear = pow(10.0, max(-80.0, min(-40.0, db)) / 20.0)
        denoisers.forEach { $0.setNoiseFloorDB(Float(linear > 0 ? 20.0 * log10(linear) : -80.0)) }
    }
    func setDenoisingWienerFloor(_ floor: Float) {
        _denoisingWienerFloorBits.store(floatBits(max(0.0, min(1.0, floor))), ordering: .relaxed)
        denoisers.forEach { $0.setWienerFloor(floor) }
    }
    func setDenoisingPreset(_ preset: DenoiserPreset) {
        let (noiseFloorDB, wienerFloor) = preset.parameters
        setDenoisingThresholdDB(noiseFloorDB)
        setDenoisingWienerFloor(wienerFloor)
    }
    func startNoiseCapture() {
        denoisers.forEach { $0.startNoiseCapture() }
    }
    func resetNoiseProfile() {
        denoisers.forEach { $0.resetNoiseProfile() }
    }
    func setChannelBalance(_ balance: Float) {
        _channelBalanceBits.store(floatBits(max(-1.0, min(1.0, balance))), ordering: .relaxed)
    }
    func setLimiterTruePeakGuardEnabled(_ v: Bool) {
        _tpGuardEnabled.store(v ? 1 : 0, ordering: .relaxed)
        mainLimiter.setTruePeakGuardEnabled(v)
    }
    func setAutoHeadroomEnabled(_ v: Bool) {
        _autoHeadroomEnabled.store(v ? 1 : 0, ordering: .relaxed)
        if !v {
            // Reset rider state when disabled so re-enabling starts from neutral.
            autoHeadroomGRAccumDB = 0.0
            autoHeadroomGainDB    = 0.0
        }
    }

    /// Recomputes the per-callback alpha and stores the target/maxReduction parameters.
    /// Must be called whenever speed, sample rate, OR frame count changes.
    func setAutoHeadroomParameters(
        speed: AutoHeadroomSpeed,
        targetGRDB: Float,
        maxReductionDB: Float,
        sampleRate: Double,
        typicalFrameCount: Int
    ) {
        let tc = speed.timeConstantSeconds
        // Alpha is defined per callback (not per sample). At steady-state buffer sizes
        // this is precise; at variable buffer sizes the rider moves slightly faster or
        // slower but remains stable and audibly correct.
        let alpha = Float(exp(-Double(typicalFrameCount) / (tc * sampleRate)))
        _autoHeadroomAlphaBits.store(floatBits(alpha), ordering: .relaxed)
        _autoHeadroomTargetGRBits.store(floatBits(max(0.0, targetGRDB)), ordering: .relaxed)
        _autoHeadroomMaxReductBits.store(floatBits(max(0.0, maxReductionDB)), ordering: .relaxed)
    }
    func setStereoTimeDelayMS(_ ms: Float) {
        _timeDelayBits.store(floatBits(max(-20.0, min(20.0, ms))), ordering: .relaxed)
    }
    func setDeltaSoloActive(_ v: Bool) {
        _deltaSoloEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setLatencyMode(_ mode: LatencyMode) {
        _latencyModeBits.store(Int32(mode.rawValue), ordering: .relaxed)
    }
    func setPauseGateEnabled(_ v: Bool) {
        _pauseGateEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    /// Sets the five pause-gate parameters from an `AdvancedProcessingConfig`.
    /// All alpha values are recomputed from millisecond inputs here on the main thread
    /// so the audio thread only reads pre-baked coefficients.
    func setPauseGateParameters(
        thresholdDBFS: Float,
        holdMs:        Float,
        attackMs:      Float,
        releaseMs:     Float,
        hysteresisDB:  Float
    ) {
        let sr = storedSampleRate
        // Convert dBFS threshold to linear RMS power: P = 10^(dBFS/10)
        let thresholdPower = pow(10.0, Double(thresholdDBFS) / 10.0)
        _pauseGateThresholdBits.store(
            floatBits(Float(thresholdPower)), ordering: .relaxed)
        // Pre-bake alpha coefficients: alpha = exp(−1 / (sr × t_seconds))
        let holdAlpha    = Float(exp(-1.0 / (sr * Double(max(holdMs,    1)) / 1000.0)))
        let attackAlpha  = Float(exp(-1.0 / (sr * Double(max(attackMs,  0.1)) / 1000.0)))
        let releaseAlpha = Float(exp(-1.0 / (sr * Double(max(releaseMs, 1)) / 1000.0)))
        _pauseGateHoldAlphaBits.store(floatBits(holdAlpha),    ordering: .relaxed)
        _pauseGateAttackAlphaBits.store(floatBits(attackAlpha),  ordering: .relaxed)
        _pauseGateReleaseAlphaBits.store(floatBits(releaseAlpha), ordering: .relaxed)
        // Hysteresis factor: linear amplitude ratio for the close-threshold reduction
        let hystFactor = pow(10.0, Double(max(hysteresisDB, 0)) / 20.0)
        _pauseGateHysteresisBits.store(floatBits(Float(hystFactor)), ordering: .relaxed)
    }
    func setHardwareSyncBufferEnabled(_ v: Bool) {
        _syncBufferEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setDitherMode(_ mode: DitherMode) {
        _ditherModeBits.store(Int32(mode.rawValue), ordering: .relaxed)
    }
    func setSubBassPhaseAlignmentEnabled(_ v: Bool) {
        // Clear filter state whenever the feature is turned on so that any NaN/Inf
        // residue from a previous divergence (before the coefficient-sign fix) cannot
        // survive a disable→re-enable cycle and immediately blow up the pipeline again.
        if v { for i in 0..<subBassPhaseState.count { subBassPhaseState[i] = 0 } }
        _subBassPhaseEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setSubBassAlignmentFrequencyHz(_ hz: Float) {
        _subBassPhaseFreqBits.store(floatBits(max(20.0, min(200.0, hz))), ordering: .relaxed)
    }
    func setSubBassPhaseQ(_ q: Float) {
        _subBassPhaseQBits.store(floatBits(max(0.1, min(4.0, q))), ordering: .relaxed)
    }
    func setOversamplingEnabled(_ v: Bool) {
        _oversamplingEnabled.store(v ? 1 : 0, ordering: .relaxed)
        // Update clipper/limiter effective sample rate
        setOversamplingActive(v, factor: 4) // 4× oversampling factor
    }
    func setInfrasonicFilterConfig(_ config: InfrasonicFilterConfig, sampleRate: Double) {
        _infrasonicEnabled.store(config.isEnabled ? 1 : 0, ordering: .releasing)
        _infrasonicTarget.store(Int32(config.target.rawValue), ordering: .releasing)

        guard config.isEnabled else {
            infrasonicPendingSectionCount = 0
            hasInfrasonicUpdate.store(true, ordering: .releasing)
            return
        }

        // Compute Butterworth HP sections for the selected slope and cutoff.
        // Use BiquadMath.calculateSections with highPass type and appropriate FilterSlope.
        let slope = mapToFilterSlope(config.slope)
        let sections = BiquadMath.calculateSections(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: Double(config.cutoffHz),
            q: 0.7071,  // Butterworth Q
            gain: 0.0,
            slope: slope
        )
        let n = min(sections.count, Self.maxInfrasonicSections)
        for i in 0..<n {
            infrasonicPendingCoeffB0[i]  = Float(sections[i].b0)
            infrasonicPendingCoeffB1[i]  = Float(sections[i].b1)
            infrasonicPendingCoeffB2[i]  = Float(sections[i].b2)
            // BiquadMath.normalise() returns raw a1/a0, a2/a0 (not pre-negated).
            // processBiquad() requires na1 = −a1/a0, na2 = −a2/a0 — negate here or the
            // HP poles land outside the unit circle and the filter diverges to ±Inf.
            infrasonicPendingCoeffNA1[i] = -Float(sections[i].a1)
            infrasonicPendingCoeffNA2[i] = -Float(sections[i].a2)
        }
        infrasonicPendingSectionCount = n   // write count LAST, after all coefficients are in place
        hasInfrasonicUpdate.store(true, ordering: .releasing)   // publish, with release ordering
    }

    /// Maps InfrasonicFilterConfig.InfrasonicSlope to FilterSlope for coefficient computation.
    private func mapToFilterSlope(_ slope: InfrasonicFilterConfig.InfrasonicSlope) -> FilterSlope {
        switch slope {
        case .db24: return .db24
        case .db48: return .db48
        case .db96: return .db96
        }
    }

    func setBassManagementEnabled(_ v: Bool) {
        _bassManagementEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setAsymmetricCrossoverEnabled(_ v: Bool) {
        _asymmetricCrossoverEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setDynamicEQEnabled(_ v: Bool) {
        _dynamicEQEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setFIREnabled(_ v: Bool) {
        _firEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setFIRConfig(_ config: FIRImpulseResponseConfig) {
        // Scale tapCount based on sample rate to preserve constant time duration
        let baseTapCount48k = 4096  // 85.3 ms @ 48 kHz
        let scaledTapCount = Int(pow(2.0, ceil(log2(Double(baseTapCount48k) * storedSampleRate / 48000.0))))
        // Clamp to reasonable maximum (e.g., 32768 for 85.3 ms @ 384 kHz)
        let finalTapCount = min(scaledTapCount, 32768)
        
        // Scale IRs to the target tapCount (pad with zeros or truncate)
        var scaledLeftIR = config.leftIR
        var scaledRightIR = config.rightIR
        
        if scaledLeftIR.count < finalTapCount {
            scaledLeftIR.append(contentsOf: Array(repeating: 0.0, count: finalTapCount - scaledLeftIR.count))
            scaledRightIR.append(contentsOf: Array(repeating: 0.0, count: finalTapCount - scaledRightIR.count))
        } else if scaledLeftIR.count > finalTapCount {
            scaledLeftIR = Array(scaledLeftIR.prefix(finalTapCount))
            scaledRightIR = Array(scaledRightIR.prefix(finalTapCount))
        }
        
        // Update ConvolutionEngine with the scaled IR
        firConvolutionEngine.updateIR(left: scaledLeftIR, right: scaledRightIR)
    }
    func setMainsHighPassHz(_ hz: Float) {
        // Store the mains high-pass frequency for asymmetric mode
        // This will be used when staging the mains high-pass crossover
        // No atomic needed since it's only used on the main thread for staging
    }
    func setDynamicEQConfig(_ config: DynamicEQConfig, sampleRate: Double) {
        let bands = config.bands
        let n = min(bands.count, DynamicEQConfig.maxDynamicEQBands)
        for (idx, band) in bands.prefix(n).enumerated() {
            // Compute biquad coefficients for this band
            let c = BiquadMath.peakingEQ(sampleRate: sampleRate,
                                          frequency: Double(band.frequency),
                                          q: Double(band.q),
                                          gain: Double(band.gain))
            // Write 5-float tuple into flat buffer at offset idx*5
            pendingDynEQCoeffsBuf[idx * 5 + 0] = Float(c.b0)
            pendingDynEQCoeffsBuf[idx * 5 + 1] = Float(c.b1)
            pendingDynEQCoeffsBuf[idx * 5 + 2] = Float(c.b2)
            pendingDynEQCoeffsBuf[idx * 5 + 3] = Float(c.a1)
            pendingDynEQCoeffsBuf[idx * 5 + 4] = Float(c.a2)
            pendingDynEQBypassBuf[idx] = band.bypass ? 1 : 0
            pendingDynEQParamsBuf[idx * 4 + 0] = band.thresholdDB
            pendingDynEQParamsBuf[idx * 4 + 1] = band.ratio
            pendingDynEQParamsBuf[idx * 4 + 2] = band.attackMs
            pendingDynEQParamsBuf[idx * 4 + 3] = band.releaseMs
        }
        pendingDynamicEQBandCount = n
        recomputeDynamicEQCoeffs()
        hasDynamicEQUpdate.store(true, ordering: .releasing)
    }

    private func recomputeDynamicEQCoeffs() {
        let sampleRate = storedSampleRate
        let n = pendingDynamicEQBandCount  // or activeDynamicEQBandCount when called post-swap
        for idx in 0..<n {
            let attackMs  = pendingDynEQParamsBuf[idx * 4 + 2]
            let releaseMs = pendingDynEQParamsBuf[idx * 4 + 3]
            dynamicEQAttackCoeffsBuf[idx]  = Float(exp(-1.0 / (Double(attackMs)  * 0.001 * sampleRate)))
            dynamicEQReleaseCoeffsBuf[idx] = Float(exp(-1.0 / (Double(releaseMs) * 0.001 * sampleRate)))
        }
    }
    func setBassManagementCrossoverHz(_ hz: Float) {
        _bassManagementCrossoverHzBits.store(floatBits(max(20.0, min(200.0, hz))), ordering: .relaxed)
    }
    func setBassManagementSlope(_ slope: BassCrossoverSlope) {
        _bassManagementSlopeBits.store(Int32(slope.rawValue), ordering: .relaxed)
    }
    func setLowBandGainDB(_ db: Float) {
        _lowBandGainDBBits.store(floatBits(max(-12.0, min(12.0, db))), ordering: .relaxed)
    }
    func setLowBandPolarityInverted(_ v: Bool) {
        _lowBandPolarityInverted.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setLowBandLowShelfEnabled(_ v: Bool) {
        if v { for i in 0..<lowBandLowShelfState.count { lowBandLowShelfState[i] = 0 } }
        _lowBandLowShelfEnabled.store(v ? 1 : 0, ordering: .relaxed)
    }
    func setLowBandLowShelfFreqHz(_ hz: Float) {
        _lowBandLowShelfFreqBits.store(floatBits(max(20.0, min(100.0, hz))), ordering: .relaxed)
    }
    func setLowBandLowShelfGainDB(_ db: Float) {
        _lowBandLowShelfGainBits.store(floatBits(max(-12.0, min(12.0, db))), ordering: .relaxed)
    }
    func setLowBandDelaySamples(_ samples: Float) {
        _lowBandDelaySamplesBits.store(floatBits(max(0.0, samples)), ordering: .relaxed)
    }
    func setSubEQBands(_ bands: [SubEQBand], sampleRate: Double) {
        let n = min(bands.count, BassManagementConfig.maxSubEQBands)
        for (idx, band) in bands.prefix(n).enumerated() {
            // Compute biquad coefficients for this band
            let c = BiquadMath.peakingEQ(sampleRate: sampleRate,
                                          frequency: Double(band.frequency),
                                          q: Double(band.q),
                                          gain: Double(band.gain))
            // Write 5-float tuple into flat buffer at offset idx*5
            pendingSubEQCoeffsBuf[idx * 5 + 0] = Float(c.b0)
            pendingSubEQCoeffsBuf[idx * 5 + 1] = Float(c.b1)
            pendingSubEQCoeffsBuf[idx * 5 + 2] = Float(c.b2)
            pendingSubEQCoeffsBuf[idx * 5 + 3] = Float(c.a1)
            pendingSubEQCoeffsBuf[idx * 5 + 4] = Float(c.a2)
            pendingSubEQBypassBuf[idx] = band.bypass ? 1 : 0
        }
        pendingSubEQBandCount = n
        hasSubEQUpdate.store(true, ordering: .releasing)
    }

    /// Applies a full config snapshot atomically (main thread).
    func applyConfig(_ config: DynamicsConfig, sampleRate: Double) {
        storedSampleRate = sampleRate

        stereoWidener.applyConfig(config.stereoWidener)
        lufsProcessor.applyConfig(config.loudnessMatch)

        setDeEsserEnabled(config.deEsser.isEnabled)
        setDeEsserFrequencyHz(config.deEsser.frequencyHz)
        setDeEsserThresholdDB(config.deEsser.thresholdDB)

        setMBEnabled(config.multibandCompressor.isEnabled)
        setMBCrossLowMidHz(config.multibandCompressor.crossLowMidHz)
        setMBCrossMidHighHz(config.multibandCompressor.crossMidHighHz)
        setMBThresholdLowDB(config.multibandCompressor.thresholdLowDB)
        setMBThresholdMidDB(config.multibandCompressor.thresholdMidDB)
        setMBThresholdHighDB(config.multibandCompressor.thresholdHighDB)
        setMBSlopeLowMid(config.multibandCompressor.slopeLowMid)
        setMBSlopeMidHigh(config.multibandCompressor.slopeMidHigh)

        setCompressorEnabled(config.compressor.isEnabled)
        setCompressorThresholdDB(config.compressor.thresholdDB)
        setCompressorRatio(config.compressor.ratio)
        setCompressorAttackMs(config.compressor.attackMs, sampleRate: sampleRate)
        setCompressorReleaseMs(config.compressor.releaseMs, sampleRate: sampleRate)
        setCompressorProgramDependentRelease(config.compressor.programDependentRelease)
        setCompressorSidechainHighPassHz(config.compressor.sidechainHighPassHz, sampleRate: sampleRate)
        setCompressorMakeupGainDB(config.compressor.makeupGainDB)
        setCompressorKneeWidthDB(config.compressor.kneeWidthDB)

        setExpanderEnabled(config.expander.isEnabled)
        setExpanderThresholdDB(config.expander.thresholdDB)
        setExpanderRatio(config.expander.ratio)
        setExpanderRangeDB(config.expander.rangeDB)
        expanderAlphaAttack  = Self.computeAlpha(tauSeconds: 0.005, sampleRate: sampleRate)
        expanderAlphaRelease = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sampleRate)

        setSoftClipperEnabled(config.softClipper.isEnabled)
        setSoftClipperDriveDB(config.softClipper.driveDB)
        setSoftClipperThresholdDB(config.softClipper.thresholdDB)
        setSoftClipperKnee(config.softClipper.kneeSmooth)

        setLimiterEnabled(config.limiter.isEnabled)
        setLimiterCeilingDB(config.limiter.ceilingDB)
        setLimiterAttackMs(config.limiter.attackMs, sampleRate: sampleRate)
        setLimiterReleaseMs(config.limiter.releaseMs, sampleRate: sampleRate)
        setLimiterLookAheadMs(config.limiter.lookAheadMs, sampleRate: sampleRate)

        setChannelBalance(config.channelBalance)

        // Advanced processing (sections A–J)
        let adv = config.advanced
        setStereoMode(adv.stereoMode)
        setDCOffsetFilterEnabled(adv.dcOffsetFilterEnabled)
        setDenoisingPreset(adv.linearDenoisingPreset)
        // Allow the user's manual threshold slider to override the preset's noise floor
        // only if it differs from the preset's seeded value; otherwise the preset wins.
        // (The store always writes the most recently set value, so call threshold last
        // to let it win over the preset if the user has diverged from it.)
        setDenoisingThresholdDB(adv.linearDenoisingThresholdDB)
        // Only call setMode() when the mode or sample rate actually changed.
        // setMode() blocks the main thread briefly; calling it on every applyConfig()
        // (which fires on every UI parameter change) causes repeated main-thread stalls
        // that destabilise Core Audio's HAL device management.
        if adv.denoiserMode != denoisersConfiguredMode ||
           storedSampleRate != denoisersConfiguredSampleRate {
            for d in denoisers {
                d.setMode(adv.denoiserMode, sampleRate: storedSampleRate)
            }
            denoisersConfiguredMode = adv.denoiserMode
            denoisersConfiguredSampleRate = storedSampleRate
        }
        for d in denoisers {
            d.setReductionAmount(adv.denoiserReductionAmount)
        }
        // Enable after buffers are confirmed initialised for the current mode.
        setDenoisingEnabled(adv.linearDenoisingEnabled)
        setDialogueGateEnabled(adv.loudnessDialogueGateEnabled)
        setLoudnessContourEnabled(adv.loudnessContourEnabled)
        setLoudnessReferencePhon(adv.loudnessReferencePhon)
        setLoudnessReferenceVolume(adv.loudnessReferenceVolume)
        setVolumeDependentLoudnessEnabled(adv.volumeDependentLoudnessEnabled)
        setDeesserDynamicModeEnabled(adv.deesserDynamicModeEnabled)
        setClipperAsymmetryTrimDB(adv.clipperAsymmetryTrimDB)
        setDeharshFilterEnabled(adv.deharshFilterEnabled)
        setDeharshTiltAmountDB(adv.deharshTiltAmountDB)
        setStereoBalancePosition(adv.stereoBalancePosition)
        setSymmetryBalanceEnabled(adv.symmetryBalanceEnabled)
        setLimiterTruePeakGuardEnabled(adv.limiterTruePeakGuardEnabled)
        setAutoHeadroomEnabled(adv.autoHeadroomEnabled)
        setAutoHeadroomParameters(
            speed:             adv.autoHeadroomSpeed,
            targetGRDB:        adv.autoHeadroomTargetGRDB,
            maxReductionDB:    adv.autoHeadroomMaxReductionDB,
            sampleRate:        storedSampleRate,
            typicalFrameCount: lookAheadSize > 0 ? lookAheadSize : 512
        )
        setStereoTimeDelayMS(adv.interChannelDelayMs)
        setIRAlignmentEnabled(adv.speakerIRAlignmentEnabled)
        setIRAlignmentDelayMs(adv.speakerIRDelayMs)
        setPanningEnabled(adv.panningGainMatrixEnabled)
        setPanningCrossfeedAmount(adv.panningCrossfeedAmount)
        setCrosstalkEnabled(adv.crosstalkCancellationEnabled)
        setCrosstalkAmount(adv.crosstalkCancellationAmount)
        setDeltaSoloActive(adv.deltaSoloActive)
        setLatencyMode(adv.latencyMode)
        setPauseGateEnabled(adv.pauseGateEnabled)
        setPauseGateParameters(
            thresholdDBFS: adv.pauseGateThresholdDBFS,
            holdMs:        adv.pauseGateHoldMs,
            attackMs:      adv.pauseGateAttackMs,
            releaseMs:     adv.pauseGateReleaseMs,
            hysteresisDB:  adv.pauseGateHysteresisDB
        )
        setHardwareSyncBufferEnabled(adv.hardwareSyncBufferEnabled)
        setDitherMode(adv.ditherMode)
        setSubBassPhaseAlignmentEnabled(adv.subBassPhaseAlignmentEnabled)
        setSubBassAlignmentFrequencyHz(adv.subBassAlignmentFrequencyHz)
        setSubBassPhaseQ(adv.subBassPhaseAlignmentQ)
        setOversamplingEnabled(adv.oversamplingEnabled)
        // Only recompute infrasonic filter coefficients if the config actually changed
        if adv.infrasonicFilter != previousInfrasonicFilter {
            setInfrasonicFilterConfig(adv.infrasonicFilter, sampleRate: sampleRate)
            previousInfrasonicFilter = adv.infrasonicFilter
        }

        // Bass Management - rebuild crossover only when parameters change
        setBassManagementEnabled(adv.bassManagement.enabled)
        setAsymmetricCrossoverEnabled(adv.bassManagement.asymmetricCrossoverEnabled)
        setDynamicEQEnabled(adv.dynamicEQ.enabled)
        setFIREnabled(adv.firImpulseResponse.enabled)
        setFIRConfig(adv.firImpulseResponse)
        setBassManagementCrossoverHz(adv.bassManagement.crossoverHz)
        setBassManagementSlope(adv.bassManagement.slope)
        setLowBandGainDB(adv.bassManagement.lowBandGainDB)
        setLowBandPolarityInverted(adv.bassManagement.lowBandPolarityInverted)
        setLowBandLowShelfEnabled(adv.bassManagement.lowBandLowShelfEnabled)
        setLowBandLowShelfFreqHz(adv.bassManagement.lowBandLowShelfFreqHz)
        setLowBandLowShelfGainDB(adv.bassManagement.lowBandLowShelfGainDB)
        setLowBandDelaySamples(adv.bassManagement.lowBandDelaySamples)
        setSubEQBands(adv.bassManagement.subEQBands, sampleRate: sampleRate)
        setDynamicEQConfig(adv.dynamicEQ, sampleRate: sampleRate)

        // Stage bass management crossover update if parameters changed
        if adv.bassManagement.crossoverHz != lastBassCrossoverHz
            || adv.bassManagement.slope != lastBassCrossoverSlope
            || adv.bassManagement.crossoverType != lastBassCrossoverType {
            stageBassManagementCrossover(crossoverHz: adv.bassManagement.crossoverHz,
                                       slope: adv.bassManagement.slope,
                                       crossoverType: adv.bassManagement.crossoverType)
            lastBassCrossoverHz = adv.bassManagement.crossoverHz
            lastBassCrossoverSlope = adv.bassManagement.slope
            lastBassCrossoverType = adv.bassManagement.crossoverType
        }

        // Stage mains high-pass crossover update if asymmetric mode is enabled and parameters changed
        if adv.bassManagement.asymmetricCrossoverEnabled {
            if adv.bassManagement.mainsHighPassHz != lastMainsHighPassHz
                || adv.bassManagement.slope != lastBassCrossoverSlope
                || adv.bassManagement.crossoverType != lastBassCrossoverType {
                stageMainsHighPassCrossover(crossoverHz: adv.bassManagement.mainsHighPassHz,
                                          slope: adv.bassManagement.slope,
                                          crossoverType: adv.bassManagement.crossoverType)
                lastMainsHighPassHz = adv.bassManagement.mainsHighPassHz
            }
        }
    }

    /// Stage a bass management crossover update for thread-safe application.
    /// Called from the main thread when bass management parameters change.
    private func stageBassManagementCrossover(crossoverHz: Float, slope: BassCrossoverSlope, crossoverType: CrossoverType) {
        let newCrossover = BassManagementCrossover(
            crossoverHz: crossoverHz,
            slope: slope,
            sampleRate: storedSampleRate,
            crossoverType: crossoverType
        )
        let newStateSize = newCrossover.stateSizePerChannel
        pendingBassCrossover = newCrossover
        pendingBassManagementStateSize = newStateSize
        hasBassCrossoverUpdate.store(true, ordering: .releasing)
    }

    /// Stage a mains high-pass crossover update for thread-safe application.
    /// Called from the main thread when asymmetric crossover parameters change.
    private func stageMainsHighPassCrossover(crossoverHz: Float, slope: BassCrossoverSlope, crossoverType: CrossoverType) {
        let newCrossover = BassManagementCrossover(
            crossoverHz: crossoverHz,
            slope: slope,
            sampleRate: storedSampleRate,
            crossoverType: crossoverType
        )
        let newStateSize = newCrossover.stateSizePerChannel
        pendingMainsHighPassCrossover = newCrossover
        pendingMainsHighPassStateSize = newStateSize
        hasMainsHighPassUpdate.store(true, ordering: .releasing)
    }

    /// Apply pending bass management crossover update on the audio thread.
    /// Called at the top of processBassManagement before use.
    @inline(__always)
    private func applyPendingBassCrossoverUpdate() {
        guard hasBassCrossoverUpdate.exchange(false, ordering: .acquiringAndReleasing) else { return }

        let newStateSize = pendingBassManagementStateSize
        let oldStateSize = bassManagementStateSize
        let minSize      = min(oldStateSize, newStateSize) * 2  // * 2 for stereo

        // Copy existing state into pending buffer (preserves filter memory across crossover changes)
        // Zero any slots that are new/wider in the new config
        if newStateSize * 2 <= Self.maxBassManagementStateTotal {
            // Zero destination first, then copy what we can preserve
            pendingBassManagementStateBuf.initialize(repeating: 0, count: newStateSize * 2)
            if minSize > 0 {
                // Preserve per-channel state (interleaved: ch0[0..n], ch1[0..n])
                let oldChStride = oldStateSize
                let newChStride = newStateSize
                for ch in 0..<2 {
                    let srcBase = ch * oldChStride
                    let dstBase = ch * newChStride
                    let toCopy  = min(oldStateSize, newStateSize)
                    for i in 0..<toCopy {
                        pendingBassManagementStateBuf[dstBase + i] = bassManagementStateBuf[srcBase + i]
                    }
                }
            }
        }

        // Swap: copy pending → active (no allocation, just memcpy)
        let totalSize = newStateSize * 2
        if totalSize > 0 && totalSize <= Self.maxBassManagementStateTotal {
            memcpy(bassManagementStateBuf, pendingBassManagementStateBuf,
                   totalSize * MemoryLayout<Float>.size)
        }
        bassManagementStateSize = newStateSize
        bassManagementCrossover = pendingBassCrossover
    }

    /// Apply pending mains high-pass crossover update on the audio thread.
    /// Called at the top of processBassManagement before use.
    @inline(__always)
    private func applyPendingMainsHighPassUpdate() {
        guard hasMainsHighPassUpdate.exchange(false, ordering: .acquiringAndReleasing) else { return }

        let newStateSize = pendingMainsHighPassStateSize
        let oldStateSize = mainsHighPassStateSize
        let minSize      = min(oldStateSize, newStateSize) * 2  // * 2 for stereo

        // Copy existing state into pending buffer (preserves filter memory across crossover changes)
        // Zero any slots that are new/wider in the new config
        if newStateSize * 2 <= Self.maxBassManagementStateTotal {
            // Zero destination first, then copy what we can preserve
            pendingMainsHighPassStateBuf.initialize(repeating: 0, count: newStateSize * 2)
            if minSize > 0 {
                // Preserve per-channel state (interleaved: ch0[0..n], ch1[0..n])
                let oldChStride = oldStateSize
                let newChStride = newStateSize
                for ch in 0..<2 {
                    let srcBase = ch * oldChStride
                    let dstBase = ch * newChStride
                    let toCopy  = min(oldStateSize, newStateSize)
                    for i in 0..<toCopy {
                        pendingMainsHighPassStateBuf[dstBase + i] = mainsHighPassStateBuf[srcBase + i]
                    }
                }
            }
        }

        // Swap: copy pending → active (no allocation, just memcpy)
        let totalSize = newStateSize * 2
        if totalSize > 0 && totalSize <= Self.maxBassManagementStateTotal {
            memcpy(mainsHighPassStateBuf, pendingMainsHighPassStateBuf,
                   totalSize * MemoryLayout<Float>.size)
        }
        mainsHighPassStateSize = newStateSize
        mainsHighPassCrossover = pendingMainsHighPassCrossover
    }

    /// Process dynamic EQ on the audio signal.
    /// - Parameters:
    ///   - abl: Audio buffer list (must have at least 2 channels)
    ///   - numCh: Number of channels
    ///   - count: Number of frames to process
    @inline(__always)
    private func processDynamicEQ(
        abl: UnsafeMutableAudioBufferListPointer,
        numCh: Int,
        count: Int
    ) {
        // Apply pending dynamic EQ update if available
        if hasDynamicEQUpdate.exchange(false, ordering: .acquiringAndReleasing) {
            let n = pendingDynamicEQBandCount
            if n > 0 {
                memcpy(dynamicEQCoeffsBuf, pendingDynEQCoeffsBuf,
                       n * 5 * MemoryLayout<Float>.size)
                memcpy(dynamicEQBypassBuf, pendingDynEQBypassBuf,
                       n * MemoryLayout<Int32>.size)
                memcpy(dynamicEQParamsBuf, pendingDynEQParamsBuf,
                       n * 4 * MemoryLayout<Float>.size)
            }
            activeDynamicEQBandCount = n
            // Preserve envelope and GR state for continuity
        }

        guard activeDynamicEQBandCount > 0 else { return }

        let sampleRate = storedSampleRate

        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }

            for idx in 0..<activeDynamicEQBandCount {
                guard idx < DynamicEQConfig.maxDynamicEQBands else { break }
                guard dynamicEQBypassBuf[idx] == 0 else { continue }

                let maxBands = DynamicEQConfig.maxDynamicEQBands
                var w1   = dynamicEQFilterState[ch * maxBands * 2 + idx * 2]
                var w2   = dynamicEQFilterState[ch * maxBands * 2 + idx * 2 + 1]
                var env  = dynamicEQEnvelopeState[ch * maxBands + idx]
                var grDB = dynamicEQGainReductionDB[ch * maxBands + idx]

                let b0 = dynamicEQCoeffsBuf[idx * 5 + 0]
                let b1 = dynamicEQCoeffsBuf[idx * 5 + 1]
                let b2 = dynamicEQCoeffsBuf[idx * 5 + 2]
                let na1 = dynamicEQCoeffsBuf[idx * 5 + 3]
                let na2 = dynamicEQCoeffsBuf[idx * 5 + 4]
                let thresholdDB = dynamicEQParamsBuf[idx * 4 + 0]
                let ratio = dynamicEQParamsBuf[idx * 4 + 1]
                let attackMs = dynamicEQParamsBuf[idx * 4 + 2]
                let releaseMs = dynamicEQParamsBuf[idx * 4 + 3]

                // Use cached attack/release coefficients (computed on main thread when sample rate or parameters change)
                let attackCoeff = dynamicEQAttackCoeffsBuf[idx]
                let releaseCoeff = dynamicEQReleaseCoeffsBuf[idx]

                for i in 0..<count {
                    let input = buf[i]

                    // Run input through the band-detection filter for level sensing only.
                    // The filter output is used exclusively for envelope detection —
                    // it is NOT written to the output buffer.
                    let filtered = Self.processBiquad(input, b0: b0, b1: b1, b2: b2,
                                                     na1: na1, na2: na2, w1: &w1, w2: &w2)

                    // Envelope follower on the band-filtered signal.
                    let absFiltered = abs(filtered)
                    if absFiltered > env {
                        env = attackCoeff * env + (1.0 - attackCoeff) * absFiltered
                    } else {
                        env = releaseCoeff * env + (1.0 - releaseCoeff) * absFiltered
                    }

                    // Gain computer: how much to reduce gain when band energy exceeds threshold.
                    let envDB = 20.0 * log10(max(env, 1e-10))
                    let overThreshold = envDB - thresholdDB
                    var targetGR: Float = 0.0
                    if overThreshold > 0 {
                        targetGR = -overThreshold * (ratio - 1.0) / ratio
                    }

                    // Smooth gain reduction.
                    let grCoeff = overThreshold > 0 ? attackCoeff : releaseCoeff
                    grDB = grCoeff * grDB + (1.0 - grCoeff) * targetGR

                    // Apply gain reduction to the ORIGINAL full-bandwidth input signal.
                    let gainLinear = pow(10.0, grDB / 20.0)
                    buf[i] = input * gainLinear
                }

                dynamicEQFilterState[ch * maxBands * 2 + idx * 2]     = w1
                dynamicEQFilterState[ch * maxBands * 2 + idx * 2 + 1] = w2
                dynamicEQEnvelopeState[ch * maxBands + idx]            = env
                dynamicEQGainReductionDB[ch * maxBands + idx]          = grDB
            }
        }
    }

    /// Process FIR impulse response convolution using ConvolutionEngine.
    /// - Parameters:
    ///   - abl: Audio buffer list (must have at least 2 channels)
    ///   - numCh: Number of channels
    ///   - count: Number of frames to process
    @inline(__always)
    private func processFIR(
        abl: UnsafeMutableAudioBufferListPointer,
        numCh: Int,
        count: Int
    ) {
        guard numCh >= 2 else { return }

        guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        // Use ConvolutionEngine for FFT-based partitioned convolution
        firConvolutionEngine.process(bufL: bufL, bufR: bufR, frameCount: count)
    }

    /// Called when the pipeline sample rate changes (main thread).
    func updateSampleRate(_ sampleRate: Double, attackMs: Float, releaseMs: Float, lookAheadMs: Float) {
        storedSampleRate = sampleRate
        recomputeCompSidechainHPCoeffs()
        recomputeDynamicEQCoeffs()
        for p in lookAheadBufs { p.initialize(repeating: 0, count: Self.maxLookAheadSamples) }
        lookAheadWriteIndex = 0
        lookAheadSize       = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: lookAheadMs)
        
        // Update clipper/limiter effective sample rate if oversampling is active
        let oversamplingActive = _oversamplingEnabled.load(ordering: .relaxed) != 0
        if oversamplingActive {
            clipperLimiterSampleRate = sampleRate * 4.0
            // Recompute limiter alphas + lookahead at the new effective rate
            setLimiterAttackMs(currentLimiterAttackMs, sampleRate: clipperLimiterSampleRate)
            setLimiterReleaseMs(currentLimiterReleaseMs, sampleRate: clipperLimiterSampleRate)
            setLimiterLookAheadMs(currentLimiterLookAheadMs, sampleRate: clipperLimiterSampleRate)
        } else {
            clipperLimiterSampleRate = sampleRate
        }
        
        // Update denoiser sample rate (updateSampleRate is safe — it does not reallocate,
        // it only rebuilds the masking bias curve and resets noise history).
        for d in denoisers {
            d.updateSampleRate(sampleRate)
        }
        // Keep tracking vars in sync so applyConfig() doesn't re-trigger setMode()
        // immediately after a sample rate change.
        denoisersConfiguredSampleRate = sampleRate
        limiterGainCurrent  = 1.0
        for i in 0..<deEsserFilterState.count  { deEsserFilterState[i]  = 0 }
        for i in 0..<mbFilterState.count        { mbFilterState[i]        = 0 }
        for i in 0..<mbFilterStateSteep.count   { mbFilterStateSteep[i]   = 0 }
        compEnvDB   = 0.0
        expEnvDB    = 0.0
        deEsserEnvDB = 0.0
        mbGainLow   = 1.0
        mbGainMid   = 1.0
        mbGainHigh  = 1.0
        expanderAlphaAttack  = Self.computeAlpha(tauSeconds: 0.005, sampleRate: sampleRate)
        expanderAlphaRelease = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sampleRate)
        setLimiterAttackMs(attackMs, sampleRate: sampleRate)
        setLimiterReleaseMs(releaseMs, sampleRate: sampleRate)
        stereoWidener.resetState()
        lufsProcessor.resetState(sampleRate: sampleRate)

        // Reset advanced DSP state
        for i in 0..<dcOffsetState.count { dcOffsetState[i] = 0 }
        for i in 0..<deharshState.count  { deharshState[i]  = 0 }
        for i in 0..<contourState.count  { contourState[i]  = 0 }
        crestPeakEnv    = 0.0
        crestRmsEnv     = 0.0
        pauseGateLevel  = 0.0
        pauseGateIsOpen = true
        ditherPrevRand  = 0.0
        for i in 0..<noiseShapeState.count { noiseShapeState[i] = 0 }
        for i in 0..<subBassPhaseState.count { subBassPhaseState[i] = 0 }
        for p in timeDelayBufs { p.initialize(repeating: 0, count: Self.maxDelaySamples) }
        timeDelayWriteIdx = 0
        for p in irAlignBufs { p.initialize(repeating: 0, count: Self.maxIRAlignSamples) }
        irAlignWriteIdx = 0
        lowBandDelayBuf.initialize(repeating: 0, count: Self.maxLowBandDelaySamples)
        lowBandDelayWriteIdx = 0
        for i in 0..<irAlignApState.count { irAlignApState[i] = 0 }
        for i in 0..<crosstalkFilterState.count { crosstalkFilterState[i] = 0 }
        denoisers.forEach { $0.reset() }
    }

    // MARK: - DSP Processing (audio thread)

    /// Applies the infrasonic high-pass filter to the left and right channel buffers.
    /// Called at the TOP of the DynamicsProcessor.process() chain, before all other processing.
    /// The filter is a passthrough (instant return) when disabled.
    @inline(__always)
    private func processInfrasonicFilter(
        abl: UnsafeMutableAudioBufferListPointer,
        numCh: Int,
        count: Int
    ) {
        guard _infrasonicEnabled.load(ordering: .relaxed) != 0 else { return }

        // Apply pending coefficient update
        if hasInfrasonicUpdate.exchange(false, ordering: .acquiringAndReleasing) {
            // Copy element-by-element between fixed pointers — no array reassignment,
            // no retain/release, just raw Float copies.
            let n = infrasonicPendingSectionCount
            for i in 0..<n {
                infrasonicCoeffB0[i]  = infrasonicPendingCoeffB0[i]
                infrasonicCoeffB1[i]  = infrasonicPendingCoeffB1[i]
                infrasonicCoeffB2[i]  = infrasonicPendingCoeffB2[i]
                infrasonicCoeffNA1[i] = infrasonicPendingCoeffNA1[i]
                infrasonicCoeffNA2[i] = infrasonicPendingCoeffNA2[i]
            }
            infrasonicActiveSectionCount = n
            // Do NOT zero infrasonicState: continuity preserved across updates.
        }

        let sectionCount = infrasonicActiveSectionCount
        guard sectionCount > 0 else { return }

        // Check target: .subOutputOnly is handled in processBassManagement, not here.
        let target = InfrasonicFilterConfig.ApplicationTarget(
            rawValue: Int(_infrasonicTarget.load(ordering: .relaxed))) ?? .mainChain
        guard target == .mainChain || target == .both else { return }

        // Apply to all channels (stereo L+R)
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stateOffset = ch * Self.maxInfrasonicSections * 2
            for idx in 0..<sectionCount {
                let b0 = infrasonicCoeffB0[idx]
                let b1 = infrasonicCoeffB1[idx]
                let b2 = infrasonicCoeffB2[idx]
                let na1 = infrasonicCoeffNA1[idx]
                let na2 = infrasonicCoeffNA2[idx]
                var w1 = infrasonicState[stateOffset + idx * 2]
                var w2 = infrasonicState[stateOffset + idx * 2 + 1]
                for i in 0..<count {
                    buf[i] = Self.processBiquad(buf[i], b0: b0, b1: b1, b2: b2,
                                                 na1: na1, na2: na2, w1: &w1, w2: &w2)
                }
                infrasonicState[stateOffset + idx * 2]     = w1
                infrasonicState[stateOffset + idx * 2 + 1] = w2
            }
        }
    }

    @inline(__always)
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let count = Int(frameCount)
        guard count > 0 else { return }
        let abl   = UnsafeMutableAudioBufferListPointer(bufferList)
        let numCh = min(channelCount, abl.count)
        guard numCh > 0 else { return }

        // Infrasonic filter — must run first, before any other processing,
        // to protect all downstream stages including the main EQ and dynamics.
        processInfrasonicFilter(abl: abl, numCh: numCh, count: count)
        // Defensive: if the HP cascade ever diverges (e.g. a future coefficient
        // regression), zero NaN/Inf before it can propagate into the RTA, meters,
        // or any downstream stage — mirrors the safety net already used after
        // processSubBassPhaseAlignment.
        DSPSafety.sanitizeAudioBufferList(abl.unsafeMutablePointer)

        let wideOn    = stereoWidener.isEnabled
        let lufsOn    = lufsProcessor.isEnabled
        let deEsserOn = _deEsserEnabled.load(ordering: .relaxed) != 0
        let mbOn      = _mbEnabled.load(ordering: .relaxed) != 0
        let compOn    = _compEnabled.load(ordering: .relaxed) != 0
        let expOn     = _expEnabled.load(ordering: .relaxed) != 0
        let softOn    = _softClipperEnabled.load(ordering: .relaxed) != 0
        let limOn     = _limiterEnabled.load(ordering: .relaxed) != 0

        let stereoModeRaw = _stereoMode.load(ordering: .relaxed)
        let dcOn          = _dcOffsetEnabled.load(ordering: .relaxed) != 0
        let contourOn     = _loudnessContourEnabled.load(ordering: .relaxed) != 0
        let deharshOn     = _deharshEnabled.load(ordering: .relaxed) != 0
        let pauseOn       = _pauseGateEnabled.load(ordering: .relaxed) != 0
        let ditherMode    = _ditherModeBits.load(ordering: .relaxed)
        let deltaSoloOn   = _deltaSoloEnabled.load(ordering: .relaxed) != 0

        let subPhaseOn   = _subBassPhaseEnabled.load(ordering: .relaxed) != 0
        let symBalanceOn = _symmetryBalanceEnabled.load(ordering: .relaxed) != 0
        let panningOn    = _panningEnabled.load(ordering: .relaxed) != 0
        let irAlignOn    = _irAlignEnabled.load(ordering: .relaxed) != 0
        let crosstalkOn  = _crosstalkEnabled.load(ordering: .relaxed) != 0
        let denoisingOn  = _denoisingEnabled.load(ordering: .relaxed) != 0
        let bassMgmtOn  = _bassManagementEnabled.load(ordering: .relaxed) != 0
        let dynamicEQOn = _dynamicEQEnabled.load(ordering: .relaxed) != 0
        let firOn       = _firEnabled.load(ordering: .relaxed) != 0
        guard stereoModeRaw != 0 || dcOn || subPhaseOn || symBalanceOn || panningOn || irAlignOn || crosstalkOn || denoisingOn || wideOn || lufsOn || contourOn
                || deEsserOn || mbOn || compOn || expOn || softOn || limOn
                || deharshOn || pauseOn || ditherMode != 0 || deltaSoloOn || bassMgmtOn || dynamicEQOn || firOn else {
            _gainReductionBits.store(floatBits(0.0), ordering: .relaxed)
            return
        }

        // Capture pre-chain signal for delta solo (must be first).
        if deltaSoloOn { captureDeltaInput(abl: abl, numCh: numCh, count: count) }

        // Stage −2: Spectral noise gate.
        if denoisingOn { processDenoising(abl: abl, numCh: numCh, count: count) }

        // Stage −1.5: Dynamic EQ.
        if dynamicEQOn { processDynamicEQ(abl: abl, numCh: numCh, count: count) }

        // Stage −1.4: FIR Impulse Response.
        if firOn { processFIR(abl: abl, numCh: numCh, count: count) }

        // Stage −1: Stereo mode fold-down.
        if stereoModeRaw != 0 { processStereoMode(abl: abl, numCh: numCh, count: count) }

        // Stage 0: DC offset filter.
        if dcOn { processDCOffset(abl: abl, numCh: numCh, count: count) }

        // Sub-bass phase alignment.
        if subPhaseOn {
            processSubBassPhaseAlignment(abl: abl, numCh: numCh, count: count)
            // Defensive: if the allpass ever diverges (e.g. invalid sample rate at init),
            // zero NaN/Inf samples before they can propagate into the widener's M/S
            // accumulators or the RTA FFT — either of which will peg meters to full-scale
            // and kill the HAL I/O proc with an overload error.
            DSPSafety.sanitizeAudioBufferList(abl.unsafeMutablePointer)
        }

        // Stage 0a: Stereo Widener.
        if wideOn { stereoWidener.process(abl: abl, numCh: numCh, count: count, sampleRate: storedSampleRate) }

        // Stage 0b: LUFS Loudness Match.
        if lufsOn {
            lufsProcessor.applyGain(abl: abl, numCh: numCh, count: count)
            lufsProcessor.update(abl: abl, numCh: numCh, count: count, sampleRate: storedSampleRate)
        }

        // Stage 0c: Loudness Contouring.
        if contourOn { processLoudnessContour(abl: abl, numCh: numCh, count: count) }

        // Stage 1: De-Esser.
        if deEsserOn { processDeEsser(abl: abl, numCh: numCh, count: count) }

        // Stage 2: Multiband Compressor.
        if mbOn { processMultiband(abl: abl, numCh: numCh, count: count) }

        // Stage 3: Compressor.
        if compOn { processCompressor(abl: abl, numCh: numCh, count: count) }

        // Crest factor measurement after compressor.
        measureCrestFactor(abl: abl, numCh: numCh, count: count)

        // Stage 4: Expander.
        if expOn { processExpander(abl: abl, numCh: numCh, count: count) }

        // Bass Management (before limiter, replaces mains high-pass and mono bass)
        processBassManagement(abl: abl, numCh: numCh, count: count)

        // Stage 5: Soft Clipper + Brickwall Limiter.
        let oversampleOn = _oversamplingEnabled.load(ordering: .relaxed) != 0
        if !oversampleOn {
            processSoftClipperAndLimiter(abl: abl, numCh: numCh, count: count, softOn: softOn, limOn: limOn)
        }

        // Stage 6: De-Harsh Tilt Filter.
        if deharshOn { processDeHarsh(abl: abl, numCh: numCh, count: count) }

        // Stage 6.5: Speaker IR Alignment fractional delay.
        if irAlignOn { processIRAlignment(abl: abl, numCh: numCh, count: count) }

        // Stage 7: Balance Matrix + Inter-Channel Time Delay.
        processBalanceAndDelay(abl: abl, numCh: numCh, count: count)

        // Stage 7.5: Panning Gain Matrix crossfeed.
        if panningOn { processPanningMatrix(abl: abl, numCh: numCh, count: count) }

        // Stage 7.6: Crosstalk cancellation.
        if crosstalkOn { processCrosstalkCancellation(abl: abl, numCh: numCh, count: count) }

        // Stage 8: Dynamic Pause Gate.
        if pauseOn { processPauseGate(abl: abl, numCh: numCh, count: count) }

        // Stage 9: TPDF Dither.
        if ditherMode != 0 { processTPDFDither(abl: abl, numCh: numCh, count: count, mode: ditherMode) }

        // Stage 10: Delta Solo (subtract original from processed).
        if deltaSoloOn { processDeltaSolo(abl: abl, numCh: numCh, count: count) }

        // Report per-stage GR to main thread.
        _deEsserGRBits.store(floatBits(deEsserEnvDB), ordering: .relaxed)
        let mbLowGRdB  = mbGainLow  > 1e-9 ? 20.0 * log10(mbGainLow)  : -90.0
        let mbMidGRdB  = mbGainMid  > 1e-9 ? 20.0 * log10(mbGainMid)  : -90.0
        let mbHighGRdB = mbGainHigh > 1e-9 ? 20.0 * log10(mbGainHigh) : -90.0
        _mbLowGRBits.store(floatBits(mbLowGRdB),   ordering: .relaxed)
        _mbMidGRBits.store(floatBits(mbMidGRdB),   ordering: .relaxed)
        _mbHighGRBits.store(floatBits(mbHighGRdB),  ordering: .relaxed)
        _compGRBits.store(floatBits(compEnvDB),     ordering: .relaxed)
        _expGRBits.store(floatBits(expEnvDB),       ordering: .relaxed)
    }

    // MARK: - Advanced Modules (A–J)

    @inline(__always)
    private func captureDeltaInput(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let safeCount = count
        for ch in 0..<numCh {
            guard let src = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let dst = deltaBufs[ch]
            for i in 0..<safeCount { dst[i] = src[i] }
        }
    }

    @inline(__always)
    private func processStereoMode(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        guard numCh >= 2 else { return }
        guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        for i in 0..<count {
            let mid = 0.5 * (bufL[i] + bufR[i])
            bufL[i] = mid
            bufR[i] = mid
        }
    }

    /// 1-pole DC blocker: y[n] = x[n] − x[n−1] + R·y[n−1], R ≈ 1 − 2π·fc/sr, fc ≈ 0.5 Hz.
    @inline(__always)
    private func processDCOffset(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let r: Float = 1.0 - Float(2.0 * Double.pi * 0.5 / storedSampleRate)
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var xPrev = dcOffsetState[ch * 2]
            var yPrev = dcOffsetState[ch * 2 + 1]
            for i in 0..<count {
                let x = buf[i]
                let y = x - xPrev + r * yPrev
                xPrev = x
                yPrev = y
                buf[i] = y
            }
            dcOffsetState[ch * 2]     = xPrev
            dcOffsetState[ch * 2 + 1] = yPrev
        }
    }

    /// Fletcher-Munson loudness compensation: low shelf +3 dB at 80 Hz, high shelf +1.5 dB at 6 kHz.
    @inline(__always)
    private func processLoudnessContour(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let sr = storedSampleRate
        let volume = bitsToFloat(_systemVolumeBits.load(ordering: .relaxed))

        let refPhon    = Double(bitsToFloat(_loudnessRefPhonBits.load(ordering: .relaxed)))
        let refVol     = bitsToFloat(_loudnessRefVolBits.load(ordering: .relaxed))
        let volumeScl  = max(0.001, Double(volume) / max(Double(refVol), 0.001))
        // Map current volume to phons via log relationship:
        // ΔdB ≈ 20·log10(volumeScl). This maps volume ratio to approximate SPL change.
        let deltaDB       = 20.0 * log10(volumeScl)
        let listeningPhon = max(20.0, refPhon + deltaDB)

        let (lowShelfGain, highShelfGain): (Float, Float) =
            bitsToFloat(_volumeDependentBits.load(ordering: .relaxed)) != 0
                ? Self.iso226CorrectionGains(listeningPhon: listeningPhon, referencePhon: refPhon)
                : (3.0 * Float(1.0 - Double(volume) * 0.5),   // legacy linear mode when vol-dep off
                   1.5 * Float(1.0 - Double(volume) * 0.5))

        let (b0ls, b1ls, b2ls, a1ls, a2ls) = Self.lowShelfCoeffs(fc: 80.0, gainDB: lowShelfGain, sr: sr)
        let (b0hs, b1hs, b2hs, a1hs, a2hs) = Self.highShelfCoeffs(fc: 6000.0, gainDB: highShelfGain, sr: sr)
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var w1ls = contourState[ch * 4]
            var w2ls = contourState[ch * 4 + 1]
            var w1hs = contourState[ch * 4 + 2]
            var w2hs = contourState[ch * 4 + 3]
            for i in 0..<count {
                let s1 = Self.processBiquad(buf[i], b0: b0ls, b1: b1ls, b2: b2ls, na1: a1ls, na2: a2ls, w1: &w1ls, w2: &w2ls)
                buf[i] = Self.processBiquad(s1,     b0: b0hs, b1: b1hs, b2: b2hs, na1: a1hs, na2: a2hs, w1: &w1hs, w2: &w2hs)
            }
            contourState[ch * 4]     = w1ls
            contourState[ch * 4 + 1] = w2ls
            contourState[ch * 4 + 2] = w1hs
            contourState[ch * 4 + 3] = w2hs
        }
    }

    /// Peak-to-RMS crest factor measurement after the compressor stage.
    @inline(__always)
    private func measureCrestFactor(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let peakDecay: Float = Float(exp(-1.0 / (storedSampleRate * 0.400)))
        let rmsDecay:  Float = Float(exp(-1.0 / (storedSampleRate * 0.300)))
        for i in 0..<count {
            var peak: Float = 0.0
            var rmsSum: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let s = buf[i]
                let a = s < 0 ? -s : s
                if a > peak { peak = a }
                rmsSum += s * s
            }
            crestPeakEnv = max(peak, peakDecay * crestPeakEnv)
            crestRmsEnv  = rmsDecay * crestRmsEnv + (1.0 - rmsDecay) * (rmsSum / Float(max(numCh, 1)))
        }
        let peakDB: Float = crestPeakEnv > 1e-10 ? 20.0 * log10(crestPeakEnv) : -100.0
        let rmsDB:  Float = crestRmsEnv  > 1e-10 ? 10.0 * log10(crestRmsEnv)  : -100.0
        _crestFactorBits.store(floatBits(max(0.0, peakDB - rmsDB)), ordering: .relaxed)
    }

    /// High-frequency tilt filter applied after the brickwall limiter (de-harsh mode).
    @inline(__always)
    private func processDeHarsh(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let tiltDB = bitsToFloat(_deharshTiltBits.load(ordering: .relaxed))
        let (b0, b1, b2, na1, na2) = Self.highShelfCoeffs(fc: 3500.0, gainDB: tiltDB, sr: storedSampleRate)
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var w1 = deharshState[ch * 2]
            var w2 = deharshState[ch * 2 + 1]
            for i in 0..<count {
                buf[i] = Self.processBiquad(buf[i], b0: b0, b1: b1, b2: b2, na1: na1, na2: na2, w1: &w1, w2: &w2)
            }
            deharshState[ch * 2]     = w1
            deharshState[ch * 2 + 1] = w2
        }
    }

    /// Constant-power balance matrix, inter-channel time delay, and live balance meter.
    @inline(__always)
    private func processBalanceAndDelay(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        guard numCh >= 2,
              let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        // Linear channel balance (centre = 100% both, left = 100%L/0%R, right = 0%L/100%R).
        let chBal    = bitsToFloat(_channelBalanceBits.load(ordering: .relaxed))
        let chGainL  = max(0.0, 1.0 - max(0.0, chBal))
        let chGainR  = max(0.0, 1.0 + min(0.0, chBal))
        if chGainL < 1.0 || chGainR < 1.0 {
            for i in 0..<count { bufL[i] *= chGainL; bufR[i] *= chGainR }
        }

        // Constant-power symmetry balance law.
        // balance ∈ [−1, +1]: −1 = full left, 0 = centre (unity gain both channels), +1 = full right.
        // Map to angle ∈ [0, π/2] symmetrically: centre → π/4, giving gainL = gainR = 1.0.
        // The √2 pre-scale ensures that cos(π/4)×√2 = 1.0 at centre, maintaining unity gain.
        let symEnabled = _symmetryBalanceEnabled.load(ordering: .relaxed) != 0
        if symEnabled {
            let balance  = bitsToFloat(_balanceBits.load(ordering: .relaxed))
            let angle    = (balance + 1.0) * Float.pi * 0.25   // 0 … π/2
            let gainL    = max(0.0, cos(angle)) * Float.sqrt2
            let gainR    = max(0.0, sin(angle)) * Float.sqrt2
            if gainL != 1.0 || gainR != 1.0 {
                for i in 0..<count { bufL[i] *= gainL; bufR[i] *= gainR }
            }
        }

        // Live balance meter: (powerR − powerL) / totalPower.
        var powerL: Float = 0.0, powerR: Float = 0.0
        for i in 0..<count { powerL += bufL[i] * bufL[i]; powerR += bufR[i] * bufR[i] }
        let total = powerL + powerR
        _balanceMeterBits.store(
            floatBits(total > 1e-12 ? (powerR - powerL) / total : 0.0),
            ordering: .relaxed
        )

        // Inter-channel time delay (signed: positive = delay R relative to L, negative = delay L relative to R).
        let delayMs      = bitsToFloat(_timeDelayBits.load(ordering: .relaxed))
        let absDelayMs  = abs(delayMs)
        let newDelay     = Int((absDelayMs / 1000.0) * Float(storedSampleRate) + 0.5)
        let delaySamples = min(newDelay, Self.maxDelaySamples - 1)
        timeDelaySamples = delaySamples
        guard delaySamples > 0 else { return }

        let bufSize  = Self.maxDelaySamples
        if delayMs > 0 {
            // Delay right channel relative to left
            let delayBuf = timeDelayBufs[1]
            for i in 0..<count {
                delayBuf[timeDelayWriteIdx] = bufR[i]
                let readIdx = (timeDelayWriteIdx - delaySamples + bufSize) % bufSize
                bufR[i] = delayBuf[readIdx]
                timeDelayWriteIdx = (timeDelayWriteIdx + 1) % bufSize
            }
        } else {
            // Delay left channel relative to right
            let delayBuf = timeDelayBufs[0]
            for i in 0..<count {
                delayBuf[timeDelayWriteIdx] = bufL[i]
                let readIdx = (timeDelayWriteIdx - delaySamples + bufSize) % bufSize
                bufL[i] = delayBuf[readIdx]
                timeDelayWriteIdx = (timeDelayWriteIdx + 1) % bufSize
            }
        }
    }

    /// Lagrange 4th-order (5-tap) fractional-sample delay applied uniformly to all channels.
    /// Compensates for multi-driver speaker acoustic-centre offset.
    @inline(__always)
    private func processIRAlignment(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let ms       = bitsToFloat(_irAlignDelayBits.load(ordering: .relaxed))
        let dSamples = Double(ms) * storedSampleRate / 1000.0
        let intDel   = min(Int(dSamples), Self.maxIRAlignSamples - 1)
        let frac     = Float(dSamples - Double(intDel))   // 0.0 ..< 1.0

        // Lagrange 4th-order (5-tap) fractional delay FIR.
        // d ∈ [0, 1.0): fractional portion of the delay in samples.
        // Centre tap is at index 2 (causal, minimum-latency form).
        // For d = 0 this collapses to a pure integer delay with no filtering.
        var lagCoeffs: (Float, Float, Float, Float, Float)
        do {
            let d = Double(frac)   // fractional delay in [0, 1.0)
            var c = [Double](repeating: 0, count: 5)
            for k in 0..<5 {
                var h = 1.0
                for n in 0..<5 where n != k {
                    h *= (d - Double(n - 2)) / Double(k - n)
                }
                c[k] = h
            }
            lagCoeffs = (Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]), Float(c[4]))
        }

        irAlignSamples = intDel
        let bufSize = Self.maxIRAlignSamples

        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ringBuf = irAlignBufs[ch]
            let base    = ch * 5
            var tap0 = irAlignApState[base + 0]
            var tap1 = irAlignApState[base + 1]
            var tap2 = irAlignApState[base + 2]
            var tap3 = irAlignApState[base + 3]
            var tap4 = irAlignApState[base + 4]
            let (lc0, lc1, lc2, lc3, lc4) = lagCoeffs
            var writeIdx = irAlignWriteIdx

            for i in 0..<count {
                // Push into integer delay ring buffer
                ringBuf[writeIdx] = buf[i]
                let readIdx = (writeIdx - intDel + bufSize) % bufSize
                let s = ringBuf[readIdx]   // integer-delayed sample

                // Shift FIR delay line and apply Lagrange coefficients
                tap4 = tap3; tap3 = tap2; tap2 = tap1; tap1 = tap0
                tap0 = s
                buf[i] = lc0 * tap0 + lc1 * tap1 + lc2 * tap2 + lc3 * tap3 + lc4 * tap4

                writeIdx = (writeIdx + 1) % bufSize
            }

            irAlignApState[base + 0] = tap0
            irAlignApState[base + 1] = tap1
            irAlignApState[base + 2] = tap2
            irAlignApState[base + 3] = tap3
            irAlignApState[base + 4] = tap4
            if ch == 0 { irAlignWriteIdx = writeIdx }
        }
    }

    /// Bilinear stereo crossfeed matrix.
    /// outL = (1−α)·inL + α·inR,  outR = (1−α)·inR + α·inL
    /// α = 0 → pure stereo, α = 0.5 → mono.
    @inline(__always)
    private func processPanningMatrix(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        guard numCh >= 2,
              let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        let alpha  = bitsToFloat(_panningCrossfeedBits.load(ordering: .relaxed))
        let direct = 1.0 - alpha

        for i in 0..<count {
            let l = bufL[i]
            let r = bufR[i]
            bufL[i] = direct * l + alpha * r
            bufR[i] = direct * r + alpha * l
        }
    }

    /// Open-loop crosstalk cancellation via shelved cross-channel subtraction.
    /// Fc ≈ 700 Hz models loudspeaker head-shadow for ~60° speaker separation.
    @inline(__always)
    private func processCrosstalkCancellation(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        guard numCh >= 2,
              let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        let beta = bitsToFloat(_crosstalkAmountBits.load(ordering: .relaxed))

        // First-order LP: y[n] = (1−α)·x[n] + α·y[n−1]
        // α = exp(−2π·fc/sr), fc = 700 Hz
        let fc: Double = 700.0
        let alpha = Float(exp(-2.0 * Double.pi * fc / storedSampleRate))
        let oneMinusAlpha = 1.0 - alpha

        var stateL = crosstalkFilterState[0]
        var stateR = crosstalkFilterState[min(1, crosstalkFilterState.count - 1)]

        for i in 0..<count {
            let inL = bufL[i]
            let inR = bufR[i]

            // Low-pass filter the cross-channel signals (captures head-shadow)
            stateL = oneMinusAlpha * inL + alpha * stateL  // filtered left (for subtraction from right)
            stateR = oneMinusAlpha * inR + alpha * stateR  // filtered right (for subtraction from left)

            // Subtract scaled cross-channel contribution from each output
            bufL[i] = inL - beta * stateR
            bufR[i] = inR - beta * stateL
        }

        crosstalkFilterState[0] = stateL
        if crosstalkFilterState.count > 1 { crosstalkFilterState[1] = stateR }
    }

    @inline(__always)
    private func processDenoising(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        for ch in 0..<min(numCh, denoisers.count) {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            denoisers[ch].process(buffer: buf, count: count)
        }
    }

    /// Dynamic pause gate: silences output smoothly when RMS falls below threshold for hold duration.
    /// Uses gain envelope with attack, hold, and release to avoid audible chatter.
    @inline(__always)
    private func processPauseGate(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        // Read all parameters from atomics once per callback — avoids redundant atomic
        // loads inside the per-sample loop and ensures a consistent parameter set.
        let holdAlpha    = bitsToFloat(_pauseGateHoldAlphaBits.load(ordering: .relaxed))
        let attackAlpha  = bitsToFloat(_pauseGateAttackAlphaBits.load(ordering: .relaxed))
        let releaseAlpha = bitsToFloat(_pauseGateReleaseAlphaBits.load(ordering: .relaxed))
        let threshold    = bitsToFloat(_pauseGateThresholdBits.load(ordering: .relaxed))
        let hystFactor   = bitsToFloat(_pauseGateHysteresisBits.load(ordering: .relaxed))

        // Hysteresis: open threshold is the raw threshold; close threshold is lower by
        // the hysteresis factor so the gate does not chatter near the boundary.
        let openThreshold  = threshold
        let closeThreshold = threshold / hystFactor

        var gateGain: Float = pauseGateIsOpen ? 1.0 : 0.0

        for i in 0..<count {
            // Accumulate instantaneous power across all channels.
            var rmsSum: Float = 0.0
            for ch in 0..<numCh {
                if let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) {
                    rmsSum += buf[i] * buf[i]
                }
            }
            // Smooth the level detector — holdAlpha sets the effective integration window.
            pauseGateLevel = holdAlpha * pauseGateLevel +
                             (1.0 - holdAlpha) * (rmsSum / Float(max(numCh, 1)))

            // Update gate state with hysteresis.
            if pauseGateLevel >= openThreshold && !pauseGateIsOpen {
                pauseGateIsOpen = true
            } else if pauseGateLevel < closeThreshold && pauseGateIsOpen {
                pauseGateIsOpen = false
            }

            // Advance the gain envelope toward target using asymmetric attack/release.
            // attackAlpha governs how fast the gate reopens (resume speed).
            let targetGain: Float = pauseGateIsOpen ? 1.0 : 0.0
            gateGain = targetGain > gateGain
                ? attackAlpha  * gateGain + (1.0 - attackAlpha)  * targetGain
                : releaseAlpha * gateGain + (1.0 - releaseAlpha) * targetGain

            // Apply gain to all channels.
            for ch in 0..<numCh {
                if let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) {
                    buf[i] *= gateGain
                }
            }
        }
    }

    /// TPDF / noise-shaped dither at 24-bit LSB.
    /// mode 1 = flat TPDF, mode 2 = first-order shaped, mode 3 = 5th-order Wannamaker.
    @inline(__always)
    private func processTPDFDither(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int, mode: Int32
    ) {
        let lsb: Float = 1.0 / 8_388_608.0
        let invLSB: Float = 8_388_608.0

        if mode == 3 {
            if let h = Self.noiseShapeCoefficients(sampleRate: storedSampleRate) {
                // Apply noise-shaped dither with rate-appropriate coefficients.
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let base = ch * 5
                    var s0 = noiseShapeState[base]
                    var s1 = noiseShapeState[base + 1]
                    var s2 = noiseShapeState[base + 2]
                    var s3 = noiseShapeState[base + 3]
                    var s4 = noiseShapeState[base + 4]
                    for i in 0..<count {
                        // TPDF input noise for the noise shaper: two independent uniform samples
                        // sum to a triangular distribution, which is optimal for error feedback.
                        let r = ditherRNG.nextFloat(in: -lsb...lsb) + ditherRNG.nextFloat(in: -lsb...lsb)
                        let shaped = r - (h.0*s0 + h.1*s1 + h.2*s2 + h.3*s3 + h.4*s4)
                        let input = buf[i] + shaped
                        let quant = (input * invLSB).rounded() * lsb
                        let error = quant - input
                        s4 = s3; s3 = s2; s2 = s1; s1 = s0; s0 = error
                        buf[i] = quant
                    }
                    noiseShapeState[base]     = s0
                    noiseShapeState[base + 1] = s1
                    noiseShapeState[base + 2] = s2
                    noiseShapeState[base + 3] = s3
                    noiseShapeState[base + 4] = s4
                }
            } else {
                // Flat TPDF — shaped dither not beneficial at this rate.
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<count {
                        let r1 = ditherRNG.nextFloat(in: -lsb...lsb)
                        let r2 = ditherRNG.nextFloat(in: -lsb...lsb)
                        buf[i] = (buf[i] * invLSB + r1 + r2).rounded() * lsb
                    }
                }
            }
            return
        }

        if mode == 1 {
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<count {
                    let r1 = ditherRNG.nextFloat(in: -lsb...lsb)
                    let r2 = ditherRNG.nextFloat(in: -lsb...lsb)
                    buf[i] = (buf[i] * invLSB + r1 + r2).rounded() * lsb
                }
            }
            return
        }

        if mode == 2 {
            for i in 0..<count {
                let r1 = ditherRNG.nextFloat(in: -lsb...lsb)
                let r2 = ditherRNG.nextFloat(in: -lsb...lsb)
                let noise = r1 - ditherPrevRand
                ditherPrevRand = r2
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    buf[i] = (buf[i] * invLSB + noise).rounded() * lsb
                }
            }
        }
    }

    /// Returns the 5-tap noise-shaping coefficients for a given sample rate.
    /// Returns nil if no shaped dither is appropriate (e.g. > 192 kHz where the
    /// quantisation noise floor is already below −120 dBFS and shaping offers no benefit).
    private static func noiseShapeCoefficients(sampleRate: Double) -> (Float, Float, Float, Float, Float)? {
        switch Int(sampleRate) {
        case 44_000...46_000:   // 44.1 kHz — Wannamaker 5th-order
            return (2.033, -2.165, 1.959, -1.590, 0.6149)
        case 47_000...50_000:   // 48 kHz — Wannamaker adapted
            return (2.412, -2.680, 2.497, -2.070, 0.8295)
        case 87_000...90_000:   // 88.2 kHz — scaled to equivalent perceptual weighting
            return (1.662, -1.411, 0.872, -0.483, 0.2000)
        case 95_000...98_000:   // 96 kHz
            return (1.540, -1.230, 0.720, -0.380, 0.1500)
        case 174_000...179_000, // 176.4 kHz
             191_000...194_000: // 192 kHz
            return (1.320, -0.980, 0.510, -0.210, 0.0750)
        default:                // 352.8, 384 kHz and above — flat TPDF sufficient
            return nil
        }
    }

    // ISO 226:2003 equal-loudness contour data.
    // Each row: (frequency Hz, α_f, L_U, T_f) — standard table values.
    // α_f and L_U are used to compute the loudness level Lp at each frequency.
    // Tf is the threshold of hearing in dB SPL.
    // Reference: ISO 226:2003 Table 1.
    private static let iso226Table: [(f: Double, af: Double, Lu: Double, Tf: Double)] = [
        (20,    0.532, -31.6, 78.5),
        (25,    0.506, -27.2, 68.7),
        (31.5,  0.480, -23.0, 59.5),
        (40,    0.455, -19.1, 51.1),
        (50,    0.432, -15.9, 44.0),
        (63,    0.409, -13.0, 37.5),
        (80,    0.387, -10.3, 31.5),
        (100,   0.367,  -8.1, 26.5),
        (125,   0.349,  -6.2, 22.1),
        (160,   0.330,  -4.5, 17.9),
        (200,   0.315,  -3.1, 14.4),
        (250,   0.301,  -2.0, 11.4),
        (315,   0.288,  -1.1,  8.6),
        (400,   0.276,  -0.4,  6.2),
        (500,   0.267,   0.0,  4.4),
        (630,   0.259,   0.3,  3.0),
        (800,   0.253,   0.5,  2.2),
        (1000,  0.250,   0.0,  2.4),
        (1250,  0.246,  -2.7,  3.5),
        (1600,  0.244,  -4.1,  1.7),
        (2000,  0.243,  -1.0, -1.3),
        (2500,  0.243,   1.7, -4.2),
        (3150,  0.243,   2.5, -6.0),
        (4000,  0.242,   1.2, -5.4),
        (5000,  0.242,  -2.1, -1.5),
        (6300,  0.245,  -7.1,  6.0),
        (8000,  0.254, -11.2, 12.6),
        (10000, 0.271, -10.7, 13.9),
        (12500, 0.301,  -3.5, 12.3)
    ]

    /// Returns the SPL level (dB) at `freqHz` for a given loudness level `phonDB` (phons)
    /// using the ISO 226:2003 inverse equal-loudness formula.
    /// Returns nil if `freqHz` is outside the table range.
    private static func iso226SPL(freqHz: Double, phonDB: Double) -> Double? {
        let table = iso226Table
        guard freqHz >= table.first!.f && freqHz <= table.last!.f else { return nil }
        // Linear interpolation of table parameters at freqHz.
        var af = 0.0, lu = 0.0
        for i in 0..<(table.count - 1) {
            if freqHz >= table[i].f && freqHz <= table[i+1].f {
                let t  = (freqHz - table[i].f) / (table[i+1].f - table[i].f)
                af = table[i].af + t * (table[i+1].af - table[i].af)
                lu = table[i].Lu + t * (table[i+1].Lu - table[i].Lu)
                break
            }
        }
        // ISO 226 inverse formula: Lp = (10/α_f) × log10(4×10^-10 × B_f + 0.005135) + 94
        let ln10_10 = 10.0 / af
        let Af = pow(10.0, 0.1 * phonDB)                       // loudness level → linear
        let Af1000 = pow(10.0, 0.1 * 1.0) * Af                 // normalised at 1 kHz, α_f=0.25
        let Bf = pow(10.0, (ln10_10 * log10(Af1000) - lu) / 1.0)
        // Direct ISO 226 forward formula for SPL at given phon:
        // Lp = (10/af) * log10( 4e-10 * Bf ) + 94  (simplified form)
        let Lp = ln10_10 * log10(max(1e-30, Bf)) + lu + 94.0 - ln10_10 * log10(4e-10)
        return Lp
    }

    /// Computes the ISO 226 loudness correction gains at bass and treble shelf frequencies.
    /// Returns (bassGainDB, trebleGainDB) — the additional EQ correction to apply
    /// relative to the reference level.
    ///
    /// - Parameters:
    ///   - listeningPhon: Estimated listening level in phons (derived from volume scalar).
    ///   - referencePhon: Phon level at which the system is calibrated (no correction applied).
    private static func iso226CorrectionGains(
        listeningPhon: Double,
        referencePhon: Double
    ) -> (bass: Float, treble: Float) {
        // Compute SPL at the bass shelf and treble shelf frequencies.
        // Bass: 80 Hz (representative low-frequency anchor).
        // Treble: 6000 Hz (representative high-frequency anchor).
        let refBass   = iso226SPL(freqHz: 80,   phonDB: referencePhon) ?? 0
        let lisBass   = iso226SPL(freqHz: 80,   phonDB: listeningPhon) ?? 0
        let refTreble = iso226SPL(freqHz: 6000, phonDB: referencePhon) ?? 0
        let lisTreble = iso226SPL(freqHz: 6000, phonDB: listeningPhon) ?? 0
        let refMid    = iso226SPL(freqHz: 1000, phonDB: referencePhon) ?? referencePhon
        let lisMid    = iso226SPL(freqHz: 1000, phonDB: listeningPhon) ?? listeningPhon

        // Correction = what the ear loses at low level relative to reference, at each frequency.
        // A positive number means we need to boost that frequency at low volume.
        let midShift  = lisMid - refMid  // overall level difference (mostly from volume itself)
        let bassCorr  = (lisBass   - refBass)   - midShift  // bass correction relative to mid
        let trebleCorr = (lisTreble - refTreble) - midShift  // treble correction relative to mid

        // Clamp to ±12 dB and negate: the ear needs MORE bass at low volume, so correction is positive.
        let bassGain   = Float(max(-12.0, min(12.0, -bassCorr)))
        let trebleGain = Float(max(-12.0, min(12.0, -trebleCorr)))
        return (bassGain, trebleGain)
    }

    /// Delta solo: outputs the difference (processed − original) so you can hear what the chain adds.
    @inline(__always)
    private func processDeltaSolo(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let safeCount = count
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let orig = deltaBufs[ch]
            for i in 0..<safeCount { buf[i] -= orig[i] }
        }
    }

    @inline(__always)
    private func processSubBassPhaseAlignment(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let freq = bitsToFloat(_subBassPhaseFreqBits.load(ordering: .relaxed))
        let q = Double(bitsToFloat(_subBassPhaseQBits.load(ordering: .relaxed)))
        let coeffs = BiquadMath.allPass(sampleRate: storedSampleRate,
                                        frequency: Double(freq), q: q)
        let b0  = Float(coeffs.b0)
        let b1  = Float(coeffs.b1)
        let b2  = Float(coeffs.b2)
        // BiquadMath.normalise() stores raw a1/a0 and a2/a0 (not pre-negated).
        // processBiquad() expects na1 = −a1/a0 and na2 = −a2/a0, matching the
        // sign convention used by all the inline coeff helpers (lpfCoeffs, hpfCoeffs, etc.).
        // Without the negation the allpass poles fall outside the unit circle, causing
        // the filter state to diverge to ±Inf within a single render callback — which
        // produces the audible ping and kills the audio graph.
        let na1 = -Float(coeffs.a1)
        let na2 = -Float(coeffs.a2)
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            // Section 1 state
            var w1a = subBassPhaseState[ch * 4]
            var w2a = subBassPhaseState[ch * 4 + 1]
            // Section 2 state
            var w1b = subBassPhaseState[ch * 4 + 2]
            var w2b = subBassPhaseState[ch * 4 + 3]
            for i in 0..<count {
                let s1 = Self.processBiquad(buf[i], b0: b0, b1: b1, b2: b2,
                                            na1: na1, na2: na2, w1: &w1a, w2: &w2a)
                buf[i] = Self.processBiquad(s1,     b0: b0, b1: b1, b2: b2,
                                            na1: na1, na2: na2, w1: &w1b, w2: &w2b)
            }
            subBassPhaseState[ch * 4]     = w1a
            subBassPhaseState[ch * 4 + 1] = w2a
            subBassPhaseState[ch * 4 + 2] = w1b
            subBassPhaseState[ch * 4 + 3] = w2b
        }
    }

    /// Bass Management: Linkwitz-Riley crossover for subwoofer integration.
    /// - Parameters:
    ///   - abl: Audio buffer list (must have at least 2 channels)
    ///   - numCh: Number of channels
    ///   - count: Number of frames to process
    @inline(__always)
    private func processBassManagement(
        abl: UnsafeMutableAudioBufferListPointer,
        numCh: Int,
        count: Int
    ) {
        guard _bassManagementEnabled.load(ordering: .relaxed) != 0 else { return }
        guard numCh >= 2 else { return }

        // Apply pending crossover updates if available
        applyPendingBassCrossoverUpdate()
        applyPendingMainsHighPassUpdate()

        // Check if asymmetric crossover mode is enabled
        let asymmetricEnabled = _asymmetricCrossoverEnabled.load(ordering: .relaxed) != 0

        // Apply pending sub EQ update if available
        if hasSubEQUpdate.exchange(false, ordering: .acquiringAndReleasing) {
            let n = pendingSubEQBandCount
            if n > 0 {
                memcpy(subEQCoeffsBuf, pendingSubEQCoeffsBuf,
                       n * 5 * MemoryLayout<Float>.size)
                memcpy(subEQBypassBuf, pendingSubEQBypassBuf,
                       n * MemoryLayout<Int32>.size)
            }
            activeSubEQBandCount = n
            // Do NOT reset subEQState here — preserve continuity like EQChain does for slider drags
        }

        guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        // Copy input to pre-allocated scratch buffers
        for i in 0..<count {
            bmLowL[i] = bufL[i]
            bmLowR[i] = bufR[i]
            bmHighL[i] = bufL[i]
            bmHighR[i] = bufR[i]
        }

        // Process LP and HP for each channel using pre-allocated buffers
        bassManagementCrossover.processLowPass(bmLowL, count: count, state: bassManagementStateBuf, channelIndex: 0)
        bassManagementCrossover.processLowPass(bmLowR, count: count, state: bassManagementStateBuf, channelIndex: 1)

        // Use separate high-pass crossover if asymmetric mode is enabled
        if asymmetricEnabled {
            mainsHighPassCrossover.processHighPass(bmHighL, count: count, state: mainsHighPassStateBuf, channelIndex: 0)
            mainsHighPassCrossover.processHighPass(bmHighR, count: count, state: mainsHighPassStateBuf, channelIndex: 1)
        } else {
            bassManagementCrossover.processHighPass(bmHighL, count: count, state: bassManagementStateBuf, channelIndex: 0)
            bassManagementCrossover.processHighPass(bmHighR, count: count, state: bassManagementStateBuf, channelIndex: 1)
        }

        // Sum low bands to get mono low
        for i in 0..<count {
            bmMonoLow[i] = bmLowL[i] + bmLowR[i]
        }

        // Apply infrasonic filter to sub path if target is .subOutputOnly or .both
        let infrasonicEnabled = _infrasonicEnabled.load(ordering: .relaxed) != 0
        let infrasonicTarget = InfrasonicFilterConfig.ApplicationTarget(
            rawValue: Int(_infrasonicTarget.load(ordering: .relaxed))) ?? .mainChain
        if infrasonicEnabled && (infrasonicTarget == .subOutputOnly || infrasonicTarget == .both) {
            // Apply pending coefficient update
            if hasInfrasonicUpdate.exchange(false, ordering: .acquiringAndReleasing) {
                // Copy element-by-element between fixed pointers — no array reassignment,
                // no retain/release, just raw Float copies.
                let n = infrasonicPendingSectionCount
                for i in 0..<n {
                    infrasonicCoeffB0[i]  = infrasonicPendingCoeffB0[i]
                    infrasonicCoeffB1[i]  = infrasonicPendingCoeffB1[i]
                    infrasonicCoeffB2[i]  = infrasonicPendingCoeffB2[i]
                    infrasonicCoeffNA1[i] = infrasonicPendingCoeffNA1[i]
                    infrasonicCoeffNA2[i] = infrasonicPendingCoeffNA2[i]
                }
                infrasonicActiveSectionCount = n
            }

            let sectionCount = infrasonicActiveSectionCount
            guard sectionCount > 0 else { return }

            // Apply to mono low buffer using infrasonicSubState
            for idx in 0..<sectionCount {
                let b0 = infrasonicCoeffB0[idx]
                let b1 = infrasonicCoeffB1[idx]
                let b2 = infrasonicCoeffB2[idx]
                let na1 = infrasonicCoeffNA1[idx]
                let na2 = infrasonicCoeffNA2[idx]
                var w1 = infrasonicSubState[idx * 2]
                var w2 = infrasonicSubState[idx * 2 + 1]
                for i in 0..<count {
                    bmMonoLow[i] = Self.processBiquad(bmMonoLow[i], b0: b0, b1: b1, b2: b2,
                                                         na1: na1, na2: na2, w1: &w1, w2: &w2)
                }
                infrasonicSubState[idx * 2]     = w1
                infrasonicSubState[idx * 2 + 1] = w2
            }
        }

        // Part 2 sub-band processing chain
        // Order: shelf → gain → polarity → delay

        // 2.1: Apply room-gain compensation low shelf if enabled
        let lowShelfEnabled = _lowBandLowShelfEnabled.load(ordering: .relaxed) != 0
        if lowShelfEnabled {
            let shelfFreq = bitsToFloat(_lowBandLowShelfFreqBits.load(ordering: .relaxed))
            let shelfGain = bitsToFloat(_lowBandLowShelfGainBits.load(ordering: .relaxed))
            let sr = storedSampleRate
            let (b0, b1, b2, na1, na2) = Self.lowShelfCoeffs(fc: shelfFreq, gainDB: shelfGain, sr: sr)
            var w1 = lowBandLowShelfState[0]
            var w2 = lowBandLowShelfState[1]
            for i in 0..<count {
                bmMonoLow[i] = Self.processBiquad(bmMonoLow[i], b0: b0, b1: b1, b2: b2,
                                                 na1: na1, na2: na2, w1: &w1, w2: &w2)
            }
            lowBandLowShelfState[0] = w1
            lowBandLowShelfState[1] = w2
        }

        // Apply sub EQ bands
        for idx in 0..<activeSubEQBandCount {
            guard idx < BassManagementConfig.maxSubEQBands else { break }
            guard subEQBypassBuf[idx] == 0 else { continue }
            var w1 = subEQState[idx * 2]
            var w2 = subEQState[idx * 2 + 1]
            let b0 = subEQCoeffsBuf[idx * 5 + 0]
            let b1 = subEQCoeffsBuf[idx * 5 + 1]
            let b2 = subEQCoeffsBuf[idx * 5 + 2]
            let na1 = subEQCoeffsBuf[idx * 5 + 3]
            let na2 = subEQCoeffsBuf[idx * 5 + 4]
            for i in 0..<count {
                bmMonoLow[i] = Self.processBiquad(bmMonoLow[i], b0: b0, b1: b1, b2: b2,
                                                 na1: na1, na2: na2, w1: &w1, w2: &w2)
            }
            subEQState[idx * 2]     = w1
            subEQState[idx * 2 + 1] = w2
        }

        // Apply sub trim gain
        let gainDB = bitsToFloat(_lowBandGainDBBits.load(ordering: .relaxed))
        let gainLinear = pow(10.0, gainDB / 20.0)
        if gainLinear != 1.0 {
            for i in 0..<count {
                bmMonoLow[i] *= gainLinear
            }
        }

        // Apply polarity inversion if enabled
        let polarityInverted = _lowBandPolarityInverted.load(ordering: .relaxed) != 0
        if polarityInverted {
            for i in 0..<count {
                bmMonoLow[i] *= -1.0
            }
        }

        // 2.4: Apply fractional delay for subwoofer alignment
        let delaySamples = bitsToFloat(_lowBandDelaySamplesBits.load(ordering: .relaxed))
        if delaySamples > 0 {
            let frac = Float(delaySamples - Float(Int(delaySamples)))

            // Lagrange 4th-order (5-tap) fractional delay FIR
            var lagCoeffs: (Float, Float, Float, Float, Float)
            do {
                let d = Double(frac)
                var c = [Double](repeating: 0, count: 5)
                for k in 0..<5 {
                    var h = 1.0
                    for n in 0..<5 where n != k {
                        h *= (d - Double(n - 2)) / Double(k - n)
                    }
                    c[k] = h
                }
                lagCoeffs = (Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]), Float(c[4]))
            }

            let bufSize = Self.maxLowBandDelaySamples
            let maxDelayForRate = Int(storedSampleRate * 0.1) - 1
            let intDel = min(Int(delaySamples), maxDelayForRate, bufSize - 1)
            var tap0 = lowBandDelayApState[0]
            var tap1 = lowBandDelayApState[1]
            var tap2 = lowBandDelayApState[2]
            var tap3 = lowBandDelayApState[3]
            var tap4 = lowBandDelayApState[4]
            let (lc0, lc1, lc2, lc3, lc4) = lagCoeffs
            var writeIdx = lowBandDelayWriteIdx

            for i in 0..<count {
                // Push into integer delay ring buffer
                lowBandDelayBuf[writeIdx] = bmMonoLow[i]
                let readIdx = (writeIdx - intDel + bufSize) % bufSize
                let s = lowBandDelayBuf[readIdx]

                // Shift FIR delay line and apply Lagrange coefficients
                tap4 = tap3; tap3 = tap2; tap2 = tap1; tap1 = tap0
                tap0 = s
                bmMonoLow[i] = lc0 * tap0 + lc1 * tap1 + lc2 * tap2 + lc3 * tap3 + lc4 * tap4

                writeIdx = (writeIdx + 1) % bufSize
            }

            lowBandDelayApState[0] = tap0
            lowBandDelayApState[1] = tap1
            lowBandDelayApState[2] = tap2
            lowBandDelayApState[3] = tap3
            lowBandDelayApState[4] = tap4
            lowBandDelayWriteIdx = writeIdx
        }

        // Recombine: high band + mono low
        for i in 0..<count {
            bufL[i] = bmHighL[i] + bmMonoLow[i]
            bufR[i] = bmHighR[i] + bmMonoLow[i]
        }
    }

    /// Called by RenderCallbackContext when oversampling is active.
    func processClipperAndLimiterOnly(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let softOn = _softClipperEnabled.load(ordering: .relaxed) != 0
        let limOn  = _limiterEnabled.load(ordering: .relaxed) != 0
        guard softOn || limOn else { return }
        processSoftClipperAndLimiter(abl: abl, numCh: numCh, count: count,
                                      softOn: softOn, limOn: limOn)
    }

    // MARK: - Module 1: De-Esser

    @inline(__always)
    private func processDeEsser(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let sr       = storedSampleRate
        let freqHz   = bitsToFloat(_deEsserFreqBits.load(ordering: .relaxed))
        let thresh   = bitsToFloat(_deEsserThreshBits.load(ordering: .relaxed))
        let alphaAtt = Self.computeAlpha(tauSeconds: 0.001, sampleRate: sr)
        let alphaRel = Self.computeAlpha(tauSeconds: 0.050, sampleRate: sr)
        let (b0, b1, b2, na1, na2) = Self.bpfCoeffs(fc: freqHz, q: 2.0, sr: sr)
        let dynMode  = _deesserDynModeEnabled.load(ordering: .relaxed) != 0
        var env = deEsserEnvDB
        // Per-frame BPF output store for dynamic EQ mode (max 2 channels; stack-allocated).
        var bpfOut0: Float = 0.0
        var bpfOut1: Float = 0.0

        for frame in 0..<count {
            var sidePeak: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var w1 = deEsserFilterState[ch * 2]
                var w2 = deEsserFilterState[ch * 2 + 1]
                let y = Self.processBiquad(buf[frame], b0: b0, b1: b1, b2: b2, na1: na1, na2: na2, w1: &w1, w2: &w2)
                deEsserFilterState[ch * 2]     = w1
                deEsserFilterState[ch * 2 + 1] = w2
                // Store BPF outputs so the dynamic-EQ gain path can use them.
                if ch == 0 { bpfOut0 = y } else if ch == 1 { bpfOut1 = y }
                let absY = y < 0 ? -y : y
                if absY > sidePeak { sidePeak = absY }
            }
            let sideDB: Float = sidePeak > 1e-5 ? 20.0 * log10(sidePeak) : -100.0
            let target: Float = sideDB > thresh ? thresh - sideDB : 0.0
            env = target < env
                ? alphaAtt * env + (1.0 - alphaAtt) * target
                : alphaRel * env + (1.0 - alphaRel) * target
            let gain = pow(10.0, env * 0.05)
            if dynMode {
                // Dynamic EQ mode: attenuate only the sibilant BPF band, leaving the
                // rest of the spectrum untouched (subtractive EQ rather than wideband gain).
                if numCh > 0, let buf = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                    buf[frame] += bpfOut0 * (gain - 1.0)
                }
                if numCh > 1, let buf = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                    buf[frame] += bpfOut1 * (gain - 1.0)
                }
            } else {
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    buf[frame] *= gain
                }
            }
        }
        deEsserEnvDB = env
    }

    // MARK: - Module 2: Multiband Compressor

    @inline(__always)
    private func processMultiband(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let sr      = storedSampleRate
        let crossLM = bitsToFloat(_mbCrossLMBits.load(ordering: .relaxed))
        let crossMH = bitsToFloat(_mbCrossMHBits.load(ordering: .relaxed))
        let threshL = bitsToFloat(_mbThreshLowBits.load(ordering: .relaxed))
        let threshM = bitsToFloat(_mbThreshMidBits.load(ordering: .relaxed))
        let threshH = bitsToFloat(_mbThreshHighBits.load(ordering: .relaxed))
        let slopeLM = _mbSlopeLMBits.load(ordering: .relaxed)  // 0=gentle, 1=steep
        let slopeMH = _mbSlopeMHBits.load(ordering: .relaxed)

        // Fixed per-band time constants from spec
        let aAttL = Self.computeAlpha(tauSeconds: 0.040, sampleRate: sr)
        let aRelL = Self.computeAlpha(tauSeconds: 0.200, sampleRate: sr)
        let aAttM = Self.computeAlpha(tauSeconds: 0.020, sampleRate: sr)
        let aRelM = Self.computeAlpha(tauSeconds: 0.100, sampleRate: sr)
        let aAttH = Self.computeAlpha(tauSeconds: 0.010, sampleRate: sr)
        let aRelH = Self.computeAlpha(tauSeconds: 0.050, sampleRate: sr)

        let (lpLMb0, lpLMb1, lpLMb2, lpLMa1, lpLMa2) = Self.lpfCoeffs(fc: crossLM, sr: sr)
        let (hpLMb0, hpLMb1, hpLMb2, hpLMa1, hpLMa2) = Self.hpfCoeffs(fc: crossLM, sr: sr)
        let (lpMHb0, lpMHb1, lpMHb2, lpMHa1, lpMHa2) = Self.lpfCoeffs(fc: crossMH, sr: sr)
        let (hpMHb0, hpMHb1, hpMHb2, hpMHa1, hpMHa2) = Self.hpfCoeffs(fc: crossMH, sr: sr)

        let safeCount = count

        // Split into three band buffers and apply LR4 crossover filters per channel.
        // If slope == steep, run two extra cascaded stages from mbFilterStateSteep.
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let b0 = mbBandBufs[0][ch]
            let b1 = mbBandBufs[1][ch]
            let b2 = mbBandBufs[2][ch]
            for i in 0..<safeCount { let s = buf[i]; b0[i] = s; b1[i] = s; b2[i] = s }

            let base  = ch * 16    // gentle state: ch*16
            let baseS = ch * 16    // steep state (separate array): ch*16

            // ── Band 0: LP4 @ crossLM (chain 0, stages 0 & 1) ───────────
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 0], s0w2 = mbFilterState[base + 1]
                let y0 = Self.processBiquad(b0[i], b0: lpLMb0, b1: lpLMb1, b2: lpLMb2, na1: lpLMa1, na2: lpLMa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 0] = s0w1; mbFilterState[base + 1] = s0w2
                var s1w1 = mbFilterState[base + 2], s1w2 = mbFilterState[base + 3]
                let y1 = Self.processBiquad(y0, b0: lpLMb0, b1: lpLMb1, b2: lpLMb2, na1: lpLMa1, na2: lpLMa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 2] = s1w1; mbFilterState[base + 3] = s1w2
                b0[i] = y1
            }
            // ── Steep extra stages 2 & 3 for LP@crossLM (chain 0) ───────
            if slopeLM == 1 {
                for i in 0..<safeCount {
                    var w1 = mbFilterStateSteep[baseS + 0], w2 = mbFilterStateSteep[baseS + 1]
                    let y0 = Self.processBiquad(b0[i], b0: lpLMb0, b1: lpLMb1, b2: lpLMb2, na1: lpLMa1, na2: lpLMa2, w1: &w1, w2: &w2)
                    mbFilterStateSteep[baseS + 0] = w1; mbFilterStateSteep[baseS + 1] = w2
                    var w3 = mbFilterStateSteep[baseS + 2], w4 = mbFilterStateSteep[baseS + 3]
                    let y1 = Self.processBiquad(y0, b0: lpLMb0, b1: lpLMb1, b2: lpLMb2, na1: lpLMa1, na2: lpLMa2, w1: &w3, w2: &w4)
                    mbFilterStateSteep[baseS + 2] = w3; mbFilterStateSteep[baseS + 3] = w4
                    b0[i] = y1
                }
            }

            // ── Band 1a: HP4 @ crossLM (chain 1, stages 0 & 1) ──────────
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 4], s0w2 = mbFilterState[base + 5]
                let y0 = Self.processBiquad(b1[i], b0: hpLMb0, b1: hpLMb1, b2: hpLMb2, na1: hpLMa1, na2: hpLMa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 4] = s0w1; mbFilterState[base + 5] = s0w2
                var s1w1 = mbFilterState[base + 6], s1w2 = mbFilterState[base + 7]
                let y1 = Self.processBiquad(y0, b0: hpLMb0, b1: hpLMb1, b2: hpLMb2, na1: hpLMa1, na2: hpLMa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 6] = s1w1; mbFilterState[base + 7] = s1w2
                b1[i] = y1
            }
            // ── Steep extra stages 2 & 3 for HP@crossLM (chain 1) ───────
            if slopeLM == 1 {
                for i in 0..<safeCount {
                    var w1 = mbFilterStateSteep[baseS + 4], w2 = mbFilterStateSteep[baseS + 5]
                    let y0 = Self.processBiquad(b1[i], b0: hpLMb0, b1: hpLMb1, b2: hpLMb2, na1: hpLMa1, na2: hpLMa2, w1: &w1, w2: &w2)
                    mbFilterStateSteep[baseS + 4] = w1; mbFilterStateSteep[baseS + 5] = w2
                    var w3 = mbFilterStateSteep[baseS + 6], w4 = mbFilterStateSteep[baseS + 7]
                    let y1 = Self.processBiquad(y0, b0: hpLMb0, b1: hpLMb1, b2: hpLMb2, na1: hpLMa1, na2: hpLMa2, w1: &w3, w2: &w4)
                    mbFilterStateSteep[baseS + 6] = w3; mbFilterStateSteep[baseS + 7] = w4
                    b1[i] = y1
                }
            }

            // ── Band 1b: LP4 @ crossMH (chain 2, stages 0 & 1) ──────────
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 8],  s0w2 = mbFilterState[base + 9]
                let y0 = Self.processBiquad(b1[i], b0: lpMHb0, b1: lpMHb1, b2: lpMHb2, na1: lpMHa1, na2: lpMHa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 8] = s0w1; mbFilterState[base + 9] = s0w2
                var s1w1 = mbFilterState[base + 10], s1w2 = mbFilterState[base + 11]
                let y1 = Self.processBiquad(y0, b0: lpMHb0, b1: lpMHb1, b2: lpMHb2, na1: lpMHa1, na2: lpMHa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 10] = s1w1; mbFilterState[base + 11] = s1w2
                b1[i] = y1
            }
            // ── Steep extra stages 2 & 3 for LP@crossMH (chain 2) ───────
            if slopeMH == 1 {
                for i in 0..<safeCount {
                    var w1 = mbFilterStateSteep[baseS + 8],  w2 = mbFilterStateSteep[baseS + 9]
                    let y0 = Self.processBiquad(b1[i], b0: lpMHb0, b1: lpMHb1, b2: lpMHb2, na1: lpMHa1, na2: lpMHa2, w1: &w1, w2: &w2)
                    mbFilterStateSteep[baseS + 8]  = w1; mbFilterStateSteep[baseS + 9]  = w2
                    var w3 = mbFilterStateSteep[baseS + 10], w4 = mbFilterStateSteep[baseS + 11]
                    let y1 = Self.processBiquad(y0, b0: lpMHb0, b1: lpMHb1, b2: lpMHb2, na1: lpMHa1, na2: lpMHa2, w1: &w3, w2: &w4)
                    mbFilterStateSteep[baseS + 10] = w3; mbFilterStateSteep[baseS + 11] = w4
                    b1[i] = y1
                }
            }

            // ── Band 2: HP4 @ crossMH (chain 3, stages 0 & 1) ───────────
            for i in 0..<safeCount {
                var s0w1 = mbFilterState[base + 12], s0w2 = mbFilterState[base + 13]
                let y0 = Self.processBiquad(b2[i], b0: hpMHb0, b1: hpMHb1, b2: hpMHb2, na1: hpMHa1, na2: hpMHa2, w1: &s0w1, w2: &s0w2)
                mbFilterState[base + 12] = s0w1; mbFilterState[base + 13] = s0w2
                var s1w1 = mbFilterState[base + 14], s1w2 = mbFilterState[base + 15]
                let y1 = Self.processBiquad(y0, b0: hpMHb0, b1: hpMHb1, b2: hpMHb2, na1: hpMHa1, na2: hpMHa2, w1: &s1w1, w2: &s1w2)
                mbFilterState[base + 14] = s1w1; mbFilterState[base + 15] = s1w2
                b2[i] = y1
            }
            // ── Steep extra stages 2 & 3 for HP@crossMH (chain 3) ───────
            if slopeMH == 1 {
                for i in 0..<safeCount {
                    var w1 = mbFilterStateSteep[baseS + 12], w2 = mbFilterStateSteep[baseS + 13]
                    let y0 = Self.processBiquad(b2[i], b0: hpMHb0, b1: hpMHb1, b2: hpMHb2, na1: hpMHa1, na2: hpMHa2, w1: &w1, w2: &w2)
                    mbFilterStateSteep[baseS + 12] = w1; mbFilterStateSteep[baseS + 13] = w2
                    var w3 = mbFilterStateSteep[baseS + 14], w4 = mbFilterStateSteep[baseS + 15]
                    let y1 = Self.processBiquad(y0, b0: hpMHb0, b1: hpMHb1, b2: hpMHb2, na1: hpMHa1, na2: hpMHa2, w1: &w3, w2: &w4)
                    mbFilterStateSteep[baseS + 14] = w3; mbFilterStateSteep[baseS + 15] = w4
                    b2[i] = y1
                }
            }
        }

        // Per-frame: detect band peaks, compute smoothed gain per band, sum bands back.
        var gL = mbGainLow; var gM = mbGainMid; var gH = mbGainHigh

        for frame in 0..<safeCount {
            var pkL: Float = 0.0; var pkM: Float = 0.0; var pkH: Float = 0.0
            for ch in 0..<numCh {
                let vL = mbBandBufs[0][ch][frame]; let aL = vL < 0 ? -vL : vL; if aL > pkL { pkL = aL }
                let vM = mbBandBufs[1][ch][frame]; let aM = vM < 0 ? -vM : vM; if aM > pkM { pkM = aM }
                let vH = mbBandBufs[2][ch][frame]; let aH = vH < 0 ? -vH : vH; if aH > pkH { pkH = aH }
            }
            gL = mbSmoothedGain(peak: pkL, threshDB: threshL, gain: gL, alphaAtt: aAttL, alphaRel: aRelL)
            gM = mbSmoothedGain(peak: pkM, threshDB: threshM, gain: gM, alphaAtt: aAttM, alphaRel: aRelM)
            gH = mbSmoothedGain(peak: pkH, threshDB: threshH, gain: gH, alphaAtt: aAttH, alphaRel: aRelH)
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buf[frame] = mbBandBufs[0][ch][frame] * gL
                           + mbBandBufs[1][ch][frame] * gM
                           + mbBandBufs[2][ch][frame] * gH
            }
        }
        mbGainLow = gL; mbGainMid = gM; mbGainHigh = gH
    }

    /// Computes next smoothed linear gain for a single multiband compressor band.
    /// Fixed ratio of 4.0 with a fixed 6 dB soft-knee.
    @inline(__always)
    private func mbSmoothedGain(
        peak: Float, threshDB: Float, gain: Float,
        alphaAtt: Float, alphaRel: Float
    ) -> Float {
        let xDB: Float = peak > 1e-5 ? 20.0 * log10(peak) : -100.0
        let ratio: Float = 4.0
        let kneeW: Float = 6.0
        let halfKnee = kneeW * 0.5

        let deltaDB: Float
        if xDB < threshDB - halfKnee {
            deltaDB = 0.0
        } else if abs(xDB - threshDB) <= halfKnee {
            let excess = xDB - threshDB + halfKnee
            deltaDB = (1.0 / ratio - 1.0) * excess * excess / (2.0 * kneeW)
        } else {
            deltaDB = (threshDB + (xDB - threshDB) / ratio) - xDB
        }

        let targetGain = pow(10.0, deltaDB * 0.05)
        return targetGain < gain
            ? alphaAtt * gain + (1.0 - alphaAtt) * targetGain
            : alphaRel * gain + (1.0 - alphaRel) * targetGain
    }

    // MARK: - Module 3: Compressor

    @inline(__always)
    private func processCompressor(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let thresh   = bitsToFloat(_compThreshBits.load(ordering: .relaxed))
        let ratio    = bitsToFloat(_compRatioBits.load(ordering: .relaxed))
        let alphaAtt = bitsToFloat(_compAlphaAttack.load(ordering: .relaxed))
        let baseAlphaRel = bitsToFloat(_compAlphaRelease.load(ordering: .relaxed))
        let makeup   = bitsToFloat(_compMakeupBits.load(ordering: .relaxed))
        let kneeW    = bitsToFloat(_compKneeWidthBits.load(ordering: .relaxed))
        let halfKnee = kneeW * 0.5
        let progDepRelease = _compProgramDependentRelease.load(ordering: .relaxed) != 0
        let sidechainHPHz = bitsToFloat(_compSidechainHighPassBits.load(ordering: .relaxed))
        var env = compEnvDB

        // Use cached sidechain HP coefficients (computed on main thread when sample rate or frequency changes)
        let hpB0 = compSidechainHPCoeffs.b0
        let hpB1 = compSidechainHPCoeffs.b1
        let hpB2 = compSidechainHPCoeffs.b2
        let hpA1 = compSidechainHPCoeffs.a1
        let hpA2 = compSidechainHPCoeffs.a2

        for frame in 0..<count {
            var peak: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var v = buf[frame]

                // Apply sidechain high-pass filter if enabled
                if sidechainHPHz > 0.0 {
                    var hpW1 = compSidechainHPState[ch * 2]
                    var hpW2 = compSidechainHPState[ch * 2 + 1]
                    let filtered = Self.processBiquad(v, b0: hpB0, b1: hpB1, b2: hpB2, na1: hpA1, na2: hpA2, w1: &hpW1, w2: &hpW2)
                    compSidechainHPState[ch * 2] = hpW1
                    compSidechainHPState[ch * 2 + 1] = hpW2
                    v = filtered
                }

                let a = v < 0 ? -v : v; if a > peak { peak = a }
            }
            let xDB: Float = peak > 1e-5 ? 20.0 * log10(peak) : -100.0

            // Soft-knee gain computer (three-region polynomial)
            let target: Float
            if kneeW < 0.01 {
                // Hard knee
                target = xDB > thresh ? (thresh + (xDB - thresh) / ratio) - xDB : 0.0
            } else if xDB < thresh - halfKnee {
                target = 0.0
            } else if abs(xDB - thresh) <= halfKnee {
                let excess = xDB - thresh + halfKnee
                target = (1.0 / ratio - 1.0) * excess * excess / (2.0 * kneeW)
            } else {
                target = (thresh + (xDB - thresh) / ratio) - xDB
            }

            // Program-dependent release: adapt release time based on signal dynamics
            let alphaRel: Float
            if progDepRelease {
                // Faster release for transients (large gain reduction changes)
                let delta = abs(target - env)
                let adaptiveFactor = min(1.0, delta / 10.0) // Scale based on GR change
                alphaRel = baseAlphaRel * (1.0 - adaptiveFactor * 0.5) // Up to 2x faster
            } else {
                alphaRel = baseAlphaRel
            }

            env = target < env
                ? alphaAtt * env + (1.0 - alphaAtt) * target
                : alphaRel * env + (1.0 - alphaRel) * target
            let gain = pow(10.0, env * 0.05) * makeup
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buf[frame] *= gain
            }
        }
        compEnvDB = env
    }

    // MARK: - Module 4: Expander

    @inline(__always)
    private func processExpander(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let thresh   = bitsToFloat(_expThreshBits.load(ordering: .relaxed))
        let ratio    = bitsToFloat(_expRatioBits.load(ordering: .relaxed))
        let rangeDB  = bitsToFloat(_expRangeDBBits.load(ordering: .relaxed))
        let alphaAtt = expanderAlphaAttack
        let alphaRel = expanderAlphaRelease
        var env = expEnvDB

        // Safeguards: clamp envelope to prevent excessive attenuation
        let minEnvDB: Float = -60.0 // Minimum gain reduction
        let maxEnvDB: Float = 0.0   // Maximum gain reduction
        env = max(minEnvDB, min(maxEnvDB, env))

        for frame in 0..<count {
            var peak: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let v = buf[frame]; let a = v < 0 ? -v : v; if a > peak { peak = a }
            }
            let xDB: Float     = peak > 1e-5 ? 20.0 * log10(peak) : -100.0
            // Downward expansion: when input is below threshold, attenuate by (ratio - 1)
            var deltaDB: Float = xDB < thresh ? (thresh - xDB) * (ratio - 1.0) : 0.0
            if deltaDB < rangeDB { deltaDB = rangeDB }
            env = deltaDB < env
                ? alphaAtt * env + (1.0 - alphaAtt) * deltaDB
                : alphaRel * env + (1.0 - alphaRel) * deltaDB

            // Clamp envelope to prevent runaway attenuation
            env = max(minEnvDB, min(maxEnvDB, env))

            let gain = pow(10.0, env * 0.05)

            // Detect NaN/Inf and replace with unity gain
            let safeGain = gain.isFinite ? max(1e-6, gain) : 1.0

            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buf[frame] *= safeGain
            }
        }
        expEnvDB = env
    }

    /// Updates the auto-headroom gain rider. Called once per audio callback, before
    /// the per-sample clipper/limiter loop. Uses the GR written by the previous callback.
    /// All state (`autoHeadroomGRAccumDB`, `autoHeadroomGainDB`) is audio-thread-only.
    @inline(__always)
    private func processAutoHeadroom(frameCount: Int) {
        guard _autoHeadroomEnabled.load(ordering: .relaxed) != 0 else {
            // Smoothly restore gain to 0 dB when disabled mid-session.
            if autoHeadroomGainDB < -0.01 {
                let alpha = bitsToFloat(_autoHeadroomAlphaBits.load(ordering: .relaxed))
                autoHeadroomGainDB = alpha * autoHeadroomGainDB + (1.0 - alpha) * 0.0
            } else {
                autoHeadroomGainDB = 0.0
            }
            return
        }

        let alpha          = bitsToFloat(_autoHeadroomAlphaBits.load(ordering: .relaxed))
        let targetGRDB     = bitsToFloat(_autoHeadroomTargetGRBits.load(ordering: .relaxed))
        let maxReductDB    = bitsToFloat(_autoHeadroomMaxReductBits.load(ordering: .relaxed))

        // Read current GR from the previous callback (≤ 0 dB, e.g. −3.0 for 3 dB GR).
        let currentGR_dB   = bitsToFloat(_gainReductionBits.load(ordering: .relaxed))

        // Slow-average the GR in dB domain. grAccumDB ≤ 0.
        autoHeadroomGRAccumDB = alpha * autoHeadroomGRAccumDB +
                                (1.0 - alpha) * currentGR_dB

        // excessGR_dB is negative when limiter is working harder than the target.
        // e.g. accum = −6 dB GR, target = 3 dB → excess = −3 dB → reduce by 3 dB.
        let excessGR_dB = autoHeadroomGRAccumDB + targetGRDB

        // targetDelta is the desired gain correction: ≤ 0, clamped to maxReduction.
        let targetDelta = max(-maxReductDB, min(0.0, excessGR_dB))

        // Smooth the gain toward the target using the same alpha.
        autoHeadroomGainDB = alpha * autoHeadroomGainDB + (1.0 - alpha) * targetDelta
    }

    // MARK: - Soft Clipper + Brickwall Limiter

    @inline(__always)
    private func processSoftClipperAndLimiter(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int,
        softOn: Bool, limOn: Bool
    ) {
        guard softOn || limOn else {
            _gainReductionBits.store(floatBits(0.0), ordering: .relaxed)
            _clipperGRBits.store(floatBits(0.0), ordering: .relaxed)
            return
        }

        // ── Auto-headroom: update rider state (reads previous callback's GR) ──────
        processAutoHeadroom(frameCount: count)

        // ── Apply auto-headroom pre-gain as a buffer-wide scalar ─────────────────
        // Applying once per buffer (not per sample) avoids branching in the hot loop.
        // Gain is ≤ 0 dB, so no clipping risk from the rider itself.
        if autoHeadroomGainDB < -0.001 {
            let linearGain = pow(10.0 as Float, autoHeadroomGainDB / 20.0)
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                // vDSP_vsmul is SIMD-accelerated on Apple Silicon.
                var g = linearGain
                vDSP_vsmul(buf, 1, &g, buf, 1, vDSP_Length(count))
            }
        }

        // ── Pass 1: Soft clipper only (per-frame, unchanged from original) ─────────
        let driveLinear  = bitsToFloat(_softClipperDrive.load(ordering: .relaxed))
        let threshold    = bitsToFloat(_softClipperThreshold.load(ordering: .relaxed))
        let knee         = bitsToFloat(_softClipperKnee.load(ordering: .relaxed))

        let halfKnee   = knee * 0.5
        let xLower     = threshold - halfKnee
        let xUpper     = threshold + halfKnee
        let invTwoKnee = knee > 1e-9 ? 1.0 / (2.0 * knee) : 0.0
        var clipperWasActive  = false
        var maxClipInputPeak: Float = 0.0

        if softOn {
            for frame in 0..<count {
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let input    = buf[frame] * driveLinear
                    let absInput = input < 0 ? -input : input
                    if absInput > xLower {
                        clipperWasActive = true
                        if absInput > maxClipInputPeak { maxClipInputPeak = absInput }
                    }
                    buf[frame] = softClip(input, threshold: threshold,
                                          xLower: xLower, xUpper: xUpper, invTwoKnee: invTwoKnee)
                }
            }
        }

        _clipperActiveBits.store(softOn && clipperWasActive ? 1 : 0, ordering: .relaxed)

        // Clipper GR: estimate as difference between pre-clip peak and threshold.
        if softOn && clipperWasActive && maxClipInputPeak > 1e-9 {
            let threshDB  = 20.0 * log10(threshold)
            let inputDB   = 20.0 * log10(maxClipInputPeak)
            let clipperGR = min(0.0, threshDB - inputDB)
            _clipperGRBits.store(floatBits(clipperGR), ordering: .relaxed)
        } else {
            _clipperGRBits.store(floatBits(0.0), ordering: .relaxed)
        }

        // ── Pass 2: Limiter (using extracted LookAheadLimiter) ───────────────────
        if limOn {
            // Convert AudioBufferList to array of pointers for LookAheadLimiter
            var buffers: [UnsafeMutablePointer<Float>] = []
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                buffers.append(buf)
            }
            mainLimiter.process(buffers: buffers, frameCount: count)

            // Update gain reduction reporting from mainLimiter
            _gainReductionBits.store(floatBits(mainLimiter.lastGainReductionDB), ordering: .relaxed)

            // Update true-peak tripped flag from mainLimiter
            if mainLimiter.truePeakTripped {
                _truePeakLimiterTripped.store(1, ordering: .relaxed)
            }
        } else {
            _gainReductionBits.store(floatBits(0.0), ordering: .relaxed)
        }
    }

    // MARK: - Inner DSP Helpers

    @inline(__always)
    private func softClip(
        _ x: Float, threshold: Float, xLower: Float, xUpper: Float, invTwoKnee: Float
    ) -> Float {
        let absX: Float = x < 0 ? -x : x
        let sign: Float = x >= 0 ? 1.0 : -1.0
        if absX <= xLower { return x }
        if absX > xUpper  { return sign * threshold }
        let delta = absX - xLower
        return sign * (xLower + delta - delta * delta * invTwoKnee)
    }

    /// Estimates the inter-sample true peak using 4-point FIR interpolation.
    /// Implements the ITU-R BS.1770-4 Annex 2 approach for two inter-sample phases.
    @inline(__always)
    private func scanPeak(_ buffer: UnsafeMutablePointer<Float>, size: Int) -> Float {
        var peak: Float = 0.0
        for i in 0..<size {
            let s = abs(buffer[i])
            if s > peak { peak = s }
            guard i >= 1, i < size - 2 else { continue }
            let x0 = buffer[i - 1], x1 = buffer[i], x2 = buffer[i + 1], x3 = buffer[i + 2]
            let p1 = abs(-0.1559 * x0 + 0.4989 * x1 + 0.9333 * x2 - 0.2766 * x3)
            let p3 = abs(-0.2766 * x0 + 0.9333 * x1 + 0.4989 * x2 - 0.1559 * x3)
            if p1 > peak { peak = p1 }
            if p3 > peak { peak = p3 }
        }
        return peak
    }

    /// Direct Form II Transposed biquad.
    /// na1 and na2 are stored as `-a1/a0` and `-a2/a0` (pre-negated) as returned by the coeff helpers.
    @inline(__always)
    private static func processBiquad(
        _ x: Float,
        b0: Float, b1: Float, b2: Float, na1: Float, na2: Float,
        w1: inout Float, w2: inout Float
    ) -> Float {
        let y = b0 * x + w1
        w1 = b1 * x + na1 * y + w2
        w2 = b2 * x + na2 * y
        return y
    }

    /// 2nd-order Butterworth LP coefficients (Q = 1/√2).
    /// Returns (b0, b1, b2, na1, na2) where na1/na2 are pre-negated for processBiquad.
    private static func lpfCoeffs(fc: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW * 0.7071067811865476          // sinW / (2Q), Q = 1/√2
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    = (1.0 - cosW) * 0.5 * a0inv
        let b1    = (1.0 - cosW) * a0inv
        let na1   =  2.0 * cosW * a0inv               // -a1/a0 = +2cosW/a0
        let na2   = -(1.0 - alpha) * a0inv             // -a2/a0
        return (b0, b1, b0, na1, na2)
    }

    /// 2nd-order Butterworth HP coefficients (Q = 1/√2).
    private static func hpfCoeffs(fc: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW * 0.7071067811865476
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    =  (1.0 + cosW) * 0.5 * a0inv
        let b1    = -(1.0 + cosW) * a0inv
        let na1   =  2.0 * cosW * a0inv
        let na2   = -(1.0 - alpha) * a0inv
        return (b0, b1, b0, na1, na2)
    }

    /// 2nd-order bandpass (constant 0 dB peak gain).
    private static func bpfCoeffs(fc: Float, q: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW / (2.0 * max(q, 0.1))
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    =  alpha * a0inv
        let b2    = -alpha * a0inv
        let na1   =  2.0 * cosW * a0inv
        let na2   = -(1.0 - alpha) * a0inv
        return (b0, 0.0, b2, na1, na2)
    }

    /// 2nd-order low shelf (Audio EQ Cookbook, S=1 matched slope).
    /// Returns (b0, b1, b2, na1, na2) where na1/na2 are pre-negated for processBiquad.
    private static func lowShelfCoeffs(fc: Float, gainDB: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let A    = pow(10.0, Double(gainDB) / 40.0)
        let w0   = 2.0 * Double.pi * Double(max(fc, 10.0)) / sr
        let cosW = cos(w0); let sinW = sin(w0)
        let alp  = sinW * 0.7071067811865476  // sinW / √2  (S=1)
        let s2A  = 2.0 * sqrt(A) * alp
        let Ap1  = A + 1.0;  let Am1 = A - 1.0
        let b0f  = A * (Ap1 - Am1 * cosW + s2A)
        let b1f  = 2.0 * A * (Am1 - Ap1 * cosW)
        let b2f  = A * (Ap1 - Am1 * cosW - s2A)
        let a0f  = Ap1 + Am1 * cosW + s2A
        let a1f  = -2.0 * (Am1 + Ap1 * cosW)   // already signed
        let a2f  = Ap1 + Am1 * cosW - s2A
        let inv  = 1.0 / a0f
        return (Float(b0f*inv), Float(b1f*inv), Float(b2f*inv),
                Float(-a1f*inv), Float(-a2f*inv))   // na1 = −a1/a0, na2 = −a2/a0
    }

    /// 2nd-order high shelf (Audio EQ Cookbook, S=1 matched slope).
    /// Returns (b0, b1, b2, na1, na2) where na1/na2 are pre-negated for processBiquad.
    private static func highShelfCoeffs(fc: Float, gainDB: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let A    = pow(10.0, Double(gainDB) / 40.0)
        let w0   = 2.0 * Double.pi * Double(max(fc, 10.0)) / sr
        let cosW = cos(w0); let sinW = sin(w0)
        let alp  = sinW * 0.7071067811865476  // sinW / √2  (S=1)
        let s2A  = 2.0 * sqrt(A) * alp
        let Ap1  = A + 1.0;  let Am1 = A - 1.0
        let b0f  = A * (Ap1 + Am1 * cosW + s2A)
        let b1f  = -2.0 * A * (Am1 + Ap1 * cosW)
        let b2f  = A * (Ap1 + Am1 * cosW - s2A)
        let a0f  = Ap1 - Am1 * cosW + s2A
        let a1f  = 2.0 * (Am1 - Ap1 * cosW)    // already signed
        let a2f  = Ap1 - Am1 * cosW - s2A
        let inv  = 1.0 / a0f
        return (Float(b0f*inv), Float(b1f*inv), Float(b2f*inv),
                Float(-a1f*inv), Float(-a2f*inv))   // na1 = −a1/a0, na2 = −a2/a0
    }

    // MARK: - Static Helpers

    static func dbToLinear(_ db: Float) -> Float { pow(10.0, db / 20.0) }

    static func computeLookAheadSamples(sampleRate: Double, lookAheadMs: Float) -> Int {
        let samples = Int((sampleRate * Double(lookAheadMs) / 1000.0).rounded(.up))
        return min(max(1, samples), maxLookAheadSamples)
    }

    static func computeAlpha(tauSeconds: Float, sampleRate: Double) -> Float {
        Float(exp(-1.0 / (Double(tauSeconds) * sampleRate)))
    }
}

// MARK: - Bit-casting helpers (inline, no boxing)

@inline(__always)
private func floatBits(_ f: Float) -> Int32 { Int32(bitPattern: f.bitPattern) }

@inline(__always)
private func bitsToFloat(_ bits: Int32) -> Float { Float(bitPattern: UInt32(bitPattern: bits)) }

private extension Float {
    /// √2 ≈ 1.41421356. Used to normalise constant-power balance law to unity at centre.
    static let sqrt2: Float = 1.4142135623730951
}
