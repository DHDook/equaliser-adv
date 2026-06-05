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

        // Upsampling coefficients: divide by factor to compensate for zero-insertion
        var upC = [[Float]](repeating: [Float](repeating: 0, count: Self.tapsPerPhase),
                          count: Self.factor)
        for p in 0..<Self.factor {
            for k in 0..<Self.tapsPerPhase {
                upC[p][k] = Float(h[p + k * Self.factor]) / Float(Self.factor)
            }
        }
        upCoeffs = upC

        // Downsampling coefficients: use full filter (no division by factor)
        var downC = [[Float]](repeating: [Float](repeating: 0, count: Self.tapsPerPhase),
                            count: Self.factor)
        for p in 0..<Self.factor {
            for k in 0..<Self.tapsPerPhase {
                downC[p][k] = Float(h[p + k * Self.factor])
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
        for i in 0..<frameCount {
            // Load 4 samples from upsampled buffer into delay line
            for p in 0..<Self.factor {
                let srcIdx = i * Self.factor + p
                delay[(delayIdx + p) % T] = src[srcIdx]
            }

            // Apply polyphase FIR filter using appropriate phase for decimation
            // For output sample i, use phase (i mod factor) coefficients
            let phase = i % Self.factor
            var acc: Float = 0
            let phaseCoeffs = downCoeffs[phase]
            for k in 0..<T {
                acc += phaseCoeffs[k] * delay[(delayIdx - k + T) % T]
            }
            dst[i] = acc

            delayIdx = (delayIdx + Self.factor) % T
        }
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0; var term = 1.0; let hx = x / 2.0
        for k in 1...25 { term *= hx / Double(k); sum += term * term }
        return sum
    }
}

