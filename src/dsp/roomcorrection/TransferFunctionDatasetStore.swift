// TransferFunctionDatasetStore.swift
//
// Persistence for transfer function measurement datasets and correction results.
// Task F of the Transfer Function Room Correction specification.

import Foundation
import CoreAudio

enum TransferFunctionDatasetStore {

    private static let measurementsDirectoryName = "measurements"
    private static let metadataFileName = "metadata.json"
    private static let correctionResultsFileName = "correction_results.json"

    /// Storage directory: ~/Library/Application Support/net.knage.equaliser/measurements/<name>/
    private static func storageURL(for name: String) throws -> URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let baseURL = appSupportURL else {
            throw DatasetError.applicationSupportDirectoryNotFound
        }

        let equaliserURL = baseURL.appendingPathComponent("net.knage.equaliser", isDirectory: true)
        let measurementsURL = equaliserURL.appendingPathComponent(measurementsDirectoryName, isDirectory: true)
        let datasetURL = measurementsURL.appendingPathComponent(name, isDirectory: true)

        // Create directories if they don't exist
        try FileManager.default.createDirectory(at: equaliserURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: measurementsURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: datasetURL, withIntermediateDirectories: true, attributes: nil)

        return datasetURL
    }

    /// Saves a dataset and its associated correction results to disk.
    ///
    /// - Parameters:
    ///   - dataset: The transfer function dataset to save.
    ///   - corrections: Correction results per channel index.
    ///   - name: Name for this dataset (used as directory name).
    static func save(
        _ dataset: TransferFunctionDataset,
        corrections: [Int: ChannelCorrectionResult],
        name: String
    ) throws {
        let datasetURL = try storageURL(for: name)

        // Save metadata (without raw samples)
        let metadata = DatasetMetadata(
            channels: dataset.channels.map { channel in
                DatasetChannelMetadata(
                    channelIndex: channel.channelIndex,
                    channelLabel: channel.channelLabel,
                    signalSource: channel.signalSource,
                    isMeasured: channel.isMeasured,
                    totalSweepCount: channel.totalSweepCount
                )
            },
            sampleRate: dataset.sampleRate,
            createdAt: dataset.createdAt,
            micPositionCount: dataset.micPositionCount,
            sweepsPerPosition: dataset.sweepsPerPosition
        )

        let metadataURL = datasetURL.appendingPathComponent(metadataFileName)
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: metadataURL)

        // Save averaged IRs as WAV files
        for channel in dataset.channels {
            guard let ir = channel.averagedIR else { continue }
            let irFileName = "channel_\(channel.channelIndex)_ir.wav"
            let irURL = datasetURL.appendingPathComponent(irFileName)
            try writeWAV(ir, to: irURL, sampleRate: Float(dataset.sampleRate))
        }

        // Save FIR kernels as WAV files
        for (channelIndex, correction) in corrections {
            let leftFileName = "channel_\(channelIndex)_fir_left.wav"
            let rightFileName = "channel_\(channelIndex)_fir_right.wav"
            let leftURL = datasetURL.appendingPathComponent(leftFileName)
            let rightURL = datasetURL.appendingPathComponent(rightFileName)

            try writeWAV(correction.firKernelLeft, to: leftURL, sampleRate: Float(dataset.sampleRate))
            try writeWAV(correction.firKernelRight, to: rightURL, sampleRate: Float(dataset.sampleRate))
        }

        // Save correction results (without FIR kernels to avoid duplication)
        let correctionsWithoutFIR = corrections.mapValues { correction in
            CodableChannelCorrectionResult(
                channelIndex: correction.channelIndex,
                channelLabel: correction.channelLabel,
                firKernelLeft: [],
                firKernelRight: [],
                excessPhaseCoefficients: correction.excessPhaseCoefficients,
                iirBands: correction.iirBands,
                correctionMode: correction.correctionMode,
                targetCurve: correction.targetCurve.map { FrequencyGainPoint(frequency: $0.frequency, gainDB: $0.gainDB) },
                residualResponseDB: correction.residualResponseDB?.map { FrequencyGainPoint(frequency: $0.frequency, gainDB: $0.gainDB) }
            )
        }

        let correctionsURL = datasetURL.appendingPathComponent(correctionResultsFileName)
        let correctionsData = try JSONEncoder().encode(correctionsWithoutFIR)
        try correctionsData.write(to: correctionsURL)
    }

    /// Loads a dataset and its associated correction results from disk.
    ///
    /// - Parameter name: Name of the dataset to load.
    /// - Returns: A tuple containing the dataset and correction results.
    static func load(name: String) throws -> (dataset: TransferFunctionDataset, corrections: [Int: ChannelCorrectionResult]) {
        let datasetURL = try storageURL(for: name)

        // Load metadata
        let metadataURL = datasetURL.appendingPathComponent(metadataFileName)
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(DatasetMetadata.self, from: metadataData)

        // Load averaged IRs
        var channels: [ChannelTransferFunctionData] = []
        for channelMetadata in metadata.channels {
            var channelData = ChannelTransferFunctionData(
                channelIndex: channelMetadata.channelIndex,
                channelLabel: channelMetadata.channelLabel,
                signalSource: channelMetadata.signalSource
            )

            // Load IR if it exists
            let irFileName = "channel_\(channelMetadata.channelIndex)_ir.wav"
            let irURL = datasetURL.appendingPathComponent(irFileName)
            if FileManager.default.fileExists(atPath: irURL.path) {
                channelData.averagedIR = try readWAV(from: irURL)
            }

            channels.append(channelData)
        }

        let dataset = TransferFunctionDataset(
            channels: channels,
            sampleRate: metadata.sampleRate,
            createdAt: metadata.createdAt,
            micPositionCount: metadata.micPositionCount,
            sweepsPerPosition: metadata.sweepsPerPosition
        )

        // Load correction results
        let correctionsURL = datasetURL.appendingPathComponent(correctionResultsFileName)
        var corrections: [Int: ChannelCorrectionResult] = [:]

        if FileManager.default.fileExists(atPath: correctionsURL.path) {
            let correctionsData = try Data(contentsOf: correctionsURL)
            let correctionsWithoutFIR = try JSONDecoder().decode([Int: CodableChannelCorrectionResult].self, from: correctionsData)

            // Reload FIR kernels from WAV files
            for (channelIndex, codableCorrection) in correctionsWithoutFIR {
                let leftFileName = "channel_\(channelIndex)_fir_left.wav"
                let rightFileName = "channel_\(channelIndex)_fir_right.wav"
                let leftURL = datasetURL.appendingPathComponent(leftFileName)
                let rightURL = datasetURL.appendingPathComponent(rightFileName)

                let leftKernel = try readWAV(from: leftURL)
                let rightKernel = try readWAV(from: rightURL)

                corrections[channelIndex] = ChannelCorrectionResult(
                    channelIndex: codableCorrection.channelIndex,
                    channelLabel: codableCorrection.channelLabel,
                    firKernelLeft: leftKernel,
                    firKernelRight: rightKernel,
                    excessPhaseCoefficients: codableCorrection.excessPhaseCoefficients,
                    iirBands: codableCorrection.iirBands,
                    correctionMode: codableCorrection.correctionMode,
                    targetCurve: codableCorrection.targetCurve.map { (frequency: $0.frequency, gainDB: $0.gainDB) },
                    residualResponseDB: codableCorrection.residualResponseDB?.map { (frequency: $0.frequency, gainDB: $0.gainDB) }
                )
            }
        }

        return (dataset: dataset, corrections: corrections)
    }

    /// Lists all saved datasets.
    ///
    /// - Returns: An array of tuples containing name, creation date, and channel count.
    static func listSaved() throws -> [(name: String, date: Date, channelCount: Int)] {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let baseURL = appSupportURL else {
            throw DatasetError.applicationSupportDirectoryNotFound
        }

        let equaliserURL = baseURL.appendingPathComponent("net.knage.equaliser", isDirectory: true)
        let measurementsURL = equaliserURL.appendingPathComponent(measurementsDirectoryName, isDirectory: true)

        guard FileManager.default.fileExists(atPath: measurementsURL.path) else {
            return []
        }

        let datasetNames = try FileManager.default.contentsOfDirectory(atPath: measurementsURL.path)
        var result: [(name: String, date: Date, channelCount: Int)] = []

        for name in datasetNames {
            let datasetURL = measurementsURL.appendingPathComponent(name, isDirectory: true)
            let metadataURL = datasetURL.appendingPathComponent(metadataFileName)

            if FileManager.default.fileExists(atPath: metadataURL.path) {
                let metadataData = try Data(contentsOf: metadataURL)
                let metadata = try JSONDecoder().decode(DatasetMetadata.self, from: metadataData)
                result.append((name: name, date: metadata.createdAt, channelCount: metadata.channels.count))
            }
        }

        return result.sorted { $0.date > $1.date }
    }

    /// Deletes a dataset from disk.
    ///
    /// - Parameter name: Name of the dataset to delete.
    static func delete(name: String) throws {
        let datasetURL = try storageURL(for: name)
        try FileManager.default.removeItem(at: datasetURL)
    }

    // MARK: - WAV I/O Helpers

    private static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Float) throws {
        let bitsPerSample: UInt32 = 32
        let audioFormat = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: bitsPerSample,
            mReserved: 0
        )

        let fileHeader = WAVHeader(
            chunkID: 0x46464952, // "RIFF"
            chunkSize: 36 + Int32(samples.count * 4),
            format: 0x45564157, // "WAVE"
            subchunk1ID: 0x20746d66, // "fmt "
            subchunk1Size: 16,
            audioFormat: 3, // IEEE float
            numChannels: 1,
            sampleRate: Int32(sampleRate),
            byteRate: Int32(sampleRate) * 4,
            blockAlign: 4,
            bitsPerSample: Int16(bitsPerSample),
            subchunk2ID: 0x61746164, // "data"
            subchunk2Size: Int32(samples.count * 4)
        )

        var data = Data()
        withUnsafePointer(to: fileHeader) { data.append(UnsafeBufferPointer(start: $0, count: 1)) }
        data.append(samples.withUnsafeBufferPointer { Data(buffer: $0) })

        try data.write(to: url)
    }

    private static func readWAV(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= MemoryLayout<WAVHeader>.size else {
            throw DatasetError.invalidWAVFile
        }

        let header = data.withUnsafeBytes { $0.load(as: WAVHeader.self) }

        guard header.chunkID == 0x46464952, // "RIFF"
              header.format == 0x45564157, // "WAVE"
              header.subchunk1ID == 0x20746d66, // "fmt "
              header.subchunk2ID == 0x61746164 // "data"
        else {
            throw DatasetError.invalidWAVFile
        }

        let samplesOffset = MemoryLayout<WAVHeader>.size
        let samplesCount = Int(header.subchunk2Size) / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: samplesCount)

        _ = samples.withUnsafeMutableBytes { destBuffer in
            data.copyBytes(to: destBuffer, from: samplesOffset..<min(samplesOffset + samplesCount * MemoryLayout<Float>.size, data.count))
        }

        return samples
    }
}

// MARK: - Supporting Types

private struct WAVHeader {
    var chunkID: Int32
    var chunkSize: Int32
    var format: Int32
    var subchunk1ID: Int32
    var subchunk1Size: Int32
    var audioFormat: Int16
    var numChannels: Int16
    var sampleRate: Int32
    var byteRate: Int32
    var blockAlign: Int16
    var bitsPerSample: Int16
    var subchunk2ID: Int32
    var subchunk2Size: Int32
}

private struct DatasetMetadata: Codable {
    var channels: [DatasetChannelMetadata]
    var sampleRate: Double
    var createdAt: Date
    var micPositionCount: Int
    var sweepsPerPosition: Int
}

private struct DatasetChannelMetadata: Codable {
    var channelIndex: Int
    var channelLabel: String
    var signalSource: SignalSource
    var isMeasured: Bool
    var totalSweepCount: Int
}

// MARK: - Codable Wrapper Types

/// Helper struct for Codable frequency/gain tuples
struct FrequencyGainPoint: Codable, Sendable {
    var frequency: Double
    var gainDB: Double
}

/// Codable wrapper for ChannelCorrectionResult
struct CodableChannelCorrectionResult: Codable, Sendable {
    var channelIndex: Int
    var channelLabel: String
    var firKernelLeft: [Float]
    var firKernelRight: [Float]
    var excessPhaseCoefficients: [BiquadCoefficients]
    var iirBands: [EQBandConfiguration]
    var correctionMode: CorrectionMode
    var targetCurve: [FrequencyGainPoint]
    var residualResponseDB: [FrequencyGainPoint]?
}

enum DatasetError: Error, LocalizedError {
    case applicationSupportDirectoryNotFound
    case invalidWAVFile

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryNotFound:
            return "Application Support directory not found"
        case .invalidWAVFile:
            return "Invalid WAV file format"
        }
    }
}
