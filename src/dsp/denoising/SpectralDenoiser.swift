// SpectralDenoiser.swift
// Block-based spectral floor noise gate using overlap-add FFT.
// One instance per channel. Lock-free threshold update via ManagedAtomic.

import Accelerate
import Atomics
import Foundation

final class SpectralDenoiser: @unchecked Sendable {

    // MARK: - Configuration

    private static let fftSize:   Int = 1024   // 21 ms at 48 kHz — low enough latency for live use
    private static let hopSize:   Int = 512    // 50% overlap
    private static let halfN:     Int = fftSize / 2

    // MARK: - FFT

    private let log2n:    vDSP_Length
    private let fftSetup: FFTSetup

    // MARK: - Buffers

    nonisolated(unsafe) private var inputAccum:  [Float]      // length fftSize
    nonisolated(unsafe) private var accumPos:    Int = 0
    nonisolated(unsafe) private var outputOverlap: [Float]    // length fftSize
    nonisolated(unsafe) private var workReal:    [Float]
    nonisolated(unsafe) private var workImag:    [Float]

    // MARK: - Output ring (bridges overlap-add output back to callback-sized chunks)

    nonisolated(unsafe) private var outRing:     [Float]      // length fftSize * 2
    nonisolated(unsafe) private var outWritePos: Int = 0
    nonisolated(unsafe) private var outReadPos:  Int = 0

    // MARK: - Threshold (main → audio)

    private let _thresholdLinearBits: ManagedAtomic<Int32>   // magnitude threshold, linear

    // MARK: - Init

    init() {
        let N  = Self.fftSize
        log2n  = vDSP_Length(log2(Double(N)).rounded())
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        inputAccum    = [Float](repeating: 0, count: N)
        outputOverlap = [Float](repeating: 0, count: N)
        workReal      = [Float](repeating: 0, count: N)
        workImag      = [Float](repeating: 0, count: N)
        outRing       = [Float](repeating: 0, count: N * 2)
        // Default threshold: −60 dBFS → linear ≈ 0.001
        _thresholdLinearBits = ManagedAtomic(Self.floatBits(pow(10.0, -60.0 / 20.0)))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Main Thread

    func setThresholdDB(_ db: Float) {
        let linear = pow(10.0, db / 20.0)
        _thresholdLinearBits.store(Self.floatBits(linear), ordering: .relaxed)
    }

    // MARK: - Audio Thread

    func reset() {
        inputAccum    = [Float](repeating: 0, count: Self.fftSize)
        outputOverlap = [Float](repeating: 0, count: Self.fftSize)
        workReal      = [Float](repeating: 0, count: Self.fftSize)
        workImag      = [Float](repeating: 0, count: Self.fftSize)
        outRing       = [Float](repeating: 0, count: Self.fftSize * 2)
        outWritePos   = 0
        outReadPos    = 0
        accumPos      = 0
    }

    /// Processes `count` samples in-place. Introduces latency of one hop (hopSize samples).
    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, count: Int) {
        let N        = Self.fftSize
        let hop      = Self.hopSize
        let halfN    = Self.halfN
        let ringSize = outRing.count
        let threshold = Self.bitsToFloat(_thresholdLinearBits.load(ordering: .relaxed))

        var srcPos = 0
        while srcPos < count {
            // Accumulate input
            let chunk = min(hop - accumPos, count - srcPos)
            for i in 0..<chunk { inputAccum[accumPos + i] = buffer[srcPos + i] }
            accumPos += chunk
            srcPos   += chunk

            if accumPos == hop {
                // Apply Hann window to inputAccum
                var windowed = [Float](repeating: 0, count: N)
                for i in 0..<hop {
                    let w = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(hop - 1)))
                    windowed[i] = inputAccum[i] * w
                }

                // Forward FFT (zrip)
                workReal = windowed
                workImag = [Float](repeating: 0, count: N)
                workReal.withUnsafeMutableBufferPointer { rp in
                    workImag.withUnsafeMutableBufferPointer { ip in
                        rp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cBuf in
                            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ctoz(cBuf, 2, &sc, 1, vDSP_Length(halfN))
                            vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
                        }
                    }
                }

                // Spectral gate: zero bins below threshold
                for k in 0..<halfN {
                    let mag = sqrt(workReal[k] * workReal[k] + workImag[k] * workImag[k])
                    if mag < threshold {
                        workReal[k] = 0
                        workImag[k] = 0
                    }
                }

                // Inverse FFT
                workReal.withUnsafeMutableBufferPointer { rp in
                    workImag.withUnsafeMutableBufferPointer { ip in
                        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))
                        var scale: Float = 1.0 / Float(N)
                        vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1, vDSP_Length(N))
                    }
                }

                // Overlap-add into output overlap buffer
                for i in 0..<hop {
                    outputOverlap[i] += workReal[i]
                }

                // Write the first hop of overlap to output ring
                for i in 0..<hop {
                    outRing[outWritePos] = outputOverlap[i]
                    outWritePos = (outWritePos + 1) % ringSize
                }

                // Shift overlap buffer: move second half to first half
                for i in 0..<hop { outputOverlap[i] = outputOverlap[hop + i] }
                for i in hop..<N { outputOverlap[i] = 0 }

                // Overlap-add the second half of the IFFT result
                for i in 0..<hop { outputOverlap[i] += workReal[hop + i] }

                accumPos = 0
            }
        }

        // Read `count` samples from output ring back into buffer
        for i in 0..<count {
            buffer[i] = outRing[outReadPos]
            outRing[outReadPos] = 0
            outReadPos = (outReadPos + 1) % ringSize
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
