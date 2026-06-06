// RTAAnalyzer.swift
// Dual 31-band real-time spectrum analyser — pre-EQ (input) and post-dynamics (output).

import Accelerate
import Combine
import Foundation

// MARK: - Data Types

/// Represents the current display state for one RTA frequency band.
struct BandData {
    var currentValue: Float = -60.0
    var peakValue:    Float = -60.0
    var peakHoldFrames: Int = 0
}

/// Biquad coefficient set for theoretical frequency-response overlay.
/// Uses standard IIR form (NOT the pre-negated na1/na2 convention of BiquadCoefficients).
struct BiquadCoefficientsRTA {
    let b0: Double, b1: Double, b2: Double
    let a1: Double, a2: Double
}

// MARK: - Lock-Free Ring Buffer

/// Single-producer / single-consumer ring buffer for RTA audio samples.
/// Written from the real-time audio thread; read from the analysis timer on the main thread.
/// Thread safety relies on the SPSC guarantee: only one writer, only one reader.
final class LockFreeAudioRingBuffer: @unchecked Sendable {
    private let bufferSize: Int
    private let buffer:     UnsafeMutablePointer<Float>
    // writeIndex is updated exclusively by the audio thread.
    // readIndex is updated exclusively by the consumer thread.
    // Both are stored as Int (word-size atomic on all Apple platforms).
    nonisolated(unsafe) private var writeIndex: Int = 0
    nonisolated(unsafe) private var readIndex:  Int = 0

    init(bufferSize: Int = 8192) {
        self.bufferSize = bufferSize
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Audio Thread API

    /// Writes interleaved stereo samples as mono (L+R)/2 to the ring buffer.
    /// Must only be called from the audio render thread.
    @inline(__always)
    func writeStereoSamples(
        leftChannel:  UnsafePointer<Float>,
        rightChannel: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let wi = writeIndex
        for i in 0..<frameCount {
            buffer[(wi + i) & (bufferSize - 1)] = (leftChannel[i] + rightChannel[i]) * 0.5
        }
        // Store-release ensures the audio thread's writes are visible before we advance the index.
        writeIndex = (wi + frameCount) & (bufferSize - 1)
    }

    // MARK: - Consumer Thread API

    /// Returns the most recent `size` mono samples from the write head.
    /// Must only be called from the consumer thread (main actor or analysis queue).
    func readLatestChunk(size: Int = 2048) -> [Float] {
        let n = min(size, bufferSize)
        var chunk = [Float](repeating: 0, count: n)
        let wi = writeIndex  // load-acquire
        var start = wi - n
        if start < 0 { start += bufferSize }
        for i in 0..<n {
            chunk[i] = buffer[(start + i) & (bufferSize - 1)]
        }
        return chunk
    }

    /// Reads the most recent `dest.count` samples into a pre-allocated buffer.
    /// Avoids heap allocation on the hot path.
    func readLatestChunkInto(_ dest: inout [Float]) {
        let n = min(dest.count, bufferSize)
        let wi = writeIndex
        var start = wi - n
        if start < 0 { start += bufferSize }
        for i in 0..<n {
            dest[i] = buffer[(start + i) & (bufferSize - 1)]
        }
    }
}

// MARK: - Analyser

/// Dual 31-band real-time spectrum analyser (ISO 1/3-octave centre frequencies).
/// The two ring buffers must be filled from the audio render thread via
/// `RenderCallbackContext.writeRTAInput/Output(…)`.
/// An internal 20 Hz timer drives FFT analysis and publishes results on the main actor.
@MainActor
final class AdvancedDualSpectrumAnalyzer: ObservableObject, @unchecked Sendable {

    // MARK: Tunable limits
    let minDb: Float = -80.0
    let maxDb: Float =   0.0   // 0 dBFS = full bar height

    // MARK: Ring buffers — written by the audio thread
    let inputRingBuffer  = LockFreeAudioRingBuffer(bufferSize: 8192)
    let outputRingBuffer = LockFreeAudioRingBuffer(bufferSize: 8192)

    // MARK: FFT state
    private let fftSize:  Int
    nonisolated(unsafe) private var fftSetup: FFTSetup
    private var log2n:    vDSP_Length
    private var window:   [Float]

    // MARK: Ballistics
    private let risingAlpha:  Float = 1.00  // instant attack
    private let fallingAlpha: Float = 0.60  // ~80 ms decay at 20 Hz
    private let peakHoldMax:  Int   = 30    // 1.5 seconds at 20 Hz
    private let peakDecay:    Float = 0.88  // slower fall — each dB step reads as a discrete segment drop

    // MARK: Published outputs
    let centerFrequencies: [Float] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250,
        1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
        10000, 12500, 16000, 20000
    ]

    @Published var inputBands:       [BandData] = Array(repeating: BandData(), count: 31)
    @Published var outputBands:      [BandData] = Array(repeating: BandData(), count: 31)
    @Published var targetLinePoints: [Float]    = []
    @Published var showInputPeaks:   Bool = true
    @Published var showOutputPeaks:  Bool = true
    @Published var showDiagnostics:  Bool = false
    @Published var currentFps:       Int  = 0

    // Assumed sample rate when no pipeline info is available.
    var assumedSampleRate: Float = 48000

    // MARK: FPS tracking
    private var frameCount: Int  = 0
    private var lastFpsTick: Date = Date()

    // MARK: Pre-allocated tick buffers (avoids per-frame heap allocation)
    private var tickInputSamples:  [Float]
    private var tickOutputSamples: [Float]

    // MARK: Timer
    private var updateTimer: AnyCancellable?

    // MARK: - Init / deinit

    init(fftSize: Int = 2048) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
                     "fftSize must be a power of two")
        self.fftSize = fftSize
        self.log2n   = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))),
                                              FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        self.tickInputSamples  = [Float](repeating: 0, count: fftSize)
        self.tickOutputSamples = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&self.window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        startTimer()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Timer

    private func startTimer() {
        updateTimer = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        inputRingBuffer.readLatestChunkInto(&tickInputSamples)
        outputRingBuffer.readLatestChunkInto(&tickOutputSamples)
        updateSmearedSpectrums(
            inputSamples:  tickInputSamples,  inputGainDb:  0,
            outputSamples: tickOutputSamples, outputGainDb: 0,
            sampleRate: assumedSampleRate
        )
        // FPS counter
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFpsTick)
        if elapsed >= 1.0 {
            currentFps  = Int(Double(frameCount) / elapsed)
            frameCount  = 0
            lastFpsTick = now
        }
    }

    // MARK: - Public API

    /// Maps a raw dB value to a 0–1 normalised position for display.
    func normaliseDb(_ db: Float) -> Float {
        (max(minDb, min(maxDb, db)) - minDb) / (maxDb - minDb)
    }

    /// Static version — safe to call from Canvas closures without capturing `self`.
    static func normaliseDbStatic(_ db: Float, min minDb: Float, max maxDb: Float) -> Float {
        (Swift.max(minDb, Swift.min(maxDb, db)) - minDb) / (maxDb - minDb)
    }

    /// Computes theoretical frequency-response overlay from a set of biquad filters.
    func updateTargetLine(
        activeFilters: [BiquadCoefficientsRTA],
        outputGainDb:  Float,
        sampleRate:    Double
    ) {
        let points: [Float] = centerFrequencies.map { fc in
            var gainDb = Double(outputGainDb)
            let w  = 2.0 * Double.pi * Double(fc) / sampleRate
            let cw = cos(w), s2w = sin(2.0 * w), c2w = cos(2.0 * w), sw = sin(w)
            for f in activeFilters {
                let nr  =  f.b0 + f.b1 * cw + f.b2 * c2w
                let ni  = -(f.b1 * sw + f.b2 * s2w)
                let dr  =  1.0  + f.a1 * cw + f.a2 * c2w
                let di  = -(f.a1 * sw + f.a2 * s2w)
                let numMag2 = nr * nr + ni * ni
                let denMag2 = dr * dr + di * di
                if denMag2 > 0 { gainDb += 10.0 * log10(numMag2 / denMag2) }
            }
            return normaliseDb(Float(gainDb))
        }
        targetLinePoints = points
    }

    /// Updates both band arrays from raw sample arrays.
    /// Called internally from the timer; may also be driven externally for testing.
    func updateSmearedSpectrums(
        inputSamples:  [Float], inputGainDb:  Float,
        outputSamples: [Float], outputGainDb: Float,
        sampleRate: Float
    ) {
        var rawIn  = executeFFT(samples: inputSamples)
        var rawOut = executeFFT(samples: outputSamples)

        if inputGainDb != 0 {
            var g = inputGainDb
            var result = rawIn
            vDSP_vsadd(&rawIn, 1, &g, &result, 1, vDSP_Length(rawIn.count))
            rawIn = result
        }
        if outputGainDb != 0 {
            var g = outputGainDb
            var result = rawOut
            vDSP_vsadd(&rawOut, 1, &g, &result, 1, vDSP_Length(rawOut.count))
            rawOut = result
        }

        let tgtIn  = mapBinsToBands(dbMagnitudes: rawIn,  sampleRate: sampleRate)
        let tgtOut = mapBinsToBands(dbMagnitudes: rawOut, sampleRate: sampleRate)

        applyBallistics(bands: &inputBands,  targets: tgtIn)
        applyBallistics(bands: &outputBands, targets: tgtOut)
    }

    // MARK: - Private DSP

    private func executeFFT(samples: [Float]) -> [Float] {
        let half = fftSize / 2
        guard samples.count >= fftSize else { return [Float](repeating: minDb, count: half) }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var resultDb = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var amps = [Float](repeating: 0, count: half)
        
        // Perform FFT using interleaved buffer approach to avoid compiler issues
        windowed.withUnsafeBytes { windowBytes in
            real.withUnsafeMutableBytes { realBytes in
                imag.withUnsafeMutableBytes { imagBytes in
                    let complexPtr = windowBytes.bindMemory(to: DSPComplex.self)
                    let realPtr = realBytes.bindMemory(to: Float.self).baseAddress!
                    let imagPtr = imagBytes.bindMemory(to: Float.self).baseAddress!
                    var split = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
            }
        }
        
        // Perform FFT
        real.withUnsafeMutableBytes { realBytes in
            imag.withUnsafeMutableBytes { imagBytes in
                let realPtr = realBytes.bindMemory(to: Float.self).baseAddress!
                let imagPtr = imagBytes.bindMemory(to: Float.self).baseAddress!
                var split = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        
        // Post-processing: magnitude to dB
        var n = Int32(half)
        vvsqrtf(&amps, &mags, &n)
        
        var norm: Float = 4.0 / Float(fftSize)
        vDSP_vsmul(amps, 1, &norm, &amps, 1, vDSP_Length(half))
        
        var ref: Float = 1.0
        vDSP_vdbcon(amps, 1, &ref, &resultDb, 1, vDSP_Length(half), 2)
        
        var clipped = resultDb
        var floorVal = self.minDb
        var ceilVal  = self.maxDb
        vDSP_vclip(&clipped, 1, &floorVal, &ceilVal, &resultDb, 1, vDSP_Length(half))
        
        return resultDb
    }

    private func mapBinsToBands(dbMagnitudes: [Float], sampleRate: Float) -> [Float] {
        var out = [Float](repeating: minDb, count: 31)
        let binWidth = sampleRate / Float(fftSize)
        let half     = fftSize / 2

        for k in 0..<31 {
            let fc = centerFrequencies[k]
            let lo = fc * pow(2.0, -1.0 / 6.0)
            let hi = fc * pow(2.0,  1.0 / 6.0)

            // Use MAX within the 1/3-octave band.
            // This gives correct amplitude for pure tones (one dominant bin)
            // and a representative level for broadband signals.
            for i in 0..<half {
                let freq = Float(i) * binWidth
                if freq >= lo && freq <= hi && dbMagnitudes[i] > out[k] {
                    out[k] = dbMagnitudes[i]
                }
            }
            // Fallback: if no bin falls in range, use nearest bin
            if out[k] == minDb {
                let idx = max(0, min(Int(round(fc / binWidth)), half - 1))
                out[k] = dbMagnitudes[idx]
            }
        }
        return out
    }

    private func applyBallistics(bands: inout [BandData], targets: [Float]) {
        for i in 0..<min(bands.count, targets.count) {
            let target = targets[i]
            // Attack/decay
            if target > bands[i].currentValue {
                bands[i].currentValue = target
            } else {
                bands[i].currentValue = max(target,
                    bands[i].currentValue * fallingAlpha + target * (1 - fallingAlpha))
            }
            // Peak hold
            if target >= bands[i].peakValue {
                bands[i].peakValue      = target
                bands[i].peakHoldFrames = peakHoldMax
            } else if bands[i].peakHoldFrames > 0 {
                bands[i].peakHoldFrames -= 1
            } else {
                bands[i].peakValue = max(minDb, bands[i].peakValue * peakDecay + minDb * (1 - peakDecay))
            }
        }
    }
}
