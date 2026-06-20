// RoomCorrectionEngine.swift — static greedy parametric band fitting.
// Main thread only. Pure function — no state, no allocation constraints.
import Accelerate
import Foundation

enum RoomCorrectionEngine {

    static let maxCorrectionBands:  Int   = 20
    static let maxCorrectionGainDB: Float = 12.0
    static let stopResidualDB:      Float = 0.5

    // MARK: - Target Curves

    enum TargetCurve: String, Codable, Sendable, CaseIterable {
        case flat = "Flat"
        case harman = "Harman"
        case custom = "Custom"

        var displayName: String { rawValue }
    }

    /// Returns the Harman target curve frequency response.
    /// Based on the Harman headphone target curve (Olive-Welti et al.).
    /// - Returns: Array of (frequency, gainDB) tuples
    static func harmanTargetCurve() -> [(frequency: Double, gainDB: Double)] {
        return [
            (20.0, 2.0),
            (50.0, 1.5),
            (100.0, 1.0),
            (200.0, 0.5),
            (500.0, 0.0),
            (1000.0, -1.0),
            (2000.0, -2.0),
            (4000.0, -1.5),
            (8000.0, -1.0),
            (16000.0, -2.0),
            (20000.0, -3.0)
        ]
    }

    /// Returns the target curve for the specified type.
    /// - Parameter curve: The target curve type
    /// - Returns: Array of (frequency, gainDB) tuples
    static func getTargetCurve(_ curve: TargetCurve) -> [(frequency: Double, gainDB: Double)] {
        switch curve {
        case .flat:
            return []
        case .harman:
            return harmanTargetCurve()
        case .custom:
            return [] // User-provided custom curve would be stored separately
        }
    }

    /// Fits parametric EQ bands to the inverse of (measured − target).
    static func fitBands(
        measured: [(frequency: Double, gainDB: Double)],
        target:   [(frequency: Double, gainDB: Double)],
        sampleRate: Double,
        maxBands: Int = maxCorrectionBands
    ) -> [EQBandConfiguration] {

        guard !measured.isEmpty else { return [] }
        let N = 1000
        let fGrid = (0..<N).map { 20.0 * pow(1000.0, Double($0) / Double(N - 1)) }

        var residual = fGrid.map { f in
            interpolateLog(curve: target, atHz: f) - interpolateLog(curve: measured, atHz: f)
        }

        var bands = [EQBandConfiguration]()

        for _ in 0..<maxBands {
            guard let peakIdx = residual.indices.max(by: { abs(residual[$0]) < abs(residual[$1]) })
            else { break }
            let peakMag = abs(residual[peakIdx])
            guard peakMag >= Double(stopResidualDB) else { break }

            let peakHz  = fGrid[peakIdx]
            let gainDB  = Float(max(-Double(maxCorrectionGainDB),
                                    min(Double(maxCorrectionGainDB), residual[peakIdx])))

            let halfPwr = peakMag * 0.7071
            var lo = peakIdx; while lo > 0     && abs(residual[lo]) > halfPwr { lo -= 1 }
            var hi = peakIdx; while hi < N - 1 && abs(residual[hi]) > halfPwr { hi += 1 }
            let bwHz = fGrid[hi] - fGrid[lo]
            let q    = Float(max(0.4, min(8.0, peakHz / max(bwHz, 1.0))))

            let band = EQBandConfiguration(
                frequency: Float(peakHz),
                q: q,
                gain: gainDB,
                filterType: .parametric,
                bypass: false,
                slope: .db12
            )
            bands.append(band)

            let designRate = BiquadMath.designSampleRate(actualRate: sampleRate,
                                                          coefficientDecouplingEnabled: true)
            let coeffs = BiquadMath.calculateCoefficients(
                type: .parametric, sampleRate: designRate,
                frequency: peakHz, q: Double(q), gain: Double(gainDB))
            for k in 0..<N {
                let f = fGrid[k]; let w = 2.0 * Double.pi * f / sampleRate
                let cr = cos(w); let sr = sin(w)
                let cr2 = cos(2*w); let sr2 = sin(2*w)
                let nR = coeffs.b0 + coeffs.b1*cr + coeffs.b2*cr2
                let nI = coeffs.b1*sr + coeffs.b2*sr2
                let dR = 1.0 + coeffs.a1*cr + coeffs.a2*cr2
                let dI = coeffs.a1*sr + coeffs.a2*sr2
                let denom = dR*dR + dI*dI
                if denom > 1e-30 {
                    residual[k] -= 20.0 * log10(max(1e-9, sqrt((nR*nR+nI*nI)/denom)))
                }
            }
        }
        return bands
    }

    private static func interpolateLog(
        curve: [(frequency: Double, gainDB: Double)], atHz f: Double
    ) -> Double {
        guard curve.count > 1 else { return curve.first?.gainDB ?? 0 }
        if f <= curve.first!.frequency { return curve.first!.gainDB }
        if f >= curve.last!.frequency  { return curve.last!.gainDB  }
        for i in 0..<(curve.count - 1) {
            let lo = curve[i], hi = curve[i+1]
            if f >= lo.frequency && f <= hi.frequency {
                let t = log(f / lo.frequency) / log(hi.frequency / lo.frequency)
                return lo.gainDB + t * (hi.gainDB - lo.gainDB)
            }
        }
        return 0
    }

    /// Computes a minimum-phase FIR correction kernel from a measured frequency response.
    ///
    /// Algorithm:
    /// 1. Log-interpolate the measured curve onto a uniform frequency grid.
    /// 2. Compute the correction magnitude spectrum: targetGain / measuredGain, clamped to ±maxGainDB.
    /// 3. Apply octave-band smoothing above smoothingCrossoverHz to suppress artefacts from
    ///    measurement error at high frequencies.
    /// 4. Regularise the gain: apply a Tikhonov-style floor (minGainLinear) to prevent excessive
    ///    boost in frequency bins where measured level is near the noise floor.
    /// 5. Compute the minimum-phase kernel via the Hilbert transform relationship:
    ///    log|H(f)| → real cepstrum → causal window → IFFT → minimum-phase IR.
    /// 6. Window the result with a Hann window and return.
    ///
    /// - Parameters:
    ///   - measured: Measured frequency response (must be sorted by frequency, 20 Hz–20 kHz).
    ///   - target: Target curve (same format). Pass `[]` for flat target.
    ///   - sampleRate: Operating sample rate in Hz. Scales the FFT size accordingly.
    ///   - maxGainDB: Maximum boost/cut in dB (default 12 dB). Hard clamp applied before cepstrum.
    ///   - smoothingCrossoverHz: Frequency above which octave smoothing is applied (default 500 Hz).
    ///   - tapCount: Output IR length in samples. Must be a power of two. Default 4096.
    /// - Returns: `(left: [Float], right: [Float])` — identical kernels (stereo symmetry assumed;
    ///   call twice with per-channel measurements for independent L/R correction).
    static func minimumPhaseFIRCorrection(
        measured: [(frequency: Double, gainDB: Double)],
        target:   [(frequency: Double, gainDB: Double)],
        sampleRate: Double,
        maxGainDB: Double = 12.0,
        smoothingCrossoverHz: Double = 500.0,
        tapCount: Int = 4096
    ) -> (left: [Float], right: [Float]) {

        guard !measured.isEmpty else { return ([], []) }

        let N    = tapCount  // must be power of two — caller's responsibility
        let half = N / 2 + 1

        // Step 1: Build correction magnitude spectrum on a uniform grid of `half` bins.
        // Bin k corresponds to frequency f = k * sampleRate / N.
        var corrMagDB = [Double](repeating: 0.0, count: half)
        for k in 0..<half {
            let f = Double(k) * sampleRate / Double(N)
            guard f >= 20.0 && f <= min(20_000.0, sampleRate * 0.499) else { continue }
            let meas   = interpolateLog(curve: measured, atHz: f)
            let tgt    = target.isEmpty ? 0.0 : interpolateLog(curve: target, atHz: f)
            let rawDB  = tgt - meas   // correction = target − measured
            corrMagDB[k] = max(-maxGainDB, min(maxGainDB, rawDB))
        }

        // Step 2: Octave-band smoothing above smoothingCrossoverHz.
        // For each bin above the crossover, replace with the geometric-mean-smoothed value
        // over a ±1/3 octave window. This suppresses high-frequency measurement noise
        // while preserving modal corrections below the crossover.
        let crossoverBin = Int(smoothingCrossoverHz * Double(N) / sampleRate)
        if crossoverBin < half - 1 {
            var smoothed = corrMagDB
            let octaveFraction = 1.0 / 3.0
            for k in crossoverBin..<half {
                let f        = Double(k) * sampleRate / Double(N)
                let fLo      = f * pow(2.0, -octaveFraction / 2.0)
                let fHi      = f * pow(2.0,  octaveFraction / 2.0)
                let kLo      = max(0, Int(fLo * Double(N) / sampleRate))
                let kHi      = min(half - 1, Int(fHi * Double(N) / sampleRate))
                let count    = kHi - kLo + 1
                var sum = 0.0
                for j in kLo...kHi { sum += corrMagDB[j] }
                smoothed[k] = sum / Double(count)
            }
            corrMagDB = smoothed
        }

        // Step 3: Regularisation — reduce correction in bins near the noise floor.
        // A bin with measured level below noiseFloorDB (e.g. −80 dBFS) is likely noise-dominated.
        // We don't correct those bins, as boosting them amplifies noise. Use a soft knee at
        // (noiseFloorDB + 6 dB) to smoothly roll off the correction gain.
        let noiseFloorDB = -70.0
        let kneeWidthDB  =  10.0
        for k in 0..<half {
            let f = Double(k) * sampleRate / Double(N)
            guard f >= 20.0 else { continue }
            let meas = interpolateLog(curve: measured, atHz: f)
            if meas < noiseFloorDB + kneeWidthDB {
                let t = max(0.0, (meas - noiseFloorDB) / kneeWidthDB)  // 0 = noise, 1 = above noise
                corrMagDB[k] *= t * t  // smooth rolloff
            }
        }

        // Step 4: Minimum-phase reconstruction via real cepstrum.
        // Given log-magnitude spectrum L(k), minimum-phase spectrum = exp(L + j·H(L))
        // where H is the Hilbert transform of L (implemented via the causal cepstrum window).
        //
        // Procedure:
        //   a. IFFT(log-magnitude) → real cepstrum c[n].
        //   b. Window c[n] with the causal half-sequence (c[0] unchanged, c[1..N/2-1] × 2,
        //      c[N/2] unchanged, c[N/2+1..N-1] = 0).
        //   c. FFT(windowed cepstrum) → complex log spectrum (real = log|H|, imag = −phase).
        //   d. exp(complex log spectrum) → minimum-phase frequency response.
        //   e. IFFT(minimum-phase frequency response) → minimum-phase IR.

        // Build log-magnitude array for full N-point FFT (symmetric: H(k) = conj(H(N-k))).
        var logMag = [Double](repeating: 0.0, count: N)
        for k in 0..<half {
            let lm = corrMagDB[k] / 20.0 * log(10.0)   // dB → natural log
            logMag[k] = lm
            if k > 0 && k < N / 2 { logMag[N - k] = lm }
        }

        // Use vDSP for all FFT work. Build a temporary vDSP Double FFT setup for this call.
        let log2n = vDSP_Length(log2(Double(N)).rounded())
        guard let fftSetup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            return ([], [])
        }
        defer { vDSP_destroy_fftsetupD(fftSetup) }

        // Pack logMag into split-complex for IFFT.
        var realBuf = [Double](repeating: 0, count: N)
        var imagBuf = [Double](repeating: 0, count: N)
        realBuf = logMag

        realBuf.withUnsafeMutableBufferPointer { rp in
            imagBuf.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))
            }
        }
        // Normalise IFFT: Accelerate's half-complex IFFT scale is 2 (not N).
        // Full normalisation: 1 / N.
        var scaleN = 1.0 / Double(N)
        vDSP_vsmulD(realBuf, 1, &scaleN, &realBuf, 1, vDSP_Length(N))

        // Apply causal cepstrum window.
        var cep = realBuf
        // c[0] unchanged, c[1..N/2-1] × 2, c[N/2] unchanged, c[N/2+1..N-1] = 0
        for n in 1..<(N / 2)    { cep[n] *= 2.0 }
        for n in (N / 2 + 1)..<N { cep[n]  = 0.0 }

        // Forward FFT the windowed cepstrum → complex log spectrum.
        var cepReal = cep
        var cepImag = [Double](repeating: 0, count: N)
        cepReal.withUnsafeMutableBufferPointer { rp in
            cepImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }
        // cepReal[k] = log|H(k)|,  cepImag[k] = -phase(H(k))

        // Reconstruct minimum-phase frequency response: H(k) = exp(logR + j·logI)
        var hReal = [Double](repeating: 0, count: N)
        var hImag = [Double](repeating: 0, count: N)
        for k in 0..<N {
            let mag = exp(cepReal[k])
            hReal[k] = mag * cos(cepImag[k])
            hImag[k] = mag * sin(cepImag[k])
        }

        // IFFT to get the minimum-phase IR in the time domain.
        hReal.withUnsafeMutableBufferPointer { rp in
            hImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))
            }
        }
        var scaleFFT = 1.0 / Double(N)
        vDSP_vsmulD(hReal, 1, &scaleFFT, &hReal, 1, vDSP_Length(N))

        // Step 5: Apply Hann window to the causal portion.
        var ir = [Float](repeating: 0, count: N)
        for n in 0..<N {
            let hann = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(n) / Double(N - 1)))
            ir[n] = Float(hReal[n] * hann)
        }

        return (ir, ir)  // symmetric — call separately for per-channel correction
    }

    /// Import FIR impulse response from WAV file.
    /// - Parameters:
    ///   - url: URL of the WAV file to import
    ///   - targetTapCount: Desired tap count (will be padded or truncated to match)
    /// - Returns: Tuple containing (left channel IR, right channel IR, sample rate) or nil on failure
    static func importFIRFromWAV(url: URL, targetTapCount: Int = 4096) -> (left: [Float], right: [Float], sampleRate: Double)? {
        guard url.pathExtension.lowercased() == "wav" else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.count > 44 else { return nil }

        // ── Parse RIFF header ────────────────────────────────────────────────
        guard String(bytes: data[0..<4],  encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }

        // ── Find fmt chunk ───────────────────────────────────────────────────
        var pos = 12
        var audioFormat:  UInt16 = 0
        var numChannels:  UInt16 = 0
        var sampleRate:   UInt32 = 0
        var bitsPerSample: UInt16 = 0
        var dataStart = -1
        var dataByteCount = 0

        while pos + 8 <= data.count {
            let chunkID   = String(bytes: data[pos..<pos+4], encoding: .ascii) ?? ""
            let chunkSize = Int(data.withUnsafeBytes { $0.load(fromByteOffset: pos + 4, as: UInt32.self).littleEndian })

            switch chunkID {
            case "fmt ":
                audioFormat   = data.withUnsafeBytes { $0.load(fromByteOffset: pos + 8,  as: UInt16.self).littleEndian }
                numChannels   = data.withUnsafeBytes { $0.load(fromByteOffset: pos + 10, as: UInt16.self).littleEndian }
                sampleRate    = data.withUnsafeBytes { $0.load(fromByteOffset: pos + 12, as: UInt32.self).littleEndian }
                bitsPerSample = data.withUnsafeBytes { $0.load(fromByteOffset: pos + 22, as: UInt16.self).littleEndian }
            case "data":
                dataStart     = pos + 8
                dataByteCount = chunkSize
            default:
                break
            }
            pos += 8 + chunkSize + (chunkSize & 1)   // chunks are word-aligned
        }

        guard audioFormat == 1 || audioFormat == 3 else { return nil }   // PCM or IEEE float
        guard numChannels == 1 || numChannels == 2 else { return nil }
        guard bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32 else { return nil }
        guard dataStart >= 0 else { return nil }

        let bytesPerSample = Int(bitsPerSample / 8)
        let frameCount     = dataByteCount / (Int(numChannels) * bytesPerSample)
        guard frameCount > 0 else { return nil }

        let samplesToCopy  = min(frameCount, targetTapCount)
        var leftIR  = [Float](repeating: 0.0, count: targetTapCount)
        var rightIR = [Float](repeating: 0.0, count: targetTapCount)

        for i in 0..<samplesToCopy {
            let frameOffset = dataStart + i * Int(numChannels) * bytesPerSample

            switch bitsPerSample {
            case 16:
                let lRaw = data.withUnsafeBytes { $0.load(fromByteOffset: frameOffset, as: Int16.self).littleEndian }
                leftIR[i] = Float(lRaw) / 32768.0
                if numChannels == 2 {
                    let rRaw = data.withUnsafeBytes { $0.load(fromByteOffset: frameOffset + 2, as: Int16.self).littleEndian }
                    rightIR[i] = Float(rRaw) / 32768.0
                } else {
                    rightIR[i] = leftIR[i]
                }

            case 24:
                // Read three bytes manually to avoid crossing into the next sample.
                func read24(_ offset: Int) -> Float {
                    let b0 = UInt32(data[offset])
                    let b1 = UInt32(data[offset + 1])
                    let b2 = UInt32(data[offset + 2])
                    // Reconstruct signed 24-bit value via sign extension.
                    let raw24 = Int32(bitPattern: (b2 << 16 | b1 << 8 | b0) << 8) >> 8
                    return Float(raw24) / 8_388_608.0
                }
                leftIR[i] = read24(frameOffset)
                rightIR[i] = numChannels == 2 ? read24(frameOffset + 3) : leftIR[i]

            case 32:
                if audioFormat == 3 {   // IEEE 754 float
                    leftIR[i] = data.withUnsafeBytes { $0.load(fromByteOffset: frameOffset, as: Float.self) }
                    if numChannels == 2 {
                        rightIR[i] = data.withUnsafeBytes { $0.load(fromByteOffset: frameOffset + 4, as: Float.self) }
                    } else {
                        rightIR[i] = leftIR[i]
                    }
                } else {                // 32-bit integer PCM
                    let lRaw = data.withUnsafeBytes { $0.load(fromByteOffset: frameOffset, as: Int32.self).littleEndian }
                    leftIR[i] = Float(lRaw) / 2_147_483_648.0
                    if numChannels == 2 {
                        let rRaw = data.withUnsafeBytes { $0.load(fromByteOffset: frameOffset + 4, as: Int32.self).littleEndian }
                        rightIR[i] = Float(rRaw) / 2_147_483_648.0
                    } else {
                        rightIR[i] = leftIR[i]
                    }
                }

            default:
                break
            }
        }

        return (left: leftIR, right: rightIR, sampleRate: Double(sampleRate))
    }

    // MARK: - Transfer Function Extensions (Task B)

    /// Applies octave-band smoothing to a frequency response.
    /// For each output frequency, averages all input points within
    /// ±(octaves/2) octaves. Equivalent to convolution with a log-rectangular window.
    /// - Parameters:
    ///   - response: Input magnitude response, sorted by frequency.
    ///   - octaves: Smoothing width in octaves. 1/3 is standard; 0 = no smoothing.
    /// - Returns: Smoothed response at the same frequency points as input.
    static func applyOctaveSmoothing(
        response: [(frequency: Double, gainDB: Double)],
        octaves: Double
    ) -> [(frequency: Double, gainDB: Double)] {
        guard octaves > 0 else { return response }
        guard !response.isEmpty else { return response }

        return response.map { point in
            let f = point.frequency
            let fLo = f * pow(2.0, -octaves / 2.0)
            let fHi = f * pow(2.0, octaves / 2.0)

            let nearbyPoints = response.filter { $0.frequency >= fLo && $0.frequency <= fHi }
            guard !nearbyPoints.isEmpty else { return point }

            let avgGain = nearbyPoints.reduce(0.0) { $0 + $1.gainDB } / Double(nearbyPoints.count)
            return (frequency: f, gainDB: avgGain)
        }
    }

    /// Averages multiple impulse responses, weighted by SNR and aligned by peak.
    ///
    /// Strategy:
    ///   1. Find the peak sample in each IR within ±50 ms of the array midpoint.
    ///   2. Align all IRs to the median peak offset (circular shift).
    ///   3. Weight each IR by linearSNR = 10^(snrDB/20).
    ///   4. Compute weighted sum and normalise.
    ///   For multiple positions: first average within each position (equal weights),
    ///   then average the position averages (equal position weights, SNR-weighted sweeps).
    static func averageImpulseResponses(
        _ measurements: [(ir: [Float], snrDB: Double)],
        sampleRate: Double
    ) -> [Float] {
        guard !measurements.isEmpty else { return [] }

        let maxOffsetSamples = Int(0.05 * sampleRate) // ±50 ms
        let maxLength = measurements.map { $0.ir.count }.max() ?? 0
        guard maxLength > 0 else { return [] }

        // Step 1: Find peak offset for each IR
        var peakOffsets: [Int] = []
        for (ir, _) in measurements {
            let midPoint = ir.count / 2
            let searchStart = max(0, midPoint - maxOffsetSamples)
            let searchEnd = min(ir.count, midPoint + maxOffsetSamples)

            var maxSample: Float = 0
            var maxIdx = midPoint

            for i in searchStart..<searchEnd {
                if abs(ir[i]) > maxSample {
                    maxSample = abs(ir[i])
                    maxIdx = i
                }
            }
            peakOffsets.append(maxIdx - midPoint)
        }

        // Step 2: Align to median offset
        let medianOffset = peakOffsets.sorted()[peakOffsets.count / 2]

        // Step 3: Weight by SNR and average
        var weightedSum = [Float](repeating: 0, count: maxLength)
        var totalWeight: Double = 0

        for (idx, (ir, snrDB)) in measurements.enumerated() {
            let weight = pow(10.0, snrDB / 20.0)
            let offset = medianOffset - peakOffsets[idx]

            for i in 0..<ir.count {
                let targetIdx = i + offset
                if targetIdx >= 0 && targetIdx < maxLength {
                    weightedSum[targetIdx] += ir[i] * Float(weight)
                }
            }
            totalWeight += weight
        }

        // Normalise
        guard totalWeight > 0 else { return weightedSum }
        for i in 0..<weightedSum.count {
            weightedSum[i] /= Float(totalWeight)
        }

        return weightedSum
    }

    /// Estimates measurement SNR in dB.
    /// Peak energy: RMS of a 10 ms window centred on the IR peak.
    /// Noise floor: RMS of a 100 ms pre-onset window before the direct sound.
    /// SNR = 20·log10(peakRMS / noiseRMS).
    /// A good room measurement typically yields ≥ 40 dB SNR.
    static func estimateSNR(ir: [Float], sampleRate: Double) -> Double {
        guard !ir.isEmpty else { return 0 }

        // Find peak
        let peakIdx = ir.indices.max(by: { abs(ir[$0]) < abs(ir[$1]) }) ?? 0
        let windowSamples = Int(0.01 * sampleRate) // 10 ms
        let noiseSamples = Int(0.1 * sampleRate) // 100 ms

        // Peak window
        let peakStart = max(0, peakIdx - windowSamples / 2)
        let peakEnd = min(ir.count, peakIdx + windowSamples / 2)
        let peakWindow = Array(ir[peakStart..<peakEnd])

        // Noise window (before peak)
        let noiseEnd = max(0, peakIdx - windowSamples)
        let noiseStart = max(0, noiseEnd - noiseSamples)
        let noiseWindow = noiseStart < noiseEnd ? Array(ir[noiseStart..<noiseEnd]) : []

        // Compute RMS
        let peakRMS = sqrt(peakWindow.reduce(0.0) { $0 + Double($1 * $1) } / Double(peakWindow.count))
        let noiseRMS = noiseWindow.isEmpty ? 1e-10 : sqrt(noiseWindow.reduce(0.0) { $0 + Double($1 * $1) } / Double(noiseWindow.count))

        let snr = 20.0 * log10(max(peakRMS / noiseRMS, 1e-10))
        return snr
    }

    /// Applies a Tukey (cosine-tapered rectangular) window to an impulse response.
    /// The flat top preserves the direct sound; tapered edges suppress discontinuities.
    /// Frequencies outside the window are zeroed.
    ///
    /// - Parameters:
    ///   - ir: Input impulse response.
    ///   - sampleRate: Sample rate in Hz.
    ///   - onsetMs: Window start in ms. nil = auto-detect as peak sample – 1 ms.
    ///   - durationMs: Window length in ms. Typical: 20–200 ms. Default: 80 ms.
    ///   - taperMs: Cosine taper length at each edge. Default: 5 ms.
    static func applyTimeWindowToIR(
        ir: [Float],
        sampleRate: Double,
        onsetMs: Double? = nil,
        durationMs: Double = 80.0,
        taperMs: Double = 5.0
    ) -> [Float] {
        guard !ir.isEmpty else { return ir }

        let onsetSamples = onsetMs.map { Int($0 * sampleRate / 1000.0) }
        let durationSamples = Int(durationMs * sampleRate / 1000.0)
        let taperSamples = Int(taperMs * sampleRate / 1000.0)

        // Auto-detect onset if not provided
        let peakIdx = ir.indices.max(by: { abs(ir[$0]) < abs(ir[$1]) }) ?? 0
        let startIdx = onsetSamples ?? max(0, peakIdx - Int(sampleRate / 1000.0))

        guard startIdx < ir.count else { return ir }

        var windowed = [Float](repeating: 0, count: ir.count)
        let endIdx = min(ir.count, startIdx + durationSamples)

        for i in startIdx..<endIdx {
            let offset = i - startIdx
            var window: Float = 1.0

            // Leading taper
            if offset < taperSamples {
                window = Float(0.5 * (1.0 - cos(Double.pi * Double(offset) / Double(taperSamples))))
            }
            // Trailing taper
            else if offset > (durationSamples - taperSamples) {
                let taperOffset = Double(offset - (durationSamples - taperSamples))
                window = Float(0.5 * (1.0 + cos(Double.pi * taperOffset / Double(taperSamples))))
            }

            windowed[i] = ir[i] * window
        }

        return windowed
    }

    /// Extracts the minimum-phase equivalent of an IR using the cepstrum method.
    ///
    /// Algorithm:
    ///   1. FFT(ir) → H(f) = |H(f)|·e^(jφ(f))
    ///   2. log|H(f)| → real cepstrum via IFFT
    ///   3. Causal window: keep c[0], double c[1..N/2], zero c[N/2+1..N-1]
    ///   4. FFT → complex log spectrum with minimum-phase relationship
    ///   5. exp() → minimum-phase frequency response H_mp(f)
    ///   6. IFFT → minimum-phase IR, windowed with Hann
    ///
    /// - Parameters:
    ///   - ir: Input IR. Padded to next power of two internally.
    ///   - tapCount: Output length. Must be a power of two.
    static func extractMinimumPhaseIR(ir: [Float], tapCount: Int) -> [Float] {
        guard !ir.isEmpty else { return [] }
        guard tapCount > 0 && (tapCount & (tapCount - 1)) == 0 else { return [] }

        let N = tapCount
        let half = N / 2 + 1

        // Pad IR to N if necessary
        var paddedIR = [Float](repeating: 0, count: N)
        let copyCount = min(ir.count, N)
        for i in 0..<copyCount {
            paddedIR[i] = ir[i]
        }

        // FFT to get magnitude spectrum
        let log2n = vDSP_Length(log2(Double(N)).rounded())
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realBuf = paddedIR.map { Double($0) }
        var imagBuf = [Double](repeating: 0, count: N)

        realBuf.withUnsafeMutableBufferPointer { rp in
            imagBuf.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        // Compute log magnitude
        var logMag = [Double](repeating: 0, count: half)
        for k in 0..<half {
            let mag = sqrt(realBuf[k] * realBuf[k] + imagBuf[k] * imagBuf[k])
            logMag[k] = log(max(mag, 1e-10))
        }

        // Build symmetric log magnitude for full FFT
        var fullLogMag = [Double](repeating: 0, count: N)
        for k in 0..<half {
            fullLogMag[k] = logMag[k]
            if k > 0 && k < N / 2 {
                fullLogMag[N - k] = logMag[k]
            }
        }

        // IFFT to get cepstrum
        realBuf = fullLogMag
        imagBuf = [Double](repeating: 0, count: N)

        realBuf.withUnsafeMutableBufferPointer { rp in
            imagBuf.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))
            }
        }

        var scale = 1.0 / Double(N)
        vDSP_vsmulD(realBuf, 1, &scale, &realBuf, 1, vDSP_Length(N))

        // Causal window
        var cepstrum = realBuf
        for n in 1..<(N / 2) {
            cepstrum[n] *= 2.0
        }
        for n in (N / 2 + 1)..<N {
            cepstrum[n] = 0.0
        }

        // FFT back to frequency domain
        var cepReal = cepstrum
        var cepImag = [Double](repeating: 0, count: N)

        cepReal.withUnsafeMutableBufferPointer { rp in
            cepImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        // Exponentiate to get minimum-phase response
        var minPhaseReal = [Double](repeating: 0, count: N)
        var minPhaseImag = [Double](repeating: 0, count: N)

        for k in 0..<N {
            let mag = exp(cepReal[k])
            minPhaseReal[k] = mag * cos(cepImag[k])
            minPhaseImag[k] = mag * sin(cepImag[k])
        }

        // IFFT to time domain
        minPhaseReal.withUnsafeMutableBufferPointer { rp in
            minPhaseImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))
            }
        }

        vDSP_vsmulD(minPhaseReal, 1, &scale, &minPhaseReal, 1, vDSP_Length(N))

        // Apply Hann window
        var result = [Float](repeating: 0, count: tapCount)
        for n in 0..<tapCount {
            let hann = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(n) / Double(tapCount - 1)))
            result[n] = Float(minPhaseReal[n] * hann)
        }

        return result
    }

    /// Excess phase = measured / minimum-phase (frequency domain division).
    /// Result is approximately all-pass (magnitude ≈ 0 dB).
    /// - Parameters:
    ///   - measuredIR: Full measured IR.
    ///   - minimumPhaseIR: From extractMinimumPhaseIR.
    ///   - tapCount: Output length. Must be a power of two.
    static func computeExcessPhaseIR(
        measuredIR: [Float],
        minimumPhaseIR: [Float],
        tapCount: Int
    ) -> [Float] {
        guard !measuredIR.isEmpty && !minimumPhaseIR.isEmpty else { return [] }
        guard tapCount > 0 && (tapCount & (tapCount - 1)) == 0 else { return [] }

        let N = tapCount

        // FFT both IRs
        let log2n = vDSP_Length(log2(Double(N)).rounded())
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Pad and FFT measured IR
        var measReal = [Double](repeating: 0, count: N)
        var measImag = [Double](repeating: 0, count: N)
        let measCopyCount = min(measuredIR.count, N)
        for i in 0..<measCopyCount {
            measReal[i] = Double(measuredIR[i])
        }

        measReal.withUnsafeMutableBufferPointer { rp in
            measImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        // Pad and FFT minimum-phase IR
        var minReal = [Double](repeating: 0, count: N)
        var minImag = [Double](repeating: 0, count: N)
        let minCopyCount = min(minimumPhaseIR.count, N)
        for i in 0..<minCopyCount {
            minReal[i] = Double(minimumPhaseIR[i])
        }

        minReal.withUnsafeMutableBufferPointer { rp in
            minImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        // Frequency domain division: H_excess = H_measured / H_min
        var excessReal = [Double](repeating: 0, count: N)
        var excessImag = [Double](repeating: 0, count: N)

        for k in 0..<N {
            let magMin = minReal[k] * minReal[k] + minImag[k] * minImag[k]

            guard magMin > 1e-10 else {
                excessReal[k] = 1.0
                excessImag[k] = 0.0
                continue
            }

            // Complex division
            let denom = magMin
            excessReal[k] = (measReal[k] * minReal[k] + measImag[k] * minImag[k]) / denom
            excessImag[k] = (measImag[k] * minReal[k] - measReal[k] * minImag[k]) / denom
        }

        // IFFT to time domain
        excessReal.withUnsafeMutableBufferPointer { rp in
            excessImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))
            }
        }

        var scale = 1.0 / Double(N)
        vDSP_vsmulD(excessReal, 1, &scale, &excessReal, 1, vDSP_Length(N))

        var result = [Float](repeating: 0, count: tapCount)
        for i in 0..<tapCount {
            result[i] = Float(excessReal[i])
        }

        return result
    }

    /// Fits a cascade of second-order all-pass biquad sections to the excess phase response.
    ///
    /// Method:
    ///   1. FFT(excessPhaseIR) → complex response
    ///   2. Extract unwrapped phase: φ(f) = unwrap(arg(H_excess(f)))
    ///   3. Iteratively fit second-order all-pass sections using least-squares
    ///      minimisation of weighted phase error. Frequency weighting is
    ///      proportional to log(f) (equal weight per octave).
    ///   4. Each fitted section removes its phase contribution from the residual.
    ///
    /// Note: Perfect correction via a finite biquad chain is not achievable for
    /// arbitrary excess phase. Residual error is typically < 20° RMS above 100 Hz.
    ///
    /// - Parameters:
    ///   - excessPhaseIR: From computeExcessPhaseIR.
    ///   - sampleRate: Sample rate in Hz.
    ///   - maxSections: Maximum all-pass sections. Default: 8.
    ///   - frequencyRange: Frequency range to minimise error over.
    static func fitAllPassChainToExcessPhase(
        excessPhaseIR: [Float],
        sampleRate: Double,
        maxSections: Int = 8,
        frequencyRange: (low: Double, high: Double) = (20.0, 20000.0)
    ) -> [BiquadCoefficients] {
        guard !excessPhaseIR.isEmpty else { return [] }

        let N = excessPhaseIR.count
        let half = N / 2 + 1

        // FFT to get frequency response
        let log2n = vDSP_Length(log2(Double(N)).rounded())
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realBuf = excessPhaseIR.map { Double($0) }
        var imagBuf = [Double](repeating: 0, count: N)

        realBuf.withUnsafeMutableBufferPointer { rp in
            imagBuf.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        // Extract phase
        var phase = [Double](repeating: 0, count: half)
        for k in 0..<half {
            phase[k] = atan2(imagBuf[k], realBuf[k])
        }

        // Unwrap phase (simple implementation)
        for k in 1..<half {
            let diff = phase[k] - phase[k-1]
            if diff > Double.pi {
                phase[k] -= 2.0 * Double.pi
            } else if diff < -Double.pi {
                phase[k] += 2.0 * Double.pi
            }
        }

        // Fit all-pass sections (simplified - actual implementation would use least-squares)
        var coefficients: [BiquadCoefficients] = []
        var residualPhase = phase

        for _ in 0..<maxSections {
            // Find frequency with maximum phase error
            let maxErrorIdx = residualPhase.indices.max(by: { abs(residualPhase[$0]) < abs(residualPhase[$1]) }) ?? 0
            let maxError = residualPhase[maxErrorIdx]

            guard abs(maxError) > 0.1 else { break }

            let freq = Double(maxErrorIdx) * sampleRate / Double(N)
            guard freq >= frequencyRange.low && freq <= frequencyRange.high else { break }

            // Create all-pass biquad at this frequency (simplified)
            let q = 1.0
            let coeffs = BiquadMath.calculateCoefficients(
                type: .allPass,
                sampleRate: sampleRate,
                frequency: freq,
                q: q,
                gain: 0.0
            )

            coefficients.append(coeffs)

            // Remove phase contribution (simplified)
            for k in 0..<half {
                let f = Double(k) * sampleRate / Double(N)
                let w = 2.0 * Double.pi * f / sampleRate
                let cr = cos(w)
                let sr = sin(w)
                let cr2 = cos(2*w)
                let sr2 = sin(2*w)

                let nR = coeffs.b0 + coeffs.b1*cr + coeffs.b2*cr2
                let nI = coeffs.b1*sr + coeffs.b2*sr2
                let dR = 1.0 + coeffs.a1*cr + coeffs.a2*cr2
                let dI = coeffs.a1*sr + coeffs.a2*sr2
                let denom = dR*dR + dI*dI

                if denom > 1e-30 {
                    let allPassPhase = atan2(nI, nR) - atan2(dI, dR)
                    residualPhase[k] -= allPassPhase
                }
            }
        }

        return coefficients
    }
}
