// SRCProcessor.swift
// Polyphase Kaiser-windowed sinc SRC.
// 64 phases × 128 taps = 8192 total taps, Kaiser β = 9.0.
// Supports arbitrary rate pairs up to 384 kHz input or output.
// NOT Sendable. Audio-thread only after configure() is called.
import Accelerate
import Foundation

final class SRCProcessor {

    // MARK: - Filter design (immutable after init)
    private static let phases:       Int    = 64
    private static let tapsPerPhase: Int    = 128
    private static let kaiserBeta:   Double = 9.0
    // Prototype cutoff = 0.45 × polyphase Nyquist.
    // Safe for all upsampling ratios.
    // Downsampling gain compensation (§ downGain) handles the decimation case.
    private static let cutoffNorm:   Double = 0.45

    private let coeffs: [[Float]]   // coeffs[phase][tap], built at init

    // MARK: - Runtime state (reset by configure())
    private var inputRate:  Double = 48_000
    private var outputRate: Double = 48_000
    private var phaseAccum: Double = 0

    // Amplitude compensation for decimation.
    // = outputRate / inputRate  when downsampling (≤ 1.0)
    // = 1.0                     when upsampling (passthrough gain)
    private var downGain: Float = 1.0

    // Circular delay lines per channel (length = tapsPerPhase + 4 guard samples)
    private var delayL: [Float]
    private var delayR: [Float]
    private var delayPos: Int = 0

    // Scratch buffer for linearising the circular buffer around wrap boundaries.
    // Exactly tapsPerPhase floats — pre-allocated, never resized.
    private let linBuf: UnsafeMutablePointer<Float>

    // Maximum output frames for worst-case 44100 → 384000 (≈ 8.7×).
    // Multiplier 10 absorbs integer rounding in maxOutputFrames(for:).
    let maxFrameCount: Int
    let maxOutFrames:  Int

    // MARK: - Init

    init(maxFrameCount: Int) {
        self.maxFrameCount = maxFrameCount
        self.maxOutFrames  = maxFrameCount * 10

        // Build Kaiser-windowed sinc prototype filter.
        let totalTaps = Self.phases * Self.tapsPerPhase
        let half      = Double(totalTaps - 1) / 2.0
        let I0beta    = Self.besselI0(Self.kaiserBeta)
        var proto     = [Double](repeating: 0, count: totalTaps)

        for n in 0..<totalTaps {
            let t    = Double(n) - half
            let arg  = Double.pi * Self.cutoffNorm * t
            let sinc: Double = t == 0 ? 1.0 : sin(arg) / arg
            let x    = max(0.0, 1.0 - pow(2.0 * Double(n) / Double(totalTaps - 1) - 1.0, 2))
            let win  = Self.besselI0(Self.kaiserBeta * sqrt(x)) / I0beta
            proto[n] = sinc * win
        }

        // Normalise prototype so the passband gain is unity.
        // Without normalisation, the polyphase subfilter sum is approximately
        // cutoffNorm * 2 * phases * tapsPerPhase * (Kaiser window average) ≠ 1.
        let protoSum = proto.reduce(0.0, +)
        if protoSum > 0 {
            let normFactor = Double(Self.phases) / protoSum  // target: sum = phases (for upsampling gain)
            for i in 0..<proto.count { proto[i] *= Float(normFactor) }
        }

        // Build polyphase bank: coeffs[phase][tap].
        var bank = [[Float]](repeating: [Float](repeating: 0, count: Self.tapsPerPhase),
                             count: Self.phases)
        for p in 0..<Self.phases {
            for k in 0..<Self.tapsPerPhase {
                bank[p][k] = Float(proto[p + k * Self.phases])
            }
        }
        coeffs = bank

        let delayLen = Self.tapsPerPhase + 4
        delayL = [Float](repeating: 0, count: delayLen)
        delayR = [Float](repeating: 0, count: delayLen)

        linBuf = UnsafeMutablePointer<Float>.allocate(capacity: Self.tapsPerPhase)
        linBuf.initialize(repeating: 0, count: Self.tapsPerPhase)
    }

    deinit { linBuf.deallocate() }

    // MARK: - Configuration (main thread or before audio starts)

    func configure(inputRate: Double, outputRate: Double) {
        self.inputRate  = inputRate
        self.outputRate = outputRate
        phaseAccum      = 0
        delayPos        = 0
        // Decimation gain: compensate for the polyphase filter's implicit upsampling gain.
        // Without this, e.g. 96 kHz → 48 kHz output amplitude would be 2× correct.
        downGain = outputRate < inputRate ? Float(outputRate / inputRate) : 1.0
        for i in 0..<delayL.count { delayL[i] = 0; delayR[i] = 0 }
    }

    var needsSRC: Bool { abs(inputRate - outputRate) > 0.5 }

    // MARK: - Processing (audio thread — no allocation, no ObjC, no locks)

    /// Converts `frameCount` input frames. Returns output frame count.
    /// `outL` and `outR` must be pre-allocated to at least `maxOutputFrames(for: frameCount)`.
    @inline(__always)
    func process(
        inL: UnsafePointer<Float>,  inR: UnsafePointer<Float>?,
        outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) -> Int {
        guard needsSRC else {
            // Pass-through: same rate — memcpy and return unchanged count.
            memcpy(outL, inL, frameCount * MemoryLayout<Float>.size)
            if let inR = inR, let outR = outR {
                memcpy(outR, inR, frameCount * MemoryLayout<Float>.size)
            }
            return frameCount
        }

        // phasesPerInput: how many polyphase steps one input sample advances the accumulator.
        // upsample (outRate > inRate): > phases → multiple outputs per input.
        // downsample (outRate < inRate): < phases → one output spans multiple inputs.
        let phasesPerInput = Double(Self.phases) * outputRate / inputRate
        let P              = Double(Self.phases)
        let delayLen       = delayL.count
        let gain           = downGain  // local copy: avoids repeated struct access in hot loop
        var outCount       = 0

        for i in 0..<frameCount {
            delayL[delayPos] = inL[i]
            delayR[delayPos] = inR?[i] ?? inL[i]
            delayPos = (delayPos + 1) % delayLen

            phaseAccum += phasesPerInput
            while phaseAccum >= P {
                phaseAccum -= P
                guard outCount < maxOutFrames else { break }

                let phaseIdx = min(Int(phaseAccum), Self.phases - 1)
                let coeffRow = coeffs[phaseIdx]
                let startPos = (delayPos &- Self.tapsPerPhase &+ delayLen) % delayLen
                let seg1     = delayLen - startPos

                var sumL: Float = 0
                var sumR: Float = 0

                coeffRow.withUnsafeBufferPointer { cp in
                    let cpBase = cp.baseAddress!
                    if seg1 >= Self.tapsPerPhase {
                        vDSP_dotpr(
                            delayL.withUnsafeBufferPointer { $0.baseAddress! }.advanced(by: startPos),
                            1, cpBase, 1, &sumL, vDSP_Length(Self.tapsPerPhase))
                        vDSP_dotpr(
                            delayR.withUnsafeBufferPointer { $0.baseAddress! }.advanced(by: startPos),
                            1, cpBase, 1, &sumR, vDSP_Length(Self.tapsPerPhase))
                    } else {
                        // Wrap: linearise into scratch buffer, then dot-product.
                        memcpy(linBuf,                    delayL.withUnsafeBufferPointer { $0.baseAddress! }.advanced(by: startPos), seg1 * 4)
                        memcpy(linBuf.advanced(by: seg1), delayL.withUnsafeBufferPointer { $0.baseAddress! },                        (Self.tapsPerPhase - seg1) * 4)
                        vDSP_dotpr(linBuf, 1, cpBase, 1, &sumL, vDSP_Length(Self.tapsPerPhase))
                        memcpy(linBuf,                    delayR.withUnsafeBufferPointer { $0.baseAddress! }.advanced(by: startPos), seg1 * 4)
                        memcpy(linBuf.advanced(by: seg1), delayR.withUnsafeBufferPointer { $0.baseAddress! },                        (Self.tapsPerPhase - seg1) * 4)
                        vDSP_dotpr(linBuf, 1, cpBase, 1, &sumR, vDSP_Length(Self.tapsPerPhase))
                    }
                }
                outL[outCount] = sumL * gain
                if let outR = outR { outR[outCount] = sumR * gain }
                outCount += 1
            }
        }
        return outCount
    }

    /// Upper bound on output frames — pre-allocate output buffers to at least this size.
    func maxOutputFrames(for inputFrames: Int) -> Int {
        Int(Double(inputFrames) * outputRate / inputRate) + Self.phases + 8
    }

    // MARK: - Helpers

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let half = x / 2.0
        for k in 1...25 {
            term *= (half / Double(k)) * (half / Double(k))
            sum  += term
            if term < 1e-12 * sum { break }
        }
        return sum
    }
}
