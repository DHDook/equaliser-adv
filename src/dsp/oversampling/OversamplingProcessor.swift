// OversamplingProcessor.swift
// 4× polyphase FIR oversampler for wrapping nonlinear DSP stages.
// NOT Sendable. Audio-thread only. No @MainActor.
import Accelerate
import Foundation

/// 4× polyphase FIR oversampler using vDSP for gain-preserving operation.
/// Wraps nonlinear stages (soft clipper, brickwall limiter) only.
final class OversamplingProcessor {

    static let factor:       Int = 4
    static let tapsPerPhase: Int = 96
    private static let kaiserBeta:  Double = 8.0
    private static let cutoffNorm:  Double = 0.45

    private let upCoeffs: [[Float]]
    private let downCoeffs: [[Float]]

    private var upDelayL: [Float]
    private var upDelayR: [Float]
    private var upDelayIdxL: Int = 0
    private var upDelayIdxR: Int = 0

    private var downDelayL: [Float]
    private var downDelayR: [Float]
    private var downDelayIdxL: Int = 0
    private var downDelayIdxR: Int = 0

    private let workBuf: UnsafeMutablePointer<Float>
    private let workBufCapacity: Int

    init(maxFrameCount: Int) {
        let total  = Self.factor * Self.tapsPerPhase
        let half   = Double(total - 1) / 2.0
        let I0beta = Self.besselI0(Self.kaiserBeta)
        var h      = [Double](repeating: 0, count: total)
        for n in 0..<total {
            let t = Double(n) - half
            let sinc: Double
            let arg = Double.pi * Self.cutoffNorm * t
            sinc = t == 0 ? 1.0 : sin(arg) / arg
            let x      = 1.0 - Foundation.pow(2.0 * Double(n) / Double(total - 1) - 1.0, 2)
            let window = Self.besselI0(Self.kaiserBeta * (x > 0 ? sqrt(x) : 0)) / I0beta
            h[n] = sinc * window
        }

        // Normalize prototype so sum(h) = factor.
        // The Kaiser-windowed sinc as computed has sum(h) ≈ 2.22 for these parameters,
        // not 4.0. Without normalization the polyphase upsampler output is ~0.555× amplitude.
        let sumH = h.reduce(0.0, +)
        let normScale = Double(Self.factor) / sumH
        h = h.map { $0 * normScale }

        // Upsampling coefficients: h_norm[p + k*factor] / factor.
        // With h normalized to sum = factor, dividing each tap by factor gives
        // a per-phase sum of 1.0 — correct unity gain for the interpolating filter.
        var upC = [[Float]](repeating: [Float](repeating: 0, count: Self.tapsPerPhase),
                          count: Self.factor)
        for p in 0..<Self.factor {
            for k in 0..<Self.tapsPerPhase {
                upC[p][k] = Float(h[p + k * Self.factor]) / Float(Self.factor)
            }
        }
        upCoeffs = upC

        // Downsampling coefficients: only phase 0 is used per output sample.
        // Store all phases so the array shape is unchanged, but decimation applies phase 0 only.
        //
        // GAIN BUDGET — why we multiply by factor here:
        //
        // The upsampler inserts (factor − 1) zeros between each input sample and then
        // filters, which produces `factor` output samples per input sample. Because the
        // prototype filter was normalised so that sum(h) = factor, dividing each tap by
        // factor in upCoeffs gives per-phase sums of 1.0 — but the actual amplitude of
        // each output sample is 1/factor (0.25 for 4×). The upsampled signal is therefore
        // at 1/4 the input amplitude in the oversampled domain.
        //
        // The decimator must compensate by applying a gain of `factor` to recover unity:
        //   round-trip gain = (1/factor) [upsample] × (factor × phase-0 sum) [downsample]
        //                   = (1/4) × (4 × 1.0) = 1.0  ✓
        //
        // Without this ×factor, the round-trip gain is exactly 1/factor = 0.25 (−12 dB),
        // which is the audible attenuation reported when oversampling is enabled.
        let factorF = Float(Self.factor)
        var downC = [[Float]](repeating: [Float](repeating: 0, count: Self.tapsPerPhase),
                            count: Self.factor)
        for p in 0..<Self.factor {
            for k in 0..<Self.tapsPerPhase {
                downC[p][k] = Float(h[p + k * Self.factor]) * factorF
            }
        }
        downCoeffs = downC

        upDelayL = [Float](repeating: 0, count: Self.tapsPerPhase)
        upDelayR = [Float](repeating: 0, count: Self.tapsPerPhase)
        downDelayL = [Float](repeating: 0, count: Self.tapsPerPhase)
        downDelayR = [Float](repeating: 0, count: Self.tapsPerPhase)

        workBufCapacity = maxFrameCount * Self.factor * 2
        workBuf = UnsafeMutablePointer<Float>.allocate(capacity: workBufCapacity)
        workBuf.initialize(repeating: 0, count: workBufCapacity)
    }

    deinit {
        workBuf.deinitialize(count: workBufCapacity)
        workBuf.deallocate()
    }

    func workBufferL() -> UnsafeMutablePointer<Float> { workBuf }

    func workBufferR(frameCount: Int) -> UnsafeMutablePointer<Float> {
        workBuf.advanced(by: frameCount * Self.factor)
    }

    func upsample(ablL: UnsafeMutablePointer<Float>,
                           ablR: UnsafeMutablePointer<Float>?,
                           frameCount: Int) {
        processChannelUpsample(src: ablL, delay: &upDelayL, delayIdx: &upDelayIdxL,
                              dst: workBuf, frameCount: frameCount, channelOffset: 0)
        if let r = ablR {
            processChannelUpsample(src: r, delay: &upDelayR, delayIdx: &upDelayIdxR,
                                  dst: workBuf, frameCount: frameCount,
                                  channelOffset: frameCount * Self.factor)
        }
    }

    func downsample(ablL: UnsafeMutablePointer<Float>,
                    ablR: UnsafeMutablePointer<Float>?,
                    frameCount: Int) {
        processChannelDownsample(src: workBuf, delay: &downDelayL, delayIdx: &downDelayIdxL,
                                  dst: ablL, frameCount: frameCount)
        if let r = ablR {
            let srcR = workBuf.advanced(by: frameCount * Self.factor)
            processChannelDownsample(src: srcR, delay: &downDelayR, delayIdx: &downDelayIdxR,
                                    dst: r, frameCount: frameCount)
        }
    }

    func reset() {
        for i in 0..<upDelayL.count { upDelayL[i] = 0 }
        for i in 0..<upDelayR.count { upDelayR[i] = 0 }
        for i in 0..<downDelayL.count { downDelayL[i] = 0 }
        for i in 0..<downDelayR.count { downDelayR[i] = 0 }
        upDelayIdxL = 0; upDelayIdxR = 0
        downDelayIdxL = 0; downDelayIdxR = 0
        workBuf.initialize(repeating: 0, count: workBufCapacity)
    }

    @inline(__always)
    private func processChannelUpsample(
        src: UnsafePointer<Float>,
        delay: inout [Float],
        delayIdx: inout Int,
        dst: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelOffset: Int
    ) {
        let T = Self.tapsPerPhase
        var outIdx = channelOffset
        for i in 0..<frameCount {
            delay[delayIdx] = src[i]
            for p in 0..<Self.factor {
                var acc: Float = 0
                let phaseCoeffs = upCoeffs[p]
                for k in 0..<T {
                    acc += phaseCoeffs[k] * delay[(delayIdx - k + T) % T]
                }
                dst[outIdx] = acc
                outIdx += 1
            }
            delayIdx = (delayIdx + 1) % T
        }
    }

    @inline(__always)
    private func processChannelDownsample(
        src: UnsafePointer<Float>,
        delay: inout [Float],
        delayIdx: inout Int,
        dst: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let T = Self.tapsPerPhase
        let F = Self.factor
        // Phase 0 coefficients are the only subfilter applied per output sample.
        // Polyphase decimation by factor F: load F new input samples, then evaluate
        // a single polyphase branch (phase 0) to produce one output sample.
        // Summing all F branches (the previous code) gives gain ≈ sum(h) instead of 1.
        let phaseCoeffs = downCoeffs[0]
        for i in 0..<frameCount {
            // 1. Write F new upsampled input samples into the delay line.
            for p in 0..<F {
                delay[(delayIdx + p) % T] = src[i * F + p]
            }
            // 2. Advance the write head.
            delayIdx = (delayIdx + F) % T
            // 3. Accumulate phase-0 filter taps (newest sample at tap 0).
            var acc: Float = 0
            for k in 0..<T {
                acc += phaseCoeffs[k] * delay[(delayIdx - 1 - k + T) % T]
            }
            dst[i] = acc
        }
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0; var term = 1.0; let hx = x / 2.0
        for k in 1...25 { term *= hx / Double(k); sum += term * term }
        return sum
    }
}

