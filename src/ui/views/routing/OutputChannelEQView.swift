// OutputChannelEQView.swift
//
// Full parametric EQ editor for one output channel. Functionally mirrors the
// mains EQ window (per Task F's explicit requirement: "must be functionally
// identical to the mains EQ window for stereo-capable output channels").
// Assembled from requirements scattered across Task F — there is no single
// "create this file" instruction in the spec; this skeleton consolidates them.

import SwiftUI

struct OutputChannelEQView: View {
    @Binding var channel: OutputChannelConfig
    let channelIndex: Int
    @ObservedObject var store: EqualiserStore

    private var capabilities: OutputChannelEQCapabilities {
        .capabilities(for: channel.source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // From Task F: "Compare mode toolbar (mirrors main EQ window exactly)"
            // EQ / Linear / Flat / Delta / Mixed — hide buttons the capabilities
            // struct disallows, do not grey them out.
            compareModeToolbar

            // From Task F: FIR crossover badge / auto-promotion notice / IIR warning.
            // Only shown when channel.eq.firCrossoverIsActive is true.
            if channel.eq.firCrossoverIsActive {
                firCrossoverBadge
            }

            // From Task F (Item 7 addition): "Phase shaping" slider.
            // Visible ONLY when compareMode == .linearEQ.
            if channel.eq.compareMode == .linearEQ {
                preRingingBlendSlider
            }

            // From Task F: Channel mode picker (Linked/Stereo/Mid-Side).
            // Hidden entirely when capabilities.supportsChannelModes == false.
            if capabilities.supportsChannelModes {
                channelModePicker
            }

            // From Task F: band editor — up to capabilities.maxBands (64 or 16),
            // all FilterType + FilterSlope values, frequency/Q/gain sliders,
            // per-band bypass, frequency response curve.
            // Reuse EQBandSliderView and curve components directly (per Task M's
            // explicit instruction: "Reuse EQBandSliderView and all EQ curve
            // rendering components directly").
            bandEditor

            // From Task F: input/output gain sliders, global bypass, Flatten button.
            globalControlsRow

            // From Task AE (Part 2): EQ Oversampling toggle.
            // Hidden for subMono source (capabilities.supportsAdvancedPhase == false).
            if capabilities.supportsAdvancedPhase {
                oversamplingToggle
            }

            // From Task AB (Part 2): Detected Resonances panel, shown only
            // when transfer function measurement data exists for this channel.
            // TODO: Uncomment when store.transferFunctionDataset exists
            // if store.transferFunctionDataset.channel(at: channelIndex)?.isMeasured == true {
            detectedResonancesPanel
            // }

            // From Task F: sub output restriction note.
            if !capabilities.supportsAdvancedPhase {
                Text("Linear phase and delta modes are not available for mono sub outputs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Section stubs — implement each from its task

    @ViewBuilder private var compareModeToolbar: some View {
        Picker("", selection: $channel.eq.compareMode) {
            Text("EQ").tag(CompareMode.eq)
            if capabilities.supportsAdvancedPhase {
                Text("Linear").tag(CompareMode.linearEQ)
                Text("Mixed").tag(CompareMode.mixedPhase)
            }
            Text("Flat").tag(CompareMode.flat)
            if capabilities.supportsDeltaMode {
                Text("Delta").tag(CompareMode.delta)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var firCrossoverBadge: some View {
        HStack {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
            Text("FIR crossover active — linear-phase EQ recommended")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var preRingingBlendSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Phase Shaping")
                .font(.subheadline)
            HStack {
                Text("Pre-ringing:")
                Slider(value: $channel.eq.preRingingBlend, in: 0...1)
                Text(String(format: "%.2f", channel.eq.preRingingBlend))
                    .frame(width: 40)
            }
            Text("0.0 = pure linear-phase, 1.0 = pure minimum-phase")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var channelModePicker: some View {
        Picker("Channel Mode", selection: $channel.eq.channelMode) {
            Text("Linked").tag(ChannelMode.linked)
            Text("Stereo").tag(ChannelMode.stereo)
            Text("Mid-Side").tag(ChannelMode.midSide)
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder private var bandEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Band Editor")
                .font(.headline)
            ForEach(channel.eq.bands.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Band \(index + 1)")
                            .font(.subheadline)
                        Toggle("", isOn: $channel.eq.bands[index].bypass)
                            .toggleStyle(.switch)
                        Spacer()
                    }
                    HStack {
                        Text("Freq:")
                        Slider(value: Binding(
                            get: { channel.eq.bands[index].frequency },
                            set: { channel.eq.bands[index].frequency = $0 }
                        ), in: 20...20000)
                        .frame(width: 100)
                        Text(String(format: "%.0f Hz", channel.eq.bands[index].frequency))
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Gain:")
                        Slider(value: Binding(
                            get: { channel.eq.bands[index].gain },
                            set: { channel.eq.bands[index].gain = $0 }
                        ), in: -24...24)
                        .frame(width: 100)
                        Text(String(format: "%.1f dB", channel.eq.bands[index].gain))
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Q:")
                        Slider(value: Binding(
                            get: { channel.eq.bands[index].q },
                            set: { channel.eq.bands[index].q = $0 }
                        ), in: 0.1...10)
                        .frame(width: 100)
                        Text(String(format: "%.2f", channel.eq.bands[index].q))
                            .frame(width: 60)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var globalControlsRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Gain")
                    .font(.caption)
                HStack {
                    Slider(value: $channel.eq.inputGainDB, in: -24...24)
                        .frame(width: 100)
                    Text(String(format: "%.1f dB", channel.eq.inputGainDB))
                        .frame(width: 50)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Output Gain")
                    .font(.caption)
                HStack {
                    Slider(value: $channel.eq.outputGainDB, in: -24...24)
                        .frame(width: 100)
                    Text(String(format: "%.1f dB", channel.eq.outputGainDB))
                        .frame(width: 50)
                }
            }
            Toggle("Bypass", isOn: $channel.eq.isBypassed)
            Button("Flatten") {
                channel.eq.bands.indices.forEach { index in
                    channel.eq.bands[index].gain = 0.0
                    channel.eq.bands[index].q = 1.0
                    channel.eq.bands[index].bypass = false
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var oversamplingToggle: some View {
        Toggle("EQ Oversampling", isOn: Binding(
            get: { false },
            set: { _ in }
        ))
    }

    @ViewBuilder private var detectedResonancesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detected Resonances")
                .font(.headline)
            Text("Detected resonances placeholder")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
