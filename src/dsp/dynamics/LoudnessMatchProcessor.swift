import Atomics
import AudioToolbox
import Foundation

/// Real-time LUFS loudness matching processor.
///
/// Implements a simplified ITU-R BS.1770-4 short-term loudness measurement (3-second
/// sliding window) followed by smooth gain correction targeting a user-specified LUFS value.
///
/// Signal chain:
/// 1. K-weighting filter (high-shelf pre-filter + high-pass) applied to a measurement copy.
/// 2. Mean-square power accumulated per callback block into a circular FIFO sized for 3 s.
/// 3. Integrated power below the gate threshold (−70 dBFS) is excluded.
/// 4. Gain correction = targetLUFS − measuredLUFS, smoothed with a 2-second RC filter.
/// 5. The smoothed linear gain multiplier is applied to the live signal in-place.
///
/// Thread safety: atomic parameters written by the main thread; all state is audio-thread-only.
final class LoudnessMatchProcessor: @unchecked Sendable {

    // MARK: - Constants

    /// Maximum blocks in the 3-second FIFO (covers 384 kHz @ 128 frames per block).
    /// Derivation: 384000 Hz × 3 s / 128 frames = 9000 blocks (worst case)
    private static let maxFIFOBlocks: Int = 9000

    /// Gate threshold: blocks with mean power below this value are excluded from integration.
    private static let gateThreshold: Float = 1e-7  // ≈ −70 dBFS (relative full-scale)

    // MARK: - Atomics (main thread → audio thread)

    private let _enabled:                ManagedAtomic<Int32>
    private let _targetLUFSBits:         ManagedAtomic<Int32>  // Float bits
    /// When non-zero, raises the gate floor from −70 dBFS to −60 dBFS.
    private let _dialogueGateEnabled:    ManagedAtomic<Int32>

    // MARK: - Audio-Thread State

    /// K-weighting stage 1 (high-shelf pre-filter) state per channel: w1, w2.
    nonisolated(unsafe) private var kwState1: [Float]
    /// K-weighting stage 2 (high-pass) state per channel: w1, w2.
    nonisolated(unsafe) private var kwState2: [Float]

    /// Circular FIFO of per-block mean-square power values.
    nonisolated(unsafe) private var powerFIFO: [Float]
    nonisolated(unsafe) private var fifoWriteIndex: Int = 0
    /// Current length of the FIFO in blocks (grows from 0 to fifoCapacity).
    nonisolated(unsafe) private var fifoFilled: Int = 0
    /// Desired FIFO length (blocks) for a 3-second window at the current sample rate.
    nonisolated(unsafe) private var fifoCapacity: Int = 300

    /// Smoothed gain correction multiplier (linear). Starts at unity.
    nonisolated(unsafe) private var smoothedGain: Float = 1.0

    /// Smoothed gain alpha for 2-second RC filter (updated when sample rate or block size changes).
    nonisolated(unsafe) private var smoothAlpha: Float = 0.999

    /// Last block size seen (for lazy smoothAlpha recalculation).
    nonisolated(unsafe) private var lastBlockSize: Int = 512
    /// Last sample rate seen (for lazy smoothAlpha recalculation).
    nonisolated(unsafe) private var lastSampleRate: Double = 48000

    // MARK: - K-weighting Coefficients (recomputed when sample rate changes)

    nonisolated(unsafe) private var hs_b0: Float = 1.0
    nonisolated(unsafe) private var hs_b1: Float = 0.0
    nonisolated(unsafe) private var hs_b2: Float = 0.0
    nonisolated(unsafe) private var hs_na1: Float = 0.0
    nonisolated(unsafe) private var hs_na2: Float = 0.0

    nonisolated(unsafe) private var hp_b0: Float = 1.0
    nonisolated(unsafe) private var hp_b1: Float = 0.0
    nonisolated(unsafe) private var hp_b2: Float = 0.0
    nonisolated(unsafe) private var hp_na1: Float = 0.0
    nonisolated(unsafe) private var hp_na2: Float = 0.0

    // MARK: - Initialisation

    init() {
        _enabled             = ManagedAtomic(0)
        _targetLUFSBits      = ManagedAtomic(floatBitsL(-16.0))
        _dialogueGateEnabled = ManagedAtomic(0)
        kwState1  = Array(repeating: 0.0, count: 2 * 2)  // 2 channels × 2 state vars
        kwState2  = Array(repeating: 0.0, count: 2 * 2)
        powerFIFO = Array(repeating: 0.0, count: Self.maxFIFOBlocks)
        // NOTE: coefficients are recomputed in resetState(sampleRate:) which is called
        // immediately after init by DynamicsProcessor.init(). The 48000 here is a safe
        // placeholder that never reaches the audio thread.
        updateCoefficients(sampleRate: 48000.0, blockSize: 512)
    }

    // MARK: - Parameter API (main thread)

    var isEnabled: Bool { _enabled.load(ordering: .relaxed) != 0 }

    func setEnabled(_ v: Bool)              { _enabled.store(v ? 1 : 0, ordering: .relaxed) }
    func setTargetLUFS(_ lufs: Float)       { _targetLUFSBits.store(floatBitsL(lufs), ordering: .relaxed) }
    func setDialogueGateEnabled(_ v: Bool)  { _dialogueGateEnabled.store(v ? 1 : 0, ordering: .relaxed) }

    func applyConfig(_ config: LoudnessMatchConfig) {
        setEnabled(config.isEnabled)
        setTargetLUFS(config.targetLoudnessLUFS)
    }

    func resetState(sampleRate: Double) {
        for i in 0..<kwState1.count { kwState1[i] = 0 }
        for i in 0..<kwState2.count { kwState2[i] = 0 }
        for i in 0..<powerFIFO.count { powerFIFO[i] = 0 }
        fifoWriteIndex = 0
        fifoFilled     = 0
        smoothedGain   = 1.0
        lastBlockSize  = 512
        lastSampleRate = sampleRate
        updateCoefficients(sampleRate: sampleRate, blockSize: 512)
    }

    // MARK: - Audio Thread: Apply Gain

    /// Apply the current smoothed gain correction multiplier in-place (before the DSP chain).
    @inline(__always)
    func applyGain(abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int) {
        guard _enabled.load(ordering: .relaxed) != 0 else { return }
        let g = smoothedGain
        guard abs(g - 1.0) > 0.0001 else { return }
        for ch in 0..<numCh {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<count { buf[i] *= g }
        }
    }

    /// Update the loudness measurement and advance the smoothed gain correction.
    /// Call AFTER `applyGain` so that the measurement reflects the widened (but not yet
    /// gain-corrected) signal. This avoids feedback oscillation.
    @inline(__always)
    func update(abl: UnsafeMutableAudioBufferListPointer, numCh: Int, count: Int, sampleRate: Double) {
        guard _enabled.load(ordering: .relaxed) != 0, count > 0 else { return }

        // Recompute smoothAlpha when block size or sample rate changes
        if count != lastBlockSize || sampleRate != lastSampleRate {
            updateCoefficients(sampleRate: sampleRate, blockSize: count)
            lastBlockSize = count
            lastSampleRate = sampleRate
        }

        // Step 1: compute K-weighted mean-square power for this block
        var sumPower: Float = 0.0
        let invCh = 1.0 / Float(max(numCh, 1))

        for ch in 0..<min(numCh, 2) {
            guard let buf = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let s1base = ch * 2
            let s2base = ch * 2

            var w1_hs = kwState1[s1base];     var w2_hs = kwState1[s1base + 1]
            var w1_hp = kwState2[s2base];     var w2_hp = kwState2[s2base + 1]

            var chPower: Float = 0.0
            for i in 0..<count {
                // High-shelf pre-filter
                let y_hs = kBiquad(buf[i], b0: hs_b0, b1: hs_b1, b2: hs_b2, na1: hs_na1, na2: hs_na2, w1: &w1_hs, w2: &w2_hs)
                // High-pass filter
                let y_kw = kBiquad(y_hs,  b0: hp_b0, b1: hp_b1, b2: hp_b2, na1: hp_na1, na2: hp_na2, w1: &w1_hp, w2: &w2_hp)
                chPower += y_kw * y_kw
            }

            kwState1[s1base]     = w1_hs; kwState1[s1base + 1] = w2_hs
            kwState2[s2base]     = w1_hp; kwState2[s2base + 1] = w2_hp

            sumPower += chPower * invCh
        }

        let blockPower = sumPower / Float(count)

        // Step 2: push block power into circular FIFO
        powerFIFO[fifoWriteIndex % Self.maxFIFOBlocks] = blockPower
        fifoWriteIndex += 1
        if fifoFilled < fifoCapacity { fifoFilled += 1 }

        // Update FIFO capacity based on actual sample rate (lazy recalc)
        let desiredCapacity = max(1, Int((sampleRate * 3.0) / Double(count)))
        if desiredCapacity != fifoCapacity {
            fifoCapacity = min(desiredCapacity, Self.maxFIFOBlocks)
        }

        // Step 3: compute integrated loudness from FIFO (excluding gated blocks)
        let activeGate: Float = _dialogueGateEnabled.load(ordering: .relaxed) != 0
            ? 1e-6   // −60 dBFS: power = (10^(−60/20))² = 1e-6
            : Self.gateThreshold
        var totalPower: Float = 0.0
        var validBlocks: Int  = 0
        let blocksToRead = min(fifoFilled, fifoCapacity)
        let startIdx = fifoWriteIndex - blocksToRead
        for k in 0..<blocksToRead {
            let p = powerFIFO[(startIdx + k) % Self.maxFIFOBlocks]
            if p >= activeGate {
                totalPower += p
                validBlocks += 1
            }
        }

        guard validBlocks > 0 else { return }
        let meanPower   = totalPower / Float(validBlocks)

        // LUFS ≈ 10*log10(meanPower) − 0.691 (K-weighting offset per BS.1770)
        let measuredLUFS: Float = meanPower > 1e-10 ? 10.0 * log10(meanPower) - 0.691 : -96.0

        // Step 4: compute target gain in dB, clamp correction to ±12 dB
        let targetLUFS  = bitsToFloatL(_targetLUFSBits.load(ordering: .relaxed))
        let deltaDB     = max(-12.0, min(12.0, targetLUFS - measuredLUFS))
        let targetGain  = pow(10.0, deltaDB / 20.0)

        // Step 5: smooth with 2-second RC filter (per block, not per sample)
        let alpha = smoothAlpha
        smoothedGain = alpha * smoothedGain + (1.0 - alpha) * targetGain
    }

    // MARK: - K-weighting Coefficient Computation

    /// Recomputes K-weighting filter coefficients for the given sample rate and block size.
    func updateCoefficients(sampleRate: Double, blockSize: Int) {
        // Update smooth alpha for 2-second time constant per-block
        // Alpha depends on actual block size to maintain correct time constant across all sample rates
        let tau = 2.0
        smoothAlpha = Float(exp(-Double(blockSize) / (sampleRate * tau)))

        // ── Stage 1: K-weighting high-shelf pre-filter ───────────────────
        // Parameters from ITU-R BS.1770-4 (bilinear transform of analogue prototype).
        // f0 ≈ 1681.97 Hz, gain ≈ +4 dB, S = 1
        let hs_f0: Double = 1681.974450955533
        let hs_dBgain: Double = 3.999843853973347
        let hs_A  = pow(10.0, hs_dBgain / 40.0)
        let hs_w0 = 2.0 * Double.pi * hs_f0 / sampleRate
        let hs_sinW = sin(hs_w0); let hs_cosW = cos(hs_w0)
        // For S=1: alpha = sin(w0)/2 * sqrt(A + 1/A)
        let hs_alphaS1 = hs_sinW / 2.0 * sqrt(hs_A + 1.0 / hs_A)
        let hs_sqrtA   = sqrt(hs_A)
        let hs_a0      = (hs_A + 1.0) - (hs_A - 1.0) * hs_cosW + 2.0 * hs_sqrtA * hs_alphaS1
        let hs_a0inv   = 1.0 / hs_a0

        hs_b0  = Float(hs_A * ((hs_A + 1.0) + (hs_A - 1.0) * hs_cosW + 2.0 * hs_sqrtA * hs_alphaS1) * hs_a0inv)
        hs_b1  = Float(-2.0 * hs_A * ((hs_A - 1.0) + (hs_A + 1.0) * hs_cosW) * hs_a0inv)
        hs_b2  = Float(hs_A * ((hs_A + 1.0) + (hs_A - 1.0) * hs_cosW - 2.0 * hs_sqrtA * hs_alphaS1) * hs_a0inv)
        let hs_rawA1 = Float(-2.0 * ((hs_A - 1.0) - (hs_A + 1.0) * hs_cosW) * hs_a0inv)
        let hs_rawA2 = Float(((hs_A + 1.0) - (hs_A - 1.0) * hs_cosW - 2.0 * hs_sqrtA * hs_alphaS1) * hs_a0inv)
        hs_na1 = -hs_rawA1
        hs_na2 = -hs_rawA2

        // ── Stage 2: K-weighting revised high-pass filter ─────────────────
        // 2nd-order Butterworth HP at f0 ≈ 38.135 Hz (gives -3 dB ≈ 100 Hz).
        let hp_f0: Double = 38.13547087602444
        let hp_w0 = 2.0 * Double.pi * hp_f0 / sampleRate
        let hp_cosW = cos(hp_w0); let hp_sinW = sin(hp_w0)
        let hp_Q: Double = 0.5003270373238773
        let hp_alpha = hp_sinW / (2.0 * hp_Q)
        let hp_a0    = 1.0 + hp_alpha
        let hp_a0inv = 1.0 / hp_a0

        hp_b0  = Float((1.0 + hp_cosW) * 0.5 * hp_a0inv)
        hp_b1  = Float(-(1.0 + hp_cosW) * hp_a0inv)
        hp_b2  = hp_b0
        hp_na1 = Float(2.0 * hp_cosW * hp_a0inv)
        hp_na2 = Float(-(1.0 - hp_alpha) * hp_a0inv)
    }

    // MARK: - Inline Biquad

    @inline(__always)
    private func kBiquad(
        _ x: Float,
        b0: Float, b1: Float, b2: Float, na1: Float, na2: Float,
        w1: inout Float, w2: inout Float
    ) -> Float {
        let y = b0 * x + w1
        w1 = b1 * x + na1 * y + w2
        w2 = b2 * x + na2 * y
        return y
    }
}

// MARK: - Bit-casting helpers

@inline(__always)
private func floatBitsL(_ f: Float) -> Int32 { Int32(bitPattern: f.bitPattern) }

@inline(__always)
private func bitsToFloatL(_ bits: Int32) -> Float { Float(bitPattern: UInt32(bitPattern: bits)) }
