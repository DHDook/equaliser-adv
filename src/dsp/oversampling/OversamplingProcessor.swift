// OversamplingProcessor.swift
// 4× polyphase FIR oversampler for wrapping nonlinear DSP stages.
// NOT Sendable. Audio-thread only. No @MainActor.
import Accelerate
import Foundation

/// 4× polyphase FIR oversampler.
/// Wraps nonlinear stages (soft clipper, brickwall limiter) only.
final class OversamplingProcessor {

    static let factor:       Int = 4
    static let tapsPerPhase: Int = 96
    private static let kaiserBeta:  Double = 8.0
    private static let cutoffNorm:  Double = 0.45

    private let coeffs: [[Float]]

    private var delayL: [Float]
    private var delayR: [Float]
    private var delayIdxL: Int = 0
    private var delayIdxR: Int = 0

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
            h[n] = sinc * window / Double(Self.factor)
        }
        var c = [[Float]](repeating: [Float](repeating: 0, count: Self.tapsPerPhase),
                          count: Self.factor)
        for p in 0..<Self.factor {
            for k in 0..<Self.tapsPerPhase {
                c[p][k] = Float(h[p + k * Self.factor])
            }
        }
        coeffs = c

        delayL = [Float](repeating: 0, count: Self.tapsPerPhase)
        delayR = [Float](repeating: 0, count: Self.tapsPerPhase)

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
        processChannel(src: ablL, delay: &delayL, delayIdx: &delayIdxL,
                       dst: workBuf, frameCount: frameCount, channelOffset: 0)
        if let r = ablR {
            processChannel(src: r, delay: &delayR, delayIdx: &delayIdxR,
                           dst: workBuf, frameCount: frameCount,
                           channelOffset: frameCount * Self.factor)
        }
    }

    func downsample(ablL: UnsafeMutablePointer<Float>,
                    ablR: UnsafeMutablePointer<Float>?,
                    frameCount: Int) {
        let srcL = workBuf
        for i in 0..<frameCount { ablL[i] = srcL[i * Self.factor] }
        if let r = ablR {
            let srcR = workBuf.advanced(by: frameCount * Self.factor)
            for i in 0..<frameCount { r[i] = srcR[i * Self.factor] }
        }
    }

    func reset() {
        for i in 0..<delayL.count { delayL[i] = 0 }
        for i in 0..<delayR.count { delayR[i] = 0 }
        delayIdxL = 0; delayIdxR = 0
        workBuf.initialize(repeating: 0, count: workBufCapacity)
    }

    @inline(__always)
    private func processChannel(
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
                let phaseCoeffs = coeffs[p]
                for k in 0..<T {
                    acc += phaseCoeffs[k] * delay[(delayIdx - k + T) % T]
                }
                dst[outIdx] = acc
                outIdx += 1
            }
            delayIdx = (delayIdx + 1) % T
        }
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0; var term = 1.0; let hx = x / 2.0
        for k in 1...25 { term *= hx / Double(k); sum += term * term }
        return sum
    }
}

