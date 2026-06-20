// TransferFunctionCorrectionEngine.swift
//
// Transfer function correction computation engine.
// Task C of the Transfer Function Room Correction specification.

import Accelerate
import Foundation

enum TransferFunctionCorrectionEngine {

    struct CorrectionParameters: Sendable {
        var mode: CorrectionMode = .firMinimumPhase
        var targetCurve: [(frequency: Double, gainDB: Double)] = TargetCurveLibrary.harmanRoom
        var maxGainDB: Double = 12.0
        var smoothingOctaves: Double = 1.0 / 3.0
        var windowDurationMs: Double? = 80.0
        var windowOnsetMs: Double? = nil
        var firTapCount: Int = 4096     // Must be power of two
        var correctionRangeHz: (low: Double, high: Double) = (20.0, 20000.0)
        var maxIIRBands: Int = 20
        var maxPhaseCorrectSections: Int = 8
        var phaseCorrectEnabled: Bool = true
    }

    /// Computes a ChannelCorrectionResult from measured data.
    /// Throws CorrectionError.noMeasurementData if averagedIR is nil.
    static func computeCorrection(
        data: ChannelTransferFunctionData,
        params: CorrectionParameters,
        sampleRate: Double
    ) throws -> ChannelCorrectionResult {
        // 1. Guard averagedIR != nil
        guard let averagedIR = data.averagedIR else {
            throw CorrectionError.noMeasurementData
        }

        // 2. Apply time window if params.windowDurationMs != nil
        var windowedIR = averagedIR
        if let windowDuration = params.windowDurationMs {
            windowedIR = RoomCorrectionEngine.applyTimeWindowToIR(
                ir: averagedIR,
                sampleRate: sampleRate,
                onsetMs: params.windowOnsetMs,
                durationMs: windowDuration
            )
        }

        // 3. Compute complex response from windowed IR
        // Note: This would use SweepAnalyser.computeComplexFrequencyResponse
        // For now, we'll use a simplified approach
        let complexResponse = computeComplexResponseFromIR(windowedIR, sampleRate: sampleRate)

        // 4. Derive magnitude response in dB
        let magnitudeDB = complexResponse.map { (frequency: $0.frequency, gainDB: 20.0 * log10(max(sqrt($0.real * $0.real + $0.imag * $0.imag), 1e-10))) }

        // 5. Apply octave smoothing
        let smoothedMagnitude = RoomCorrectionEngine.applyOctaveSmoothing(response: magnitudeDB, octaves: params.smoothingOctaves)

        // 6. Apply frequency range taper
        let taperedMagnitude = applyFrequencyRangeTaper(
            response: smoothedMagnitude,
            range: params.correctionRangeHz,
            sampleRate: sampleRate
        )

        // 7. Fit IIR bands
        let iirBands = RoomCorrectionEngine.fitBands(
            measured: taperedMagnitude,
            target: params.targetCurve,
            sampleRate: sampleRate,
            maxBands: params.maxIIRBands
        )

        // 8. Compute FIR kernel for FIR modes
        var firKernelLeft: [Float] = []
        var firKernelRight: [Float] = []
        var excessPhaseCoefficients: [BiquadCoefficients] = []

        if params.mode == .firMinimumPhase || params.mode == .firWithPhaseCorrection {
            let (left, right) = RoomCorrectionEngine.minimumPhaseFIRCorrection(
                measured: taperedMagnitude,
                target: params.targetCurve,
                sampleRate: sampleRate,
                maxGainDB: params.maxGainDB,
                smoothingCrossoverHz: 500.0,
                tapCount: params.firTapCount
            )
            firKernelLeft = left
            firKernelRight = right
        }

        // 9. For FIR with phase correction: extract minimum-phase IR, compute excess phase IR, fit all-pass chain
        if params.mode == .firWithPhaseCorrection && params.phaseCorrectEnabled {
            let minimumPhaseIR = RoomCorrectionEngine.extractMinimumPhaseIR(ir: windowedIR, tapCount: params.firTapCount)
            let excessPhaseIR = RoomCorrectionEngine.computeExcessPhaseIR(
                measuredIR: windowedIR,
                minimumPhaseIR: minimumPhaseIR,
                tapCount: params.firTapCount
            )
            excessPhaseCoefficients = RoomCorrectionEngine.fitAllPassChainToExcessPhase(
                excessPhaseIR: excessPhaseIR,
                sampleRate: sampleRate,
                maxSections: params.maxPhaseCorrectSections,
                frequencyRange: params.correctionRangeHz
            )
        }

        // 10. Return ChannelCorrectionResult
        return ChannelCorrectionResult(
            channelIndex: data.channelIndex,
            channelLabel: data.channelLabel,
            firKernelLeft: firKernelLeft,
            firKernelRight: firKernelRight,
            excessPhaseCoefficients: excessPhaseCoefficients,
            iirBands: iirBands,
            correctionMode: params.mode,
            targetCurve: params.targetCurve,
            residualResponseDB: nil
        )
    }

    // MARK: - Helper Functions

    private static func computeComplexResponseFromIR(_ ir: [Float], sampleRate: Double) -> [(frequency: Double, real: Double, imag: Double)] {
        // Simplified FFT-based complex response computation
        // In production, this would use SweepAnalyser.computeComplexFrequencyResponse
        let N = ir.count
        let half = N / 2 + 1

        let log2n = vDSP_Length(log2(Double(N)).rounded())
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realBuf = ir.map { Double($0) }
        var imagBuf = [Double](repeating: 0, count: N)

        realBuf.withUnsafeMutableBufferPointer { rp in
            imagBuf.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        var result: [(frequency: Double, real: Double, imag: Double)] = []
        for k in 0..<half {
            let frequency = Double(k) * sampleRate / Double(N)
            result.append((frequency: frequency, real: realBuf[k], imag: imagBuf[k]))
        }

        return result
    }

    private static func applyFrequencyRangeTaper(
        response: [(frequency: Double, gainDB: Double)],
        range: (low: Double, high: Double),
        sampleRate: Double
    ) -> [(frequency: Double, gainDB: Double)] {
        let lowOctave = log2(range.low / 20.0)
        let highOctave = log2(range.high / 20.0)

        return response.map { point in
            let octave = log2(point.frequency / 20.0)

            // Below low cutoff: taper to 0 over one octave
            if octave < lowOctave {
                let t = max(0.0, (octave - (lowOctave - 1.0)))
                return (frequency: point.frequency, gainDB: point.gainDB * t)
            }
            // Above high cutoff: taper to 0 over one octave
            else if octave > highOctave {
                let t = max(0.0, 1.0 - (octave - highOctave))
                return (frequency: point.frequency, gainDB: point.gainDB * t)
            }
            // Within range: unchanged
            else {
                return point
            }
        }
    }
}

enum CorrectionError: LocalizedError {
    case noMeasurementData
    case insufficientSNR(snrDB: Double, minimumRequired: Double)
    case computationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMeasurementData:
            return "No measurement data available"
        case .insufficientSNR(let snrDB, let minimumRequired):
            return "Insufficient SNR: \(snrDB) dB (minimum required: \(minimumRequired) dB)"
        case .computationFailed(let message):
            return "Computation failed: \(message)"
        }
    }
}
