// OutputChannelMatrixView.swift
//
// Top-level panel for the Output Channel Matrix feature.
// This is a skeleton — each section below is filled in by a specific V7 task.
// Insertion points are marked with // TASK <letter>: comments.

import SwiftUI

struct OutputChannelMatrixView: View {
    @ObservedObject var store: EqualiserStore
    @ObservedObject var meterStore: MeterStore

    // Tab selection for the Analysis section (filled in by Tasks Q, R, X, Z)
    @State private var selectedAnalysisTab: AnalysisTab = .groupDelay
    @State private var showCalibrationSheet = false

    // Calibration state
    @State private var isCalibrating = false
    @State private var targetSPL: Double = 85.0
    @State private var micCalibration: Double = 0.0
    @State private var calibrationWarnings: [BandLevelCalibrationEngine.CalibrationWarning] = []
    @State private var measuredLevels: [Int: Double] = [:]

    // Preset state
    @State private var showSavePresetSheet = false
    @State private var showLoadPresetSheet = false
    @State private var showDeletePresetSheet = false
    @State private var presetName = ""
    @State private var savedPresets: [String] = []

    // Coordination warnings
    @State private var coordinationWarnings: [CoordinationWarning] = []

    enum CoordinationWarning: Equatable, Sendable {
        case bandRejectNotch(frequency: Double)
        case crossoverOverlap(lowerFreq: Double, upperFreq: Double)
        case missingSubwoofer
    }

    enum AnalysisTab: String, CaseIterable {
        case groupDelay = "Group Delay"      // Task Q
        case summation  = "Summation"        // Task R
        case optimise   = "Optimise"         // Task X
        case timeAlign  = "Time Alignment"   // Task V/W/AF
        case verification = "Verification"   // Task AD - Combined Multi-Driver Measurement
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Master enable toggle — drives whether the rest of this view is interactive.
                // OutputChannelMatrixConfig.isEnabled (Task D)
                matrixEnableHeader

                if store.outputChannelMatrix.isEnabled {

                    // TASK B: Active Crossover section
                    // (mode picker, lower/upper frequency, slope, type, LR vs Butterworth note)
                    activeCrossoverSection

                    // TASK M: Topology template quick-select buttons
                    // (Vertical Bi-Amp / Horizontal Bi-Amp / Vertical Tri-Amp / Horizontal Tri-Amp)
                    topologyTemplateSection

                    // TASK M (sync section): Device Synchronisation
                    // (sync mode picker, clock master picker, PLL parameters, PLL status)
                    // Shown only when channels target >1 physical device.
                    if store.hasMultipleDevices {
                        deviceSynchronisationSection
                    }

                    // TASK D/G: Output channel list — one OutputChannelRowView per channel
                    outputChannelListSection

                    // TASK AA: Dynamic Loudness (Fletcher–Munson) section
                    // Shown only when activeCrossover.bandCount != .fullRange
                    if store.activeCrossoverConfig.bandCount != .fullRange {
                        dynamicLoudnessSection
                    }

                    // TASK Q/R/X/V/W/AF: Analysis tab strip
                    // (Group Delay / Summation / Optimise / Time Alignment)
                    analysisTabSection

                    // TASK T: Coordination warnings (band-reject notch, overlap, missing sub)
                    // Non-blocking amber/red banners. Always visible when warnings exist,
                    // regardless of which section of the view is scrolled into view.
                    coordinationWarningsSection

                    // TASK S: Speaker System Preset save/load buttons
                    speakerSystemPresetSection

                    // TASK P: "Calibrate Levels…" button — opens BandLevelCalibrationView sheet
                    calibrateLevelsButton

                    // TASK N: Sample-rate mismatch / device-not-found warning banner
                    deviceStatusBanner
                }
            }
            .padding()
        }
        .navigationTitle("Output Channel Matrix")
        .onChange(of: store.activeCrossoverConfig) { oldValue, newValue in
            validateCoordination()
        }
        .onChange(of: store.outputChannelMatrix.channels.count) { oldValue, newValue in
            validateCoordination()
        }
        .onAppear {
            validateCoordination()
        }
        .sheet(isPresented: $showCalibrationSheet) {
            calibrationSheet
        }
        .sheet(isPresented: $showSavePresetSheet) {
            savePresetSheet
        }
        .sheet(isPresented: $showLoadPresetSheet) {
            loadPresetSheet
        }
        .sheet(isPresented: $showDeletePresetSheet) {
            deletePresetSheet
        }
    }

    // MARK: - Section stubs (implement each from its corresponding V7 task)

    @ViewBuilder private var matrixEnableHeader: some View {
        HStack {
            Toggle("Enable Output Channel Matrix", isOn: Binding(
                get: { store.outputChannelMatrix.isEnabled },
                set: { store.outputChannelMatrix.isEnabled = $0 }
            ))
            .toggleStyle(.switch)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var activeCrossoverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mains Active Crossover")
                .font(.headline)
            HStack {
                Picker("Mode", selection: $store.activeCrossoverConfig.bandCount) {
                    Text("Full Range").tag(ActiveCrossoverBandCount.fullRange)
                    Text("Bi-Amp").tag(ActiveCrossoverBandCount.biAmp)
                    Text("Tri-Amp").tag(ActiveCrossoverBandCount.triAmp)
                }
                .pickerStyle(.segmented)
                Spacer()
            }
            if store.activeCrossoverConfig.bandCount != .fullRange {
                HStack {
                    Text("Lower Frequency:")
                    Slider(value: Binding(
                        get: { store.activeCrossoverConfig.lowerCrossoverHz },
                        set: { store.activeCrossoverConfig.lowerCrossoverHz = $0 }
                    ), in: 50...500)
                    .frame(width: 100)
                    Text(String(format: "%.0f Hz", store.activeCrossoverConfig.lowerCrossoverHz))
                        .frame(width: 60)
                }
                if store.activeCrossoverConfig.bandCount == .triAmp {
                    HStack {
                        Text("Upper Frequency:")
                        Slider(value: Binding(
                            get: { store.activeCrossoverConfig.upperCrossoverHz },
                            set: { store.activeCrossoverConfig.upperCrossoverHz = $0 }
                        ), in: 500...5000)
                        .frame(width: 100)
                        Text(String(format: "%.0f Hz", store.activeCrossoverConfig.upperCrossoverHz))
                            .frame(width: 60)
                    }
                }
                HStack {
                    Text("Slope:")
                    Picker("", selection: $store.activeCrossoverConfig.slope) {
                        Text("Gentle (24 dB/oct)").tag(CrossoverSlope.gentle)
                        Text("Steep (48 dB/oct)").tag(CrossoverSlope.steep)
                    }
                    .pickerStyle(.menu)
                    Text("Steep provides sharper roll-off between frequency bands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var topologyTemplateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Topology")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Single Amp") {
                    applySingleAmpTemplate()
                }
                .buttonStyle(.bordered)
                Button("Vertical Bi-Amp") {
                    applyVerticalBiAmpTemplate()
                }
                .buttonStyle(.bordered)
                Button("Horizontal Bi-Amp") {
                    applyHorizontalBiAmpTemplate()
                }
                .buttonStyle(.bordered)
                Button("Vertical Tri-Amp") {
                    applyVerticalTriAmpTemplate()
                }
                .buttonStyle(.bordered)
                Button("Horizontal Tri-Amp") {
                    applyHorizontalTriAmpTemplate()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Topology Templates

    private func applySingleAmpTemplate() {
        store.activeCrossoverConfig.bandCount = .fullRange
        store.outputChannelMatrix.channels = [
            OutputChannelConfig(label: "Left", source: .mainsLeft, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right", source: .mainsRight, target: nil, isEnabled: true),
        ]
    }

    private func applyVerticalBiAmpTemplate() {
        store.activeCrossoverConfig.bandCount = .biAmp
        store.outputChannelMatrix.channels = [
            OutputChannelConfig(label: "Left High", source: .mainsLeftHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Left Low", source: .mainsLeftLow, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right High", source: .mainsRightHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right Low", source: .mainsRightLow, target: nil, isEnabled: true),
        ]
    }

    private func applyHorizontalBiAmpTemplate() {
        store.activeCrossoverConfig.bandCount = .biAmp
        store.outputChannelMatrix.channels = [
            OutputChannelConfig(label: "Left High", source: .mainsLeftHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right High", source: .mainsRightHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Left Low", source: .mainsLeftLow, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right Low", source: .mainsRightLow, target: nil, isEnabled: true),
        ]
    }

    private func applyVerticalTriAmpTemplate() {
        store.activeCrossoverConfig.bandCount = .triAmp
        store.outputChannelMatrix.channels = [
            OutputChannelConfig(label: "Left High", source: .mainsLeftHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Left Mid", source: .mainsLeftMid, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Left Low", source: .mainsLeftLow, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right High", source: .mainsRightHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right Mid", source: .mainsRightMid, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right Low", source: .mainsRightLow, target: nil, isEnabled: true),
        ]
    }

    private func applyHorizontalTriAmpTemplate() {
        store.activeCrossoverConfig.bandCount = .triAmp
        store.outputChannelMatrix.channels = [
            OutputChannelConfig(label: "Left High", source: .mainsLeftHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right High", source: .mainsRightHigh, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Left Mid", source: .mainsLeftMid, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right Mid", source: .mainsRightMid, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Left Low", source: .mainsLeftLow, target: nil, isEnabled: true),
            OutputChannelConfig(label: "Right Low", source: .mainsRightLow, target: nil, isEnabled: true),
        ]
    }
    @ViewBuilder private var deviceSynchronisationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device Synchronisation")
                .font(.headline)
            HStack {
                Text("Sync Mode:")
                Picker("", selection: $store.multiDeviceSyncMode) {
                    Text("Aggregate Device").tag(MultiDeviceSyncMode.aggregateDevice)
                    Text("Software PLL").tag(MultiDeviceSyncMode.softwarePLL)
                }
                .pickerStyle(.menu)
                Spacer()
            }
            if store.multiDeviceSyncMode == .aggregateDevice {
                HStack {
                    Text("Clock Master:")
                    Picker("", selection: $store.aggregateClockMasterUID) {
                        Text("Auto").tag(nil as String?)
                        ForEach(store.outputDevices, id: \.uid) { device in
                            Text(device.name).tag(device.uid as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
            }
            if store.multiDeviceSyncMode == .softwarePLL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PLL Parameters")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    HStack {
                        Text("Bandwidth:")
                        Slider(value: Binding(
                            get: { 0.5 },
                            set: { _ in }
                        ), in: 0.01...1.0)
                        .frame(width: 100)
                        Text("0.5 Hz")
                            .frame(width: 50)
                        Spacer()
                    }
                    HStack {
                        Text("Status:")
                        Text("PLL locked")
                            .foregroundColor(.green)
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var outputChannelListSection: some View {
        ForEach(store.outputChannelMatrix.channels.indices, id: \.self) { idx in
            OutputChannelRowView(
                channel: $store.outputChannelMatrix.channels[idx],
                channelIndex: idx,
                store: store,
                meterStore: meterStore
            )
        }
        // TASK M: "+ Add Channel" button (max 8, see OutputChannelMatrixConfig.maxChannels)
        if store.outputChannelMatrix.channels.count < OutputChannelMatrixConfig.maxChannels {
            Button("+ Add Channel") {
                let newChannel = OutputChannelConfig(
                    label: "Output \(store.outputChannelMatrix.channels.count + 1)",
                    source: .mainsLeft,
                    target: nil,
                    isEnabled: true
                )
                store.outputChannelMatrix.channels.append(newChannel)
            }
            .buttonStyle(.bordered)
        }
    }
    @ViewBuilder private var dynamicLoudnessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dynamic Loudness (Fletcher–Munson)")
                .font(.headline)
            Toggle("Enable", isOn: $store.dynamicsConfig.advanced.perBandLoudness.isEnabled)
            if store.dynamicsConfig.advanced.perBandLoudness.isEnabled {
                HStack {
                    Text("Reference level:")
                    Slider(value: $store.dynamicsConfig.advanced.perBandLoudness.referencePhons, in: 60...95)
                    Text("\(Int(store.dynamicsConfig.advanced.perBandLoudness.referencePhons)) phons")
                }
                HStack {
                    Text("Max boost:")
                    Slider(value: $store.dynamicsConfig.advanced.perBandLoudness.maxBoostDB, in: 6...20)
                    Text(String(format: "%.0f dB", store.dynamicsConfig.advanced.perBandLoudness.maxBoostDB))
                }
                HStack {
                    Text("Max cut:")
                    Slider(value: $store.dynamicsConfig.advanced.perBandLoudness.maxCutDB, in: 0...6)
                    Text(String(format: "%.0f dB", store.dynamicsConfig.advanced.perBandLoudness.maxCutDB))
                }
                Picker("Level source", selection: $store.dynamicsConfig.advanced.perBandLoudness.levelSource) {
                    Text("System volume").tag(PerBandLoudnessConfig.LevelSource.systemVolume)
                    Text("Programme LUFS").tag(PerBandLoudnessConfig.LevelSource.integrated)
                }
            }
            Text("Compensates for human hearing sensitivity at different volume levels by independently adjusting bass and treble band levels. Requires bi-amp or tri-amp mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var analysisTabSection: some View {
        Picker("", selection: $selectedAnalysisTab) {
            ForEach(AnalysisTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        // Route to CrossoverAnalysisView, passing the selected tab.
        // CrossoverAnalysisView owns the actual tab content (see Section C below).
        CrossoverAnalysisView(selectedTab: $selectedAnalysisTab, store: store)
    }
    @ViewBuilder private var coordinationWarningsSection: some View {
        // Task T: Coordination warnings (band-reject notch, overlap, missing sub)
        // Non-blocking amber/red banners. Always visible when warnings exist.
        if !coordinationWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(coordinationWarnings.indices, id: \.self) { index in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(warningText(coordinationWarnings[index]))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
    @ViewBuilder private var speakerSystemPresetSection: some View {
        HStack(spacing: 8) {
            Button("Save Preset…") {
                showSavePresetSheet = true
            }
            .buttonStyle(.bordered)
            Button("Load Preset…") {
                loadPresets()
                showLoadPresetSheet = true
            }
            .buttonStyle(.bordered)
            Button("Delete Preset…") {
                loadPresets()
                showDeletePresetSheet = true
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var calibrateLevelsButton: some View {
        Button("Calibrate Levels…") {
            showCalibrationSheet = true
        }
        .buttonStyle(.borderedProminent)
        .padding(.vertical, 8)
    }
    @ViewBuilder private var deviceStatusBanner: some View {
        // Task N: Sample-rate mismatch / device-not-found warning banner
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text("Sample-rate mismatch between output devices")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var calibrationSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Band Level Calibration")
                    .font(.headline)
                Text("Calibrate output channel levels using pink noise and SPL measurement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target SPL (dB)")
                    TextField("Target SPL", value: $targetSPL, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCalibrating)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mic Calibration (dB)")
                    TextField("Mic Calibration", value: $micCalibration, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCalibrating)
                }
                HStack(spacing: 8) {
                    Button(isCalibrating ? "Calibrating..." : "Start Calibration") {
                        startCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCalibrating)
                    Button("Stop") {
                        stopCalibration()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isCalibrating)
                }
                if !calibrationWarnings.isEmpty {
                    Divider()
                    Text("Warnings")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    ForEach(calibrationWarnings.indices, id: \.self) { index in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(warningText(calibrationWarnings[index]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !measuredLevels.isEmpty {
                    Divider()
                    Text("Measured Levels")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    ForEach(measuredLevels.keys.sorted(), id: \.self) { channelIndex in
                        HStack {
                            Text("Channel \(channelIndex + 1):")
                            Spacer()
                            Text(String(format: "%.1f dBFS", measuredLevels[channelIndex] ?? 0.0))
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Calibration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showCalibrationSheet = false
                    }
                }
            }
        }
    }

    private func startCalibration() {
        isCalibrating = true
        calibrationWarnings = []
        measuredLevels = [:]

        // TODO: Integrate with BandLevelCalibrationEngine for full audio playback/capture
        // Current implementation simulates measured levels
        // Full integration requires:
        // 1. Generate pink noise using BandLevelCalibrationEngine.generatePinkNoise
        // 2. Play through each output channel via render pipeline
        // 3. Capture audio from input device
        // 4. Measure SPL using BandLevelCalibrationEngine.measureSPLFromAudio
        // 5. Compute gain trims using BandLevelCalibrationEngine.computeGainTrims
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Simulate measured levels
            measuredLevels = [0: -20.0, 1: -22.0, 2: -19.0, 3: -21.0]

            // Compute gain trims
            let existingTrims = store.outputChannelMatrix.channels.enumerated().map { ($0.offset, $0.element.gainTrimDB) }
            let (trims, warnings) = BandLevelCalibrationEngine.computeGainTrims(
                measuredLevelsDB: measuredLevels,
                existingTrimsDB: Dictionary(uniqueKeysWithValues: existingTrims)
            )

            calibrationWarnings = warnings

            // Apply computed trims
            for (index, trim) in trims {
                if index < store.outputChannelMatrix.channels.count {
                    store.outputChannelMatrix.channels[index].gainTrimDB = trim
                }
            }

            isCalibrating = false
        }
    }

    private func stopCalibration() {
        isCalibrating = false
        calibrationWarnings = []
        measuredLevels = [:]
    }

    private func warningText(_ warning: BandLevelCalibrationEngine.CalibrationWarning) -> String {
        switch warning {
        case .largeTrimRequired(_, let label, let trim):
            return "Large trim required for \(label): \(String(format: "%.1f", trim)) dB"
        case .suspiciouslyQuiet(_, let label, let measured):
            return "Suspiciously quiet measurement for \(label): \(String(format: "%.1f", measured)) dBFS"
        case .measurementFailed(_, let label):
            return "Measurement failed for \(label)"
        case .trimClamped(_, let label, let requested, let applied):
            return "Trim clamped for \(label): requested \(String(format: "%.1f", requested)) dB, applied \(String(format: "%.1f", applied)) dB"
        }
    }

    // MARK: - Preset Sheets

    @ViewBuilder private var savePresetSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save Speaker System Preset")
                    .font(.headline)
                Text("Save the current output channel matrix configuration as a preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preset Name")
                    TextField("Enter preset name", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Save") {
                    savePreset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetName.isEmpty)
                Spacer()
            }
            .padding()
            .navigationTitle("Save Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showSavePresetSheet = false
                        presetName = ""
                    }
                }
            }
        }
    }

    @ViewBuilder private var loadPresetSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Load Speaker System Preset")
                    .font(.headline)
                Text("Load a saved speaker system preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                if savedPresets.isEmpty {
                    Text("No saved presets")
                        .foregroundStyle(.secondary)
                } else {
                    List(savedPresets, id: \.self) { preset in
                        Button(preset) {
                            loadPreset(named: preset)
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Load Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showLoadPresetSheet = false
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletePresetSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Delete Speaker System Preset")
                    .font(.headline)
                Text("Delete a saved speaker system preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                if savedPresets.isEmpty {
                    Text("No saved presets")
                        .foregroundStyle(.secondary)
                } else {
                    List(savedPresets, id: \.self) { preset in
                        HStack {
                            Text(preset)
                            Spacer()
                            Button("Delete") {
                                deletePreset(named: preset)
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Delete Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showDeletePresetSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Preset Functions

    private let presetKey = "outputChannelMatrixPresets"

    private func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: presetKey),
           let presets = try? JSONDecoder().decode([String: OutputChannelMatrixConfig].self, from: data) {
            savedPresets = Array(presets.keys).sorted()
        } else {
            savedPresets = []
        }
    }

    private func savePreset() {
        var presets: [String: OutputChannelMatrixConfig] = [:]

        // Load existing presets
        if let data = UserDefaults.standard.data(forKey: presetKey),
           let existingPresets = try? JSONDecoder().decode([String: OutputChannelMatrixConfig].self, from: data) {
            presets = existingPresets
        }

        // Add new preset
        presets[presetName] = store.outputChannelMatrix

        // Save to UserDefaults
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetKey)
        }

        loadPresets()
        showSavePresetSheet = false
        presetName = ""
    }

    private func loadPreset(named name: String) {
        if let data = UserDefaults.standard.data(forKey: presetKey),
           let presets = try? JSONDecoder().decode([String: OutputChannelMatrixConfig].self, from: data),
           let preset = presets[name] {
            store.outputChannelMatrix = preset
            validateCoordination()
        }
        showLoadPresetSheet = false
    }

    private func deletePreset(named name: String) {
        var presets: [String: OutputChannelMatrixConfig] = [:]

        // Load existing presets
        if let data = UserDefaults.standard.data(forKey: presetKey),
           let existingPresets = try? JSONDecoder().decode([String: OutputChannelMatrixConfig].self, from: data) {
            presets = existingPresets
        }

        // Remove preset
        presets.removeValue(forKey: name)

        // Save to UserDefaults
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetKey)
        }

        loadPresets()
    }

    // MARK: - Coordination Warnings

    private func warningText(_ warning: CoordinationWarning) -> String {
        switch warning {
        case .bandRejectNotch(let frequency):
            return "Band-reject notch detected at \(String(format: "%.0f", frequency)) Hz"
        case .crossoverOverlap(let lowerFreq, let upperFreq):
            return "Crossover overlap between \(String(format: "%.0f", lowerFreq)) Hz and \(String(format: "%.0f", upperFreq)) Hz"
        case .missingSubwoofer:
            return "Missing subwoofer for bass management"
        }
    }

    private func validateCoordination() {
        coordinationWarnings = []

        // Check for crossover overlap
        if store.activeCrossoverConfig.bandCount == .triAmp {
            let lowerFreq = store.activeCrossoverConfig.lowerCrossoverHz
            let upperFreq = store.activeCrossoverConfig.upperCrossoverHz
            if upperFreq <= lowerFreq + 100 { // 100 Hz minimum separation
                coordinationWarnings.append(.crossoverOverlap(lowerFreq: Double(lowerFreq), upperFreq: Double(upperFreq)))
            }
        }

        // Check for band-reject notch (simplified check)
        if store.activeCrossoverConfig.bandCount != .fullRange {
            let crossoverFreq = store.activeCrossoverConfig.lowerCrossoverHz
            if crossoverFreq < 50 || crossoverFreq > 5000 {
                coordinationWarnings.append(.bandRejectNotch(frequency: Double(crossoverFreq)))
            }
        }

        // Check for missing subwoofer
        let hasSub = store.outputChannelMatrix.channels.contains { channel in
            channel.source == .subMono
        }
        if !hasSub && store.activeCrossoverConfig.bandCount == .biAmp {
            coordinationWarnings.append(.missingSubwoofer)
        }
    }
}
