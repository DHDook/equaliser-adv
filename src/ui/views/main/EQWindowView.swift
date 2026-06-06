import SwiftUI
import Combine

/// The main EQ settings window - detailed controls.
struct EQWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var store: EqualiserStore
    @StateObject private var driverManager = DriverManager.shared
    @State private var showCompareHelp = false
    @State private var metersEnabledUI = true
    @State private var showDriverSheet = true
    @State private var showSaveSheet = false

    /// Whether the driver installation overlay should be shown.
    private var needsDriverInstallation: Bool {
        !driverManager.isReady && !store.routingCoordinator.manualModeEnabled
    }

    /// Whether the driver needs updating (outdated version).
    private var needsDriverUpdate: Bool {
        store.showDriverUpdateRequired && !store.routingCoordinator.manualModeEnabled
    }

    /// View model for routing status.
    private var routingViewModel: RoutingViewModel {
        RoutingViewModel(store: store)
    }

    /// View model for EQ configuration.
    private var eqViewModel: EQViewModel {
        EQViewModel(store: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Level meters + control panel
            HStack(alignment: .top, spacing: 0) {
                LevelMetersView(meterStore: store.meterStore)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .offset(x: -8)
                    .opacity(metersEnabledUI ? 1.0 : 0.35)
                    .saturation(metersEnabledUI ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.25), value: metersEnabledUI)

                Spacer(minLength: 64)

                VStack(spacing: 12) {
                    GainControlsView(
                        inputGain: store.inputGain,
                        outputGain: store.outputGain,
                        onInputGainChange: { store.updateInputGain($0) },
                        onOutputGainChange: { store.updateOutputGain($0) }
                    )

                    ChannelBalanceSlider(
                        balance: Binding(
                            get: { store.dynamicsConfig.channelBalance },
                            set: { store.updateChannelBalance($0) }
                        )
                    )

                    EQCurveView(metersEnabled: metersEnabledUI)
                }

                DynamicsInlineView()
                    .padding(.leading, 24)
                    .padding(.bottom, 0)
                    .padding(.trailing, 4)

                // Manual-mode controls (device pickers + routing toggle)
                // Only reserve horizontal space when manual mode is active.
                if routingViewModel.manualModeEnabled {
                    VStack(alignment: .trailing, spacing: 8) {
                        DevicePickerView()

                        ToggleWithHelp(
                            label: "Audio Routing",
                            isOn: Binding(
                                get: { routingViewModel.isActive },
                                set: { newValue in
                                    if newValue {
                                        store.reconfigureRouting()
                                    } else {
                                        store.stopRouting()
                                    }
                                }
                            ),
                            helpText: "Enable or disable audio routing between the selected input and output devices. Both devices must be selected to enable routing."
                        )
                        .disabled(!routingViewModel.canToggleRouting)
                        .errorTint({
                            if case .error = store.routingStatus { return true }
                            return false
                        }())
                    }
                    .frame(minWidth: 376)
                }
            }

            // Dual 31-band real-time spectrum analyser
            RTADashboardView(analyzer: store.rtaAnalyzer, metersEnabled: metersEnabledUI)
                .padding(.top, -8)

            Divider()

            // Preset and band controls toolbar
            HStack(alignment: .top) {
                PresetToolbar()
                    .frame(minWidth: 280, maxWidth: 280, alignment: .leading)

                Spacer()

                VStack(spacing: 4) {
                    Text("Bands")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BandCountControl()
                }

                Spacer()

                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        Text("Channel")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $store.channelMode) {
                            Text("Linked").tag(ChannelMode.linked)
                            Text("Stereo").tag(ChannelMode.stereo)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 100)
                    }

                    if store.channelMode == .stereo {
                        VStack(spacing: 4) {
                            Text("Edit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $store.channelFocus) {
                                Text("L").tag(ChannelFocus.left)
                                Text("R").tag(ChannelFocus.right)
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(width: 60)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Mode")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                showCompareHelp = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showCompareHelp, arrowEdge: .trailing) {
                                Text("Mode comparison: EQ = full processing active. Linear EQ = zero-phase FIR EQ mode (increased latency). Flat = bypass EQ at matched volume to hear unprocessed audio. Delta = solo the difference signal to hear the processed effect.")
                                    .font(.caption)
                                    .padding(12)
                                    .frame(width: 280)
                            }
                        }

                        Picker("", selection: $store.compareMode) {
                            Text("EQ").tag(CompareMode.eq)
                            Text("Linear").tag(CompareMode.linearEQ)
                            Text("Flat").tag(CompareMode.flat)
                            Text("Delta").tag(CompareMode.delta)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 180)
                    }

                    VStack(spacing: 4) {
                        Text("Flatten")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .opacity(0)
                        Button {
                            store.flattenBands()
                        } label: {
                            Text("Flatten")
                                .frame(width: 50, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reset all gains to 0 dB while keeping current band configuration")
                    }
                }
                .frame(minWidth: 280, maxWidth: 280, alignment: .trailing)
            }
            .padding(.vertical, 4)

            EQBandGridView()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(minWidth: 1280, minHeight: 700)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                VStack(spacing: 2) {
                    Text("Master")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { !store.isBypassed },
                        set: { store.isBypassed = !$0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Enable or disable EQ processing. When disabled, audio passes through without EQ applied.")
                }
                .frame(minWidth: 40, alignment: .center)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .padding(.leading, 4)
                .padding(.trailing, 8)

                VStack(spacing: 2) {
                    Text("Meters")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $metersEnabledUI)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Master switch for level meters and RTA graphs. Disabling reduces CPU overhead.")
                }
                .frame(minWidth: 40, alignment: .center)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .padding(.leading, 4)
                .padding(.trailing, 8)

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .frame(height: 20)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .frame(minWidth: 40, alignment: .center)
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
        }
        .background(
            WindowAccessor { window in
                store.setEqualiserWindow(window)
            }
        )
        .onAppear {
            store.meterStore.windowBecameVisible()
            metersEnabledUI = store.meterStore.metersEnabled
        }
        .onChange(of: metersEnabledUI) { _, newValue in
            store.meterStore.metersEnabled = newValue
        }
        .onReceive(store.meterStore.$metersEnabled.removeDuplicates()) { value in
            if metersEnabledUI != value { metersEnabledUI = value }
        }
        .onDisappear {
            store.meterStore.windowBecameHidden()
        }
        .sheet(isPresented: $showDriverSheet) {
            DriverInstallationView(
                onInstall: {
                    store.handleDriverInstalled()
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .environmentObject(store)
            .frame(minWidth: 500, minHeight: 400)
        }
        .onChange(of: needsDriverInstallation) { _, newValue in
            showDriverSheet = newValue
        }
        .onChange(of: needsDriverUpdate) { _, newValue in
            if newValue {
                openSettings()
            }
        }
        .onAppear {
            showDriverSheet = needsDriverInstallation
            if needsDriverUpdate {
                openSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .savePresetShortcut)) { _ in
            showSaveSheet = true
        }
        .sheet(isPresented: $showSaveSheet) {
            SavePresetSheet()
                .environmentObject(store)
        }
    }
}

struct SystemEQToggleView: View {
    enum Style {
        case standard
        case menuBar
    }

    @EnvironmentObject var store: EqualiserStore
    var style: Style = .standard

    var body: some View {
        switch style {
        case .standard:
            ToggleWithHelp(
                label: "System EQ",
                isOn: binding,
                helpText: "Enable or disable the equalizer processing. When disabled, audio passes through without EQ applied."
            )
        case .menuBar:
            Toggle("System EQ", isOn: binding)
                .controlSize(.small)
                .toggleStyle(.switch)
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { !store.isBypassed },
            set: { store.isBypassed = !$0 }
        )
    }
}

// #Preview("EQ Window") {
//     EQWindowView()
//         .environmentObject(EqualiserStore())
// }
