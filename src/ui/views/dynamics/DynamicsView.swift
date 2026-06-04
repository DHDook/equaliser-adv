// DynamicsView.swift
// Controls for the full dynamics processor chain:
// Stereo Widener → LUFS Loudness Match → De-Esser → Multiband Compressor
// → Compressor → Expander → Soft Clipper → Brickwall Limiter
// → LTI Processing Suite.
// Layout: two-column form to minimise scrolling.

import AppKit
import SwiftUI

// MARK: - Main View

/// Panel for configuring the full dynamics chain.
/// Reads and writes through `EqualiserStore.dynamicsConfig` so all changes
/// are propagated atomically to the audio thread while running.
struct DynamicsView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dynamics")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    // ── Left column ──────────────────────────────────────────
                    Form {
                        stereoWidenerSection
                        deEsserSection
                        multibandSection
                        compressorSection
                        expanderSection
                        ltiSymmetrySection
                        ltiPanningSection
                        ltiIRAlignmentSection
                        ltiCrosstalkSection
                        ltiMultiSeatSection
                    }
                    .formStyle(.grouped)
                    .frame(width: 460)

                    // ── Right column ─────────────────────────────────────────
                    Form {
                        loudnessMatchSection
                        clipperSection
                        limiterSection
                        stereoMatrixSection
                        spectralEnhancementSection
                        systemUtilitiesSection
                        ltiDenoisingSection
                        ltiEarlyReflectionSection
                        ltiHPFLinearizationSection
                        ltiSubBassSection
                        ltiZLReverbSection
                    }
                    .formStyle(.grouped)
                    .frame(width: 460)
                }
            }
        }
        .frame(width: 940)
        .frame(minHeight: 640)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: - Stereo Widener Section

    private var stereoWidenerSection: some View {
        Section {
            Toggle("Enabled", isOn: stereoWidenerEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Low Width",
                value: widthLow,
                range: 0.0...1.0,
                step: 0.05,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Mono",
                rightEndLabel: "Stereo",
                isDisabled: !store.dynamicsConfig.stereoWidener.isEnabled
            )

            DynamicsSliderRow(
                label: "Mid Width",
                value: widthMid,
                range: 1.0...2.0,
                step: 0.05,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Narrow",
                rightEndLabel: "Wide",
                isDisabled: !store.dynamicsConfig.stereoWidener.isEnabled
            )

            DynamicsSliderRow(
                label: "High Width",
                value: widthHigh,
                range: 1.0...2.0,
                step: 0.05,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Narrow",
                rightEndLabel: "Wide",
                isDisabled: !store.dynamicsConfig.stereoWidener.isEnabled
            )
        } header: {
            Text("Stereo Widener")
        }
    }

    // MARK: - De-Esser Section

    private var deEsserSection: some View {
        Section {
            Toggle("Enabled", isOn: deEsserEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Frequency",
                value: deEsserFreq,
                range: 2000.0...10000.0,
                step: 100.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.deEsser.isEnabled
            )

            DynamicsSliderRow(
                label: "Threshold",
                value: deEsserThreshold,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.deEsser.isEnabled
            )

            Toggle("Dynamic EQ Mode", isOn: deesserDynModeBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))
                .disabled(!store.dynamicsConfig.deEsser.isEnabled)
                .opacity(!store.dynamicsConfig.deEsser.isEnabled ? 0.4 : 1.0)
        } header: {
            Text("De-Esser")
        }
    }

    // MARK: - Multiband Compressor Section

    private var multibandSection: some View {
        Section {
            Toggle("Enabled", isOn: mbEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Low / Mid",
                value: mbCrossLowMid,
                range: 40.0...250.0,
                step: 5.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            HStack(spacing: 8) {
                Text("LM Slope")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: mbSlopeLowMid) {
                    Text("Gentle (24 dB/oct)").tag(CrossoverSlope.gentle)
                    Text("Steep (48 dB/oct)").tag(CrossoverSlope.steep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(!store.dynamicsConfig.multibandCompressor.isEnabled)
            .opacity(!store.dynamicsConfig.multibandCompressor.isEnabled ? 0.4 : 1.0)

            DynamicsSliderRow(
                label: "Mid / High",
                value: mbCrossMidHigh,
                range: 1000.0...8000.0,
                step: 100.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            HStack(spacing: 8) {
                Text("MH Slope")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: mbSlopeMidHigh) {
                    Text("Gentle (24 dB/oct)").tag(CrossoverSlope.gentle)
                    Text("Steep (48 dB/oct)").tag(CrossoverSlope.steep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(!store.dynamicsConfig.multibandCompressor.isEnabled)
            .opacity(!store.dynamicsConfig.multibandCompressor.isEnabled ? 0.4 : 1.0)

            DynamicsSliderRow(
                label: "Low Thresh",
                value: mbThreshLow,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Mid Thresh",
                value: mbThreshMid,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )

            DynamicsSliderRow(
                label: "High Thresh",
                value: mbThreshHigh,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.multibandCompressor.isEnabled
            )
        } header: {
            Text("Multiband Compressor")
        }
    }

    // MARK: - Compressor Section

    private var compressorSection: some View {
        Section {
            Toggle("Enabled", isOn: compressorEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Threshold",
                value: compressorThreshold,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Ratio",
                value: compressorRatio,
                range: 1.0...20.0,
                step: 0.1,
                formatValue: { String(format: "%.1f : 1", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Knee",
                value: compressorKneeWidth,
                range: 0.0...20.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                leftEndLabel: "Hard",
                rightEndLabel: "Soft",
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Attack",
                value: compressorAttack,
                range: 0.1...100.0,
                step: 0.5,
                formatValue: { String(format: "%.1f ms", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Release",
                value: compressorRelease,
                range: 5.0...1000.0,
                step: 5.0,
                formatValue: { String(format: "%.0f ms", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )

            DynamicsSliderRow(
                label: "Makeup",
                value: compressorMakeup,
                range: 0.0...24.0,
                step: 0.5,
                formatValue: { String(format: "%+.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.compressor.isEnabled
            )
        } header: {
            Text("Compressor")
        }
    }

    // MARK: - Expander Section

    private var expanderSection: some View {
        Section {
            Toggle("Enabled", isOn: expanderEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Threshold",
                value: expanderThreshold,
                range: -60.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.expander.isEnabled
            )

            DynamicsSliderRow(
                label: "Ratio",
                value: expanderRatio,
                range: 1.0...4.0,
                step: 0.1,
                formatValue: { String(format: "%.1f : 1", $0) },
                isDisabled: !store.dynamicsConfig.expander.isEnabled
            )

            DynamicsSliderRow(
                label: "Range",
                value: expanderRange,
                range: -40.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.expander.isEnabled
            )
        } header: {
            Text("Expander")
        }
    }

    // MARK: - LTI: Symmetry Balance Section

    private var ltiSymmetrySection: some View {
        Section {
            Toggle("Enabled", isOn: ltiSymmetryEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Balance",
                value: balanceBinding,
                range: -1.0...1.0,
                step: 0.01,
                formatValue: { val in
                    if val < -0.01 { return String(format: "%.0f%% L", -val * 100) }
                    if val >  0.01 { return String(format: "%.0f%% R",  val * 100) }
                    return "Centre"
                },
                leftEndLabel: "L",
                rightEndLabel: "R",
                isDisabled: !store.dynamicsConfig.advanced.symmetryBalanceEnabled
            )
        } header: {
            Text("Symmetry Balance")
        }
    }

    // MARK: - LTI: Panning Gain Matrix Section

    private var ltiPanningSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiPanningEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Crossfeed",
                value: ltiPanningCrossfeedBinding,
                range: 0.0...1.0,
                step: 0.01,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "None",
                rightEndLabel: "Full",
                isDisabled: !store.dynamicsConfig.advanced.panningGainMatrixEnabled
            )
        } header: {
            Text("Panning Gain Matrix")
        }
    }

    // MARK: - LTI: Speaker IR Alignment Section

    private var ltiIRAlignmentSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiIRAlignmentEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Fine Delay",
                value: ltiIRDelayBinding,
                range: 0.0...5.0,
                step: 0.01,
                formatValue: { String(format: "%.2f ms", $0) },
                leftEndLabel: "0 ms",
                rightEndLabel: "5 ms",
                isDisabled: !store.dynamicsConfig.advanced.speakerIRAlignmentEnabled
            )
        } header: {
            Text("Speaker IR Alignment")
        }
    }

    // MARK: - LTI: Crosstalk Cancellation Section

    private var ltiCrosstalkSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiCrosstalkEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Amount",
                value: ltiCrosstalkAmountBinding,
                range: 0.0...1.0,
                step: 0.01,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Off",
                rightEndLabel: "Max",
                isDisabled: !store.dynamicsConfig.advanced.crosstalkCancellationEnabled
            )
        } header: {
            Text("Crosstalk Cancellation Matrix")
        }
    }

    // MARK: - LTI: Multi-Seat Averaging Section

    private var ltiMultiSeatSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiMultiSeatEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Seat Count",
                value: ltiMultiSeatCountBinding,
                range: 1.0...8.0,
                step: 1.0,
                formatValue: { String(format: "%.0f seats", $0) },
                isDisabled: !store.dynamicsConfig.advanced.multiSeatAveragingEnabled
            )
        } header: {
            Text("Multi-Seat Complex Averaging")
        }
    }

    // MARK: - Loudness Match Section

    private var loudnessMatchSection: some View {
        Section {
            Toggle("Enabled", isOn: loudnessMatchEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Target",
                value: targetLUFS,
                range: -24.0...(-10.0),
                step: 0.5,
                formatValue: { String(format: "%.1f LUFS", $0) },
                isDisabled: !store.dynamicsConfig.loudnessMatch.isEnabled
            )

            Toggle("Dialogue Gate", isOn: dialogueGateBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))
                .disabled(!store.dynamicsConfig.loudnessMatch.isEnabled)
                .opacity(!store.dynamicsConfig.loudnessMatch.isEnabled ? 0.4 : 1.0)
        } header: {
            Text("LUFS Loudness Match")
        }
    }

    // MARK: - Clipper Section

    private var clipperSection: some View {
        Section {
            Toggle("Enabled", isOn: softClipperEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Drive",
                value: softClipperDrive,
                range: -6.0...18.0,
                step: 0.5,
                formatValue: { String(format: "%+.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )

            DynamicsSliderRow(
                label: "Threshold",
                value: softClipperThreshold,
                range: -12.0...0.0,
                step: 0.1,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )

            DynamicsSliderRow(
                label: "Knee",
                value: softClipperKnee,
                range: 0.001...1.0,
                step: 0.001,
                formatValue: { String(format: "%.3f", $0) },
                leftEndLabel: "Soft",
                rightEndLabel: "Hard",
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )

            DynamicsSliderRow(
                label: "Asym. Trim",
                value: asymmetryTrimBinding,
                range: -3.0...3.0,
                step: 0.1,
                formatValue: { String(format: "%+.1f dB", $0) },
                leftEndLabel: "−",
                rightEndLabel: "+",
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )
        } header: {
            Text("Clipper")
        }
    }

    // MARK: - Limiter Section

    private var limiterSection: some View {
        Section {
            Toggle("Enabled", isOn: limiterEnabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Ceiling",
                value: limiterCeiling,
                range: -6.0...0.0,
                step: 0.1,
                formatValue: { String(format: "%.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            DynamicsSliderRow(
                label: "Attack",
                value: limiterAttack,
                range: 0.0...10.0,
                step: 0.1,
                formatValue: { String(format: "%.1f ms", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            DynamicsSliderRow(
                label: "Release",
                value: limiterRelease,
                range: 5.0...250.0,
                step: 1.0,
                formatValue: { String(format: "%.0f ms", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            DynamicsSliderRow(
                label: "Look-ahead",
                value: limiterLookAhead,
                range: 0.5...10.0,
                step: 0.5,
                formatValue: { String(format: "%.1f ms", $0) },
                isDisabled: !store.dynamicsConfig.limiter.isEnabled
            )

            Toggle("TP Guard", isOn: tpGuardBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))
                .disabled(!store.dynamicsConfig.limiter.isEnabled)
                .opacity(!store.dynamicsConfig.limiter.isEnabled ? 0.4 : 1.0)
        } header: {
            Text("Limiter")
        }
    }

    // MARK: - Stereo Matrix Section

    private var stereoMatrixSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Stereo Mode")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: stereoModeBinding) {
                    Text("Stereo").tag(StereoModeSelection.stereo)
                    Text("Wide Mono").tag(StereoModeSelection.wideMono)
                    Text("True Mono").tag(StereoModeSelection.trueMono)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            DynamicsSliderRow(
                label: "L/R Delay",
                value: timeDelayBinding,
                range: 0.0...20.0,
                step: 0.1,
                formatValue: { String(format: "%.1f ms", $0) }
            )
        } header: {
            Text("Stereo Matrix")
        }
    }

    // MARK: - Spectral Enhancement Section

    private var spectralEnhancementSection: some View {
        Section {
            Toggle("Loudness Contouring", isOn: loudnessContourBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("De-Harsh Filter", isOn: deharshEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Tilt Amount",
                value: deharshTiltBinding,
                range: -6.0...0.0,
                step: 0.5,
                formatValue: { String(format: "%+.1f dB", $0) },
                isDisabled: !store.dynamicsConfig.advanced.deharshFilterEnabled
            )
        } header: {
            Text("Spectral Enhancement")
        }
    }

    // MARK: - System Utilities Section

    private var systemUtilitiesSection: some View {
        Section {
            Toggle("Hi-Res Coef. Decoupling", isOn: coefficientDecouplingBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            HStack(spacing: 8) {
                Text("Decoupling Active")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Text(store.dynamicsConfig.advanced.highResDecouplingActive ? "Yes (>96 kHz)" : "No")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(store.dynamicsConfig.advanced.highResDecouplingActive ? .green : .secondary)
                Spacer()
            }

            Toggle("DC Offset Filter", isOn: dcOffsetEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            HStack(spacing: 8) {
                Text("Latency Mode")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: latencyModeBinding) {
                    Text("Music").tag(LatencyMode.music)
                    Text("Movie").tag(LatencyMode.movie)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("Dither")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: ditherModeBinding) {
                    Text("Off").tag(DitherMode.bypass)
                    Text("TPDF").tag(DitherMode.tpdf)
                    Text("Shaped").tag(DitherMode.shaped)
                    Text("5th-Order").tag(DitherMode.highOrder)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Pause Gate", isOn: pauseGateBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("4x Oversampling", isOn: oversamplingBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("Linear-Phase EQ", isOn: linearPhaseEQBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("Room Correction", isOn: roomCorrectionBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            Toggle("Multi-Seat Averaging", isOn: multiSeatBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))
                .disabled(!store.dynamicsConfig.advanced.roomCorrectionEnabled)

            Toggle("Sync Buffer to Latency Mode", isOn: syncBufferBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))
        } header: {
            Text("System Utilities")
        }
    }

    // MARK: - LTI: Linear Denoising Section

    private var ltiDenoisingSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiDenoisingEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Threshold",
                value: ltiDenoisingThresholdBinding,
                range: -80.0...(-40.0),
                step: 1.0,
                formatValue: { String(format: "%.0f dB", $0) },
                isDisabled: !store.dynamicsConfig.advanced.linearDenoisingEnabled
            )
        } header: {
            Text("Linear Denoising Engine")
        }
    }

    // MARK: - LTI: Early Reflection Cancellation Section

    private var ltiEarlyReflectionSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiEarlyReflectionEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Room Size",
                value: ltiEarlyReflectionRoomSizeBinding,
                range: 5.0...50.0,
                step: 0.5,
                formatValue: { String(format: "%.1f ms", $0) },
                leftEndLabel: "Small",
                rightEndLabel: "Large",
                isDisabled: !store.dynamicsConfig.advanced.earlyReflectionCancellationEnabled
            )
        } header: {
            Text("Early Reflection Cancellation")
        }
    }

    // MARK: - LTI: HPF Phase Linearisation Section

    private var ltiHPFLinearizationSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiHPFLinearizationEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Frequency",
                value: ltiHPFLinearizationFreqBinding,
                range: 20.0...200.0,
                step: 1.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.advanced.hpfPhaseLinearizationEnabled
            )
        } header: {
            Text("HPF Phase Linearisation")
        }
    }

    // MARK: - LTI: Sub-Bass Phase Alignment Section

    private var ltiSubBassSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiSubBassEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Crossover",
                value: ltiSubBassFreqBinding,
                range: 40.0...120.0,
                step: 1.0,
                formatValue: { String(format: "%.0f Hz", $0) },
                isDisabled: !store.dynamicsConfig.advanced.subBassPhaseAlignmentEnabled
            )
        } header: {
            Text("Sub-Bass Phase Alignment")
        }
    }

    // MARK: - LTI: Zero-Latency Convolution Reverb Section

    private var ltiZLReverbSection: some View {
        Section {
            Toggle("Enabled", isOn: ltiZLReverbEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.system(size: 13))

            DynamicsSliderRow(
                label: "Dry / Wet",
                value: ltiZLReverbMixBinding,
                range: 0.0...1.0,
                step: 0.01,
                formatValue: { String(format: "%.2f", $0) },
                leftEndLabel: "Dry",
                rightEndLabel: "Wet",
                isDisabled: !store.dynamicsConfig.advanced.zlConvolutionReverbEnabled
            )
        } header: {
            Text("ZL Convolution Reverb")
        }
    }

    // MARK: - Stereo Widener Bindings

    private var stereoWidenerEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.stereoWidener.isEnabled },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.isEnabled = v; store.updateStereoWidener(c) }
        )
    }

    private var widthLow: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.stereoWidener.widthFactorLow) },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorLow = Float(v); store.updateStereoWidener(c) }
        )
    }

    private var widthMid: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.stereoWidener.widthFactorMid) },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorMid = Float(v); store.updateStereoWidener(c) }
        )
    }

    private var widthHigh: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.stereoWidener.widthFactorHigh) },
            set: { v in var c = store.dynamicsConfig.stereoWidener; c.widthFactorHigh = Float(v); store.updateStereoWidener(c) }
        )
    }

    // MARK: - Loudness Match Bindings

    private var loudnessMatchEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.loudnessMatch.isEnabled },
            set: { v in var c = store.dynamicsConfig.loudnessMatch; c.isEnabled = v; store.updateLoudnessMatch(c) }
        )
    }

    private var targetLUFS: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.loudnessMatch.targetLoudnessLUFS) },
            set: { v in var c = store.dynamicsConfig.loudnessMatch; c.targetLoudnessLUFS = Float(v); store.updateLoudnessMatch(c) }
        )
    }

    // MARK: - De-Esser Bindings

    private var deEsserEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.deEsser.isEnabled },
            set: { v in var c = store.dynamicsConfig.deEsser; c.isEnabled = v; store.updateDeEsser(c) }
        )
    }

    private var deEsserFreq: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.deEsser.frequencyHz) },
            set: { v in var c = store.dynamicsConfig.deEsser; c.frequencyHz = Float(v); store.updateDeEsser(c) }
        )
    }

    private var deEsserThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.deEsser.thresholdDB) },
            set: { v in var c = store.dynamicsConfig.deEsser; c.thresholdDB = Float(v); store.updateDeEsser(c) }
        )
    }

    // MARK: - Multiband Bindings

    private var mbEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.isEnabled = v; store.updateMultibandCompressor(c) }
        )
    }

    private var mbCrossLowMid: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.crossLowMidHz) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.crossLowMidHz = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbCrossMidHigh: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.crossMidHighHz) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.crossMidHighHz = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbThreshLow: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.thresholdLowDB) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdLowDB = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbThreshMid: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.thresholdMidDB) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdMidDB = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbThreshHigh: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.multibandCompressor.thresholdHighDB) },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.thresholdHighDB = Float(v); store.updateMultibandCompressor(c) }
        )
    }

    private var mbSlopeLowMid: Binding<CrossoverSlope> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.slopeLowMid },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.slopeLowMid = v; store.updateMultibandCompressor(c) }
        )
    }

    private var mbSlopeMidHigh: Binding<CrossoverSlope> {
        Binding(
            get: { store.dynamicsConfig.multibandCompressor.slopeMidHigh },
            set: { v in var c = store.dynamicsConfig.multibandCompressor; c.slopeMidHigh = v; store.updateMultibandCompressor(c) }
        )
    }

    // MARK: - Compressor Bindings

    private var compressorEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.compressor.isEnabled },
            set: { v in var c = store.dynamicsConfig.compressor; c.isEnabled = v; store.updateCompressor(c) }
        )
    }

    private var compressorThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.thresholdDB) },
            set: { v in var c = store.dynamicsConfig.compressor; c.thresholdDB = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorRatio: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.ratio) },
            set: { v in var c = store.dynamicsConfig.compressor; c.ratio = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorKneeWidth: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.kneeWidthDB) },
            set: { v in var c = store.dynamicsConfig.compressor; c.kneeWidthDB = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorAttack: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.attackMs) },
            set: { v in var c = store.dynamicsConfig.compressor; c.attackMs = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorRelease: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.releaseMs) },
            set: { v in var c = store.dynamicsConfig.compressor; c.releaseMs = Float(v); store.updateCompressor(c) }
        )
    }

    private var compressorMakeup: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.compressor.makeupGainDB) },
            set: { v in var c = store.dynamicsConfig.compressor; c.makeupGainDB = Float(v); store.updateCompressor(c) }
        )
    }

    // MARK: - Expander Bindings

    private var expanderEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.expander.isEnabled },
            set: { v in var c = store.dynamicsConfig.expander; c.isEnabled = v; store.updateExpander(c) }
        )
    }

    private var expanderThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.expander.thresholdDB) },
            set: { v in var c = store.dynamicsConfig.expander; c.thresholdDB = Float(v); store.updateExpander(c) }
        )
    }

    private var expanderRatio: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.expander.ratio) },
            set: { v in var c = store.dynamicsConfig.expander; c.ratio = Float(v); store.updateExpander(c) }
        )
    }

    private var expanderRange: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.expander.rangeDB) },
            set: { v in var c = store.dynamicsConfig.expander; c.rangeDB = Float(v); store.updateExpander(c) }
        )
    }

    // MARK: - Clipper Bindings

    private var softClipperEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.softClipper.isEnabled },
            set: { enabled in var sc = store.dynamicsConfig.softClipper; sc.isEnabled = enabled; store.updateSoftClipper(sc) }
        )
    }

    private var softClipperDrive: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.driveDB) },
            set: { val in var sc = store.dynamicsConfig.softClipper; sc.driveDB = Float(val); store.updateSoftClipper(sc) }
        )
    }

    private var softClipperThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.thresholdDB) },
            set: { val in var sc = store.dynamicsConfig.softClipper; sc.thresholdDB = Float(val); store.updateSoftClipper(sc) }
        )
    }

    private var softClipperKnee: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.kneeSmooth) },
            set: { val in var sc = store.dynamicsConfig.softClipper; sc.kneeSmooth = Float(val); store.updateSoftClipper(sc) }
        )
    }

    // MARK: - Limiter Bindings

    private var limiterEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.limiter.isEnabled },
            set: { enabled in var lim = store.dynamicsConfig.limiter; lim.isEnabled = enabled; store.updateLimiter(lim) }
        )
    }

    private var limiterCeiling: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.ceilingDB) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.ceilingDB = Float(val); store.updateLimiter(lim) }
        )
    }

    private var limiterAttack: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.attackMs) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.attackMs = Float(val); store.updateLimiter(lim) }
        )
    }

    private var limiterRelease: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.releaseMs) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.releaseMs = Float(val); store.updateLimiter(lim) }
        )
    }

    private var limiterLookAhead: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.lookAheadMs) },
            set: { val in var lim = store.dynamicsConfig.limiter; lim.lookAheadMs = Float(val); store.updateLimiter(lim) }
        )
    }

    // MARK: - Advanced Bindings

    private var stereoModeBinding: Binding<StereoModeSelection> {
        Binding(
            get: { store.dynamicsConfig.advanced.stereoMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.stereoMode = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var coefficientDecouplingBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.coefficientDecouplingEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.coefficientDecouplingEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var dcOffsetEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.dcOffsetFilterEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.dcOffsetFilterEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var balanceBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.stereoBalancePosition) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.stereoBalancePosition = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var timeDelayBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.stereoTimeDelayMS) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.stereoTimeDelayMS = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var loudnessContourBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.loudnessContourEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.loudnessContourEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var deharshEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.deharshFilterEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.deharshFilterEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var deharshTiltBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.deharshTiltAmountDB) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.deharshTiltAmountDB = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var dialogueGateBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.loudnessDialogueGateEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.loudnessDialogueGateEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var deesserDynModeBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.deesserDynamicModeEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.deesserDynamicModeEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var asymmetryTrimBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.clipperAsymmetryTrimDB) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.clipperAsymmetryTrimDB = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var tpGuardBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.limiterTruePeakGuardEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.limiterTruePeakGuardEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var latencyModeBinding: Binding<LatencyMode> {
        Binding(
            get: { store.dynamicsConfig.advanced.latencyMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.latencyMode = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ditherModeBinding: Binding<DitherMode> {
        Binding(
            get: { store.dynamicsConfig.advanced.ditherMode },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.ditherMode = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var pauseGateBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.pauseGateEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.pauseGateEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var oversamplingBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.oversamplingEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.oversamplingEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var linearPhaseEQBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.linearPhaseEQEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.linearPhaseEQEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var roomCorrectionBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.roomCorrectionEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.roomCorrectionEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var targetCurveTypeBinding: Binding<TargetCurveType> {
        Binding(
            get: { store.dynamicsConfig.advanced.targetCurveType },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.targetCurveType = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var syncBufferBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.hardwareSyncBufferEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.hardwareSyncBufferEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var multiSeatBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.multiSeatAveragingEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.multiSeatAveragingEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }

    // MARK: - LTI Bindings

    private var ltiSymmetryEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.symmetryBalanceEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.symmetryBalanceEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiPanningEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.panningGainMatrixEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.panningGainMatrixEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiPanningCrossfeedBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.panningCrossfeedAmount) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.panningCrossfeedAmount = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiDenoisingEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.linearDenoisingEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.linearDenoisingEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiDenoisingThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.linearDenoisingThresholdDB) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.linearDenoisingThresholdDB = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiIRAlignmentEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.speakerIRAlignmentEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.speakerIRAlignmentEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiIRDelayBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.speakerIRDelayMs) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.speakerIRDelayMs = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiCrosstalkEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.crosstalkCancellationEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.crosstalkCancellationEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiCrosstalkAmountBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.crosstalkCancellationAmount) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.crosstalkCancellationAmount = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiEarlyReflectionEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.earlyReflectionCancellationEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.earlyReflectionCancellationEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiEarlyReflectionRoomSizeBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.earlyReflectionRoomSizeMs) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.earlyReflectionRoomSizeMs = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiHPFLinearizationEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.hpfPhaseLinearizationEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.hpfPhaseLinearizationEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiHPFLinearizationFreqBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.hpfPhaseLinearizationFrequencyHz) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.hpfPhaseLinearizationFrequencyHz = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiMultiSeatEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.multiSeatAveragingEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.multiSeatAveragingEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiMultiSeatCountBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.multiSeatCount) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.multiSeatCount = Int(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiSubBassEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.subBassPhaseAlignmentEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.subBassPhaseAlignmentEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiSubBassFreqBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.subBassAlignmentFrequencyHz) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.subBassAlignmentFrequencyHz = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiZLReverbEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.zlConvolutionReverbEnabled },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.zlConvolutionReverbEnabled = val; store.updateAdvancedProcessing(adv) }
        )
    }
    private var ltiZLReverbMixBinding: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.advanced.zlConvolutionReverbMix) },
            set: { val in var adv = store.dynamicsConfig.advanced; adv.zlConvolutionReverbMix = Float(val); store.updateAdvancedProcessing(adv) }
        )
    }
}

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
/// Four-column layout (max 6 toggles per column):
///   Col 1 — core dynamics chain stages
///   Col 2 — spectral/spatial utilities
///   Col 3 — LTI processing (late chain)
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
                        definitionEntry(title: "Pause Gate", body: "Smoothly silences output during extended silence, preventing amplifier hiss.")
                        Divider()
                        definitionEntry(title: "Sync Buffer", body: "Synchronises processing buffer to latency mode, preventing dropouts at low latency settings.")
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
                        definitionEntry(title: "Early Reflection", body: "FIR comb filter targeting first-order room boundary reflections.")
                        Divider()
                        definitionEntry(title: "HPF Linearise", body: "All-pass FIR network linearising group delay introduced by high-pass filter networks.")
                        Divider()
                        definitionEntry(title: "Sub-Bass Align", body: "All-pass network phase-aligning sub-bass with main speaker bandwidth at the crossover frequency.")
                        Divider()
                        definitionEntry(title: "Room Correction", body: "Applies inverse filter to match a target response curve. Requires REW measurement import for accurate room correction.")
                        Divider()
                        definitionEntry(title: "Multi-Seat Avg.", body: "Composite HRTF correction averaged across multiple listening positions for more robust room correction.")
                        Divider()
                        definitionEntry(title: "ZL Reverb", body: "Uniformly-partitioned FFT convolution reverb with zero added processing latency.")
                    }
                    .padding(14)
                }
                .frame(width: 290, height: 620)
            }

            Button {
                showDynamicsPanel.toggle()
            } label: {
                Image(systemName: "waveform.path")
                    .font(.system(size: 21))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Dynamics settings")
            .popover(isPresented: $showDynamicsPanel, arrowEdge: .trailing) {
                DynamicsView()
                    .environmentObject(store)
            }
        }
    }

    // MARK: - Column 1: Signal chain (early stages)

    private var column1: some View {
        VStack(alignment: .leading, spacing: 4) {
            col2Toggle(label: "Hi-Res Coef", isOn: inlineCoefficientDecouplingEnabled)
            col2Toggle(label: "DC Filter",   isOn: inlineDcOffsetEnabled)
            col2Toggle(label: "Widener",     isOn: inlineWideEnabled)
            col2Toggle(label: "LUFS",        isOn: inlineLufsEnabled)
            col2Toggle(label: "Contour",     isOn: inlineLoudnessContourEnabled)
            col2Toggle(label: "4x OS",       isOn: inlineOversamplingBinding)
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
            col2Toggle(label: "Early Refl",  isOn: inlineEarlyReflectionEnabled)
            col2Toggle(label: "HPF Lin.",    isOn: inlineHPFLinearizationEnabled)
            col2Toggle(label: "RC",          isOn: inlineRoomCorrectionBinding)
            col2Toggle(label: "Sub Align",   isOn: inlineSubBassEnabled)
            col2Toggle(label: "ZL Reverb",   isOn: inlineZLReverbEnabled)
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
            InlineTruePeakView(bridge: inlineMeterBridge)
            InlineIspLatchView(bridge: inlineMeterBridge)
            InlineDRFactorView(bridge: inlineMeterBridge)
            InlineBitStreamView(bridge: inlineMeterBridge)
            InlineBitRateView()
        }
        .frame(minWidth: 110)
    }

    // MARK: - Column 6: Stereo Goniometer

    private var column6: some View {
        StereoGoniometerView(engine: store.goniometerEngine, isBypassed: store.isBypassed)
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

    private var inlineEarlyReflectionEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.earlyReflectionCancellationEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.earlyReflectionCancellationEnabled = v; store.updateAdvancedProcessing(adv) }
        )
    }

    private var inlineHPFLinearizationEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.hpfPhaseLinearizationEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.hpfPhaseLinearizationEnabled = v; store.updateAdvancedProcessing(adv) }
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

    private var inlineZLReverbEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.advanced.zlConvolutionReverbEnabled },
            set: { v in var adv = store.dynamicsConfig.advanced; adv.zlConvolutionReverbEnabled = v; store.updateAdvancedProcessing(adv) }
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

#Preview("Dynamics Panel") {
    DynamicsView()
        .environmentObject(EqualiserStore())
}

#Preview("Dynamics Inline") {
    DynamicsInlineView()
        .environmentObject(EqualiserStore())
        .padding()
}
