// CamillaDSPExporter.swift
// CamillaDSP filter-set export (Part 9.4)
//
// Exports the current configuration as a CamillaDSP-compatible YAML filter pipeline.

import Foundation

enum CamillaDSPExporter {

    /// Exports the current configuration as CamillaDSP YAML.
    /// - Parameters:
    ///   - eqBands: User EQ bands
    ///   - roomCorrectionBands: Room correction bands
    ///   - subEQBands: Subwoofer EQ bands
    ///   - sampleRate: Sample rate in Hz
    /// - Returns: YAML string
    static func exportToYAML(
        eqBands: [PresetBand],
        roomCorrectionBands: [PresetBand],
        subEQBands: [PresetBand],
        sampleRate: Int
    ) -> String {
        var yaml = "devices:\n"
        yaml += "  - name: equaliser\n"
        yaml += "    type: pipeline\n"
        yaml += "    channels: 2\n"
        yaml += "    format: S32LE\n"
        yaml += "    rate: \(sampleRate)\n"
        yaml += "\n"
        yaml += "pipeline:\n"

        // Add user EQ filters
        if !eqBands.isEmpty {
            yaml += "  # User EQ\n"
            for band in eqBands {
                if !band.bypass {
                    yaml += "  - type: Biquad\n"
                    yaml += "    parameters:\n"
                    yaml += "      type: \(camillaDSPFilterType(band.filterType))\n"
                    yaml += "      freq: \(band.frequency)\n"
                    yaml += "      gain: \(band.gain)\n"
                    yaml += "      q: \(band.q)\n"
                    yaml += "\n"
                }
            }
        }

        // Add room correction filters
        if !roomCorrectionBands.isEmpty {
            yaml += "  # Room Correction\n"
            for band in roomCorrectionBands {
                if !band.bypass {
                    yaml += "  - type: Biquad\n"
                    yaml += "    parameters:\n"
                    yaml += "      type: \(camillaDSPFilterType(band.filterType))\n"
                    yaml += "      freq: \(band.frequency)\n"
                    yaml += "      gain: \(band.gain)\n"
                    yaml += "      q: \(band.q)\n"
                    yaml += "\n"
                }
            }
        }

        // Add sub EQ filters
        if !subEQBands.isEmpty {
            yaml += "  # Subwoofer EQ\n"
            for band in subEQBands {
                if !band.bypass {
                    yaml += "  - type: Biquad\n"
                    yaml += "    parameters:\n"
                    yaml += "      type: \(camillaDSPFilterType(band.filterType))\n"
                    yaml += "      freq: \(band.frequency)\n"
                    yaml += "      gain: \(band.gain)\n"
                    yaml += "      q: \(band.q)\n"
                    yaml += "\n"
                }
            }
        }

        return yaml
    }

    /// Maps FilterType to CamillaDSP filter type string.
    private static func camillaDSPFilterType(_ type: FilterType) -> String {
        switch type {
        case .parametric:
            return "Peaking"
        case .lowShelf:
            return "Lowshelf"
        case .highShelf:
            return "Highshelf"
        case .lowPass:
            return "Lowpass"
        case .highPass:
            return "Highpass"
        case .bandPass:
            return "Bandpass"
        case .notch:
            return "Bandstop"
        case .allPass:
            return "Allpass"
        }
    }
}
