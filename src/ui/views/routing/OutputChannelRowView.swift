// OutputChannelRowView.swift
//
// One row per output channel in the matrix. Each section below is filled in
// by a specific V7 task. Build the layout shell first, then implement each
// control from its corresponding task.

import SwiftUI
import Combine

struct OutputChannelRowView: View {
    @Binding var channel: OutputChannelConfig
    let channelIndex: Int
    @ObservedObject var store: EqualiserStore
    @ObservedObject var meterStore: MeterStore

    @State private var showEQEditor = false
    @State private var showBaffleStepCalculator = false   // sheet presentation flag for Section D

    // Baffle step calculator state
    @State private var speakerWidthCM: Double = 30.0
    @State private var listeningDistanceM: Double = 3.0
    @State private var calculatedBaffleStepFreq: Double = 0.0
    @State private var recommendedBoostDB: Double = 0.0

    // Excursion protection state
    @State private var showExcursionProtection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // TASK D: Channel number badge, editable label, enable toggle
            rowHeader

            // TASK D: Source picker (filtered by current crossover mode — see
            // SignalSource.requiresCrossover / requiresTriAmp from Task A)
            sourcePicker

            // TASK D + K: Device picker, channel picker (from outputChannelInfo)
            deviceAndChannelPicker

            // TASK D (revised range ±24dB) + AA (loudness, applied invisibly,
            // NOT shown here — see Task AA architectural note: loudness correction
            // is a separate atomic, gainTrimDB display always reflects calibration only)
            gainTrimAndPolarityControls

            // TASK D: Delay slider + distance-to-delay helper
            delayControls

            // TASK D: EQ toggle + "Edit EQ…" button → opens OutputChannelEQView sheet
            eqSection

            // TASK D: Limiter toggle + ceiling slider
            // TASK Y: Excursion Protection sub-section (collapsed by default)
            limiterAndExcursionSection

            // TASK U: "Baffle Step…" button — shown only for low-frequency sources
            // (.mainsLeftLow, .mainsRightLow, .mainsLeft, .mainsRight)
            if isLowFrequencySource {
                baffleStepButton
            }

            // TASK AG: Pre-limiter / post-limiter level meters
            levelMeters

            // TASK D: Delete button (disabled below OutputChannelMatrixConfig.minChannels)
            deleteButton
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
        .sheet(isPresented: $showEQEditor) {
            OutputChannelEQView(channel: $channel, channelIndex: channelIndex, store: store)
        }
        .sheet(isPresented: $showBaffleStepCalculator) {
            baffleStepCalculatorSheet
        }
    }

    private var isLowFrequencySource: Bool {
        [.mainsLeftLow, .mainsRightLow, .mainsLeft, .mainsRight].contains(channel.source)
    }

    // MARK: - Section stubs

    @ViewBuilder private var rowHeader: some View {
        HStack {
            Text("\(channelIndex + 1)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .frame(width: 24)
            TextField("Channel Label", text: Binding(
                get: { channel.label },
                set: { channel.label = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            Toggle("", isOn: $channel.isEnabled)
                .toggleStyle(.switch)
            Spacer()
        }
    }

    @ViewBuilder private var sourcePicker: some View {
        Picker("Source", selection: $channel.source) {
            ForEach(filteredSources, id: \.self) { source in
                Text(source.displayName).tag(source)
            }
        }
        .pickerStyle(.menu)
    }

    private var filteredSources: [SignalSource] {
        let bandCount = store.activeCrossoverConfig.bandCount
        return SignalSource.allCases.filter { source in
            // Filter out sources that require crossover when crossover is not enabled
            if source.requiresCrossover && bandCount == .fullRange {
                return false
            }
            // Filter out sources that require tri-amp when not in tri-amp mode
            if source.requiresTriAmp && bandCount != .triAmp {
                return false
            }
            return true
        }
    }

    @ViewBuilder private var deviceAndChannelPicker: some View {
        HStack {
            Text("Device:")
            Picker("", selection: Binding(
                get: { channel.target?.deviceUID },
                set: { newValue in
                    if let uid = newValue {
                        if channel.target == nil {
                            channel.target = OutputTarget(deviceUID: uid, channelIndices: [0])
                        } else {
                            channel.target?.deviceUID = uid
                        }
                    }
                }
            )) {
                Text("None").tag(nil as String?)
                ForEach(store.outputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid as String?)
                }
            }
            .pickerStyle(.menu)
            Spacer()
            if let deviceUID = channel.target?.deviceUID,
               let device = store.outputDevices.first(where: { $0.uid == deviceUID }) {
                Text("Channel:")
                Picker("", selection: Binding(
                    get: { channel.target?.channelIndices.first },
                    set: { newValue in
                        if let index = newValue {
                            channel.target?.channelIndices = [index]
                        }
                    }
                )) {
                    ForEach(0..<store.deviceManager.outputChannelCount(deviceID: device.id), id: \.self) { index in
                        Text("Channel \(index + 1)").tag(index)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder private var gainTrimAndPolarityControls: some View {
        HStack {
            Text("Gain:")
            Slider(value: Binding(
                get: { channel.gainTrimDB },
                set: { channel.gainTrimDB = $0 }
            ), in: -24...24)
            .frame(width: 100)
            Text(String(format: "%.1f dB", channel.gainTrimDB))
                .frame(width: 60)
            Toggle("Invert", isOn: $channel.polarityInverted)
                .toggleStyle(.switch)
            Spacer()
        }
    }

    @ViewBuilder private var delayControls: some View {
        HStack {
            Text("Delay:")
            Slider(value: Binding(
                get: { channel.delayMs },
                set: { channel.delayMs = $0 }
            ), in: 0...20)
            .frame(width: 100)
            Text(String(format: "%.1f ms", channel.delayMs))
                .frame(width: 60)
            Spacer()
        }
    }
    @ViewBuilder private var eqSection: some View {
        HStack {
            Toggle("EQ", isOn: Binding(
                get: { !channel.eq.isBypassed },
                set: { channel.eq.isBypassed = !$0 }
            ))
            Button("Edit EQ…") { showEQEditor = true }
        }
    }
    @ViewBuilder private var limiterAndExcursionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Limiter", isOn: $channel.limiter.isEnabled)
                Slider(value: Binding(
                    get: { channel.limiter.ceilingDB },
                    set: { channel.limiter.ceilingDB = $0 }
                ), in: -20...0)
                .frame(width: 80)
                Text(String(format: "%.1f dB", channel.limiter.ceilingDB))
                    .frame(width: 50)
            }
            // TASK Y: Excursion Protection sub-section (collapsed by default)
            DisclosureGroup("Excursion Protection", isExpanded: $showExcursionProtection) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Attack:")
                        Slider(value: Binding(
                            get: { channel.limiter.attackMs },
                            set: { channel.limiter.attackMs = $0 }
                        ), in: 0.01...100)
                        .frame(width: 100)
                        Text(String(format: "%.2f ms", channel.limiter.attackMs))
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Release:")
                        Slider(value: Binding(
                            get: { channel.limiter.releaseMs },
                            set: { channel.limiter.releaseMs = $0 }
                        ), in: 1...1000)
                        .frame(width: 100)
                        Text(String(format: "%.0f ms", channel.limiter.releaseMs))
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Look-ahead:")
                        Slider(value: Binding(
                            get: { channel.limiter.lookAheadMs },
                            set: { channel.limiter.lookAheadMs = $0 }
                        ), in: 0...20)
                        .frame(width: 100)
                        Text(String(format: "%.1f ms", channel.limiter.lookAheadMs))
                            .frame(width: 60)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder private var baffleStepButton: some View {
        Button("Baffle Step…") {
            showBaffleStepCalculator = true
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var baffleStepCalculatorSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Baffle Step Compensation Calculator")
                    .font(.headline)
                Text("Calculate baffle step compensation based on speaker dimensions and listening distance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker Width (cm)")
                    TextField("Width", value: $speakerWidthCM, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Listening Distance (m)")
                    TextField("Distance", value: $listeningDistanceM, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Calculate") {
                    calculateBaffleStep()
                }
                .buttonStyle(.borderedProminent)
                if calculatedBaffleStepFreq > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Results")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        HStack {
                            Text("Baffle Step Frequency:")
                            Spacer()
                            Text(String(format: "%.0f Hz", calculatedBaffleStepFreq))
                        }
                        HStack {
                            Text("Recommended Boost:")
                            Spacer()
                            Text(String(format: "%.1f dB", recommendedBoostDB))
                        }
                        Button("Apply to EQ") {
                            applyBaffleStepCompensation()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Baffle Step Calculator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showBaffleStepCalculator = false
                    }
                }
            }
        }
    }

    private func calculateBaffleStep() {
        // Baffle step frequency formula: f = c / (2 * width)
        // where c = speed of sound (343 m/s) and width is in meters
        let speedOfSound = 343.0 // m/s
        let widthM = speakerWidthCM / 100.0 // convert cm to m
        calculatedBaffleStepFreq = speedOfSound / (2 * widthM)

        // Recommended boost is typically 3-6 dB depending on baffle size
        // For smaller baffles, more boost is needed
        recommendedBoostDB = min(6.0, max(3.0, 30.0 / speakerWidthCM))
    }

    private func applyBaffleStepCompensation() {
        // Add a low-shelf filter at the baffle step frequency
        // This is a simplified implementation - in practice you'd add a proper EQ band
        let shelfBandIndex = 0 // Use the first band for the shelf
        if shelfBandIndex < channel.eq.bands.count {
            channel.eq.bands[shelfBandIndex].frequency = Float(calculatedBaffleStepFreq)
            channel.eq.bands[shelfBandIndex].gain = Float(recommendedBoostDB)
            channel.eq.bands[shelfBandIndex].q = 0.5 // Low Q for shelving
            channel.eq.bands[shelfBandIndex].bypass = false
        }
        showBaffleStepCalculator = false
    }
    @ViewBuilder private var levelMeters: some View {
        let meterData = meterStore.outputChannelLevels[channelIndex]
        let preLimiterDB = meterData?.preLimiterPeakDB ?? -100.0
        let postLimiterDB = meterData?.postLimiterPeakDB ?? -100.0
        let isClipping = meterData?.isClipping ?? false

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pre-Limiter")
                    .font(.caption)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 20)
                        Rectangle()
                            .fill(preLimiterDB > -3 ? .red : .green)
                            .frame(width: geometry.size.width * CGFloat(max(0, (preLimiterDB + 60) / 60)), height: 20)
                    }
                }
                .frame(width: 100, height: 20)
                Text(String(format: "%.1f dB", preLimiterDB))
                    .font(.caption2)
                    .foregroundStyle(isClipping ? .red : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Post-Limiter")
                    .font(.caption)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 20)
                        Rectangle()
                            .fill(postLimiterDB > -3 ? .red : .green)
                            .frame(width: geometry.size.width * CGFloat(max(0, (postLimiterDB + 60) / 60)), height: 20)
                    }
                }
                .frame(width: 100, height: 20)
                Text(String(format: "%.1f dB", postLimiterDB))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
    @ViewBuilder private var deleteButton: some View {
        Button("Delete") {
            store.outputChannelMatrix.channels.remove(at: channelIndex)
        }
        .disabled(channelIndex < OutputChannelMatrixConfig.minChannels)
        .foregroundColor(.red)
    }
}
