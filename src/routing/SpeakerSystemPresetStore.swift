// SpeakerSystemPresetStore.swift
// Save and load speaker system presets to/from JSON files.

import Foundation
import OSLog

enum SpeakerSystemPresetStore {

    private static let logger = Logger(subsystem: "net.knage.equaliser", category: "SpeakerSystemPresetStore")

    /// Directory where speaker system presets are stored.
    /// ~/Library/Application Support/net.knage.equaliser/speaker-presets/
    private static var presetsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let equaliserDir = appSupport.appendingPathComponent("net.knage.equaliser")
        let presetsDir = equaliserDir.appendingPathComponent("speaker-presets")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)

        return presetsDir
    }

    /// Saves a speaker system preset to a JSON file.
    /// - Parameter preset: The preset to save.
    /// - Throws: File I/O errors.
    static func save(_ preset: SpeakerSystemPreset) throws {
        let filename = "\(preset.name).json"
        let fileURL = presetsDirectory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(preset)
        try data.write(to: fileURL, options: .atomic)

        logger.info("Saved speaker system preset: \(preset.name)")
    }

    /// Loads a speaker system preset by name.
    /// - Parameter name: The preset name (without .json extension).
    /// - Returns: The loaded preset, or nil if not found.
    /// - Throws: File I/O or decoding errors.
    static func load(named name: String) throws -> SpeakerSystemPreset {
        let filename = "\(name).json"
        let fileURL = presetsDirectory.appendingPathComponent(filename)

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let preset = try decoder.decode(SpeakerSystemPreset.self, from: data)

        logger.info("Loaded speaker system preset: \(name)")
        return preset
    }

    /// Lists all saved speaker system presets.
    /// - Returns: Array of preset metadata (name, topology hint, date, channel count).
    static func listAll() throws -> [PresetMetadata] {
        let files = try FileManager.default.contentsOfDirectory(at: presetsDirectory, includingPropertiesForKeys: nil)

        var presets: [PresetMetadata] = []

        for file in files {
            guard file.pathExtension == "json" else { continue }

            let name = file.deletingPathExtension().lastPathComponent

            do {
                let preset = try load(named: name)
                let metadata = PresetMetadata(
                    name: preset.name,
                    topologyHint: preset.topologyHint,
                    createdAt: preset.createdAt,
                    modifiedAt: preset.modifiedAt,
                    channelCount: preset.outputChannels.count
                )
                presets.append(metadata)
            } catch {
                logger.warning("Failed to load preset for listing: \(name), error: \(error.localizedDescription)")
            }
        }

        return presets.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Deletes a speaker system preset by name.
    /// - Parameter name: The preset name (without .json extension).
    /// - Throws: File I/O errors.
    static func delete(named name: String) throws {
        let filename = "\(name).json"
        let fileURL = presetsDirectory.appendingPathComponent(filename)

        try FileManager.default.removeItem(at: fileURL)

        logger.info("Deleted speaker system preset: \(name)")
    }

    /// Metadata for a speaker system preset (lightweight for listing).
    struct PresetMetadata: Sendable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var topologyHint: String
        var createdAt: Date
        var modifiedAt: Date
        var channelCount: Int
    }
}
