// CrossoverAnalysisView.swift
//
// Tabbed analysis panel embedded in OutputChannelMatrixView.
// Each tab's content is specified by a different V7 task — this file owns
// only the tab container. Implement each tab body from its task.

import SwiftUI

struct CrossoverAnalysisView: View {
    @Binding var selectedTab: OutputChannelMatrixView.AnalysisTab
    @ObservedObject var store: EqualiserStore

    @State private var showGroupDelayAlert = false
    @State private var showPeaksAlert = false
    @State private var showTimeAlignmentAlert = false
    @State private var showPolarityAlert = false

    var body: some View {
        Group {
            switch selectedTab {
            case .groupDelay:
                // TASK Q: Group Delay plot, warning badges, auto-correct buttons
                groupDelayTab

            case .summation:
                // TASK R: Acoustic summation plot, live RTA overlay toggle (Task Z)
                // The live RTA toggle from Task Z is a control WITHIN this tab,
                // not a separate tab — see Task Z spec: "add live RTA overlay"
                // to the Summation tab specifically.
                summationTab

            case .optimise:
                // TASK X: Crossover Optimisation controls and results
                optimiseTab

            case .timeAlign:
                // TASK V: Driver Time Alignment table + Apply button
                // TASK W: Polarity Detection results (lives in the same tab,
                // directly below the time alignment table — see Task W spec:
                // "Add a 'Detect Polarity' button to the Driver Time Alignment panel")
                // TASK AF: "Refine at Crossover Frequency" button(s) — appended
                // below the broadband alignment button in this same tab.
                timeAlignmentTab
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Tab stubs — implement each from its task

    @ViewBuilder private var groupDelayTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group Delay Analysis")
                .font(.headline)
            Text("Group delay plot placeholder — implement from Task Q")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Auto-Correct") {
                    // TODO: Wire to CrossoverGroupDelayEngine.fitAllPassChainToGroupDelay
                    // Requires: crossover config, target group delay, frequency range
                    showGroupDelayAlert = true
                }
                .buttonStyle(.bordered)
                .alert("Auto-Correct Group Delay", isPresented: $showGroupDelayAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Group delay auto-correction requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
                }
                Button("Detect Peaks") {
                    // TODO: Wire to CrossoverGroupDelayEngine.detectGroupDelayPeaks
                    // Requires: group delay data, threshold
                    showPeaksAlert = true
                }
                .buttonStyle(.bordered)
                .alert("Detect Group Delay Peaks", isPresented: $showPeaksAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Group delay peak detection requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
                }
            }
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var summationTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Acoustic Summation")
                .font(.headline)
            Text("Acoustic summation plot placeholder — implement from Task R")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Live RTA Overlay", isOn: Binding(
                get: { false },
                set: { _ in }
            ))
            .disabled(true)
            // Task Z: Live RTA toggle added here
            // TODO: Wire to AcousticSummationEngine.computeSummation
            // Requires: measured driver responses, crossover config, delays
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var optimiseTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crossover Optimisation")
                .font(.headline)
            Text("Crossover optimisation controls placeholder — implement from Task X")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Run Optimisation") {
                // TODO: Wire to CrossoverOptimiser.optimise
                // Requires: measured driver responses, target curve, crossover config
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        }
        .padding(.vertical, 8)
    }
    @ViewBuilder private var timeAlignmentTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Driver Time Alignment")
                .font(.headline)
            Text("Time alignment table placeholder — implement from Task V")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Apply Time Alignment") {
                // TODO: Wire to DriverTimeAlignmentEngine.computeAlignment
                // Requires: impulse responses per channel, crossover frequencies
                showTimeAlignmentAlert = true
            }
            .buttonStyle(.borderedProminent)
            .alert("Apply Time Alignment", isPresented: $showTimeAlignmentAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Time alignment requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
            }
            // Task W: Polarity Detection results (lives in the same tab)
            Divider()
            Text("Polarity Detection")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Polarity detection placeholder — implement from Task W")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Detect Polarity") {
                // TODO: Wire to DriverTimeAlignmentEngine.detectPolarity
                // Requires: impulse response per channel
                showPolarityAlert = true
            }
            .buttonStyle(.bordered)
            .alert("Detect Polarity", isPresented: $showPolarityAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Polarity detection requires measured impulse responses. Use the Transfer Function Wizard to measure your system first.")
            }
            // Task AF: "Refine at Crossover Frequency" button(s) appended below
            Divider()
            Text("Refine at Crossover Frequency")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Refine controls placeholder — implement from Task AF")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
