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

    static let maxLookAheadSamples: Int = 4096

    // MARK: - Audio-Thread State

    private let channelCount: Int

    /// Current sample rate. Written by the main thread before audio starts (or on
    /// quiescent reconfigure). Read only on the audio thread during processing.
    nonisolated(unsafe) var storedSampleRate: Double

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

    // ── Stereo Widener + LUFS ─────────────────────────────────────────────
    let stereoWidener:  StereoWidener
    let lufsProcessor:  LoudnessMatchProcessor

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
    /// 2nd-order allpass biquad state for sub-bass phase alignment.
    /// Layout: [ch * 2 + 0] = w1, [ch * 2 + 1] = w2.
    nonisolated(unsafe) var subBassPhaseState: [Float]

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
    private let _deesserDynModeEnabled:  ManagedAtomic<Int32>
    private let _asymmetryTrimBits:      ManagedAtomic<Int32>  // Float bits, dB
    private let _deharshEnabled:         ManagedAtomic<Int32>
    private let _deharshTiltBits:        ManagedAtomic<Int32>  // Float bits, dB
    private let _balanceBits:            ManagedAtomic<Int32>  // Float bits, −1 to +1
    private let _channelBalanceBits:     ManagedAtomic<Int32>  // Float bits, −1 to +1 (linear L/R)
    private let _tpGuardEnabled:              ManagedAtomic<Int32>

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
    private let _oversamplingEnabled: ManagedAtomic<Int32>

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
    }

    // MARK: - Initialization

    init(channelCount: UInt32, sampleRate: Double) {
        let ch = Int(channelCount)
        self.channelCount    = ch
        self.storedSampleRate = sampleRate

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
                let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLookAheadSamples)
                p.initialize(repeating: 0, count: Self.maxLookAheadSamples)
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
        self.stereoWidener = StereoWidener()
        self.lufsProcessor = LoudnessMatchProcessor()

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
        for _ in 0..<ch {
            let dBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDelaySamples)
            dBuf.initialize(repeating: 0, count: Self.maxDelaySamples)
            delays.append(dBuf)
            let dtBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxLookAheadSamples)
            dtBuf.initialize(repeating: 0, count: Self.maxLookAheadSamples)
            deltas.append(dtBuf)
        }
        self.timeDelayBufs = delays
        self.deltaBufs     = deltas

        // Advanced DSP state arrays (initialised to zero = neutral)
        self.dcOffsetState = Array(repeating: 0.0, count: 2 * ch)
        self.deharshState  = Array(repeating: 0.0, count: 2 * ch)
        self.contourState  = Array(repeating: 0.0, count: 4 * ch)
        self.noiseShapeState = Array(repeating: 0.0, count: ch * 5)
        self.subBassPhaseState = Array(repeating: 0.0, count: ch * 2)

        // Advanced processing atomics (main → audio)
        _stereoMode             = ManagedAtomic(Int32(StereoModeSelection.stereo.rawValue))
        _dcOffsetEnabled        = ManagedAtomic(0)
        _dialogueGateEnabled    = ManagedAtomic(0)
        _loudnessContourEnabled = ManagedAtomic(0)
        _deesserDynModeEnabled  = ManagedAtomic(0)
        _asymmetryTrimBits      = ManagedAtomic(floatBits(0.0))
        _deharshEnabled         = ManagedAtomic(0)
        _deharshTiltBits        = ManagedAtomic(floatBits(-1.5))
        _balanceBits            = ManagedAtomic(floatBits(0.0))
        _channelBalanceBits     = ManagedAtomic(floatBits(0.0))
        _tpGuardEnabled               = ManagedAtomic(0)
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
        _oversamplingEnabled = ManagedAtomic(0)

        // Advanced metric atomics (audio → main)
        _phaseCorrelationBits   = ManagedAtomic(floatBits(0.0))
        _crestFactorBits        = ManagedAtomic(floatBits(0.0))
        _balanceMeterBits       = ManagedAtomic(floatBits(0.0))
        _truePeakClipperTripped = ManagedAtomic(0)
        _truePeakLimiterTripped = ManagedAtomic(0)
    }

    deinit {
        for p in lookAheadBufs {
            p.deinitialize(count: Self.maxLookAheadSamples)
            p.deallocate()
        }
        for band in mbBandBufs {
            for p in band {
                p.deinitialize(count: Self.maxLookAheadSamples)
                p.deallocate()
            }
        }
        for p in timeDelayBufs {
            p.deinitialize(count: Self.maxDelaySamples)
            p.deallocate()
        }
        for p in deltaBufs {
            p.deinitialize(count: Self.maxLookAheadSamples)
            p.deallocate()
        }
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

    func setLimiterEnabled(_ enabled: Bool) { _limiterEnabled.store(enabled ? 1 : 0, ordering: .relaxed) }
    func setLimiterCeilingDB(_ db: Float) {
        _limiterCeiling.store(floatBits(Self.dbToLinear(db)), ordering: .relaxed)
    }
    func setLimiterAttackMs(_ ms: Float, sampleRate: Double) {
        let tau = max(ms, 0.0) / 1000.0
        let alpha: Float = tau < 1e-7 ? 0.0 : Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)
        _limiterAlphaAttack.store(floatBits(alpha), ordering: .relaxed)
    }
    func setLimiterReleaseMs(_ ms: Float, sampleRate: Double) {
        let tau = ms / 1000.0
        _limiterAlphaRelease.store(floatBits(Self.computeAlpha(tauSeconds: tau, sampleRate: sampleRate)), ordering: .relaxed)
    }
    func setLimiterLookAheadMs(_ ms: Float, sampleRate: Double) {
        let newSize = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: ms)
        guard newSize != lookAheadSize else { return }
        for p in lookAheadBufs { p.initialize(repeating: 0, count: Self.maxLookAheadSamples) }
        lookAheadWriteIndex = 0
        limiterGainCurrent  = 1.0
        lookAheadSize = newSize
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
    func setChannelBalance(_ balance: Float) {
        _channelBalanceBits.store(floatBits(max(-1.0, min(1.0, balance))), ordering: .relaxed)
    }
    func setLimiterTruePeakGuardEnabled(_ v: Bool) {
        _tpGuardEnabled.store(v ? 1 : 0, ordering: .relaxed)
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
        _timeDelayBits.store(floatBits(max(0.0, min(20.0, ms))), ordering: .relaxed)
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
    func setOversamplingEnabled(_ v: Bool) {
        _oversamplingEnabled.store(v ? 1 : 0, ordering: .relaxed)
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
        setDialogueGateEnabled(adv.loudnessDialogueGateEnabled)
        setLoudnessContourEnabled(adv.loudnessContourEnabled)
        setDeesserDynamicModeEnabled(adv.deesserDynamicModeEnabled)
        setClipperAsymmetryTrimDB(adv.clipperAsymmetryTrimDB)
        setDeharshFilterEnabled(adv.deharshFilterEnabled)
        setDeharshTiltAmountDB(adv.deharshTiltAmountDB)
        setStereoBalancePosition(adv.stereoBalancePosition)
        setLimiterTruePeakGuardEnabled(adv.limiterTruePeakGuardEnabled)
        setAutoHeadroomEnabled(adv.autoHeadroomEnabled)
        setAutoHeadroomParameters(
            speed:             adv.autoHeadroomSpeed,
            targetGRDB:        adv.autoHeadroomTargetGRDB,
            maxReductionDB:    adv.autoHeadroomMaxReductionDB,
            sampleRate:        storedSampleRate,
            typicalFrameCount: lookAheadSize > 0 ? lookAheadSize : 512
        )
        setStereoTimeDelayMS(adv.stereoTimeDelayMS)
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
        setOversamplingEnabled(adv.oversamplingEnabled)
    }

    /// Called when the pipeline sample rate changes (main thread).
    func updateSampleRate(_ sampleRate: Double, attackMs: Float, releaseMs: Float, lookAheadMs: Float) {
        storedSampleRate = sampleRate
        for p in lookAheadBufs { p.initialize(repeating: 0, count: Self.maxLookAheadSamples) }
        lookAheadWriteIndex = 0
        lookAheadSize       = Self.computeLookAheadSamples(sampleRate: sampleRate, lookAheadMs: lookAheadMs)
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
    }

    // MARK: - DSP Processing (audio thread)

    @inline(__always)
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let count = Int(frameCount)
        guard count > 0 else { return }
        let abl   = UnsafeMutableAudioBufferListPointer(bufferList)
        let numCh = min(channelCount, abl.count)
        guard numCh > 0 else { return }

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

        let subPhaseOn = _subBassPhaseEnabled.load(ordering: .relaxed) != 0
        guard stereoModeRaw != 0 || dcOn || subPhaseOn || wideOn || lufsOn || contourOn
                || deEsserOn || mbOn || compOn || expOn || softOn || limOn
                || deharshOn || pauseOn || ditherMode != 0 || deltaSoloOn else {
            _gainReductionBits.store(floatBits(0.0), ordering: .relaxed)
            return
        }

        // Capture pre-chain signal for delta solo (must be first).
        if deltaSoloOn { captureDeltaInput(abl: abl, numCh: numCh, count: count) }

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

        // Stage 5: Soft Clipper + Brickwall Limiter.
        let oversampleOn = _oversamplingEnabled.load(ordering: .relaxed) != 0
        if !oversampleOn {
            processSoftClipperAndLimiter(abl: abl, numCh: numCh, count: count, softOn: softOn, limOn: limOn)
        }

        // Stage 6: De-Harsh Tilt Filter.
        if deharshOn { processDeHarsh(abl: abl, numCh: numCh, count: count) }

        // Stage 7: Balance Matrix + Inter-Channel Time Delay.
        processBalanceAndDelay(abl: abl, numCh: numCh, count: count)

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
        let safeCount = min(count, Self.maxLookAheadSamples)
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
        let (b0ls, b1ls, b2ls, a1ls, a2ls) = Self.lowShelfCoeffs(fc: 80.0, gainDB:  3.0, sr: sr)
        let (b0hs, b1hs, b2hs, a1hs, a2hs) = Self.highShelfCoeffs(fc: 6000.0, gainDB: 1.5, sr: sr)
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
        let balance  = bitsToFloat(_balanceBits.load(ordering: .relaxed))
        let angle    = (balance + 1.0) * Float.pi * 0.25   // 0 … π/2
        let gainL    = max(0.0, cos(angle)) * Float.sqrt2
        let gainR    = max(0.0, sin(angle)) * Float.sqrt2
        if gainL != 1.0 || gainR != 1.0 {
            for i in 0..<count { bufL[i] *= gainL; bufR[i] *= gainR }
        }

        // Live balance meter: (powerR − powerL) / totalPower.
        var powerL: Float = 0.0, powerR: Float = 0.0
        for i in 0..<count { powerL += bufL[i] * bufL[i]; powerR += bufR[i] * bufR[i] }
        let total = powerL + powerR
        _balanceMeterBits.store(
            floatBits(total > 1e-12 ? (powerR - powerL) / total : 0.0),
            ordering: .relaxed
        )

        // Inter-channel time delay (right channel delayed relative to left).
        let delayMs      = bitsToFloat(_timeDelayBits.load(ordering: .relaxed))
        let newDelay     = Int((delayMs / 1000.0) * Float(storedSampleRate) + 0.5)
        let delaySamples = min(newDelay, Self.maxDelaySamples - 1)
        timeDelaySamples = delaySamples
        guard delaySamples > 0 else { return }

        let delayBuf = timeDelayBufs[1]
        let bufSize  = Self.maxDelaySamples
        for i in 0..<count {
            delayBuf[timeDelayWriteIdx] = bufR[i]
            let readIdx = (timeDelayWriteIdx - delaySamples + bufSize) % bufSize
            bufR[i] = delayBuf[readIdx]
            timeDelayWriteIdx = (timeDelayWriteIdx + 1) % bufSize
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
            if storedSampleRate > 54_000 {
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
            let h: (Float, Float, Float, Float, Float) = (2.033, -2.165, 1.959, -1.590, 0.6149)
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let base = ch * 5
                var s0 = noiseShapeState[base]
                var s1 = noiseShapeState[base + 1]
                var s2 = noiseShapeState[base + 2]
                var s3 = noiseShapeState[base + 3]
                var s4 = noiseShapeState[base + 4]
                for i in 0..<count {
                    let r = ditherRNG.nextFloat(in: -lsb...lsb)
                    let shaped = r - (h.0*s0 + h.1*s1 + h.2*s2 + h.3*s3 + h.4*s4)
                    let input = buf[i] + shaped
                    let quant = (input * invLSB).rounded() * lsb
                    let error = quant - input
                    s4 = s3; s3 = s2; s2 = s1; s1 = s0
                    s0 = error
                    buf[i] = quant
                }
                noiseShapeState[base]     = s0
                noiseShapeState[base + 1] = s1
                noiseShapeState[base + 2] = s2
                noiseShapeState[base + 3] = s3
                noiseShapeState[base + 4] = s4
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

    /// Delta solo: outputs the difference (processed − original) so you can hear what the chain adds.
    @inline(__always)
    private func processDeltaSolo(
        abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int
    ) {
        let safeCount = min(count, Self.maxLookAheadSamples)
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
        let freq   = bitsToFloat(_subBassPhaseFreqBits.load(ordering: .relaxed))
        let coeffs = BiquadMath.allPass(sampleRate: storedSampleRate,
                                        frequency: Double(freq), q: 0.7)
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
            var w1 = subBassPhaseState[ch * 2]
            var w2 = subBassPhaseState[ch * 2 + 1]
            for i in 0..<count {
                buf[i] = Self.processBiquad(buf[i],
                    b0: b0, b1: b1, b2: b2, na1: na1, na2: na2,
                    w1: &w1, w2: &w2)
            }
            subBassPhaseState[ch * 2]     = w1
            subBassPhaseState[ch * 2 + 1] = w2
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

        let safeCount = min(count, Self.maxLookAheadSamples)

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
        let alphaRel = bitsToFloat(_compAlphaRelease.load(ordering: .relaxed))
        let makeup   = bitsToFloat(_compMakeupBits.load(ordering: .relaxed))
        let kneeW    = bitsToFloat(_compKneeWidthBits.load(ordering: .relaxed))
        let halfKnee = kneeW * 0.5
        var env = compEnvDB

        for frame in 0..<count {
            var peak: Float = 0.0
            for ch in 0..<numCh {
                guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let v = buf[frame]; let a = v < 0 ? -v : v; if a > peak { peak = a }
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

        let driveLinear  = bitsToFloat(_softClipperDrive.load(ordering: .relaxed))
        let threshold    = bitsToFloat(_softClipperThreshold.load(ordering: .relaxed))
        let knee         = bitsToFloat(_softClipperKnee.load(ordering: .relaxed))
        let alphaAttack  = bitsToFloat(_limiterAlphaAttack.load(ordering: .relaxed))
        let alphaRelease = bitsToFloat(_limiterAlphaRelease.load(ordering: .relaxed))

        // ── TP Guard ceiling offset ───────────────────────────────────────────────
        // The four-point FIR interpolator in scanPeak has a theoretical maximum gain
        // of ≈1.865×. While peak signals that trigger this extreme overshoot are rare,
        // reducing the effective ceiling by 0.5 dBTP when the guard is active provides
        // safety headroom for the estimator's uncertainty.
        let tpGuardOn    = _tpGuardEnabled.load(ordering: .relaxed) != 0
        let rawCeiling   = bitsToFloat(_limiterCeiling.load(ordering: .relaxed))
        // 0.5 dBTP offset: 10^(−0.5/20) ≈ 0.9441
        let ceiling      = tpGuardOn ? rawCeiling * 0.9441 : rawCeiling

        let halfKnee   = knee * 0.5
        let xLower     = threshold - halfKnee
        let xUpper     = threshold + halfKnee
        let invTwoKnee = knee > 1e-9 ? 1.0 / (2.0 * knee) : 0.0
        let la         = max(1, min(lookAheadSize, Self.maxLookAheadSamples))
        var writeIdx   = lookAheadWriteIndex
        var gC         = limiterGainCurrent
        var lastGC     = gC
        var clipperWasActive  = false
        var maxClipInputPeak: Float = 0.0
        // TP guard: track inter-sample peak of post-limiter output.
        var postLimiterPeak: Float = 0.0

        for frame in 0..<count {
            if softOn {
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

                // TP guard: check if clipper output could produce inter-sample peaks above ceiling.
                if tpGuardOn {
                    for ch in 0..<numCh {
                        guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        let s = abs(buf[frame])
                        if s > postLimiterPeak { postLimiterPeak = s }
                    }
                }
            }
            if limOn {
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    lookAheadBufs[ch][writeIdx] = buf[frame]
                }
                var peakAmplitude: Float = 0.0
                for ch in 0..<numCh {
                    let p = scanPeak(lookAheadBufs[ch], size: la)
                    if p > peakAmplitude { peakAmplitude = p }
                }
                let gTarget: Float = peakAmplitude > ceiling && peakAmplitude > 1e-9
                    ? ceiling / peakAmplitude : 1.0
                if gTarget < gC {
                    gC = alphaAttack < 1e-6 ? gTarget : gC * alphaAttack + gTarget * (1.0 - alphaAttack)
                } else {
                    gC = gC * alphaRelease + gTarget * (1.0 - alphaRelease)
                }
                let readIdx = (writeIdx + 1) % la
                for ch in 0..<numCh {
                    guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    buf[frame] = lookAheadBufs[ch][readIdx] * gC
                }

                // TP guard: accumulate inter-sample peak of the post-limiter output.
                if tpGuardOn {
                    for ch in 0..<numCh {
                        guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        let s = abs(buf[frame])
                        if s > postLimiterPeak { postLimiterPeak = s }
                    }
                }

                lastGC   = gC
                writeIdx = (writeIdx + 1) % la
            }
        }

        lookAheadWriteIndex = writeIdx
        limiterGainCurrent  = gC
        _clipperActiveBits.store(softOn && clipperWasActive ? 1 : 0, ordering: .relaxed)
        let grDB = lastGC > 1e-9 ? 20.0 * log10(lastGC) : Float(-90.0)
        _gainReductionBits.store(floatBits(grDB), ordering: .relaxed)

        // ── TP Guard: set sticky tripped flags ───────────────────────────────────
        // Check post-processing output for residual inter-sample peaks above rawCeiling.
        // scanPeak is run on the look-ahead buffer above; here we check the sample-domain
        // output as a secondary indicator that the guard was needed.
        if tpGuardOn && postLimiterPeak > rawCeiling {
            if limOn  { _truePeakLimiterTripped.store(1, ordering: .relaxed) }
            if softOn { _truePeakClipperTripped.store(1, ordering: .relaxed) }
        }

        // Clipper GR: estimate as difference between pre-clip peak and threshold.
        if softOn && clipperWasActive && maxClipInputPeak > 1e-9 {
            let threshDB  = 20.0 * log10(threshold)
            let inputDB   = 20.0 * log10(maxClipInputPeak)
            let clipperGR = min(0.0, threshDB - inputDB)
            _clipperGRBits.store(floatBits(clipperGR), ordering: .relaxed)
        } else {
            _clipperGRBits.store(floatBits(0.0), ordering: .relaxed)
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
