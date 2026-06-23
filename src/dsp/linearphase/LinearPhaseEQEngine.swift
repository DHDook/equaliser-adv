// LinearPhaseEQEngine.swift
// Overlap-save FFT convolution EQ — zero phase shift, lock-free IR updates.
import Accelerate
import Atomics
import Foundation

final class LinearPhaseEQEngine: @unchecked Sendable {

    private var fftSize: Int
    private var hopSize: Int
    private var log2n:   vDSP_Length

    private var fftSetup: FFTSetup?

    nonisolated(unsafe) private var activeReal:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var activeImag:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var activeRealR: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var activeImagR: UnsafeMutablePointer<Float>
    private var pendingReal:  UnsafeMutablePointer<Float>
    private var pendingImag:  UnsafeMutablePointer<Float>
    private var pendingRealR: UnsafeMutablePointer<Float>
    private var pendingImagR: UnsafeMutablePointer<Float>
    private var nextPendingReal:  UnsafeMutablePointer<Float>
    private var nextPendingImag:  UnsafeMutablePointer<Float>
    private var nextPendingRealR: UnsafeMutablePointer<Float>
    private var nextPendingImagR: UnsafeMutablePointer<Float>
    private let hasPendingIR = ManagedAtomic<Bool>(false)

    nonisolated(unsafe) private var overlapL: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var overlapR: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var fftWorkReal: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var fftWorkImag: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var accumL: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var accumR: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var accumPosL: Int = 0
    nonisolated(unsafe) private var accumPosR: Int = 0

    /// Contiguous time-domain output buffer. Sized to fftSize.
    /// Filled by vDSP_ztoc after IFFT to unpack the split-complex result.
    private var outputBuf: UnsafeMutablePointer<Float>

    private var halfN: Int

    init(maxFrameCount: Int) {
        _ = maxFrameCount
        fftSize = 4096
        hopSize = fftSize / 2
        log2n   = vDSP_Length(12)
        halfN   = fftSize / 2
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        activeReal  = Self.alloc(fftSize)
        activeImag  = Self.alloc(fftSize)
        activeRealR = Self.alloc(fftSize)
        activeImagR = Self.alloc(fftSize)
        pendingReal  = Self.alloc(fftSize)
        pendingImag  = Self.alloc(fftSize)
        pendingRealR = Self.alloc(fftSize)
        pendingImagR = Self.alloc(fftSize)
        nextPendingReal  = Self.alloc(fftSize)
        nextPendingImag  = Self.alloc(fftSize)
        nextPendingRealR = Self.alloc(fftSize)
        nextPendingImagR = Self.alloc(fftSize)

        overlapL = Self.alloc(hopSize)
        overlapR = Self.alloc(hopSize)
        fftWorkReal = Self.alloc(fftSize)
        fftWorkImag = Self.alloc(fftSize)
        accumL = Self.alloc(fftSize)
        accumR = Self.alloc(fftSize)
        outputBuf = Self.alloc(fftSize)

        activeReal[0] = 1.0
        activeRealR[0] = 1.0
        pendingReal[0] = 1.0
        pendingRealR[0] = 1.0
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
        [activeReal, activeImag, activeRealR, activeImagR,
         pendingReal, pendingImag, pendingRealR, pendingImagR,
         nextPendingReal, nextPendingImag, nextPendingRealR, nextPendingImagR,
         overlapL, overlapR, fftWorkReal, fftWorkImag,
         accumL, accumR, outputBuf].forEach { Self.free($0) }
    }

    func updateIR(leftBands:  [EQBandConfiguration],
                  rightBands: [EQBandConfiguration],
                  sampleRate: Double) {
        let newFFTSize: Int
        switch sampleRate {
        case ...48_000:  newFFTSize = 4096
        case ...96_000:  newFFTSize = 8192
        case ...192_000: newFFTSize = 16384
        default:         newFFTSize = 32768   // 384 kHz: ~85 ms, ~11.7 Hz/bin
        }
        if newFFTSize != fftSize {
            fftSize = newFFTSize
            hopSize = fftSize / 2
            halfN   = fftSize / 2
            log2n   = vDSP_Length(log2(Double(fftSize)).rounded())
            if let s = fftSetup { vDSP_destroy_fftsetup(s) }
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
            [activeReal, activeImag, activeRealR, activeImagR,
             pendingReal, pendingImag, pendingRealR, pendingImagR,
             nextPendingReal, nextPendingImag, nextPendingRealR, nextPendingImagR,
             fftWorkReal, fftWorkImag].forEach { Self.free($0) }
            activeReal   = Self.alloc(fftSize); activeImag   = Self.alloc(fftSize)
            activeRealR  = Self.alloc(fftSize); activeImagR  = Self.alloc(fftSize)
            pendingReal  = Self.alloc(fftSize); pendingImag  = Self.alloc(fftSize)
            pendingRealR = Self.alloc(fftSize); pendingImagR = Self.alloc(fftSize)
            nextPendingReal  = Self.alloc(fftSize); nextPendingImag  = Self.alloc(fftSize)
            nextPendingRealR = Self.alloc(fftSize); nextPendingImagR = Self.alloc(fftSize)
            fftWorkReal  = Self.alloc(fftSize); fftWorkImag  = Self.alloc(fftSize)
            Self.free(outputBuf); outputBuf = Self.alloc(fftSize)
            Self.free(overlapL); overlapL = Self.alloc(hopSize)
            Self.free(overlapR); overlapR = Self.alloc(hopSize)
            Self.free(accumL);   accumL   = Self.alloc(fftSize)
            Self.free(accumR);   accumR   = Self.alloc(fftSize)
            accumPosL = 0; accumPosR = 0
        }
        computeIRSpectrum(bands: leftBands,  sampleRate: sampleRate,
                          outReal: nextPendingReal, outImag: nextPendingImag)
        computeIRSpectrum(bands: rightBands, sampleRate: sampleRate,
                          outReal: nextPendingRealR, outImag: nextPendingImagR)
        hasPendingIR.store(true, ordering: .releasing)
    }

    @inline(__always)
    func process(bufL: UnsafeMutablePointer<Float>,
                 bufR: UnsafeMutablePointer<Float>?,
                 frameCount: Int) {
        if hasPendingIR.load(ordering: .acquiring) {
            // First swap: nextPending → pending (main thread → audio thread handoff)
            swap(&nextPendingReal,  &pendingReal)
            swap(&nextPendingImag,  &pendingImag)
            swap(&nextPendingRealR, &pendingRealR)
            swap(&nextPendingImagR, &pendingImagR)
            // Second swap: pending → active (audio thread internal swap)
            swap(&activeReal,  &pendingReal)
            swap(&activeImag,  &pendingImag)
            swap(&activeRealR, &pendingRealR)
            swap(&activeImagR, &pendingImagR)
            hasPendingIR.store(false, ordering: .relaxed)
        }

        processChannel(src: bufL, dst: bufL, overlap: overlapL, accum: accumL,
                       accumPos: &accumPosL,
                       specReal: activeReal, specImag: activeImag, frameCount: frameCount)
        if let r = bufR {
            processChannel(src: r, dst: r, overlap: overlapR, accum: accumR,
                           accumPos: &accumPosR,
                           specReal: activeRealR, specImag: activeImagR, frameCount: frameCount)
        }
    }

    func reset() {
        vDSP_vclr(overlapL, 1, vDSP_Length(hopSize))
        vDSP_vclr(overlapR, 1, vDSP_Length(hopSize))
        vDSP_vclr(accumL,   1, vDSP_Length(fftSize))
        vDSP_vclr(accumR,   1, vDSP_Length(fftSize))
        accumPosL = 0
        accumPosR = 0
    }

    @inline(__always)
    private func processChannel(
        src: UnsafePointer<Float>, dst: UnsafeMutablePointer<Float>,
        overlap: UnsafeMutablePointer<Float>,
        accum: UnsafeMutablePointer<Float>,
        accumPos: inout Int,
        specReal: UnsafePointer<Float>, specImag: UnsafePointer<Float>,
        frameCount: Int
    ) {
        assert(hopSize >= frameCount,
            "LinearPhaseEQEngine: frameCount \(frameCount) exceeds hopSize \(hopSize). Increase FFT size.")
        guard let setup = fftSetup else {
            if src != dst { memcpy(dst, src, frameCount * 4) }
            return
        }

        var srcPos = 0
        var dstPos = 0
        while srcPos < frameCount {
            let chunk = min(hopSize - accumPos, frameCount - srcPos)
            memcpy(accum.advanced(by: hopSize + accumPos), src.advanced(by: srcPos),
                   chunk * MemoryLayout<Float>.size)
            accumPos += chunk
            srcPos += chunk

            if accumPos == hopSize {
                memcpy(accum, overlap, hopSize * MemoryLayout<Float>.size)

                var sc = DSPSplitComplex(realp: fftWorkReal, imagp: fftWorkImag)
                accum.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cBuf in
                    var sc2 = sc
                    vDSP_ctoz(cBuf, 2, &sc2, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, Int32(FFT_FORWARD))

                var irSC = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: specReal),
                                           imagp: UnsafeMutablePointer(mutating: specImag))
                vDSP_zvmul(&sc, 1, &irSC, 1, &sc, 1, vDSP_Length(halfN), 1)

                vDSP_fft_zrip(setup, &sc, 1, log2n, Int32(FFT_INVERSE))

                // After vDSP_fft_zrip inverse, the N real time-domain samples are packed
                // into the split-complex pair as N/2 interleaved complex values:
                //   fftWorkReal[k] = x[2k],  fftWorkImag[k] = x[2k+1]
                // Use vDSP_ztoc to unpack into a contiguous array of N real samples.
                outputBuf.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cBuf in
                    vDSP_ztoc(&sc, 1, cBuf, 2, vDSP_Length(halfN))
                }

                // Normalise. For overlap-save, scale is 1/N (round-trip vDSP scale = N).
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(outputBuf, 1, &scale, outputBuf, 1, vDSP_Length(fftSize))

                // The valid (alias-free) output is the SECOND half of the IFFT result,
                // indices [hopSize .. fftSize-1].
                let outSamples = min(hopSize, frameCount - dstPos)
                memcpy(dst.advanced(by: dstPos),
                       outputBuf.advanced(by: hopSize),
                       outSamples * MemoryLayout<Float>.size)
                dstPos += outSamples

                // Save second half of INPUT as the overlap for the next frame (overlap-save).
                memcpy(overlap, accum.advanced(by: hopSize), hopSize * MemoryLayout<Float>.size)
                accumPos = 0
            }
        }
    }

    private func computeIRSpectrum(
        bands: [EQBandConfiguration],
        sampleRate: Double,
        outReal: UnsafeMutablePointer<Float>,
        outImag: UnsafeMutablePointer<Float>
    ) {
        guard let setup = fftSetup else { return }
        let N = fftSize

        var mag = [Double](repeating: 1.0, count: halfN + 1)
        for band in bands where !band.bypass && !band.isDynamic {
            let designRate = BiquadMath.designSampleRate(
                actualRate: sampleRate,
                coefficientDecouplingEnabled: true)
            let freq = designRate != sampleRate
                ? BiquadMath.prewarpFrequency(frequency: Double(band.frequency),
                                              actualRate: sampleRate,
                                              designRate: designRate)
                : Double(band.frequency)
            let sections = BiquadMath.calculateSections(
                type: band.filterType, sampleRate: designRate,
                frequency: freq, q: Double(band.q),
                gain: Double(band.gain), slope: band.slope)
            for k in 0...halfN {
                let f = Double(k) * sampleRate / Double(N)
                var bandMag = 1.0
                for sec in sections {
                    let w  = 2.0 * Double.pi * f / sampleRate
                    let cr = cos(w), sr = sin(w)
                    let cr2 = cos(2*w), sr2 = sin(2*w)
                    let numR = sec.b0 + sec.b1 * cr  + sec.b2 * cr2
                    let numI =          sec.b1 * sr  + sec.b2 * sr2
                    let denR = 1.0  + sec.a1 * cr  + sec.a2 * cr2
                    let denI =          sec.a1 * sr  + sec.a2 * sr2
                    let denom = denR*denR + denI*denI
                    if denom > 1e-30 {
                        bandMag *= sqrt((numR*numR + numI*numI) / denom)
                    }
                }
                mag[k] *= bandMag
            }
        }

        var irReal = [Float](repeating: 0, count: N)
        for k in 0...halfN { irReal[k] = Float(mag[k]) }
        for k in 1..<halfN { irReal[N - k] = irReal[k] }

        var irImag = [Float](repeating: 0, count: N)
        var sc = DSPSplitComplex(realp: &irReal, imagp: &irImag)
        vDSP_fft_zrip(setup, &sc, 1, log2n, Int32(FFT_INVERSE))
        var scaled = [Float](repeating: 0, count: N)
        var invN = Float(1.0 / Float(N))
        vDSP_vsmul(&irReal, 1, &invN, &scaled, 1, vDSP_Length(N))

        var window = [Float](repeating: 0, count: N)
        for i in 0..<N {
            let x = 2.0 * Double.pi * Double(i) / Double(N - 1)
            window[i] = Float(0.355768 - 0.487396 * cos(x) + 0.144232 * cos(2*x) - 0.012604 * cos(3*x))
        }
        var windowed = [Float](repeating: 0, count: N)
        vDSP_vmul(&scaled, 1, &window, 1, &windowed, 1, vDSP_Length(N))

        var shifted = [Float](repeating: 0, count: N)
        let h = N / 2
        for i in 0..<N { shifted[(i + h) % N] = windowed[i] }

        var shiftedImag = [Float](repeating: 0, count: N)
        var sc2 = DSPSplitComplex(realp: &shifted, imagp: &shiftedImag)
        vDSP_fft_zrip(setup, &sc2, 1, log2n, Int32(FFT_FORWARD))

        memcpy(outReal, &shifted,      halfN * MemoryLayout<Float>.size)
        memcpy(outImag, &shiftedImag,  halfN * MemoryLayout<Float>.size)
    }

    private static func alloc(_ count: Int) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
        p.initialize(repeating: 0, count: count)
        return p
    }
    private static func free(_ p: UnsafeMutablePointer<Float>) {
        p.deallocate()
    }
}
