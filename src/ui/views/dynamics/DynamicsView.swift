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
    @FocusState private var isFieldFocused: Bool

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

            Slider(value: $value, in: range)
                .controlSize(.small)
                .onChange(of: value) { _, newVal in
                    if !isFieldFocused {
                        textValue = formatValue(newVal)
                    }
                }

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
                .onSubmit { commitTextEdit() }
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused { commitTextEdit() }
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
/// Six-column layout (max 8 toggles per column):
///   Col 1 — core dynamics chain stages, in signal-chain order
///   Col 2 — later dynamics + spatial stages
///   Col 3 — LTI processing + global processing-mode flags
///   Col 4 — Segmented pickers (stereo / latency / dither)
///   Col 5 — Analytics meters
///   Col 6 — Goniometer
struct DynamicsInlineView: View {
    @EnvironmentObject var store: EqualiserStore

    @State private var showDynamicsPanel = false
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
                        definitionEntry(title: "Hi-Res Coef", body: "Enables high-resolution coefficient decoupling for per-sample filter updates at the cost of higher CPU.")
                        Divider()
                        definitionEntry(title: "DC Filter", body: "0.5 Hz single-pole high-pass removing DC bias before the dynamics chain.")
                        Divider()
                        definitionEntry(title: "Stereo Widener", body: "Three-band M/S processor that independently adjusts stereo width in the Low (< 200 Hz), Mid (200 Hz – 4 kHz), and High (> 4 kHz) regions.")
                        Divider()
                        definitionEntry(title: "LUFS Loudness Match", body: "Measures 3-second K-weighted loudness and continuously adjusts gain to hit the target LUFS level.")
                        Divider()
                        definitionEntry(title: "Loudness Contour", body: "Fletcher-Munson compensation curve adding gentle bass and treble lift for low-level listening.")
                        Divider()
                        definitionEntry(title: "4x Oversampling", body: "Upsamples audio by 4× before EQ and downsamples after EQ. Improves high-frequency response and reduces aliasing artifacts.")
                        Divider()
                        definitionEntry(title: "De-Esser", body: "Tames harsh, high-frequency sibilance by applying frequency-selective gain reduction around a tunable centre frequency.")
                        Divider()
                        definitionEntry(title: "Multiband Compressor", body: "Independently controls the dynamics of three separate frequency bands using Linkwitz-Riley crossovers.")
                        Divider()
                        // Column 2 — later dynamics + spatial
                        definitionEntry(title: "Expander", body: "Downward dynamic-range expander. Widens perceived dynamics by attenuating signals below threshold.")
                        Divider()
                        definitionEntry(title: "Clipper", body: "Analogue-style wave-shaper that gently rounds transient peaks before the limiter.")
                        Divider()
                        definitionEntry(title: "Limiter", body: "Look-ahead true peak limiter. Guarantees the output cannot exceed the ceiling.")
                        Divider()
                        definitionEntry(title: "De-Harsh", body: "High-frequency tilt filter attenuating above ~3.5 kHz to reduce tweeter fatigue.")
                        Divider()
                        definitionEntry(title: "Pause Gate", body: "Silences output when signal falls below the threshold for the Hold duration, then reopens at the Resume Speed when audio returns. Use the Preset picker or tune individually to match your amplifier and listening habits.")
                        Divider()
                        definitionEntry(title: "Sync Buffer", body: "Synchronises processing buffer to latency mode, preventing dropouts at low latency settings.")
                        Divider()
                        definitionEntry(title: "Pipeline Latency", body: "If using with video, your AV receiver or display's audio delay/lip-sync setting may need adjustment by the algorithmic latency amount.")
                        Divider()
                        definitionEntry(title: "Symmetry Balance", body: "Gain-matrix correction for asymmetric listening positions. Aligns L/R loudness at the ear.")
                        Divider()
                        definitionEntry(title: "Panning Gain Matrix", body: "Bilinear crossfeed matrix blending a proportion of each channel into the opposite channel.")
                        Divider()
                        // Column 3 — LTI suite
                        definitionEntry(title: "Denoiser", body: "Spectral subtraction noise floor reduction using a running noise power estimate.")
                        Divider()
                        definitionEntry(title: "IR Alignment", body: "Fractional-sample delay compensation for multi-driver speaker acoustic centres.")
                        Divider()
                        definitionEntry(title: "Crosstalk Cancel.", body: "Recursive binaural inversion filter reducing inter-channel acoustic leakage between speakers.")
                        Divider()
                        definitionEntry(title: "Sub-Bass Align", body: "All-pass network phase-aligning sub-bass with main speaker bandwidth at the crossover frequency.")
                        Divider()
                        definitionEntry(title: "Room Correction", body: "Applies inverse filter to match a target response curve. Requires REW measurement import for accurate room correction.")
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
            col2Toggle(label: "Infrasonic",  isOn: inlineInfrasonicFilterEnabled)
            col2Toggle(label: "Hi-Res Coef", isOn: inlineCoefficientDecouplingEnabled)
            col2Toggle(label: "DC Filter",   isOn: inlineDcOffsetEnabled)
            col2Toggle(label: "Widener",     isOn: inlineWideEnabled)
            col2Toggle(label: "LUFS",        isOn: inlineLufsEnabled)
            col2Toggle(label: "Contour",     isOn: inlineLoudnessContourEnabled)
            col2Toggle(label: "De-Esser",    isOn: deEsserEnabledBinding)
            col2Toggle(label: "M-Band",      isOn: mbEnabledBinding)
        }
    }

    // MARK: - Column 2: Dynamics + spatial

    private var column2: some View {
        VStack(alignment: .leading, spacing: 4) {
            col2Toggle(label: "Comp.",       isOn: compressorEnabledBinding)
            col2Toggle(label: "Expander",    isOn: expanderEnabledBinding)
            col2Toggle(label: "Clipper",     isOn: clipperEnabledBinding)
            col2Toggle(label: "Limiter",     isOn: limiterEnabledBinding)
            col2Toggle(label: "De-Harsh",    isOn: inlineDeharshEnabled)
            col2Toggle(label: "Pause Gate",  isOn: inlinePauseGateEnabled)
            col2Toggle(label: "Sync Buffer", isOn: inlineSyncBufferEnabled)
            col2Toggle(label: "Sym. Bal.",   isOn: inlineSymmetryBalanceEnabled)
        }
    }

    // MARK: - Column 3: LTI suite

    private var column3: some View {
        VStack(alignment: .leading, spacing: 4) {
            col2Toggle(label: "Denoiser",    isOn: inlineDenoisingEnabled)
            col2Toggle(label: "IR Align",    isOn: inlineIRAlignmentEnabled)
            col2Toggle(label: "Crosstalk",   isOn: inlineCrosstalkEnabled)
            col2Toggle(label: "Rm. Correct.", isOn: inlineRoomCorrectionBinding)
            col2Toggle(label: "Sub Align",   isOn: inlineSubBassEnabled)
            col2Toggle(label: "FIR",         isOn: inlineConvolutionEnabled)
            col2Toggle(label: "4x OS",       isOn: inlineOversamplingBinding)
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
            TruePeakMeterView(truePeakDB: -90.0, isOversampled: false)
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
    private var inlineRoomCorrectionBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.roomCorrectionEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.roomCorrectionEnabled = val; store.updateAdvancedProcessing(adv) }
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
