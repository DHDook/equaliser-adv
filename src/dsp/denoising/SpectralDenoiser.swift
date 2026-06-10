// SpectralDenoiser.swift
// Fixes applied:
//   1. Hard binary gate replaced with Wiener soft gain — eliminates musical noise.
//   2. IFFT normalization corrected from 1/N to 1/(2N) — fixes 6 dB level error.
//   3. workImag zeroed with vDSP_vclr instead of Array allocation — real-time safe.
//   4. Configurable noise floor parameter added to Wiener gain.

import Accelerate
import Atomics
import Foundation

final class SpectralDenoiser: @unchecked Sendable {

    // MARK: - Configuration
    private static let fftSize: Int = 1024  // N
    private static let hopSize: Int = 512   // N/2 — 50% overlap
    private static let halfN:   Int = fftSize / 2

    // MARK: - FFT
    private let log2n:    vDSP_Length
    private let fftSetup: FFTSetup

    // MARK: - Pre-computed N-point Hann window
    private let hannWindow: [Float]  // length N

    // MARK: - Buffers (all pre-allocated at init — no allocations in process())
    nonisolated(unsafe) private var prevHop:       [Float]  // length hopSize
    nonisolated(unsafe) private var inputAccum:    [Float]  // length hopSize
    nonisolated(unsafe) private var accumPos:      Int = 0
    nonisolated(unsafe) private var outputOverlap: [Float]  // length N
    nonisolated(unsafe) private var workReal:      [Float]  // length N
    nonisolated(unsafe) private var workImag:      [Float]  // length N — zeroed with vDSP_vclr

    // MARK: - Output ring
    nonisolated(unsafe) private var outRing:     [Float]    // length N * 2
    nonisolated(unsafe) private var outWritePos: Int = 0
    nonisolated(unsafe) private var outReadPos:  Int = 0

    // MARK: - Parameters (atomic — main-thread writes, audio-thread reads)
    //
    // noiseFloor:  the estimated noise magnitude below which a bin is considered
    //              noise-dominated. Corresponds to the "threshold" from before,
    //              but now feeds the Wiener gain curve rather than a hard gate.
    //              Set this to the RMS level of the noise-only signal in linear
    //              amplitude (not dB). A good starting point is -60 dBFS.
    //
    // wienerFloor: minimum gain applied to any bin (range 0.0–1.0).
    //              Prevents bins from being completely zeroed, which is the
    //              primary cause of musical noise. 0.01 (-40 dB) is a good
    //              default — residual noise is inaudible but phase continuity
    //              is maintained across frames, eliminating the synthetic sound.
    //              Increase toward 0.1 for more natural-sounding processing at
    //              the cost of less noise reduction.

    private let _noiseFloorBits:  ManagedAtomic<Int32>   // linear amplitude
    private let _wienerFloorBits: ManagedAtomic<Int32>   // linear gain 0.0–1.0

    // MARK: - Init
    init() {
        let N   = Self.fftSize
        let hop = Self.hopSize
        log2n    = vDSP_Length(log2(Double(N)).rounded())
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Periodic Hann window (N in denominator).
        // Satisfies COLA-1 at 50% overlap: w[n] + w[n + N/2] = 1.0 for all n.
        // This gives perfect reconstruction on unmodified signals via OLA.
        var hann = [Float](repeating: 0, count: N)
        for i in 0..<N {
            hann[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(N)))
        }
        hannWindow = hann

        prevHop       = [Float](repeating: 0, count: hop)
        inputAccum    = [Float](repeating: 0, count: hop)
        outputOverlap = [Float](repeating: 0, count: N)
        workReal      = [Float](repeating: 0, count: N)
        workImag      = [Float](repeating: 0, count: N)
        outRing       = [Float](repeating: 0, count: N * 2)

        // Initialize read pointer to lag one hop behind write pointer
        // to account for the inherent OLA latency of one analysis frame.
        outWritePos = 0
        outReadPos  = N * 2 - hop

        // Default: noise floor = -60 dBFS, Wiener floor = 0.01 (-40 dB)
        _noiseFloorBits  = ManagedAtomic(Self.floatBits(pow(10.0, -60.0 / 20.0)))
        _wienerFloorBits = ManagedAtomic(Self.floatBits(0.01))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: - Main Thread API

    /// Sets the noise floor in dBFS.
    /// Bins whose magnitude is at or below this level are considered noise-dominated.
    /// -60 dBFS is a reasonable default for hiss removal; raise to -40 dBFS for
    /// more aggressive suppression of low-level room noise.
    func setNoiseFloorDB(_ db: Float) {
        _noiseFloorBits.store(Self.floatBits(pow(10.0, db / 20.0)), ordering: .relaxed)
    }

    /// Sets the Wiener gain floor (0.0–1.0, default 0.01 = -40 dB).
    /// This is the minimum gain applied to any bin regardless of its SNR.
    /// It prevents bins from being completely zeroed, which is the primary cause
    /// of musical noise. Lower values give more attenuation at the cost of
    /// increased residual musical noise artifacts.
    func setWienerFloor(_ floor: Float) {
        _wienerFloorBits.store(Self.floatBits(max(0.0, min(1.0, floor))), ordering: .relaxed)
    }

    // MARK: - Audio Thread

    func reset() {
        let N   = Self.fftSize
        let hop = Self.hopSize
        workReal.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N)) }
        workImag.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N)) }
        prevHop.withUnsafeMutableBufferPointer       { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(hop)) }
        inputAccum.withUnsafeMutableBufferPointer    { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(hop)) }
        outputOverlap.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N)) }
        outRing.withUnsafeMutableBufferPointer       { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N * 2)) }
        outWritePos = 0
        outReadPos  = N * 2 - hop
        accumPos    = 0
    }

    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, count: Int) {
        let N          = Self.fftSize
        let hop        = Self.hopSize
        let halfN      = Self.halfN
        let ringSize   = outRing.count
        let noiseFloor = Self.bitsToFloat(_noiseFloorBits.load(ordering: .relaxed))
        let wienerFloor = Self.bitsToFloat(_wienerFloorBits.load(ordering: .relaxed))

        // FIX 3: Pre-compute noise floor squared once per block — not per bin.
        let noiseFloorSq = noiseFloor * noiseFloor

        var srcPos = 0
        while srcPos < count {
            let chunk = min(hop - accumPos, count - srcPos)
            for i in 0..<chunk { inputAccum[accumPos + i] = buffer[srcPos + i] }
            accumPos += chunk
            srcPos   += chunk

            if accumPos == hop {

                // Form the full N-point analysis frame [prevHop | currentHop]
                // and apply the N-point Hann window.
                for i in 0..<hop { workReal[i]       = prevHop[i]    * hannWindow[i] }
                for i in 0..<hop { workReal[hop + i] = inputAccum[i] * hannWindow[hop + i] }

                // FIX 3: Zero workImag with vDSP_vclr — no Array allocation.
                workImag.withUnsafeMutableBufferPointer {
                    vDSP_vclr($0.baseAddress!, 1, vDSP_Length(N))
                }

                // Save current hop for next frame.
                for i in 0..<hop { prevHop[i]    = inputAccum[i] }
                for i in 0..<hop { inputAccum[i] = 0 }
                accumPos = 0

                workReal.withUnsafeMutableBufferPointer { rp in
                    workImag.withUnsafeMutableBufferPointer { ip in
                        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        rp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: halfN) { cBuf in
                            vDSP_ctoz(cBuf, 2, &sc, 1, vDSP_Length(halfN))
                        }

                        // Forward FFT.
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))

                        // ── FIX 1: Wiener soft gain — replaces hard binary gate ────────
                        //
                        // Old code: if mag < threshold { rp[k] = 0; ip[k] = 0 }
                        // This zeros bins completely near the threshold, causing each
                        // to switch between fully present and fully absent between frames.
                        // At 50% overlap the switching frequency is ~43 Hz — perceived
                        // as the "synthesized" or "vocoder" quality (musical noise).
                        //
                        // Wiener gain: G(k) = SNR²(k) / (SNR²(k) + 1)
                        // where SNR(k) = |X(k)| / noiseFloor.
                        // A bin well above the noise floor: SNR >> 1, G → 1.0 (passes).
                        // A bin at the noise floor: SNR = 1, G = 0.5 (-6 dB, attenuated).
                        // A bin well below: SNR << 1, G → 0 (suppressed).
                        // The gain is continuous and monotone — no abrupt switching,
                        // no musical noise.
                        //
                        // The wienerFloor prevents G from reaching zero for any bin.
                        // This maintains phase continuity across frames and eliminates
                        // residual musical noise at the cost of a noise floor.
                        //
                        // DC (rp[0]) and Nyquist (ip[0]) are real-valued scalars.
                        let dcMagSq  = rp[0] * rp[0]
                        let dcSNRsq  = dcMagSq / noiseFloorSq
                        rp[0] *= max(wienerFloor, dcSNRsq / (dcSNRsq + 1.0))

                        let nyMagSq  = ip[0] * ip[0]
                        let nySNRsq  = nyMagSq / noiseFloorSq
                        ip[0] *= max(wienerFloor, nySNRsq / (nySNRsq + 1.0))

                        // Complex bins 1 .. halfN-1.
                        for k in 1..<halfN {
                            let magSq  = rp[k] * rp[k] + ip[k] * ip[k]
                            let snrSq  = magSq / noiseFloorSq
                            let gain   = max(wienerFloor, snrSq / (snrSq + 1.0))
                            rp[k] *= gain
                            ip[k] *= gain
                        }

                        // Inverse FFT.
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))

                        // ── FIX 2: Correct IFFT normalization ─────────────────────────
                        //
                        // vDSP_fft_zrip forward scales output by 2 relative to a
                        // standard DFT. The inverse does not cancel this factor.
                        // Round-trip: IFFT(FFT(x)) = 2N * x.
                        // Correct normalization: 1/(2N), not 1/N.
                        //
                        // The previous 1/N made every frame 6 dB too loud. For input
                        // signals above ~-6 dBFS, the output exceeded 0 dBFS and was
                        // clipped or limited by downstream stages — causing the
                        // level-dependent distortion.
                        var scale: Float = 1.0 / Float(2 * N)
                        vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1,
                                   vDSP_Length(halfN))
                        vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1,
                                   vDSP_Length(halfN))

                        // Convert split-complex back to interleaved real (ztoc).
                        rp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: halfN) { cBuf in
                            vDSP_ztoc(&sc, 1, cBuf, 2, vDSP_Length(halfN))
                        }
                    }
                }

                // Overlap-add into outputOverlap.
                for i in 0..<N { outputOverlap[i] += workReal[i] }

                // Flush the first hop to the output ring.
                for i in 0..<hop {
                    outRing[outWritePos] = outputOverlap[i]
                    outWritePos = (outWritePos + 1) % ringSize
                }

                // Shift overlap buffer: move second half to first half.
                for i in 0..<hop { outputOverlap[i] = outputOverlap[hop + i] }
                for i in hop..<N { outputOverlap[i] = 0 }
            }
        }

        // Drain output ring to caller's buffer.
        for i in 0..<count {
            buffer[i]            = outRing[outReadPos]
            outRing[outReadPos]  = 0
            outReadPos           = (outReadPos + 1) % ringSize
        }
    }

    // MARK: - Helpers
    private static func floatBits(_ f: Float) -> Int32 {
        Int32(bitPattern: f.bitPattern)
    }
    private static func bitsToFloat(_ bits: Int32) -> Float {
        Float(bitPattern: UInt32(bitPattern: bits))
    }
}
