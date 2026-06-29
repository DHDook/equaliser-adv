// CamillaDSPExporter.swift
// Exports the full pipeline configuration as a CamillaDSP-compatible YAML string.

import Foundation

// MARK: - Export Config

/// Captures the complete pipeline state needed to produce a CamillaDSP configuration.
struct CamillaDSPExportConfig {
    let sampleRate: Int
    let chunkSize: Int                       // default 1024
    let captureDeviceName: String            // "Notch Sixty" (the virtual driver)
    let playbackDeviceName: String           // target output device display name

    // Main-chain EQ bands (pre-crossover)
    let leftEQBands:  [EQBandConfiguration]
    let rightEQBands: [EQBandConfiguration]

    // Room correction bands (applied to both channels)
    let roomCorrectionBands: [EQBandConfiguration]

    // Active crossover config (nil if disabled)
    let activeCrossover: ActiveCrossoverConfig?

    // Output channel matrix (nil if disabled)
    let outputMatrix: OutputChannelMatrixConfig?

    // Bass management (for sub output channel)
    let bassManagementCrossoverHz: Float?
    let bassManagementSlope: BassCrossoverSlope?
}

// MARK: - Exporter

enum CamillaDSPExporter {

    // MARK: - Public Entry Point

    /// Exports a complete CamillaDSP configuration YAML string.
    ///
    /// - Parameter config: A `CamillaDSPExportConfig` capturing the full pipeline state.
    /// - Returns: A YAML string loadable directly by CamillaDSP.
    static func exportToYAML(_ config: CamillaDSPExportConfig) -> String {
        [
            devicesSection(config),
            "",
            filtersSection(config),
            "",
            mixersSection(config),
            "",
            pipelineSection(config)
        ].joined(separator: "\n")
    }

    // MARK: - Devices Section

    private static func devicesSection(_ config: CamillaDSPExportConfig) -> String {
        let outCount = config.outputMatrix.map { m in
            m.channels.filter { $0.isEnabled }.count
        } ?? 2
        return """
        ---
        devices:
          samplerate: \(config.sampleRate)
          chunksize: \(config.chunkSize)
          capture:
            type: CoreAudio
            channels: 2
            device: "\(config.captureDeviceName)"
            format: FLOAT32LE
          playback:
            type: CoreAudio
            channels: \(outCount)
            device: "\(config.playbackDeviceName)"
            format: FLOAT32LE
        """
    }

    // MARK: - Filters Section

    private static func filtersSection(_ config: CamillaDSPExportConfig) -> String {
        var lines: [String] = ["filters:"]

        // Main EQ — left
        for (i, band) in config.leftEQBands.enumerated() where !band.bypass {
            lines += filterEntry(named: "eq_L_\(i)", band: band)
        }
        // Main EQ — right
        for (i, band) in config.rightEQBands.enumerated() where !band.bypass {
            lines += filterEntry(named: "eq_R_\(i)", band: band)
        }
        // Room correction (channel-agnostic, referenced by both L and R in pipeline)
        for (i, band) in config.roomCorrectionBands.enumerated() where !band.bypass {
            lines += filterEntry(named: "room_\(i)", band: band)
        }
        // Active crossover
        if let xo = config.activeCrossover, xo.isEnabled {
            lines += crossoverFilterEntries(xo)
        }
        // Per-output-channel filters
        if let matrix = config.outputMatrix {
            let enabled = matrix.channels.filter { $0.isEnabled }
            for (i, ch) in enabled.enumerated() {
                if ch.delayMs > 0 {
                    lines += [
                        "  ch\(i)_delay:",
                        "    type: Delay",
                        "    parameters:",
                        "      delay: \(String(format: "%.4f", ch.delayMs))",
                        "      unit: ms"
                    ]
                }
                if ch.gainTrimDB != 0 || ch.polarityInverted {
                    lines += [
                        "  ch\(i)_gain:",
                        "    type: Gain",
                        "    parameters:",
                        "      gain: \(String(format: "%.2f", ch.gainTrimDB))",
                        "      inverted: \(ch.polarityInverted ? "true" : "false")"
                    ]
                }
                for (j, apCoeff) in ch.groupDelayAllPassCoefficients.enumerated() {
                    lines += biquadFilterEntry(
                        named: "ch\(i)_ap\(j)",
                        b0: Double(apCoeff.b0), b1: Double(apCoeff.b1), b2: Double(apCoeff.b2),
                        a1: Double(apCoeff.a1), a2: Double(apCoeff.a2)
                    )
                }
                let activeBands = ch.eq.bands.prefix(ch.eq.activeBandCount)
                for (j, band) in activeBands.enumerated() where !band.bypass {
                    lines += filterEntry(named: "ch\(i)_eq\(j)", band: band)
                }
                if ch.limiter.isEnabled {
                    lines += [
                        "  # ch\(i) limiter: ceiling \(String(format: "%.1f", ch.limiter.ceilingDB)) dBFS",
                        "  # Note: CamillaDSP has no native brickwall limiter.",
                        "  # The per-channel gain trim above accounts for headroom.",
                        "  # For true peak limiting, use an external pipeline plugin."
                    ]
                }
            }
        }

        // If no filters were added, emit a placeholder comment so the section is valid YAML
        if lines.count == 1 {
            lines.append("  # (no filters)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - filterEntry

    /// Maps a single `EQBandConfiguration` to one or more named YAML filter lines.
    private static func filterEntry(named name: String, band: EQBandConfiguration) -> [String] {
        if band.filterType == .fir {
            guard let kernel = band.firKernelLeft, !kernel.isEmpty else { return [] }
            let valuesStr = kernel.map { String(format: "%.8f", $0) }.joined(separator: ", ")
            return [
                "  \(name):",
                "    type: Conv",
                "    parameters:",
                "      type: Values",
                "      values: [\(valuesStr)]"
            ]
        }
        let typeStr = camillaDSPFilterType(band.filterType)
        var lines = [
            "  \(name):",
            "    type: Biquad",
            "    parameters:",
            "      type: \(typeStr)",
            "      freq: \(String(format: "%.1f", band.frequency))"
        ]
        if requiresGain(band.filterType) {
            lines.append("      gain: \(String(format: "%.2f", band.gain))")
        }
        if requiresQ(band.filterType) {
            lines.append("      q: \(String(format: "%.4f", band.q))")
        }
        return lines
    }

    // MARK: - Crossover filter entries

    private static func crossoverFilterEntries(_ xo: ActiveCrossoverConfig) -> [String] {
        var lines: [String] = []

        func addPoint(_ point: CrossoverPointConfig, suffix: String) {
            let lpType  = camillaDSPCrossoverType(point.lpType, isLP: true)
            let hpType  = camillaDSPCrossoverType(point.hpType, isLP: false)
            let lpOrder = filterSlopeToOrder(point.lpSlope)
            let hpOrder = filterSlopeToOrder(point.hpSlope)
            lines += [
                "  xo_\(suffix)_LP:",
                "    type: BiquadCombo",
                "    parameters:",
                "      type: \(lpType)",
                "      freq: \(String(format: "%.1f", point.lpHz))",
                "      order: \(lpOrder)",
                "  xo_\(suffix)_HP:",
                "    type: BiquadCombo",
                "    parameters:",
                "      type: \(hpType)",
                "      freq: \(String(format: "%.1f", point.hpHz))",
                "      order: \(hpOrder)"
            ]
        }

        addPoint(xo.lowerPoint, suffix: "lower")
        if xo.bandCount == .triAmp {
            addPoint(xo.upperPoint, suffix: "upper")
        }
        return lines
    }

    private static func camillaDSPCrossoverType(_ type: CrossoverFilterType, isLP: Bool) -> String {
        switch type {
        case .linkwitzRiley:
            return isLP ? "LinkwitzRileyLowpass" : "LinkwitzRileyHighpass"
        case .butterworth:
            return isLP ? "ButterworthLowpass" : "ButterworthHighpass"
        case .firLinearPhase:
            return isLP
                ? "LinkwitzRileyLowpass  # FIR: substitute Conv filter manually"
                : "LinkwitzRileyHighpass # FIR: substitute Conv filter manually"
        }
    }

    private static func filterSlopeToOrder(_ slope: FilterSlope) -> Int {
        switch slope {
        case .db6:  return 1
        case .db12: return 2
        case .db18: return 3
        case .db24: return 4
        case .db36: return 6
        case .db48: return 8
        case .db60: return 10
        case .db72: return 12
        case .db84: return 14
        case .db96: return 16
        }
    }

    // MARK: - Mixers Section

    private static func mixersSection(_ config: CamillaDSPExportConfig) -> String {
        guard let matrix = config.outputMatrix, matrix.isEnabled else {
            return """
            mixers:
              stereo_passthrough:
                channels:
                  in: 2
                  out: 2
                mapping:
                  - dest: 0
                    sources:
                      - channel: 0
                        gain: 0
                        inverted: false
                  - dest: 1
                    sources:
                      - channel: 1
                        gain: 0
                        inverted: false
            """
        }

        let enabled = matrix.channels.filter { $0.isEnabled }
        var lines: [String] = [
            "mixers:",
            "  channel_matrix:",
            "    channels:",
            "      in: 2",
            "      out: \(enabled.count)",
            "    mapping:"
        ]
        for (i, ch) in enabled.enumerated() {
            let (inputChannel, note) = signalSourceToMixerInput(ch.source)
            lines += [
                "      - dest: \(i)",
                "        sources:",
                "          - channel: \(inputChannel)  # \(note)",
                "            gain: 0",
                "            inverted: false"
            ]
        }
        return lines.joined(separator: "\n")
    }

    private static func signalSourceToMixerInput(_ source: SignalSource) -> (Int, String) {
        switch source {
        case .mainsLeft:      return (0, "L mains")
        case .mainsRight:     return (1, "R mains")
        case .mainsLeftHigh:  return (0, "L high — route after xo_lower_HP")
        case .mainsLeftMid:   return (0, "L mid — route after xo_upper_LP + xo_lower_HP")
        case .mainsLeftLow:   return (0, "L low — route after xo_lower_LP")
        case .mainsRightHigh: return (1, "R high — route after xo_lower_HP")
        case .mainsRightMid:  return (1, "R mid — route after xo_upper_LP + xo_lower_HP")
        case .mainsRightLow:  return (1, "R low — route after xo_lower_LP")
        case .subMono:        return (0, "Sub mono — sum L+R after bass management LP")
        }
    }

    // MARK: - Pipeline Section

    private static func pipelineSection(_ config: CamillaDSPExportConfig) -> String {
        var lines: [String] = ["pipeline:"]

        // Step 1: Main EQ — left channel
        let leftIIRNames = config.leftEQBands.enumerated()
            .filter { !$1.bypass && $1.filterType != .fir }
            .map { "eq_L_\($0.offset)" }
        let leftFIRNames = config.leftEQBands.enumerated()
            .filter { !$1.bypass && $1.filterType == .fir && $1.firKernelLeft != nil }
            .map { "eq_L_\($0.offset)" }
        if !leftIIRNames.isEmpty {
            lines += pipelineFilterStep(channel: 0, names: leftIIRNames, comment: "Main EQ — L")
        }
        if !leftFIRNames.isEmpty {
            lines += pipelineFilterStep(channel: 0, names: leftFIRNames, comment: "FIR bands — L")
        }

        // Step 1: Main EQ — right channel
        let rightIIRNames = config.rightEQBands.enumerated()
            .filter { !$1.bypass && $1.filterType != .fir }
            .map { "eq_R_\($0.offset)" }
        let rightFIRNames = config.rightEQBands.enumerated()
            .filter { !$1.bypass && $1.filterType == .fir && $1.firKernelLeft != nil }
            .map { "eq_R_\($0.offset)" }
        if !rightIIRNames.isEmpty {
            lines += pipelineFilterStep(channel: 1, names: rightIIRNames, comment: "Main EQ — R")
        }
        if !rightFIRNames.isEmpty {
            lines += pipelineFilterStep(channel: 1, names: rightFIRNames, comment: "FIR bands — R")
        }

        // Step 2: Room correction
        let roomNames = config.roomCorrectionBands.enumerated()
            .filter { !$1.bypass }
            .map { "room_\($0.offset)" }
        if !roomNames.isEmpty {
            lines += pipelineFilterStep(channel: 0, names: roomNames, comment: "Room correction — L")
            lines += pipelineFilterStep(channel: 1, names: roomNames, comment: "Room correction — R")
        }

        // Step 3: Crossover
        if let xo = config.activeCrossover, xo.isEnabled {
            lines += ["  # --- Crossover ---"]
            lines += pipelineFilterStep(channel: 0, names: ["xo_lower_LP"], comment: "L low")
            lines += pipelineFilterStep(channel: 0, names: ["xo_lower_HP"], comment: "L high (or mid+high in tri-amp)")
            if xo.bandCount == .triAmp {
                lines += pipelineFilterStep(channel: 0, names: ["xo_upper_LP"], comment: "L mid")
                lines += pipelineFilterStep(channel: 0, names: ["xo_upper_HP"], comment: "L high")
            }
            lines += ["  # Right channel crossover mirrors left — add equivalent steps for channel: 1"]
        }

        // Step 4: Mixer
        let mixerName = (config.outputMatrix?.isEnabled == true) ? "channel_matrix" : "stereo_passthrough"
        lines += [
            "  # --- Output routing ---",
            "  - type: Mixer",
            "    name: \(mixerName)"
        ]

        // Step 5: Per-channel processing
        if let matrix = config.outputMatrix {
            let enabled = matrix.channels.filter { $0.isEnabled }
            for (i, ch) in enabled.enumerated() {
                var chFilters: [String] = []
                if ch.delayMs > 0 { chFilters.append("ch\(i)_delay") }
                if ch.gainTrimDB != 0 || ch.polarityInverted { chFilters.append("ch\(i)_gain") }
                for j in 0..<ch.groupDelayAllPassCoefficients.count { chFilters.append("ch\(i)_ap\(j)") }
                let activeBands = ch.eq.bands.prefix(ch.eq.activeBandCount)
                let chEQNames = activeBands.enumerated()
                    .filter { !$1.bypass }
                    .map { "ch\(i)_eq\($0.offset)" }
                chFilters += chEQNames
                if !chFilters.isEmpty {
                    lines += pipelineFilterStep(channel: i, names: chFilters, comment: ch.label)
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func pipelineFilterStep(channel: Int, names: [String], comment: String) -> [String] {
        let namesStr = names.map { "\"\($0)\"" }.joined(separator: ", ")
        return [
            "  - type: Filter  # \(comment)",
            "    channel: \(channel)",
            "    names: [\(namesStr)]"
        ]
    }

    // MARK: - Helpers

    private static func camillaDSPFilterType(_ type: FilterType) -> String {
        switch type {
        case .parametric: return "Peaking"
        case .lowShelf:   return "Lowshelf"
        case .highShelf:  return "Highshelf"
        case .lowPass:    return "Lowpass"
        case .highPass:   return "Highpass"
        case .bandPass:   return "Bandpass"
        case .notch:      return "Bandstop"
        case .allPass:    return "Allpass"
        case .fir:        return "Conv"  // handled separately in filterEntry
        }
    }

    private static func requiresGain(_ type: FilterType) -> Bool {
        switch type {
        case .parametric, .lowShelf, .highShelf: return true
        default: return false
        }
    }

    private static func requiresQ(_ type: FilterType) -> Bool {
        switch type {
        case .parametric, .lowPass, .highPass, .bandPass, .notch, .allPass: return true
        default: return false
        }
    }

    private static func biquadFilterEntry(
        named name: String,
        b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    ) -> [String] {
        [
            "  \(name):",
            "    type: Biquad",
            "    parameters:",
            "      type: Raw",
            "      a1: \(String(format: "%.8f", a1))",
            "      a2: \(String(format: "%.8f", a2))",
            "      b0: \(String(format: "%.8f", b0))",
            "      b1: \(String(format: "%.8f", b1))",
            "      b2: \(String(format: "%.8f", b2))"
        ]
    }
}
