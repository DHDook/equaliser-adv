// DynamicsView.swift
// Controls for the full dynamics processor chain:
// Stereo Widener → LUFS Loudness Match → De-Esser → Multiband Compressor
// → Compressor → Expander → Soft Clipper → Brickwall Limiter
// → LTI Processing Suite.
// Layout: six-column inline view with per-control settings popovers.

import AppKit
import SwiftUI

// MARK: - Slider Row

/// A labelled slider row with an inline editable value field on the right.
/// Optional endpoint labels are rendered as Slider minimum/maximum value labels.
private struct DynamicsSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatValue: (Double) -> String
    var leftEndLabel: String? = nil
    var rightEndLabel: String? = nil
    var isDisabled: Bool = false

    @State private var textValue: String = ""
    @State private var isUserEditing: Bool = false   // new — tracks an in-progress edit, not raw focus state
    @FocusState private var isFieldFocused: Bool
    /// Snaps to the step grid on write without using Slider's built-in
    /// `step:` parameter, which draws visible tick marks along the track —
    /// this keeps drag-to-step-increment behavior while avoiding that look.
    private var steppedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newVal in
                guard step > 0 else { value = newVal; return }
                let snapped = (newVal / step).rounded() * step
                value = min(range.upperBound, max(range.lowerBound, snapped))
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            if let left = leftEndLabel {
                Text(left)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Slider(value: steppedValue, in: range)
                .controlSize(.small)
                .onChange(of: value) { _, newVal in
                    if !isUserEditing {
                        textValue = formatValue(newVal)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if isFieldFocused {
                                // Don't wait for SwiftUI's @FocusState to round-trip —
                                // go straight to AppKit and clear the window's first
                                // responder the instant a touch lands on this slider,
                                // before the slider's own drag-tracking has a chance
                                // to be blocked by a still-active text-editor session
                                // in the sibling TextField.
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }
                        }
                )
            if let right = rightEndLabel {
                Text(right)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

           TextField("", text: $textValue)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 74)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onAppear { textValue = formatValue(value) }
                .onChange(of: textValue) { _, _ in
                    // Only true once the user has actually typed a keystroke
                    // while this field is focused — not set merely by gaining
                    // focus, and not set by the programmatic textValue
                    // assignments above (see ordering note below).
                    if isFieldFocused {
                        isUserEditing = true
                    }
                }
                .onSubmit {
                    commitTextEdit()
                    isUserEditing = false
                }
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused {
                        if isUserEditing {
                            commitTextEdit()
                        }
                        isUserEditing = false
                    }
                }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
    }

    private func commitTextEdit() {
        let cleaned = textValue
            .replacingOccurrences(of: " dB", with: "")
            .replacingOccurrences(of: " Hz", with: "")
            .replacingOccurrences(of: " ms", with: "")
            .replacingOccurrences(of: " LUFS", with: "")
            .replacingOccurrences(of: " : 1", with: "")
            .replacingOccurrences(of: "% L", with: "")
            .replacingOccurrences(of: "% R", with: "")
            .replacingOccurrences(of: " seats", with: "")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let parsed = Double(cleaned) {
            value = min(range.upperBound, max(range.lowerBound, parsed))
        }
        textValue = formatValue(value)
    }
}

// MARK: - Inline Header Widget

/// Compact dynamics widget shown inline in the main window header.
/// Six-column layout (max 10 toggles per column):
///   Col 1 — core dynamics chain stages, in signal-chain order
///   Col 2 — later dynamics + spatial stages
///   Col 3 — LTI processing + global processing-mode flags
///   Col 4 — Segmented pickers (stereo / latency / dither)
///   Col 5 — Analytics meters
///   Col 6 — Goniometer
struct DynamicsInlineView: View {
    @EnvironmentObject var store: EqualiserStore

    @State private var showDefinitions   = false
    @StateObject private var inlineMeterBridge = InlineMeterBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            HStack(alignment: .top, spacing: 12) {
                column1
                Divider()
                column2
                Divider()
                column3
                Divider()
                column4
                Divider()
                column5
                Divider()
                column6
            }
        }
        .onAppear { inlineMeterBridge.register(with: store.meterStore, equaliserStore: store) }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text("Dynamics")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                showDefinitions.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDefinitions, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        // Column 1 — early signal chain
                        definitionEntry(title: "Infrasonic Filter", body: "Steep high-pass filter removing subsonic content below the threshold of hearing. Protects drivers and amplifiers from HVAC turbulence, record warps, and room pressurisation. Does not affect audible content when set at or below 20 Hz.")
                        Divider()
                        definitionEntry(title: "Denoiser", body: "Spectral subtraction noise floor reduction using a running noise power estimate.")
                        Divider()
                        definitionEntry(title: "FIR Impulse Response", body: "Loads a user-supplied impulse response file and convolves it with the signal — distinct from FIR Correction's convolution slot. Intended for headphone or speaker correction profiles supplied as a raw impulse response rather than a measurement-derived filter.")
                        Divider()
                        definitionEntry(title: "DC Filter", body: "0.5 Hz single-pole high-pass removing DC bias before the dynamics chain.")
                        Divider()
                        definitionEntry(title: "Sub-Bass Align", body: "All-pass network phase-aligning sub-bass with main speaker bandwidth at the crossover frequency.")
                        Divider()
                        definitionEntry(title: "Stereo Widener", body: "Three-band M/S processor that independently adjusts stereo width in the Low (< 200 Hz), Mid (200 Hz – 4 kHz), and High (> 4 kHz) regions.")
                        Divider()
                        definitionEntry(title: "LUFS Loudness Match", body: "Measures 3-second K-weighted loudness and continuously adjusts gain to hit the target LUFS level.")
                        Divider()
                        definitionEntry(title: "Loudness Contour", body: "Fletcher-Munson compensation curve adding gentle bass and treble lift for low-level listening.")
                        Divider()
                        definitionEntry(title: "De-Esser", body: "Tames harsh, high-frequency sibilance by applying frequency-selective gain reduction around a tunable centre frequency.")
                        Divider()
                        definitionEntry(title: "Multiband Compressor", body: "Independently controls the dynamics of three separate frequency bands using Linkwitz-Riley crossovers.")
                        Divider()
                        definitionEntry(title: "Compressor", body: "Standard feed-forward dynamics compressor with adjustable threshold, ratio, soft-knee width, attack, release, and makeup gain. Supports program-dependent release time adaptation and an optional sidechain high-pass filter to reduce low-frequency pumping.")
                        Divider()
                        definitionEntry(title: "Expander", body: "Downward dynamic-range expander. Widens perceived dynamics by attenuating signals below threshold.")
                        Divider()
                        definitionEntry(title: "Bass Management", body: "Unified subwoofer integration: crossover frequency, slope, and type; independent sub-channel gain, polarity, and delay; room-gain compensation shelf; and per-speaker distance compensation for time alignment.")
                        Divider()
                        definitionEntry(title: "Dynamic Gain Rider", body: "Slowly reduces the signal feeding the clipper/limiter to keep sustained limiter gain reduction near a target level, trading a small amount of loudness for fewer audible limiting artefacts on hot mixes.")
                        Divider()
                        definitionEntry(title: "Clipper", body: "Analogue-style wave-shaper that gently rounds transient peaks before the limiter.")
                        Divider()
                        definitionEntry(title: "Limiter", body: "Look-ahead true peak limiter. Guarantees the output cannot exceed the ceiling.")
                        Divider()
                        definitionEntry(title: "De-Harsh", body: "High-frequency tilt filter attenuating above ~3.5 kHz to reduce tweeter fatigue.")
                        Divider()
                        definitionEntry(title: "IR Alignment", body: "Fractional-sample delay compensation for multi-driver speaker acoustic centres.")
                        Divider()
                        definitionEntry(title: "Symmetry Balance", body: "Gain-matrix correction for asymmetric listening positions. Aligns L/R loudness at the ear.")
                        Divider()
                        definitionEntry(title: "Panning Gain Matrix", body: "Bilinear crossfeed matrix blending a proportion of each channel into the opposite channel.")
                        Divider()
                        definitionEntry(title: "Crosstalk Cancel.", body: "Recursive binaural inversion filter reducing inter-channel acoustic leakage between speakers.")
                        Divider()
                        definitionEntry(title: "Pause Gate", body: "Silences output when signal falls below the threshold for the Hold duration, then reopens at the Resume Speed when audio returns. Use the Preset picker or tune individually to match your amplifier and listening habits.")
                        Divider()
                        definitionEntry(title: "Hi-Res Coef", body: "Enables high-resolution coefficient decoupling for per-sample filter updates at the cost of higher CPU.")
                        Divider()
                        definitionEntry(title: "4x Oversampling", body: "Upsamples audio by 4× before EQ and downsamples after EQ. Improves high-frequency response and reduces aliasing artifacts.")
                        Divider()
                        definitionEntry(title: "Sync Buffer", body: "Synchronises processing buffer to latency mode, preventing dropouts at low latency settings.")
                        Divider()
                        definitionEntry(title: "Pipeline Latency", body: "If using with video, your AV receiver or display's audio delay/lip-sync setting may need adjustment by the algorithmic latency amount.")
                        Divider()
                        definitionEntry(title: "EQ Headroom Compensation", body: "Predictive static preamp gain, computed from EQ and room-correction filter design data, that backs off input level ahead of time to prevent EQ/correction boosts from clipping. Complements the reactive Dynamic Gain Rider.")
                        Divider()
                        definitionEntry(title: "Multi-Seat Avg.", body: "Composite HRTF correction averaged across multiple listening positions for more robust room correction.")
                        Divider()
                        definitionEntry(
                            title: "FIR Correction",
                            body: "Uniformly-partitioned FFT convolution with a user-supplied WAV/AIFF impulse response. " +
                                  "Supports headphone frequency response correction profiles (AutoEq, manufacturer measurements) " +
                                  "and speaker/room FIR filters exported from measurement systems such as REW. " +
                                  "Processed after the EQ chain. Zero added latency beyond one partition (~43 ms at 48 kHz)."
                        )
                    }
                    .padding(14)
                }
                .frame(width: 290, height: 620)
            }

        }
    }

    // MARK: - Column 1: Signal chain (early stages)

    private var column1: some View {
        VStack(alignment: .leading, spacing: 4) {
            col2ToggleWithSettings(
                label: "Infrasonic",
                isOn: inlineInfrasonicFilterEnabled,
                fullName: "Infrasonic Filter"
            ) {
                DynamicsSliderRow(
                    label: "Frequency",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.infrasonicFilter.cutoffHz) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.infrasonicFilter.cutoffHz = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 10.0...30.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
                HStack(spacing: 8) {
                    Text("Slope")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.infrasonicFilter.slope },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.infrasonicFilter.slope = v; store.updateAdvancedProcessing(adv) }
                    )) {
                        ForEach(InfrasonicFilterConfig.InfrasonicSlope.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("Target")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.infrasonicFilter.target },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.infrasonicFilter.target = v; store.updateAdvancedProcessing(adv) }
                    )) {
                        ForEach(InfrasonicFilterConfig.ApplicationTarget.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            col2ToggleWithSettings(
                label: "Denoiser",
                isOn: inlineDenoisingEnabled,
                fullName: "Linear Denoising Engine"
            ) {
                DynamicsSliderRow(
                    label: "Threshold",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.linearDenoisingThresholdDB) },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.linearDenoisingThresholdDB = Float(v)
                            if adv.linearDenoisingPreset.parameters?.noiseFloorDB != adv.linearDenoisingThresholdDB ||
                               adv.linearDenoisingPreset.parameters?.wienerFloor != adv.denoiserWienerFloor {
                                adv.linearDenoisingPreset = .custom
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    ),
                    range: -80.0...(-20.0),
                    step: 1.0,
                    formatValue: { String(format: "%.0f dB", $0) }
                )
                HStack(spacing: 8) {
                    Text("Preset")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.linearDenoisingPreset },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.linearDenoisingPreset = v
                            if let bundle = v.parameters {
                                adv.linearDenoisingThresholdDB = bundle.noiseFloorDB
                                adv.denoiserWienerFloor        = bundle.wienerFloor
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    )) {
                        ForEach(DenoiserPreset.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("Quality")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.denoiserMode },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.denoiserMode = v; store.updateAdvancedProcessing(adv) }
                    )) {
                        Text("Quality").tag(DenoiserMode.quality)
                        Text("High").tag(DenoiserMode.high)
                        Text("Ultra").tag(DenoiserMode.ultra)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                DynamicsSliderRow(
                    label: "Wiener Floor",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.denoiserWienerFloor) },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.denoiserWienerFloor = Float(v)
                            if adv.linearDenoisingPreset.parameters?.noiseFloorDB != adv.linearDenoisingThresholdDB ||
                               adv.linearDenoisingPreset.parameters?.wienerFloor != adv.denoiserWienerFloor {
                                adv.linearDenoisingPreset = .custom
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    ),
                    range: 0.0...0.2,
                    step: 0.001,
                    formatValue: { String(format: "%.3f", $0) }
                )
                DynamicsSliderRow(
                    label: "Reduction",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.denoiserReductionAmount) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.denoiserReductionAmount = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 0.0...1.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "FIR IR",
                isOn: inlineFirImpulseResponseEnabled,
                fullName: "FIR Impulse Response"
            ) {
                let fir = store.dynamicsConfig.advanced.firImpulseResponse
                if !fir.leftIR.isEmpty {
                    Text("Loaded: \(fir.leftIR.count) taps @ \(Int(fir.sampleRate)) Hz")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No impulse response loaded")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    Button("Load IR…") { openImpulseResponseFile { store.loadFIRImpulseResponse(url: $0) } }
                    if !fir.leftIR.isEmpty {
                        Button("Clear") { store.clearFIRImpulseResponse() }
                    }
                }
            }
            col2Toggle(label: "DC Filter", isOn: inlineDcOffsetEnabled)
            col2ToggleWithSettings(
                label: "Sub Align",
                isOn: inlineSubBassEnabled,
                fullName: "Sub-Bass Phase Alignment"
            ) {
                DynamicsSliderRow(
                    label: "Frequency",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.subBassAlignmentFrequencyHz) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.subBassAlignmentFrequencyHz = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 40.0...120.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
                DynamicsSliderRow(
                    label: "Q",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.subBassPhaseAlignmentQ) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.subBassPhaseAlignmentQ = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 0.5...2.0,
                    step: 0.1,
                    formatValue: { String(format: "%.1f", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "Widener",
                isOn: inlineWideEnabled,
                fullName: "Stereo Widener"
            ) {
                DynamicsSliderRow(
                    label: "Low Width",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.stereoWidener.widthFactorLow) },
                        set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorLow = Float(v); store.updateStereoWidener(c) }
                    ),
                    range: 0.0...1.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f", $0) },
                    leftEndLabel: "Mono",
                    rightEndLabel: "Stereo"
                )
                DynamicsSliderRow(
                    label: "Mid Width",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.stereoWidener.widthFactorMid) },
                        set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorMid = Float(v); store.updateStereoWidener(c) }
                    ),
                    range: 1.0...2.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f", $0) },
                    leftEndLabel: "Stereo",
                    rightEndLabel: "Wide"
                )
                DynamicsSliderRow(
                    label: "High Width",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.stereoWidener.widthFactorHigh) },
                        set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorHigh = Float(v); store.updateStereoWidener(c) }
                    ),
                    range: 1.0...2.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f", $0) },
                    leftEndLabel: "Stereo",
                    rightEndLabel: "Wide"
                )
            }
            col2ToggleWithSettings(
                label: "LUFS",
                isOn: inlineLufsEnabled,
                fullName: "LUFS Loudness Match"
            ) {
                DynamicsSliderRow(
                    label: "Target",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.loudnessMatch.targetLoudnessLUFS) },
                        set: { v in var c = store.dynamicsConfig.loudnessMatch; c.targetLoudnessLUFS = Float(v); store.updateLoudnessMatch(c) }
                    ),
                    range: -24.0...(-10.0),
                    step: 0.5,
                    formatValue: { String(format: "%.1f LUFS", $0) }
                )
                Toggle("Dialogue Gate", isOn: Binding(
                    get: { store.dynamicsConfig.advanced.loudnessDialogueGateEnabled },
                    set: { v in var adv = store.dynamicsConfig.advanced; adv.loudnessDialogueGateEnabled = v; store.updateAdvancedProcessing(adv) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Toggle("Volume-Dependent Loudness", isOn: Binding(
                    get: { store.dynamicsConfig.advanced.volumeDependentLoudnessEnabled },
                    set: { v in var adv = store.dynamicsConfig.advanced; adv.volumeDependentLoudnessEnabled = v; store.updateAdvancedProcessing(adv) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                if store.dynamicsConfig.advanced.volumeDependentLoudnessEnabled {
                    DynamicsSliderRow(
                        label: "Ref. Level",
                        value: Binding(
                            get: { Double(store.dynamicsConfig.advanced.loudnessReferencePhon) },
                            set: { v in var adv = store.dynamicsConfig.advanced; adv.loudnessReferencePhon = Float(v); store.updateAdvancedProcessing(adv) }
                        ),
                        range: 60.0...95.0,
                        step: 1.0,
                        formatValue: { String(format: "%.0f phon", $0) }
                    )
                    DynamicsSliderRow(
                        label: "Ref. Volume",
                        value: Binding(
                            get: { Double(store.dynamicsConfig.advanced.loudnessReferenceVolume) },
                            set: { v in var adv = store.dynamicsConfig.advanced; adv.loudnessReferenceVolume = Float(v); store.updateAdvancedProcessing(adv) }
                        ),
                        range: 0.0...1.0,
                        step: 0.01,
                        formatValue: { String(format: "%.2f", $0) }
                    )
                    DynamicsSliderRow(
                        label: "Strength",
                        value: Binding(
                            get: { Double(store.dynamicsConfig.advanced.loudnessContourStrength) },
                            set: { v in
                                var adv = store.dynamicsConfig.advanced
                                adv.loudnessContourStrength = Float(v)
                                store.updateAdvancedProcessing(adv)
                            }
                        ),
                        range: 0.0...1.0,
                        step: 0.05,
                        formatValue: { String(format: "%.0f%%", $0 * 100) }
                    )
                    // Real-time correction preview — re-evaluates whenever liveSystemVolumeGain changes
                    let _ = store.liveSystemVolumeGain  // observed to trigger re-render on volume change
                    let previewTuple = store.routingCoordinator.pipelineManager.renderPipeline?
                        .callbackContext?.dynamicsProcessor.previewContourGains() ?? (0, 0)
                    let previewBass   = previewTuple.0
                    let previewTreble = previewTuple.1
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current correction")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Text("Bass")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(previewBass == 0
                                    ? "—"
                                    : String(format: "%+.1f dB", previewBass))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(previewBass > 0 ? .primary : .secondary)
                            }
                            HStack(spacing: 4) {
                                Text("Treble")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(previewTreble == 0
                                    ? "—"
                                    : String(format: "%+.1f dB", previewTreble))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(previewTreble > 0 ? .primary : .secondary)
                            }
                            Spacer()
                            if previewBass == 0 && previewTreble == 0 {
                                Text("At reference level")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            col2Toggle(label: "Contour", isOn: inlineLoudnessContourEnabled)
            col2ToggleWithSettings(
                label: "De-Esser",
                isOn: deEsserEnabledBinding,
                fullName: "De-Esser"
            ) {
                DynamicsSliderRow(
                    label: "Frequency",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.deEsser.frequencyHz) },
                        set: { v in var c = store.dynamicsConfig.deEsser; c.frequencyHz = Float(v); store.updateDeEsser(c) }
                    ),
                    range: 2000.0...12000.0,
                    step: 100.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
                DynamicsSliderRow(
                    label: "Detect Q",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.deEsser.detectionQ) },
                        set: { v in var c = store.dynamicsConfig.deEsser; c.detectionQ = Float(v); store.updateDeEsser(c) }
                    ),
                    range: 0.5...8.0,
                    step: 0.1,
                    formatValue: { String(format: "%.1f", $0) }
                )
                DynamicsSliderRow(
                    label: "Threshold",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.deEsser.thresholdDB) },
                        set: { v in var c = store.dynamicsConfig.deEsser; c.thresholdDB = Float(v); store.updateDeEsser(c) }
                    ),
                    range: -60.0...0.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Ratio",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.deEsser.ratio) },
                        set: { v in var c = store.dynamicsConfig.deEsser; c.ratio = Float(v); store.updateDeEsser(c) }
                    ),
                    range: 1.0...10.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f:1", $0) }
                )
                DynamicsSliderRow(
                    label: "Range",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.deEsser.rangeDB) },
                        set: { v in var c = store.dynamicsConfig.deEsser; c.rangeDB = Float(v); store.updateDeEsser(c) }
                    ),
                    range: -24.0...0.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Attack",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.deEsser.attackMs) },
                        set: { v in var c = store.dynamicsConfig.deEsser; c.attackMs = Float(v); store.updateDeEsser(c) }
                    ),
                    range: 0.1...20.0,
                    step: 0.1,
                    formatValue: { String(format: "%.1f ms", $0) }
                )
                DynamicsSliderRow(
                    label: "Release",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.deEsser.releaseMs) },
                        set: { v in var c = store.dynamicsConfig.deEsser; c.releaseMs = Float(v); store.updateDeEsser(c) }
                    ),
                    range: 10.0...300.0,
                    step: 5.0,
                    formatValue: { String(format: "%.0f ms", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "M-Band",
                isOn: mbEnabledBinding,
                fullName: "Multiband Compressor"
            ) {
                DynamicsSliderRow(
                    label: "Low/Mid X-over",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.crossLowMidHz) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.crossLowMidHz = Float(v); store.updateMultibandCompressor(c) }
                    ),
                    range: 60.0...500.0,
                    step: 5.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
                DynamicsSliderRow(
                    label: "Mid/High X-over",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.crossMidHighHz) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.crossMidHighHz = Float(v); store.updateMultibandCompressor(c) }
                    ),
                    range: 1000.0...8000.0,
                    step: 100.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
                DynamicsSliderRow(
                    label: "Sidechain HP",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.sidechainHighPassHz) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.sidechainHighPassHz = Float(v); store.updateMultibandCompressor(c) }
                    ),
                    range: 0.0...300.0,
                    step: 5.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
                DisclosureGroup("Low Band") {
                    DynamicsSliderRow(label: "Threshold", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.thresholdLowDB) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdLowDB = Float(v); store.updateMultibandCompressor(c) }
                    ), range: -60.0...0.0, step: 0.5, formatValue: { String(format: "%.1f dB", $0) })
                    DynamicsSliderRow(label: "Ratio", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.ratioLow) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.ratioLow = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 1.0...20.0, step: 0.5, formatValue: { String(format: "%.1f:1", $0) })
                    DynamicsSliderRow(label: "Attack", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.attackLowMs) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.attackLowMs = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 1.0...200.0, step: 1.0, formatValue: { String(format: "%.0f ms", $0) })
                    DynamicsSliderRow(label: "Release", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.releaseLowMs) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.releaseLowMs = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 10.0...1000.0, step: 10.0, formatValue: { String(format: "%.0f ms", $0) })
                    DynamicsSliderRow(label: "Knee", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.kneeWidthLowDB) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.kneeWidthLowDB = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 0.0...20.0, step: 0.5, formatValue: { String(format: "%.1f dB", $0) })
                }
                DisclosureGroup("Mid Band") {
                    DynamicsSliderRow(label: "Threshold", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.thresholdMidDB) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdMidDB = Float(v); store.updateMultibandCompressor(c) }
                    ), range: -60.0...0.0, step: 0.5, formatValue: { String(format: "%.1f dB", $0) })
                    DynamicsSliderRow(label: "Ratio", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.ratioMid) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.ratioMid = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 1.0...20.0, step: 0.5, formatValue: { String(format: "%.1f:1", $0) })
                    DynamicsSliderRow(label: "Attack", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.attackMidMs) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.attackMidMs = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 1.0...200.0, step: 1.0, formatValue: { String(format: "%.0f ms", $0) })
                    DynamicsSliderRow(label: "Release", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.releaseMidMs) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.releaseMidMs = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 10.0...1000.0, step: 10.0, formatValue: { String(format: "%.0f ms", $0) })
                    DynamicsSliderRow(label: "Knee", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.kneeWidthMidDB) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.kneeWidthMidDB = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 0.0...20.0, step: 0.5, formatValue: { String(format: "%.1f dB", $0) })
                }
                DisclosureGroup("High Band") {
                    DynamicsSliderRow(label: "Threshold", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.thresholdHighDB) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdHighDB = Float(v); store.updateMultibandCompressor(c) }
                    ), range: -60.0...0.0, step: 0.5, formatValue: { String(format: "%.1f dB", $0) })
                    DynamicsSliderRow(label: "Ratio", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.ratioHigh) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.ratioHigh = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 1.0...20.0, step: 0.5, formatValue: { String(format: "%.1f:1", $0) })
                    DynamicsSliderRow(label: "Attack", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.attackHighMs) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.attackHighMs = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 1.0...200.0, step: 1.0, formatValue: { String(format: "%.0f ms", $0) })
                    DynamicsSliderRow(label: "Release", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.releaseHighMs) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.releaseHighMs = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 10.0...1000.0, step: 10.0, formatValue: { String(format: "%.0f ms", $0) })
                    DynamicsSliderRow(label: "Knee", value: Binding(
                        get: { Double(store.dynamicsConfig.multibandCompressor.kneeWidthHighDB) },
                        set: { v in var c = store.dynamicsConfig.multibandCompressor; c.kneeWidthHighDB = Float(v); store.updateMultibandCompressor(c) }
                    ), range: 0.0...20.0, step: 0.5, formatValue: { String(format: "%.1f dB", $0) })
                }
            }
        }
    }

    // MARK: - Column 2: Dynamics + spatial

    private var column2: some View {
        VStack(alignment: .leading, spacing: 4) {
            col2ToggleWithSettings(
                label: "Comp.",
                isOn: compressorEnabledBinding,
                fullName: "Compressor"
            ) {
                DynamicsSliderRow(
                    label: "Threshold",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.compressor.thresholdDB) },
                        set: { v in var c = store.dynamicsConfig.compressor; c.thresholdDB = Float(v); store.updateCompressor(c) }
                    ),
                    range: -60.0...0.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Ratio",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.compressor.ratio) },
                        set: { v in var c = store.dynamicsConfig.compressor; c.ratio = Float(v); store.updateCompressor(c) }
                    ),
                    range: 1.0...20.0,
                    step: 0.1,
                    formatValue: { String(format: "%.1f : 1", $0) }
                )
                DynamicsSliderRow(
                    label: "Knee",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.compressor.kneeWidthDB) },
                        set: { v in var c = store.dynamicsConfig.compressor; c.kneeWidthDB = Float(v); store.updateCompressor(c) }
                    ),
                    range: 0.0...20.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) },
                    leftEndLabel: "Hard",
                    rightEndLabel: "Soft"
                )
                DynamicsSliderRow(
                    label: "Attack",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.compressor.attackMs) },
                        set: { v in var c = store.dynamicsConfig.compressor; c.attackMs = Float(v); store.updateCompressor(c) }
                    ),
                    range: 0.1...100.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f ms", $0) }
                )
                DynamicsSliderRow(
                    label: "Release",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.compressor.releaseMs) },
                        set: { v in var c = store.dynamicsConfig.compressor; c.releaseMs = Float(v); store.updateCompressor(c) }
                    ),
                    range: 5.0...1000.0,
                    step: 5.0,
                    formatValue: { String(format: "%.0f ms", $0) }
                )
                DynamicsSliderRow(
                    label: "Makeup",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.compressor.makeupGainDB) },
                        set: { v in var c = store.dynamicsConfig.compressor; c.makeupGainDB = Float(v); store.updateCompressor(c) }
                    ),
                    range: 0.0...24.0,
                    step: 0.5,
                    formatValue: { String(format: "%+.1f dB", $0) }
                )
                Toggle("Program-Dependent Release", isOn: Binding(
                    get: { store.dynamicsConfig.compressor.programDependentRelease },
                    set: { v in var c = store.dynamicsConfig.compressor; c.programDependentRelease = v; store.updateCompressor(c) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                DynamicsSliderRow(
                    label: "Sidechain HP",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.compressor.sidechainHighPassHz) },
                        set: { v in var c = store.dynamicsConfig.compressor; c.sidechainHighPassHz = Float(v); store.updateCompressor(c) }
                    ),
                    range: 0.0...300.0,
                    step: 5.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "Expander",
                isOn: expanderEnabledBinding,
                fullName: "Expander"
            ) {
                DynamicsSliderRow(
                    label: "Threshold",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.expander.thresholdDB) },
                        set: { v in var c = store.dynamicsConfig.expander; c.thresholdDB = Float(v); store.updateExpander(c) }
                    ),
                    range: -60.0...0.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Ratio",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.expander.ratio) },
                        set: { v in var c = store.dynamicsConfig.expander; c.ratio = Float(v); store.updateExpander(c) }
                    ),
                    range: 1.0...4.0,
                    step: 0.1,
                    formatValue: { String(format: "%.1f : 1", $0) }
                )
                DynamicsSliderRow(
                    label: "Range",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.expander.rangeDB) },
                        set: { v in var c = store.dynamicsConfig.expander; c.rangeDB = Float(v); store.updateExpander(c) }
                    ),
                    range: -40.0...0.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "Bass Mgmt",
                isOn: inlineBassManagementEnabled,
                fullName: "Bass Management"
            ) {
                DynamicsSliderRow(
                    label: "Crossover",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.bassManagement.crossoverHz) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.crossoverHz = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 40.0...200.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f Hz", $0) }
                )
                HStack(spacing: 8) {
                    Text("Slope")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.bassManagement.slope },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.slope = v; store.updateAdvancedProcessing(adv) }
                    )) {
                        ForEach(BassCrossoverSlope.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                DynamicsSliderRow(
                    label: "Sub Gain",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.bassManagement.lowBandGainDB) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.lowBandGainDB = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: -12.0...12.0,
                    step: 0.5,
                    formatValue: { String(format: "%+.1f dB", $0) }
                )
                Toggle("Invert Sub Polarity", isOn: Binding(
                    get: { store.dynamicsConfig.advanced.bassManagement.lowBandPolarityInverted },
                    set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.lowBandPolarityInverted = v; store.updateAdvancedProcessing(adv) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                HStack(spacing: 8) {
                    Text("X-over Type")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.bassManagement.crossoverType },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.crossoverType = v; store.updateAdvancedProcessing(adv) }
                    )) {
                        Text("Linkwitz-Riley").tag(CrossoverType.linkwitzRiley)
                        Text("Butterworth").tag(CrossoverType.butterworth)
                        Text("Bessel").tag(CrossoverType.bessel)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Toggle("Asymmetric Crossover", isOn: Binding(
                    get: { store.dynamicsConfig.advanced.bassManagement.asymmetricCrossoverEnabled },
                    set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.asymmetricCrossoverEnabled = v; store.updateAdvancedProcessing(adv) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                if store.dynamicsConfig.advanced.bassManagement.asymmetricCrossoverEnabled {
                    DynamicsSliderRow(
                        label: "Mains HP",
                        value: Binding(
                            get: { Double(store.dynamicsConfig.advanced.bassManagement.mainsHighPassHz) },
                            set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.mainsHighPassHz = Float(v); store.updateAdvancedProcessing(adv) }
                        ),
                        range: 40.0...200.0,
                        step: 1.0,
                        formatValue: { String(format: "%.0f Hz", $0) }
                    )
                }
                DynamicsSliderRow(
                    label: "Sub Delay",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.bassManagement.lowBandDelaySamples) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.lowBandDelaySamples = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 0.0...500.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f samples", $0) }
                )
                // TODO: Expose lowBandLowShelfEnabled/FreqHz/GainDB, leftSpeakerDistanceM/rightSpeakerDistanceM/subwooferDistanceM, subEQBands
            }
            col2ToggleWithSettings(
                label: "Gain Rider",
                isOn: inlineAutoHeadroomEnabled,
                fullName: "Dynamic Gain Rider"
            ) {
                DynamicsSliderRow(
                    label: "Target GR",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.autoHeadroomTargetGRDB) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.autoHeadroomTargetGRDB = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 0.5...6.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Max Cut",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.autoHeadroomMaxReductionDB) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.autoHeadroomMaxReductionDB = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 3.0...12.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f dB", $0) }
                )
                HStack(spacing: 8) {
                    Text("Response")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.autoHeadroomSpeed },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.autoHeadroomSpeed = v; store.updateAdvancedProcessing(adv) }
                    )) {
                        Text("Fast").tag(AutoHeadroomSpeed.fast)
                        Text("Medium").tag(AutoHeadroomSpeed.medium)
                        Text("Slow").tag(AutoHeadroomSpeed.slow)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("Rider Gain")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(store.liveAutoHeadroomGainDB < -0.05
                         ? String(format: "%+.1f dB", store.liveAutoHeadroomGainDB)
                         : "0.0 dB")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(store.liveAutoHeadroomGainDB < -0.5 ? .orange : .secondary)
                }
            }
            col2ToggleWithSettings(
                label: "Clipper",
                isOn: clipperEnabledBinding,
                fullName: "Clipper"
            ) {
                DynamicsSliderRow(
                    label: "Drive",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.softClipper.driveDB) },
                        set: { v in var sc = store.dynamicsConfig.softClipper; sc.driveDB = Float(v); store.updateSoftClipper(sc) }
                    ),
                    range: 0.0...12.0,
                    step: 0.5,
                    formatValue: { String(format: "%+.1f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Threshold",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.softClipper.thresholdDB) },
                        set: { v in var sc = store.dynamicsConfig.softClipper; sc.thresholdDB = Float(v); store.updateSoftClipper(sc) }
                    ),
                    range: -6.0...0.0,
                    step: 0.1,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Knee",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.softClipper.kneeSmooth) },
                        set: { v in var sc = store.dynamicsConfig.softClipper; sc.kneeSmooth = Float(v); store.updateSoftClipper(sc) }
                    ),
                    range: 0.0...1.0,
                    step: 0.05,
                    formatValue: { String(format: "%.2f", $0) },
                    leftEndLabel: "Hard",
                    rightEndLabel: "Soft"
                )
                HStack(spacing: 8) {
                    Text("Curve")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.softClipper.curveType },
                        set: { v in var sc = store.dynamicsConfig.softClipper; sc.curveType = v; store.updateSoftClipper(sc) }
                    )) {
                        Text("Quadratic").tag(ClipperCurveType.quadratic)
                        Text("Cubic").tag(ClipperCurveType.cubic)
                        Text("Sine").tag(ClipperCurveType.sine)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Toggle("Auto-Compensate Gain", isOn: Binding(
                    get: { store.dynamicsConfig.softClipper.autoCompensateGain },
                    set: { v in var sc = store.dynamicsConfig.softClipper; sc.autoCompensateGain = v; store.updateSoftClipper(sc) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            col2ToggleWithSettings(
                label: "Limiter",
                isOn: limiterEnabledBinding,
                fullName: "Limiter"
            ) {
                DynamicsSliderRow(
                    label: "Ceiling",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.limiter.ceilingDB) },
                        set: { v in var c = store.dynamicsConfig.limiter; c.ceilingDB = Float(v); store.updateLimiter(c) }
                    ),
                    range: -20.0...0.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
                DynamicsSliderRow(
                    label: "Attack",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.limiter.attackMs) },
                        set: { v in var c = store.dynamicsConfig.limiter; c.attackMs = Float(v); store.updateLimiter(c) }
                    ),
                    range: 0.1...50.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f ms", $0) }
                )
                DynamicsSliderRow(
                    label: "Release",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.limiter.releaseMs) },
                        set: { v in var c = store.dynamicsConfig.limiter; c.releaseMs = Float(v); store.updateLimiter(c) }
                    ),
                    range: 5.0...500.0,
                    step: 5.0,
                    formatValue: { String(format: "%.0f ms", $0) }
                )
                DynamicsSliderRow(
                    label: "Look-ahead",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.limiter.lookAheadMs) },
                        set: { v in var c = store.dynamicsConfig.limiter; c.lookAheadMs = Float(v); store.updateLimiter(c) }
                    ),
                    range: 0.0...20.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f ms", $0) }
                )
                Toggle("TP Guard", isOn: Binding(
                    get: { store.dynamicsConfig.advanced.limiterTruePeakGuardEnabled },
                    set: { v in var adv = store.dynamicsConfig.advanced; adv.limiterTruePeakGuardEnabled = v; store.updateAdvancedProcessing(adv) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            col2ToggleWithSettings(
                label: "De-Harsh",
                isOn: inlineDeharshEnabled,
                fullName: "De-Harsh Filter"
            ) {
                DynamicsSliderRow(
                    label: "Tilt Amount",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.deharshTiltAmountDB) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.deharshTiltAmountDB = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: -6.0...0.0,
                    step: 0.5,
                    formatValue: { String(format: "%+.1f dB", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "IR Align",
                isOn: inlineIRAlignmentEnabled,
                fullName: "Speaker IR Alignment"
            ) {
                DynamicsSliderRow(
                    label: "Fine Delay",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.speakerIRDelayMs) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.speakerIRDelayMs = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 0.0...5.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f ms", $0) },
                    leftEndLabel: "0 ms",
                    rightEndLabel: "5 ms"
                )
            }
            col2ToggleWithSettings(
                label: "Sym. Bal.",
                isOn: inlineSymmetryBalanceEnabled,
                fullName: "Symmetry Balance"
            ) {
                DynamicsSliderRow(
                    label: "Balance",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.stereoBalancePosition) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.stereoBalancePosition = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: -1.0...1.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f", $0) },
                    leftEndLabel: "L",
                    rightEndLabel: "R"
                )
            }
            col2ToggleWithSettings(
                label: "Panning",
                isOn: inlinePanningEnabled,
                fullName: "Panning Gain Matrix"
            ) {
                DynamicsSliderRow(
                    label: "Crossfeed",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.panningCrossfeedAmount) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.panningCrossfeedAmount = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 0.0...1.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f", $0) },
                    leftEndLabel: "None",
                    rightEndLabel: "Full"
                )
            }
        }
    }

    // MARK: - Column 3: LTI suite + processing-mode flags

    private var column3: some View {
        VStack(alignment: .leading, spacing: 4) {
            col2ToggleWithSettings(
                label: "Crosstalk",
                isOn: inlineCrosstalkEnabled,
                fullName: "Crosstalk Cancellation Matrix"
            ) {
                DynamicsSliderRow(
                    label: "Amount",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.crosstalkCancellationAmount) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.crosstalkCancellationAmount = Float(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 0.0...1.0,
                    step: 0.01,
                    formatValue: { String(format: "%.2f", $0) },
                    leftEndLabel: "Off",
                    rightEndLabel: "Max"
                )
            }
            col2ToggleWithSettings(
                label: "Pause Gate",
                isOn: inlinePauseGateEnabled,
                fullName: "Pause Gate"
            ) {
                HStack(spacing: 8) {
                    Text("Preset")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { store.dynamicsConfig.advanced.pauseGatePreset },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.pauseGatePreset = v
                            if let bundle = v.parameters {
                                adv.pauseGateThresholdDBFS = bundle.thresholdDBFS
                                adv.pauseGateHoldMs        = bundle.holdMs
                                adv.pauseGateAttackMs      = bundle.attackMs
                                adv.pauseGateReleaseMs     = bundle.releaseMs
                                adv.pauseGateHysteresisDB  = bundle.hysteresisDB
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    )) {
                        ForEach(PauseGatePreset.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                DynamicsSliderRow(
                    label: "Threshold",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.pauseGateThresholdDBFS) },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.pauseGateThresholdDBFS = Float(v)
                            if let bundle = adv.pauseGatePreset.parameters,
                               adv.pauseGateThresholdDBFS != bundle.thresholdDBFS ||
                               adv.pauseGateHoldMs != bundle.holdMs ||
                               adv.pauseGateAttackMs != bundle.attackMs ||
                               adv.pauseGateReleaseMs != bundle.releaseMs ||
                               adv.pauseGateHysteresisDB != bundle.hysteresisDB {
                                adv.pauseGatePreset = .custom
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    ),
                    range: -80.0 ... -40.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f dBFS", $0) },
                    leftEndLabel: "Quiet",
                    rightEndLabel: "Loud"
                )
                DynamicsSliderRow(
                    label: "Hold",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.pauseGateHoldMs) },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.pauseGateHoldMs = Float(v)
                            if let bundle = adv.pauseGatePreset.parameters,
                               adv.pauseGateThresholdDBFS != bundle.thresholdDBFS ||
                               adv.pauseGateHoldMs != bundle.holdMs ||
                               adv.pauseGateAttackMs != bundle.attackMs ||
                               adv.pauseGateReleaseMs != bundle.releaseMs ||
                               adv.pauseGateHysteresisDB != bundle.hysteresisDB {
                                adv.pauseGatePreset = .custom
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    ),
                    range: 100.0 ... 2000.0,
                    step: 50.0,
                    formatValue: { String(format: "%.0f ms", $0) },
                    leftEndLabel: "Tight",
                    rightEndLabel: "Loose"
                )
                DynamicsSliderRow(
                    label: "Attack",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.pauseGateAttackMs) },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.pauseGateAttackMs = Float(v)
                            if let bundle = adv.pauseGatePreset.parameters,
                               adv.pauseGateThresholdDBFS != bundle.thresholdDBFS ||
                               adv.pauseGateHoldMs != bundle.holdMs ||
                               adv.pauseGateAttackMs != bundle.attackMs ||
                               adv.pauseGateReleaseMs != bundle.releaseMs ||
                               adv.pauseGateHysteresisDB != bundle.hysteresisDB {
                                adv.pauseGatePreset = .custom
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    ),
                    range: 1.0...100.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f ms", $0) }
                )
                DynamicsSliderRow(
                    label: "Release",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.pauseGateReleaseMs) },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.pauseGateReleaseMs = Float(v)
                            if let bundle = adv.pauseGatePreset.parameters,
                               adv.pauseGateThresholdDBFS != bundle.thresholdDBFS ||
                               adv.pauseGateHoldMs != bundle.holdMs ||
                               adv.pauseGateAttackMs != bundle.attackMs ||
                               adv.pauseGateReleaseMs != bundle.releaseMs ||
                               adv.pauseGateHysteresisDB != bundle.hysteresisDB {
                                adv.pauseGatePreset = .custom
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    ),
                    range: 10.0...500.0,
                    step: 10.0,
                    formatValue: { String(format: "%.0f ms", $0) }
                )
                DynamicsSliderRow(
                    label: "Hysteresis",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.pauseGateHysteresisDB) },
                        set: { v in
                            var adv = store.dynamicsConfig.advanced
                            adv.pauseGateHysteresisDB = Float(v)
                            if let bundle = adv.pauseGatePreset.parameters,
                               adv.pauseGateThresholdDBFS != bundle.thresholdDBFS ||
                               adv.pauseGateHoldMs != bundle.holdMs ||
                               adv.pauseGateAttackMs != bundle.attackMs ||
                               adv.pauseGateReleaseMs != bundle.releaseMs ||
                               adv.pauseGateHysteresisDB != bundle.hysteresisDB {
                                adv.pauseGatePreset = .custom
                            }
                            store.updateAdvancedProcessing(adv)
                        }
                    ),
                    range: 0.0...10.0,
                    step: 0.5,
                    formatValue: { String(format: "%.1f dB", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "Hi-Res Coef",
                isOn: inlineCoefficientDecouplingEnabled,
                fullName: "Hi-Res Coefficient Decoupling"
            ) {
                HStack(spacing: 8) {
                    Text("Decoupling Active")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(store.dynamicsConfig.advanced.highResDecouplingActive ? "Yes (>96 kHz)" : "No")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(store.dynamicsConfig.advanced.highResDecouplingActive ? .green : .secondary)
                }
            }
            col2Toggle(label: "4x OS", isOn: inlineOversamplingBinding)
            col2Toggle(label: "Sync Buffer", isOn: inlineSyncBufferEnabled)
            col2ToggleWithSettings(
                label: "EQ Headroom",
                isOn: inlineEqHeadroomCompensationEnabled,
                fullName: "EQ Headroom Compensation"
            ) {
                HStack(spacing: 8) {
                    Text("Static Preamp")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", store.staticPreampDB)) dB applied")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            col2ToggleWithSettings(
                label: "Multi-Seat",
                isOn: inlineMultiSeatEnabled,
                fullName: "Multi-Seat Complex Averaging"
            ) {
                DynamicsSliderRow(
                    label: "Seat Count",
                    value: Binding(
                        get: { Double(store.dynamicsConfig.advanced.multiSeatCount) },
                        set: { v in var adv = store.dynamicsConfig.advanced; adv.multiSeatCount = Int(v); store.updateAdvancedProcessing(adv) }
                    ),
                    range: 1.0...8.0,
                    step: 1.0,
                    formatValue: { String(format: "%.0f seats", $0) }
                )
            }
            col2ToggleWithSettings(
                label: "FIR",
                isOn: inlineConvolutionEnabled,
                fullName: "FIR Correction"
            ) {
                if let name = store.convolutionConfig.irDisplayName {
                    Text("Loaded: \(name)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No impulse response loaded")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    Button("Load IR…") { openImpulseResponseFile { store.loadConvolutionIR(url: $0) } }
                    if store.convolutionConfig.irDisplayName != nil {
                        Button("Clear") { store.clearConvolutionIR() }
                    }
                }
                if let errorMessage = store.convolutionLoadError {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }


    // MARK: - Column 4: Pickers only (signal-chain order)

    private var column4: some View {
        VStack(alignment: .leading, spacing: 6) {
            inlineSegmentedPicker(label: "Stereo", selection: inlineStereoModeBinding) {
                Text("Stereo").tag(StereoModeSelection.stereo)
                Text("Wide").tag(StereoModeSelection.wideMono)
                Text("Mono").tag(StereoModeSelection.trueMono)
            }
            inlineSegmentedPicker(label: "Latency", selection: inlineLatencyModeBinding) {
                Text("Music").tag(LatencyMode.music)
                Text("Movie").tag(LatencyMode.movie)
            }
            inlineSegmentedPicker(label: "Dither", selection: inlineDitherModeBinding) {
                Text("Off").tag(DitherMode.bypass)
                Text("TPDF").tag(DitherMode.tpdf)
                Text("Shape").tag(DitherMode.shaped)
                Text("5th").tag(DitherMode.highOrder)
            }
            Divider()
            GainStructureMeterView()
        }
    }

    // MARK: - Column 5: Meters only

    private var column5: some View {
        VStack(alignment: .leading, spacing: 4) {
            InlinePhaseCorrelationView()
            InlineCrestFactorView(bridge: inlineMeterBridge)
            InlineIspLatchView(bridge: inlineMeterBridge)
            InlineDRFactorView(bridge: inlineMeterBridge)
            InlineBitStreamView(bridge: inlineMeterBridge)
            InlineBitRateView()
            InlineTruePeakView(bridge: inlineMeterBridge)
            InlineTruePeakMeterView()
        }
        .frame(minWidth: 110)
    }

    // MARK: - Column 6: Stereo Goniometer

    private var column6: some View {
        VStack(spacing: 8) {
            StereoGoniometerView(engine: store.goniometerEngine, isBypassed: store.isBypassed)
            LatencyReadoutView(
                totalLatencyMs: 0.0,  // TODO: Compute from pipeline stages
                alignmentDelayMs: Double(store.dynamicsConfig.advanced.interChannelDelayMs),
                sampleRate: store.streamSampleRate
            )
        }
    }


    // MARK: - Inline Picker Helper

    @ViewBuilder
    private func inlineSegmentedPicker<S: Hashable, Content: View>(
        label: String,
        selection: Binding<S>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Picker("", selection: selection, content: content)
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    // MARK: - Toggle Helper

    @ViewBuilder
    private func col2Toggle(label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func col2ToggleWithSettings<Content: View>(
        label: String,
        isOn: Binding<Bool>,
        fullName: String,
        @ViewBuilder settings: @escaping () -> Content
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
            DynamicsControlSettingsButton(fullName: fullName, content: settings)
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func definitionEntry(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Text(body).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Column 1 Bindings

    private var deEsserEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.deEsser.isEnabled },
            set: { v in var c = store.dynamicsConfig.deEsser; c.isEnabled = v; store.updateDeEsser(c) }
        )
    }

    private var mbEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.isEnabled = v; store.updateMultibandCompressor(c) }
        )
    }

    private var compressorEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.compressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.compressor; c.isEnabled = v; store.updateCompressor(c) }
        )
    }

    private var expanderEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.expander.isEnabled },
            set: { v in var c = store.dynamicsConfig.expander; c.isEnabled = v; store.updateExpander(c) }
        )
    }

    private var clipperEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.softClipper.isEnabled },
            set: { v in var sc = store.dynamicsConfig.softClipper; sc.isEnabled = v; store.updateSoftClipper(sc) }
        )
    }

    private var limiterEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.limiter.isEnabled },
            set: { v in var lim = store.dynamicsConfig.limiter; lim.isEnabled = v; store.updateLimiter(lim) }
        )
    }

    // MARK: - Column 2 Bindings

    private var inlineWideEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.stereoWidener.isEnabled },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.isEnabled = v; store.updateStereoWidener(c) }
        )
    }

    private var inlineLufsEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.loudnessMatch.isEnabled },
            set: { v in var c = store.dynamicsConfig.loudnessMatch; c.isEnabled = v; store.updateLoudnessMatch(c) }
        )
    }

    private var inlineDeharshEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.deharshFilterEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.deharshFilterEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineLoudnessContourEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.loudnessContourEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.loudnessContourEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    // MARK: - Column 1 Bindings

    private var inlineInfrasonicFilterEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.infrasonicFilter.isEnabled },
            set: { v in
                var adv = store.dynamicsConfig.advanced
                adv.infrasonicFilter.isEnabled = v
                store.updateAdvancedProcessing(adv)
            }
        )
    }

    private var inlineDcOffsetEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.dcOffsetFilterEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.dcOffsetFilterEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineSymmetryBalanceEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.symmetryBalanceEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.symmetryBalanceEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlinePauseGateEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.pauseGateEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.pauseGateEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineSyncBufferEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.hardwareSyncBufferEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.hardwareSyncBufferEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    // MARK: - Column 3 Bindings

    private var inlinePanningEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.panningGainMatrixEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.panningGainMatrixEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineDenoisingEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.linearDenoisingEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.linearDenoisingEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineIRAlignmentEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.speakerIRAlignmentEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.speakerIRAlignmentEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineCrosstalkEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.crosstalkCancellationEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.crosstalkCancellationEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineConvolutionEnabled: Binding<Bool> {
        Binding(
            get: { store.convolutionConfig.enabled },
            set: { store.setConvolutionEnabled($0) }
        )
    }


    // MARK: - IR File Picker

    private func openImpulseResponseFile(onSelect: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff, .audio]
        panel.allowsMultipleSelection = false
        panel.title = "Load Impulse Response"
        panel.message = "Select a WAV or AIFF impulse response (mono or stereo, max 30 s)"
        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url)
        }
    }

    // MARK: - Column 4 Bindings

    private var inlineMultiSeatEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.multiSeatAveragingEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.multiSeatAveragingEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineSubBassEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.subBassPhaseAlignmentEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.subBassPhaseAlignmentEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    // MARK: - Column 5 Bindings

    private var inlineStereoModeBinding: Binding<StereoModeSelection> {
        Binding(
            get: { store.dynamicsConfig.advanced.stereoMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.stereoMode = val; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineCoefficientDecouplingEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.coefficientDecouplingEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.coefficientDecouplingEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineLatencyModeBinding: Binding<LatencyMode> {
        Binding(
            get: { store.dynamicsConfig.advanced.latencyMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.latencyMode = val; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineDitherModeBinding: Binding<DitherMode> {
        Binding(
            get: { store.dynamicsConfig.advanced.ditherMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.ditherMode = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var inlineOversamplingBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.oversamplingEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.oversamplingEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var inlineLinearPhaseEQBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.linearPhaseEQEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.linearPhaseEQEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineFirImpulseResponseEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.firImpulseResponse.enabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.firImpulseResponse.enabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineBassManagementEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.bassManagement.enabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.bassManagement.enabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineAutoHeadroomEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.autoHeadroomEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.autoHeadroomEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineEqHeadroomCompensationEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.eqHeadroomCompensationEnabled },
            set: { v in
                var adv = store.dynamicsConfig.advanced
                adv.eqHeadroomCompensationEnabled = v
                store.updateAdvancedProcessing(adv)
            }
        )
    }
}

// MARK: - Inline Meter Bridge

/// Bridges MeterStore observer callbacks to SwiftUI @Published properties
/// for the analytics metrics and goniometer displays in DynamicsInlineView.
@MainActor
final class InlineMeterBridge: ObservableObject {
    // Input channels
    @Published var peakL: Float = 0
    @Published var peakR: Float = 0
    @Published var rmsL:  Float = 0
    @Published var rmsR:  Float = 0
    // Output channels
    @Published var peakOutL: Float = 0
    @Published var peakOutR: Float = 0
    @Published var rmsOutL:  Float = 0
    @Published var rmsOutR:  Float = 0
    // Latching indicators
    @Published var ispInputLatched:  Bool = false
    @Published var ispOutputLatched: Bool = false

    private let obsPeakL    = BridgeChannelObs()
    private let obsPeakR    = BridgeChannelObs()
    private let obsRmsL     = BridgeChannelObs()
    private let obsRmsR     = BridgeChannelObs()
    private let obsPeakOutL = BridgeChannelObs()
    private let obsPeakOutR = BridgeChannelObs()
    private let obsRmsOutL  = BridgeChannelObs()
    private let obsRmsOutR  = BridgeChannelObs()

    // Store reference for gain reduction metrics
    private weak var store: EqualiserStore?

    // MARK: - Computed Metrics

    /// Input peak-to-RMS crest factor in dB. Higher = more dynamic.
    var crestFactorDb: Float {
        let peak = max(peakL, peakR)
        let rms  = max(rmsL, rmsR)
        guard rms > 0.001 else { return 0 }
        return max(0, 20 * log10(peak / rms))
    }

    /// Output dynamic range factor (peak/RMS) clamped to 0–24 dB.
    var drFactor: Float {
        let peak = max(peakOutL, peakOutR)
        let rms  = max(rmsOutL, rmsOutR)
        guard rms > 0.001 else { return 0 }
        return max(0, min(24, 20 * log10(peak / rms)))
    }

    var truePeakInputClipped:  Bool { max(peakL, peakR) >= 0.9 }
    var truePeakOutputClipped: Bool { max(peakOutL, peakOutR) >= 0.9 }

    /// -1.0 = fully left, 0 = centred, +1.0 = fully right.
    var balance: Float {
        let l = peakL, r = peakR
        guard l + r > 0.001 else { return 0 }
        return (r - l) / (l + r)
    }

    /// 24-bit activity mask — bits lit when set in the quantised peak sample.
    var inputBitMask: UInt32 {
        let p = max(peakL, peakR)
        guard p > 1e-6 else { return 0 }
        let sample24 = UInt32(min(0xFFFFFF, p * 8_388_607.0 + 0.5))
        return sample24
    }

    func resetIspLatches() {
        ispInputLatched  = false
        ispOutputLatched = false
    }

    // MARK: - Registration

    func register(with store: MeterStore, equaliserStore: EqualiserStore?) {
        self.store = equaliserStore
        obsPeakL.onUpdate = { [weak self] v in Task { @MainActor [weak self] in
            self?.peakL = v
            if v > 0.99 { self?.ispInputLatched = true }
        }}
        obsPeakR.onUpdate = { [weak self] v in Task { @MainActor [weak self] in
            self?.peakR = v
            if v > 0.99 { self?.ispInputLatched = true }
        }}
        obsRmsL.onUpdate  = { [weak self] v in Task { @MainActor [weak self] in self?.rmsL  = v } }
        obsRmsR.onUpdate  = { [weak self] v in Task { @MainActor [weak self] in self?.rmsR  = v } }
        obsPeakOutL.onUpdate = { [weak self] v in Task { @MainActor [weak self] in
            self?.peakOutL = v
            if v > 0.99 { self?.ispOutputLatched = true }
        }}
        obsPeakOutR.onUpdate = { [weak self] v in Task { @MainActor [weak self] in
            self?.peakOutR = v
            if v > 0.99 { self?.ispOutputLatched = true }
        }}
        obsRmsOutL.onUpdate = { [weak self] v in Task { @MainActor [weak self] in self?.rmsOutL = v } }
        obsRmsOutR.onUpdate = { [weak self] v in Task { @MainActor [weak self] in self?.rmsOutR = v } }

        store.addObserver(obsPeakL,    for: .inputPeakLeft)
        store.addObserver(obsPeakR,    for: .inputPeakRight)
        store.addObserver(obsRmsL,     for: .inputRMSLeft)
        store.addObserver(obsRmsR,     for: .inputRMSRight)
        store.addObserver(obsPeakOutL, for: .outputPeakLeft)
        store.addObserver(obsPeakOutR, for: .outputPeakRight)
        store.addObserver(obsRmsOutL,  for: .outputRMSLeft)
        store.addObserver(obsRmsOutR,  for: .outputRMSRight)
    }
}

private final class BridgeChannelObs: MeterObserver {
    nonisolated(unsafe) var onUpdate: ((Float) -> Void)?
    nonisolated func meterUpdated(value: Float, hold: Float, clipping: Bool) {
        onUpdate?(value)
    }
}

// MARK: - Inline Crest Factor View

/// Displays the instantaneous peak-to-RMS difference (crest factor) in dB.
struct InlineCrestFactorView: View {
    @ObservedObject var bridge: InlineMeterBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Crest Factor")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f dB", bridge.crestFactorDb))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(crestColor)
            }
        }
    }

    private var crestColor: Color {
        switch bridge.crestFactorDb {
        case ..<8:   return .secondary
        case 8..<16: return .yellow
        default:     return .orange
        }
    }
}

// MARK: - Phase Correlation View

/// Centre-pivoted phase correlation meter: centre = uncorrelated (0),
/// right = in-phase (+1), left = anti-phase (−1).
struct InlinePhaseCorrelationView: View {
    @EnvironmentObject private var store: EqualiserStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let correlation = store.livePhaseCorrelation
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text("Phase")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(String(format: "%+.2f", correlation))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(phaseColour(for: correlation))
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let mid = w / 2
                    let clamped = CGFloat(max(-1, min(1, correlation)))
                    let tipX = mid + clamped * (mid - 1)
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.10))
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 1, height: h)
                            .position(x: mid, y: h / 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(phaseColour(for: correlation).opacity(0.85))
                            .frame(
                                width: max(2, abs(tipX - mid)),
                                height: h - 1
                            )
                            .position(
                                x: mid + (tipX - mid) / 2,
                                y: h / 2
                            )
                    }
                }
                .frame(height: 6)
            }
            .frame(width: 90)
        }
    }

    private func phaseColour(for correlation: Float) -> Color {
        if correlation >= 0.5 { return .green }
        if correlation >= 0   { return .yellow }
        return .red
    }
}

// MARK: - Continuous True Peak Meter (live data wrapper)

/// Live-data wrapper around `TruePeakMeterView`, reading the continuous dBTP
/// measurement and oversampling state from the store at 30 fps.
struct InlineTruePeakMeterView: View {
    @EnvironmentObject private var store: EqualiserStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            TruePeakMeterView(
                truePeakDB: store.liveTruePeakDB,
                isOversampled: store.isOversamplingActive
            )
        }
    }
}

// MARK: - True Peak View

/// Shows a true-peak clip indicator for input and output signals.
struct InlineTruePeakView: View {
    @ObservedObject var bridge: InlineMeterBridge

    var body: some View {
        HStack(spacing: 6) {
            truePeakIndicator(label: "TP-In",  clipped: bridge.truePeakInputClipped)
            truePeakIndicator(label: "TP-Out", clipped: bridge.truePeakOutputClipped)
        }
    }

    @ViewBuilder
    private func truePeakIndicator(label: String, clipped: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(clipped ? Color.red : Color.green.opacity(0.6))
                .frame(width: 12, height: 12)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ISP Latch View

/// Latching over-load indicator. Tap to reset.
struct InlineIspLatchView: View {
    @ObservedObject var bridge: InlineMeterBridge

    var body: some View {
        HStack(spacing: 6) {
            ispIndicator(label: "ISP-In",  latched: bridge.ispInputLatched)
            ispIndicator(label: "ISP-Out", latched: bridge.ispOutputLatched)
        }
        .onTapGesture { bridge.resetIspLatches() }
        .help("Tap to reset over-load latches")
    }

    @ViewBuilder
    private func ispIndicator(label: String, latched: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(latched ? Color.orange : Color.green.opacity(0.6))
                .frame(width: 12, height: 12)
            Text(label)
                .font(.caption)
                .foregroundStyle(latched ? .orange : .secondary)
        }
    }
}

// MARK: - DR Factor View

/// Displays the output dynamic-range factor (output peak-to-RMS ratio).
struct InlineDRFactorView: View {
    @ObservedObject var bridge: InlineMeterBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text("DR Factor")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(String(format: "%.1f dB", bridge.drFactor))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(drColor)
            }
        }
    }

    private var drColor: Color {
        switch bridge.drFactor {
        case ..<8:    return .secondary
        case 8..<16:  return .yellow
        default:      return .orange
        }
    }
}

// MARK: - Bit Stream View

/// 24-bit activity monitor — one LED per bit, lit when that bit carries energy.
struct InlineBitStreamView: View {
    @ObservedObject var bridge: InlineMeterBridge
    private let bitCount = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Bit Stream")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 1) {
                ForEach(0..<bitCount, id: \.self) { bit in
                    let active = (bridge.inputBitMask >> UInt32(bitCount - 1 - bit)) & 1 == 1
                    RoundedRectangle(cornerRadius: 1)
                        .fill(active ? bitColor(bit: bit) : Color.secondary.opacity(0.12))
                        .frame(width: 3, height: 8)
                }
            }
        }
    }

    private func bitColor(bit: Int) -> Color {
        if bit < 4  { return .red }      // Top 4 bits (loudest)
        if bit < 12 { return .yellow }   // Mid 8 bits
        return .green                    // Lower bits (quiet detail)
    }
}

// MARK: - Bit Rate View

/// Displays the nominal audio bit rate based on standard CD/HD formats.
struct InlineBitRateView: View {
    @EnvironmentObject private var store: EqualiserStore

    private let bitsPerSample = 32

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let sr = store.streamSampleRate
            let kbps = Int(sr * Double(bitsPerSample) * 2.0 / 1000.0)
            let srText = sr >= 1000
                ? String(format: "%.0f kHz", sr / 1000)
                : String(format: "%.0f Hz", sr)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sample Rate")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(srText)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(kbps) kbps")
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Preview

// #Preview("Dynamics Panel") {
//     DynamicsView()
//         .environmentObject(EqualiserStore())
// }

// #Preview("Dynamics Inline") {
//     DynamicsInlineView()
//         .environmentObject(EqualiserStore())
//         .padding()
// }
