// TransferFunctionMeasurement.swift
//
// Multi-channel transfer function measurement data structures.
// Task A of the Transfer Function Room Correction specification.

import Foundation

/// One complete measurement from a single sweep at a single mic position.
struct SingleSweepMeasurement: Sendable {
    var impulseResponse: [Float]
    var complexResponse: [(frequency: Double, real: Double, imag: Double)]
    var magnitudeResponseDB: [(frequency: Double, gainDB: Double)]
    /// SNR estimate in dB. Computed as peak IR energy vs pre-sweep noise floor.
    var estimatedSNRDB: Double
    var sampleRate: Double
    var capturedAt: Date
}

/// All measurements for one output channel across all positions and sweeps.
struct ChannelTransferFunctionData: Identifiable, Sendable {
    var id: UUID = UUID()
    /// Index in OutputChannelMatrixConfig.channels. –1 = main stereo output.
    var channelIndex: Int
    var channelLabel: String
    var signalSource: SignalSource
    /// [position][sweep] — sweepsByPosition[p][s] = sweep s at position p.
    var sweepsByPosition: [[SingleSweepMeasurement]] = []
    var averagedIR: [Float]? = nil
    var averagedComplexResponse: [(frequency: Double, real: Double, imag: Double)]? = nil
    var averagedMagnitudeDB: [(frequency: Double, gainDB: Double)]? = nil
    var isMeasured: Bool { averagedIR != nil }
    var totalSweepCount: Int { sweepsByPosition.flatMap { $0 }.count }
}

/// Complete dataset for all channels.
struct TransferFunctionDataset: Sendable {
    var channels: [ChannelTransferFunctionData] = []
    var sampleRate: Double = 48000
    var micCalibration: MicCalibration? = nil
    var createdAt: Date = Date()
    var micPositionCount: Int = 1
    var sweepsPerPosition: Int = 1
}

/// Correction result for one channel.
struct ChannelCorrectionResult: Sendable {
    var channelIndex: Int
    var channelLabel: String
    var firKernelLeft: [Float]
    var firKernelRight: [Float]
    var excessPhaseCoefficients: [BiquadCoefficients]
    var iirBands: [EQBandConfiguration]
    var correctionMode: CorrectionMode
    var targetCurve: [(frequency: Double, gainDB: Double)]
    /// Residual response measured with correction active. nil until verification.
    var residualResponseDB: [(frequency: Double, gainDB: Double)]?
}

/// How the correction is applied to the signal chain.
enum CorrectionMode: Int, Codable, Equatable, Sendable, CaseIterable {
    /// IIR parametric bands only. Zero additional latency.
    case iirParametric = 0
    /// Minimum-phase FIR via ConvolutionEngine. Corrects magnitude only.
    /// Latency: ~10.7 ms (512 samples at 48 kHz).
    case firMinimumPhase = 1
    /// FIR magnitude + all-pass excess phase correction.
    /// Same FIR latency; all-pass adds no additional latency.
    case firWithPhaseCorrection = 2

    var displayName: String {
        switch self {
        case .iirParametric:          return "Parametric EQ (IIR)"
        case .firMinimumPhase:        return "FIR — Magnitude only"
        case .firWithPhaseCorrection: return "FIR + Phase correction"
        }
    }

    var description: String {
        switch self {
        case .iirParametric:
            return "Up to 20 parametric bands. Zero additional latency. Best for subtle corrections."
        case .firMinimumPhase:
            return "FIR kernel corrects magnitude response. Adds ~11 ms latency. More precise than IIR for complex responses."
        case .firWithPhaseCorrection:
            return "FIR magnitude correction plus all-pass phase correction of the minimum-phase component. Most complete. Same latency as FIR."
        }
    }
}
