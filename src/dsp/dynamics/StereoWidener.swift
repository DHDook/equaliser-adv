import Atomics
import AudioToolbox
import Foundation

/// Three-band frequency-dependent stereo widener using M/S encoding.
///
/// Signal path per frame (stereo only, passthrough for mono):
/// ```
/// Stereo Input
///   ├─ LP4 @ 200 Hz  →  [M/S width: widthLow]  →  Low
///   ├─ HP4@200 → LP4@4kHz  →  [M/S width: widthMid]   →  Mid
///   └─ HP4 @ 4 kHz  →  [M/S width: widthHigh] →  High
///                                                          └─ Sum → Output
/// ```
///
/// Width factor encoding:
/// - 0.0 = pure mono (S = 0)
/// - 1.0 = original stereo width (unity pass-through)
/// - 2.0 = maximum expansion (M → 0, full S)
///
/// Thread safety: same atomic pattern as `DynamicsProcessor`. All filter/envelope
/// state is audio-thread-only (`nonisolated(unsafe)`); width atomics are read on the
/// audio thread and written on the main thread.
final class StereoWidener: @unchecked Sendable {

    // MARK: - Constants

    private static let defaultMaxFrames: Int = 4096
    private var storedMaxFrames: Int = 4096

    // MARK: - Atomic Parameters

    private let _enabled:     ManagedAtomic<Int32>   // 0 or 1
    private let _widthLowBits:  ManagedAtomic<Int32> // Float bits
    private let _widthMidBits:  ManagedAtomic<Int32>
    private let _widthHighBits: ManagedAtomic<Int32>
    private let _monoLowBand:   ManagedAtomic<Int32> // 0 or 1

    // MARK: - Pre-baked LR4 Crossover Coefficients
    //
    // A Linkwitz-Riley 4th-order crossover = two cascaded 2nd-order Butterworth sections.
    // Both LP stages use identical coefficients; both HP stages use identical coefficients.
    // Set on the main thread via stageCoefficients(); consumed on the audio thread each callback.

    nonisolated(unsafe) private var lmLP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var lmLP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var lmHP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var lmHP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var mhLP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var mhLP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var mhHP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var mhHP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)

    // Pending staged values (written main thread, swapped in on audio thread)
    nonisolated(unsafe) private var pendingLmLP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var pendingLmLP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var pendingLmHP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var pendingLmHP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var pendingMhLP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var pendingMhLP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var pendingMhHP1: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    nonisolated(unsafe) private var pendingMhHP2: (Float,Float,Float,Float,Float) = (1,0,0,0,0)
    private let hasPendingCoeffs: ManagedAtomic<Bool>

    // MARK: - Phase Correlation Output (audio → main)

    /// Pearson correlation of L and R channels after M/S processing.
    /// Range −1.0 (anti-phase) to +1.0 (in-phase). Written by audio thread, read by main thread.
    private let _phaseCorrelationBits: ManagedAtomic<Int32>

    // ── Running correlation accumulators (audio-thread only) ──────────
    nonisolated(unsafe) private var corrAccLL: Double = 0.0
    nonisolated(unsafe) private var corrAccRR: Double = 0.0
    nonisolated(unsafe) private var corrAccLR: Double = 0.0
    nonisolated(unsafe) private var corrSmoothed: Float = 0.0

    // MARK: - Audio-Thread Filter State
    //
    // State layout per channel (16 floats):
    //   Chain 0 (LP4 @ 200 Hz):  offsets [0..3]  — stage 0 (0,1), stage 1 (2,3)
    //   Chain 1 (HP4 @ 200 Hz):  offsets [4..7]
    //   Chain 2 (LP4 @ 4 kHz):   offsets [8..11]
    //   Chain 3 (HP4 @ 4 kHz):   offsets [12..15]
    //
    // Total: 16 floats × 2 channels = 32 floats.
    nonisolated(unsafe) private var filterState: [Float]

    // ── Temp band buffers [bandIdx 0-2][chIdx 0-1] ──────────────────────────
    // Band 0 = Low, Band 1 = Mid, Band 2 = High.
    private let bandBufs: [[UnsafeMutablePointer<Float>]]

    // MARK: - Initialisation

    init(maxFrameCount: Int = 4096) {
        _enabled             = ManagedAtomic(0)
        _widthLowBits        = ManagedAtomic(floatBitsW(0.0))
        _widthMidBits        = ManagedAtomic(floatBitsW(1.4))
        _widthHighBits       = ManagedAtomic(floatBitsW(1.25))
        _monoLowBand         = ManagedAtomic(0)
        _phaseCorrelationBits = ManagedAtomic(floatBitsW(0.0))
        hasPendingCoeffs     = ManagedAtomic(false)

        storedMaxFrames = maxFrameCount
        filterState = Array(repeating: 0.0, count: 2 * 16)

        // Pre-bake default LR4 coefficients (200 Hz / 4 kHz at 48 kHz)
        let initLmLP = Self.lpfCoeffs(fc: Float(200.0),  sr: 48000.0)
        let initLmHP = Self.hpfCoeffs(fc: Float(200.0),  sr: 48000.0)
        let initMhLP = Self.lpfCoeffs(fc: Float(4000.0), sr: 48000.0)
        let initMhHP = Self.hpfCoeffs(fc: Float(4000.0), sr: 48000.0)
        lmLP1 = initLmLP; lmLP2 = initLmLP
        lmHP1 = initLmHP; lmHP2 = initLmHP
        mhLP1 = initMhLP; mhLP2 = initMhLP
        mhHP1 = initMhHP; mhHP2 = initMhHP
        pendingLmLP1 = initLmLP; pendingLmLP2 = initLmLP
        pendingLmHP1 = initLmHP; pendingLmHP2 = initLmHP
        pendingMhLP1 = initMhLP; pendingMhLP2 = initMhLP
        pendingMhHP1 = initMhHP; pendingMhHP2 = initMhHP

        var bands: [[UnsafeMutablePointer<Float>]] = []
        for _ in 0..<3 {
            var chBufs: [UnsafeMutablePointer<Float>] = []
            for _ in 0..<2 {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
                p.initialize(repeating: 0, count: maxFrameCount)
                chBufs.append(p)
            }
            bands.append(chBufs)
        }
        bandBufs = bands
    }

    deinit {
        for band in bandBufs { for p in band { p.deinitialize(count: storedMaxFrames); p.deallocate() } }
    }

    // MARK: - Parameter API (main thread)

    var isEnabled: Bool { _enabled.load(ordering: .relaxed) != 0 }

    func setEnabled(_ v: Bool)         { _enabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setWidthLow(_ w: Float)       { _widthLowBits.store(floatBitsW(clampW(w)),  ordering: .relaxed) }
    func setWidthMid(_ w: Float)       { _widthMidBits.store(floatBitsW(clampW(w)),  ordering: .relaxed) }
    func setWidthHigh(_ w: Float)      { _widthHighBits.store(floatBitsW(clampW(w)), ordering: .relaxed) }

    private func clampW(_ w: Float) -> Float { max(0.0, min(2.0, w)) }

    func applyConfig(_ config: StereoWidenerConfig) {
        let wasEnabled = isEnabled
        setEnabled(config.isEnabled)
        // Clear any accumulated filter state (including potential NaN) whenever the
        // widener transitions from off to on. Without this, a state poisoned during
        // a previous invalid-sampleRate callback would persist across re-enables.
        if config.isEnabled && !wasEnabled { resetState() }
        setWidthLow(config.widthFactorLow)
        setWidthMid(config.widthFactorMid)
        setWidthHigh(config.widthFactorHigh)
        _monoLowBand.store(config.monoLowBand ? 1 : 0, ordering: .relaxed)
    }

    /// Stages pre-baked LR4 crossover coefficients (main thread only).
    /// The audio thread consumes them at the top of the next process() call.
    func stageCoefficients(lowMidHz: Float, midHighHz: Float, sampleRate: Double) {
        pendingLmLP1 = Self.lpfCoeffs(fc: lowMidHz,  sr: sampleRate)
        pendingLmLP2 = pendingLmLP1
        pendingLmHP1 = Self.hpfCoeffs(fc: lowMidHz,  sr: sampleRate)
        pendingLmHP2 = pendingLmHP1
        pendingMhLP1 = Self.lpfCoeffs(fc: midHighHz, sr: sampleRate)
        pendingMhLP2 = pendingMhLP1
        pendingMhHP1 = Self.hpfCoeffs(fc: midHighHz, sr: sampleRate)
        pendingMhHP2 = pendingMhHP1
        hasPendingCoeffs.store(true, ordering: .releasing)
    }

    func resetState() {
        for i in 0..<filterState.count { filterState[i] = 0 }
        corrAccLL    = 0.0
        corrAccRR    = 0.0
        corrAccLR    = 0.0
        corrSmoothed = 0.0
        _phaseCorrelationBits.store(floatBitsW(0.0), ordering: .relaxed)
    }

    // MARK: - Phase Correlation Read (main thread)

    /// Smoothed Pearson correlation coefficient between L and R channels (−1.0 … +1.0).
    /// Written atomically by the audio thread at the end of each `process()` call.
    var livePhaseCorrelation: Float {
        Float(bitPattern: UInt32(bitPattern: _phaseCorrelationBits.load(ordering: .relaxed)))
    }

    // MARK: - Audio Thread Processing

    /// Process a stereo AudioBufferList in-place.
    /// - Parameters:
    ///   - abl: Buffer list pointer (must have at least 2 channels for meaningful processing).
    ///   - numCh: Total number of channels in the buffer.
    ///   - count: Number of frames to process.
    ///   - sampleRate: Current sample rate (used to compute crossover coefficients).
    @inline(__always)
    func process(
        abl: UnsafeMutableAudioBufferListPointer,
        numCh: Int,
        count: Int,
        sampleRate: Double
    ) {
        guard numCh >= 2, count > 0, count <= storedMaxFrames,
              sampleRate > 0, sampleRate.isFinite else { return }
        guard _enabled.load(ordering: .relaxed) != 0 else { return }

        let wL  = bitsToFloatW(_widthLowBits.load(ordering: .relaxed))
        let wM  = bitsToFloatW(_widthMidBits.load(ordering: .relaxed))
        let wH  = bitsToFloatW(_widthHighBits.load(ordering: .relaxed))

        // Consume pending pre-baked coefficients (staged by stageCoefficients on main thread).
        if hasPendingCoeffs.exchange(false, ordering: .acquiringAndReleasing) {
            lmLP1 = pendingLmLP1; lmLP2 = pendingLmLP2
            lmHP1 = pendingLmHP1; lmHP2 = pendingLmHP2
            mhLP1 = pendingMhLP1; mhLP2 = pendingMhLP2
            mhHP1 = pendingMhHP1; mhHP2 = pendingMhHP2
        }

        let (lp200b0, lp200b1, lp200b2, lp200na1, lp200na2) = lmLP1
        let (lp200b0s2, lp200b1s2, lp200b2s2, lp200na1s2, lp200na2s2) = lmLP2
        let (hp200b0, hp200b1, hp200b2, hp200na1, hp200na2) = lmHP1
        let (hp200b0s2, hp200b1s2, hp200b2s2, hp200na1s2, hp200na2s2) = lmHP2
        let (lp4kb0, lp4kb1, lp4kb2, lp4kna1, lp4kna2) = mhLP1
        let (lp4kb0s2, lp4kb1s2, lp4kb2s2, lp4kna1s2, lp4kna2s2) = mhLP2
        let (hp4kb0, hp4kb1, hp4kb2, hp4kna1, hp4kna2) = mhHP1
        let (hp4kb0s2, hp4kb1s2, hp4kb2s2, hp4kna1s2, hp4kna2s2) = mhHP2

        let monoLow = _monoLowBand.load(ordering: .relaxed) != 0

        // Process each stereo channel (L = index 0, R = index 1)
        for ch in 0..<2 {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }

            let lowBuf  = bandBufs[0][ch]
            let midBuf  = bandBufs[1][ch]
            let highBuf = bandBufs[2][ch]

            // Copy input to all three band buffers
            for i in 0..<count {
                let s = buf[i]
                lowBuf[i]  = s
                midBuf[i]  = s
                highBuf[i] = s
            }

            let base = ch * 16

            // ── Band 0: LP4 @ lowMid crossover (chain 0, stages 0 & 1) ──────────
            for i in 0..<count {
                var w1 = filterState[base + 0], w2 = filterState[base + 1]
                let y0 = Self.processBiquad(lowBuf[i], b0: lp200b0, b1: lp200b1, b2: lp200b2, na1: lp200na1, na2: lp200na2, w1: &w1, w2: &w2)
                filterState[base + 0] = w1; filterState[base + 1] = w2
                var w3 = filterState[base + 2], w4 = filterState[base + 3]
                let y1 = Self.processBiquad(y0, b0: lp200b0s2, b1: lp200b1s2, b2: lp200b2s2, na1: lp200na1s2, na2: lp200na2s2, w1: &w3, w2: &w4)
                filterState[base + 2] = w3; filterState[base + 3] = w4
                lowBuf[i] = y1
            }

            // ── Band 1 stage A: HP4 @ lowMid crossover (chain 1, stages 0 & 1) ─
            for i in 0..<count {
                var w1 = filterState[base + 4], w2 = filterState[base + 5]
                let y0 = Self.processBiquad(midBuf[i], b0: hp200b0, b1: hp200b1, b2: hp200b2, na1: hp200na1, na2: hp200na2, w1: &w1, w2: &w2)
                filterState[base + 4] = w1; filterState[base + 5] = w2
                var w3 = filterState[base + 6], w4 = filterState[base + 7]
                let y1 = Self.processBiquad(y0, b0: hp200b0s2, b1: hp200b1s2, b2: hp200b2s2, na1: hp200na1s2, na2: hp200na2s2, w1: &w3, w2: &w4)
                filterState[base + 6] = w3; filterState[base + 7] = w4
                midBuf[i] = y1
            }

            // ── Band 1 stage B: LP4 @ midHigh crossover (chain 2, stages 0 & 1) ─
            for i in 0..<count {
                var w1 = filterState[base + 8],  w2 = filterState[base + 9]
                let y0 = Self.processBiquad(midBuf[i], b0: lp4kb0, b1: lp4kb1, b2: lp4kb2, na1: lp4kna1, na2: lp4kna2, w1: &w1, w2: &w2)
                filterState[base + 8]  = w1; filterState[base + 9]  = w2
                var w3 = filterState[base + 10], w4 = filterState[base + 11]
                let y1 = Self.processBiquad(y0, b0: lp4kb0s2, b1: lp4kb1s2, b2: lp4kb2s2, na1: lp4kna1s2, na2: lp4kna2s2, w1: &w3, w2: &w4)
                filterState[base + 10] = w3; filterState[base + 11] = w4
                midBuf[i] = y1
            }

            // ── Band 2: HP4 @ midHigh crossover (chain 3, stages 0 & 1) ────────
            for i in 0..<count {
                var w1 = filterState[base + 12], w2 = filterState[base + 13]
                let y0 = Self.processBiquad(highBuf[i], b0: hp4kb0, b1: hp4kb1, b2: hp4kb2, na1: hp4kna1, na2: hp4kna2, w1: &w1, w2: &w2)
                filterState[base + 12] = w1; filterState[base + 13] = w2
                var w3 = filterState[base + 14], w4 = filterState[base + 15]
                let y1 = Self.processBiquad(y0, b0: hp4kb0s2, b1: hp4kb1s2, b2: hp4kb2s2, na1: hp4kna1s2, na2: hp4kna2s2, w1: &w3, w2: &w4)
                filterState[base + 14] = w3; filterState[base + 15] = w4
                highBuf[i] = y1
            }
        }

        // Apply M/S width matrix per band, then sum back to L/R buffers.
        // Guard that both channel buffers are available before modifying them.
        guard let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        for i in 0..<count {
            let xLL = bandBufs[0][0][i]; let xRL = bandBufs[0][1][i]
            let xLM = bandBufs[1][0][i]; let xRM = bandBufs[1][1][i]
            let xLH = bandBufs[2][0][i]; let xRH = bandBufs[2][1][i]

            // M/S width for each band; mono-bass toggle forces low band to mono
            let effectiveWL = monoLow ? 0.0 : wL
            let (outLL, outRL) = widthScale(xL: xLL, xR: xRL, width: effectiveWL)
            let (outLM, outRM) = widthScale(xL: xLM, xR: xRM, width: wM)
            let (outLH, outRH) = widthScale(xL: xLH, xR: xRH, width: wH)

            bufL[i] = outLL + outLM + outLH
            bufR[i] = outRL + outRM + outRH
        }

        // Measure Pearson phase correlation after the M/S output.
        // Uses an exponential decay accumulator (≈ 300 ms time constant).
        // exp(-1/(sr*0.3)) is numerically stable at all sample rates.
        let decay = exp(-1.0 / (sampleRate * 0.3))  // Double, consistent with corrAcc types
        for i in 0..<count {
            let l = Double(bufL[i])
            let r = Double(bufR[i])
            corrAccLL = corrAccLL * decay + l * l
            corrAccRR = corrAccRR * decay + r * r
            corrAccLR = corrAccLR * decay + l * r
        }
        let denom = (corrAccLL * corrAccRR).squareRoot()
        let corrRaw: Float = denom > 1e-12 ? Float(corrAccLR / denom) : 0.0
        let corrAlpha: Float = Float(exp(-1.0 / (sampleRate * 0.1)))
        corrSmoothed = corrAlpha * corrSmoothed + (1.0 - corrAlpha) * max(-1.0, min(1.0, corrRaw))
        _phaseCorrelationBits.store(floatBitsW(corrSmoothed), ordering: .relaxed)
    }

    // MARK: - M/S Width Encoding

    /// Applies M/S width scaling to a stereo pair.
    /// - Returns: Scaled (L, R) sample pair.
    @inline(__always)
    private func widthScale(xL: Float, xR: Float, width: Float) -> (Float, Float) {
        let mid  = 0.5 * (xL + xR)
        let side = 0.5 * (xL - xR)
        let mScaled = mid  * (2.0 - width)
        let sScaled = side * width
        return (mScaled + sScaled, mScaled - sScaled)
    }

    // MARK: - Biquad DSP (mirrors DynamicsProcessor.processBiquad)

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

    /// 2nd-order Butterworth LP (Q = 1/√2).
    private static func lpfCoeffs(fc: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW * 0.7071067811865476
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    = (1.0 - cosW) * 0.5 * a0inv
        let b1    = (1.0 - cosW) * a0inv
        let na1   =  2.0 * cosW  * a0inv
        let na2   = -(1.0 - alpha) * a0inv
        return (b0, b1, b0, na1, na2)
    }

    /// 2nd-order Butterworth HP (Q = 1/√2).
    private static func hpfCoeffs(fc: Float, sr: Double) -> (Float, Float, Float, Float, Float) {
        let w0    = 2.0 * Float.pi * max(fc, 10.0) / Float(sr)
        let cosW  = cos(w0); let sinW = sin(w0)
        let alpha = sinW * 0.7071067811865476
        let a0inv = 1.0 / (1.0 + alpha)
        let b0    =  (1.0 + cosW) * 0.5 * a0inv
        let b1    = -(1.0 + cosW) * a0inv
        let na1   =  2.0 * cosW   * a0inv
        let na2   = -(1.0 - alpha) * a0inv
        return (b0, b1, b0, na1, na2)
    }
}

// MARK: - Bit-casting helpers (file-private to avoid symbol collision)

@inline(__always)
private func floatBitsW(_ f: Float) -> Int32 { Int32(bitPattern: f.bitPattern) }

@inline(__always)
private func bitsToFloatW(_ bits: Int32) -> Float { Float(bitPattern: UInt32(bitPattern: bits)) }
