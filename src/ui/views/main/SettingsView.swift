import AppKit
import CoreAudio
import SwiftUI

/// Tab identifier for Settings window.
enum SettingsTab: String {
    case display = "display"
    case driver = "driver"
    case userGuide = "userGuide"
    case roomCalibration = "roomCalibration"
}

struct SettingsView: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var selectedTab: SettingsTab = .display
    
    /// Allows programmatic selection of tab (e.g., to show Driver tab when update required).
    var initialTab: SettingsTab? {
        if store.showDriverUpdateRequired {
            return .driver
        }
        return nil
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DisplaySettingsTab()
                .tabItem {
                    Label("Display", systemImage: "paintbrush")
                }
                .tag(SettingsTab.display)
            
            DriverSettingsTab()
                .tabItem {
                    Label("Driver", systemImage: "speaker.wave.3")
                }
                .tag(SettingsTab.driver)

            UserGuideTab()
                .tabItem {
                    Label("User Guide", systemImage: "book")
                }
                .tag(SettingsTab.userGuide)

            RoomCalibrationTab()
                .tabItem {
                    Label("Room Cal.", systemImage: "waveform.path.ecg.rectangle")
                }
                .tag(SettingsTab.roomCalibration)
        }
        .frame(width: 700, height: 540)
        .onAppear {
            // Auto-select Driver tab if update required
            if let initialTab = initialTab {
                selectedTab = initialTab
                // Clear the flag so user doesn't get forced back on subsequent opens
                store.clearDriverUpdateRequired()
            }
        }
    }
}

struct DisplaySettingsTab: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var showDriverRequiredAlert = false
    @State private var showPermissionDeniedAlert = false

    private var routingViewModel: RoutingViewModel {
        RoutingViewModel(store: store)
    }

    private enum Mode {
        case automatic
        case manual
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Picker("Mode", selection: Binding(
                            get: { store.manualModeEnabled ? Mode.manual : Mode.automatic },
                            set: { newValue in
                                switch newValue {
                                case .automatic:
                                    if !DriverManager.shared.isReady {
                                        showDriverRequiredAlert = true
                                        return
                                    }
                                    store.switchToAutomaticMode()
                                case .manual:
                                    Task {
                                        let granted = await store.switchToManualMode()
                                        if !granted {
                                            showPermissionDeniedAlert = true
                                        }
                                    }
                                }
                            }
                        )) {
                            Text("Automatic").tag(Mode.automatic)
                            Text("Manual").tag(Mode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatic mode (recommended):")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("App manages device selection automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Works with macOS Sound settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Manual mode:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("You choose input and output devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Requires microphone permission")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Device Selection Mode")
            }

            Section {
                RoutingStatusView(viewModel: routingViewModel)
            } header: {
                Text("Routing Status")
            }

            if store.manualModeEnabled {
                Section {
                    DevicePickerView(layout: .vertical)
                } header: {
                    Text("Device Selection")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Picker("Format", selection: $store.bandwidthDisplayMode) {
                            ForEach(BandwidthDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Q Factor:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Bandwidth as precision value")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Higher = narrower, more surgical")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Octaves:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Bandwidth as musical intervals")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Higher = wider frequency range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Bandwidth Display")
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Driver Required", isPresented: $showDriverRequiredAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Automatic mode requires the virtual audio driver. Please install it from the Driver tab in Settings.")
        }
        .alert("Permission Required", isPresented: $showPermissionDeniedAlert) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Manual mode requires microphone permission.\n\nOpen System Settings to enable it.")
        }
    }
}

struct DriverSettingsTab: View {
    @EnvironmentObject var store: EqualiserStore
    @StateObject private var driverManager = DriverManager.shared
    @State private var showUninstallConfirm = false
    @State private var showHALPermissionDeniedAlert = false
    
    /// Whether the driver lacks shared memory capability
    private var driverNeedsUpdate: Bool {
        driverManager.isReady && !driverManager.hasSharedMemoryCapability()
    }
    
    var body: some View {
        Form {
            Section {
                contentView
            } header: {
                Text("Virtual Audio Driver")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Picker("Method", selection: Binding(
                            get: { store.effectiveCaptureMode },
                            set: { newMode in
                                if newMode == .halInput {
                                    Task {
                                        let granted = await store.requestMicPermissionAndSwitchToHALCapture()
                                        if !granted {
                                            await MainActor.run {
                                                showHALPermissionDeniedAlert = true
                                            }
                                        }
                                    }
                                } else {
                                    store.captureMode = newMode
                                }
                            }
                        )) {
                            Text("Shared Memory").tag(CaptureMode.sharedMemory)
                            Text("HAL Input").tag(CaptureMode.halInput)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(store.manualModeEnabled)
                        .opacity(store.manualModeEnabled ? 0.5 : 1.0)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shared Memory (recommended):")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("No microphone permission required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("No indicator in Control Center")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("HAL Input:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Requires microphone permission")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Shows microphone indicator")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Capture Mode")
            } footer: {
                if store.manualModeEnabled {
                    Text("Capture mode is not available in manual mode.")
                } else if driverNeedsUpdate {
                    Text("Using HAL Input because your driver version doesn't support shared memory. Update the driver to enable this feature.")
                }
            }
            
            Section {
                if driverManager.isInstalling {
                    HStack {
                        Spacer()
                        ProgressView("Please wait...")
                        Spacer()
                    }
                }
                
                if let error = driverManager.installError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                        Spacer()
                        Button {
                            driverManager.installError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Uninstall Driver", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Uninstall", role: .destructive) {
                Task {
                    do {
                        try await driverManager.uninstallDriver()
                    } catch {
                        driverManager.installError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This will remove the Equaliser virtual audio driver from your system. You may need to restart coreaudiod.")
        }
        .alert("Permission Required", isPresented: $showHALPermissionDeniedAlert) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("HAL Input capture requires microphone permission.\n\nOpen System Settings to enable it.")
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch driverManager.status {
        case .notInstalled:
            notInstalledView
        case .installed(let version):
            installedView(version: version)
        case .needsUpdate(let current, let bundled):
            needsUpdateView(current: current, bundled: bundled)
        case .error(let message):
            errorView(message: message)
        }
    }
    
    private var notInstalledView: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Driver not installed")
                    .fontWeight(.medium)
            }
            
            Text("Install the driver to route audio through the equaliser.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Install Driver") {
                Task {
                    do {
                        try await driverManager.installDriver()
                    } catch {
                        driverManager.installError = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(driverManager.isInstalling)
        }
    }
    
    private func installedView(version: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Driver installed")
                    .fontWeight(.medium)
                Spacer()
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sampleRate = driverManager.driverSampleRate {
                HStack {
                    Text("Sample Rate")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(sampleRate).formatted()) Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("SRC")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The driver is ready to use.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Uninstall", role: .destructive) {
                showUninstallConfirm = true
            }
            .disabled(driverManager.isInstalling)
            .buttonStyle(.bordered)
        }
    }
    
    private func needsUpdateView(current: String, bundled: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.orange)
                Text("Update available")
                    .fontWeight(.medium)
            }
            
            HStack(spacing: 8) {
                Text("Current: v\(current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("→")
                    .foregroundStyle(.secondary)
                Text("v\(bundled)")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            
            // Dynamic message based on version
            Text(updateMessage(for: current))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 16) {
                Button("Update Driver") {
                    Task {
                        do {
                            try await driverManager.installDriver()
                        } catch {
                            driverManager.installError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(driverManager.isInstalling)
                
                Button("Uninstall", role: .destructive) {
                    showUninstallConfirm = true
                }
                .disabled(driverManager.isInstalling)
            }
        }
    }
    
    /// Minimum driver version that supports shared memory capture.
    private static let sharedMemoryMinVersion = "1.1.0"
    
    /// Returns the appropriate update message based on the installed version.
    /// Versions below 1.1.0 don't support shared memory capture.
    private func updateMessage(for currentVersion: String) -> String {
        if currentVersion < Self.sharedMemoryMinVersion {
            return "The current installed version does not support the \"Shared Memory\" capture mode.\nUpdate for improved audio routing without requiring microphone permission."
        } else {
            return "A newer version is available. Update to get the latest features and fixes."
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title)
            
            Text("Error")
                .fontWeight(.medium)
                .foregroundStyle(.red)
            
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Retry") {
                driverManager.checkInstallationStatus()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - User Guide Tab

/// Scrollable user guide embedded inside the Settings window.
/// Uses an NSViewController + NSScrollView wrapper to allow rich attributed
/// text rendering with section headers, sub-headings, and body copy per spec.
struct UserGuideTab: View {
    var body: some View {
        UserGuideViewControllerRepresentable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Room Calibration Tab

/// Multi-seat room acoustic measurement and correction.
struct RoomCalibrationTab: View {
    @EnvironmentObject var store: EqualiserStore

    // Measurement state
    @State private var isMeasuring    = false
    @State private var calibPosition  = 0        // 0 = Centre, 1 = Left, 2 = Right
    @State private var acousticMode   = 0        // 0 = Single Point, 1 = Multi-Seat Avg
    @State private var measuredSeats: Set<Int> = []   // indices of measured positions
    @State private var statusMessage  = "Ambient shield active — monitoring room silence."
    @State private var selectedMeasurementTab = 0  // 0 = Magnitude, 1 = Phase, 2 = Group Delay, 3 = Impulse, 4 = Step, 5 = ETC/Waterfall

    // Loopback measurement state
    @State private var maxBands: Int = 16

    // Microphone selection
    @State private var selectedMicID: AudioDeviceID? = nil
    @State private var availableMics: [(id: AudioDeviceID, name: String)] = []

    private let positionLabels = ["Centre", "Left", "Right"]

    var body: some View {
        Form {
            // ── About ────────────────────────────────────────────────────────
            Section {
                Text("Room calibration measures your listening environment's acoustic response and applies correction filters to compensate for room modes and reflections. Multi-seat averaging combines measurements from multiple listening positions into a single composite correction.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("About Room Calibration")
            }

            // ── Target Curve ───────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a target curve for room correction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Target curve", selection: $store.selectedTargetCurveName) {
                        ForEach(TargetCurveLibrary.allCurves.filter { !$0.appliesToSubBandOnly }, id: \.name) { curve in
                            Text(curve.name).tag(curve.name)
                        }
                        Text("Custom…").tag("Custom…")
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .onChange(of: store.selectedTargetCurveName) { _, newValue in
                        if let curve = TargetCurveLibrary.allCurves.first(where: { $0.name == newValue }) {
                            store.targetCurve = curve.curve
                        }
                    }
                }
            } header: {
                Text("Target Curve")
            }

            // ── Microphone Calibration (Part 4.1) ───────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Load a microphone calibration file to correct for the measurement mic's frequency response deviation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let calibration = store.micCalibration {
                        HStack(spacing: 8) {
                            Text(calibration.filename ?? "Loaded calibration")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button("Clear") {
                                store.clearMicCalibration()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                    } else {
                        Button("Load Mic Calibration File…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.plainText]
                            panel.allowsMultipleSelection = false
                            panel.title = "Select Microphone Calibration File"
                            if panel.runModal() == .OK, let url = panel.url {
                                store.loadMicCalibration(url: url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let error = store.micCalibrationLoadError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Microphone Calibration")
            }

            // ── Excess-Phase Correction (Part 5) ───────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Excess-Phase Correction (Experimental)", isOn: $store.excessPhaseConfig.enabled)

                    if store.excessPhaseConfig.enabled {
                        VStack(alignment: .leading, spacing: 8) {
                            // Frequency slider
                            HStack {
                                Text("Cutoff frequency:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $store.excessPhaseConfig.cutoffFreqHz, in: 100...500, step: 10)
                                    .frame(width: 150)
                                Text("\(Int(store.excessPhaseConfig.cutoffFreqHz)) Hz")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40)
                            }

                            // Filter length picker
                            HStack {
                                Text("Filter length:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $store.excessPhaseConfig.filterTaps) {
                                    Text("4096").tag(4096)
                                    Text("8192").tag(8192)
                                    Text("16384").tag(16384)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                            }

                            // Latency display
                            let latency = ExcessPhaseCorrector.estimateLatency(
                                filterTaps: store.excessPhaseConfig.filterTaps,
                                sampleRate: 48000.0
                            )
                            HStack {
                                Text("Added latency:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(String(format: "%.1f", latency)) ms")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            // Help text
                            Text("Recommend leaving this off for video playback unless you have lip-sync delay compensation available. Suitable for 2-channel music listening.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Excess-Phase Correction")
            }

            // ── Microphone Selection ───────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select the microphone used to capture room reflections during the sweep.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if availableMics.isEmpty {
                        Text("No input devices found.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Picker("Input Microphone", selection: $selectedMicID) {
                            Text("None selected").tag(Optional<AudioDeviceID>.none)
                            ForEach(availableMics, id: \.id) { mic in
                                Text(mic.name).tag(Optional(mic.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Microphone")
            }

            // ── Configuration ─────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Acoustic Mapping")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $acousticMode) {
                                Text("Single Point").tag(0)
                                Text("Multi-Seat Avg").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(width: 200)
                        }

                        if acousticMode == 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Calibration Position")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $calibPosition) {
                                    ForEach(positionLabels.indices, id: \.self) { i in
                                        Text(positionLabels[i]).tag(i)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .frame(width: 200)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Configuration")
            }

            // ── Measurement ───────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Place a calibrated measurement microphone at the \(acousticMode == 1 ? positionLabels[calibPosition].lowercased() : "primary") listening position, then start the sweep tone and allow it to complete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(isMeasuring ? "Stop Measurement" : "Start Sweep") {
                            if isMeasuring {
                                isMeasuring = false
                                store.stopSweepMeasurement(seatIndex: calibPosition)
                                measuredSeats.insert(calibPosition)
                                let pos = acousticMode == 1 ? positionLabels[calibPosition] : "primary"
                                statusMessage = "Measurement complete for \(pos) position."
                            } else {
                                Task {
                                    let granted = await store.switchToManualMode()
                                    if granted {
                                        await MainActor.run {
                                            isMeasuring = true
                                            statusMessage = "Sweep in progress — keep the room quiet…"
                                            store.startSweepMeasurement()
                                        }
                                    } else {
                                        await MainActor.run {
                                            statusMessage = "Microphone permission required for room measurement."
                                        }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(acousticMode == 1 && measuredSeats.contains(calibPosition) && !isMeasuring)

                        if acousticMode == 1 && measuredSeats.contains(calibPosition) && !isMeasuring {
                            Button("Re-measure") {
                                measuredSeats.remove(calibPosition)
                                statusMessage = "Ambient shield active — monitoring room silence."
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Ambient status readout
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isMeasuring ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Measurement")
            }

            // ── Measurement Visualization (Part 6) ───────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    // Tab picker
                    Picker("View", selection: $selectedMeasurementTab) {
                        Text("Magnitude").tag(0)
                        Text("Phase").tag(1)
                        Text("Group Delay").tag(2)
                        Text("Impulse").tag(3)
                        Text("Step").tag(4)
                        Text("ETC/Waterfall").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    // Display selected view
                    Group {
                        switch selectedMeasurementTab {
                        case 0:
                            // Magnitude view (existing EQ curve view)
                            Text("Magnitude view - use existing EQ curve display")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case 1:
                            // Phase view
                            Text("Phase view - use existing EQ curve display with phase toggle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case 2:
                            // Group Delay view
                            if !store.measuredResponse.isEmpty {
                                let complexResponse = store.measuredResponse.map { (frequency: Double($0.frequency), real: 1.0, imag: 0.0) }
                                GroupDelayView(complexResponse: complexResponse)
                            } else {
                                Text("No measurement data available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case 3:
                            // Impulse Response view
                            if !store.measuredResponse.isEmpty {
                                // Convert magnitude response to impulse response placeholder
                                let impulseResponse = Array(repeating: Float(0.0), count: 1024)
                                ImpulseResponseView(impulseResponse: impulseResponse, sampleRate: 48000.0)
                            } else {
                                Text("No measurement data available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case 4:
                            // Step Response view
                            if !store.measuredResponse.isEmpty {
                                let impulseResponse = Array(repeating: Float(0.0), count: 1024)
                                StepResponseView(impulseResponse: impulseResponse, sampleRate: 48000.0)
                            } else {
                                Text("No measurement data available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case 5:
                            // ETC/Waterfall view
                            if !store.measuredResponse.isEmpty {
                                let impulseResponse = Array(repeating: Float(0.0), count: 1024)
                                EnergyDecayView(impulseResponse: impulseResponse, sampleRate: 48000.0)
                            } else {
                                Text("No measurement data available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        default:
                            EmptyView()
                        }
                    }
                }
            } header: {
                Text("Measurement Visualization")
            }

            // ── Loopback Measurement ─────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Automated loopback measurement plays a sweep through your output and captures it via a microphone to measure room response.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Progress indicator
                    HStack(spacing: 8) {
                        switch store.measurementState {
                        case .idle:
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 8, height: 8)
                            Text("Ready to measure")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .playing:
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Playing sweep...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .capturing:
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Capturing reverb tail...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .computing:
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Computing response...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .done:
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Measurement complete")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Measure button
                    HStack(spacing: 12) {
                        Button("Measure") {
                            Task {
                                // Check if HAL input mode is active
                                if store.routingCoordinator.captureMode == .sharedMemory {
                                    // Prompt to switch to HAL Input mode
                                    let granted = await store.switchToManualMode()
                                    if !granted {
                                        return
                                    }
                                }
                                store.startLoopbackMeasurement()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.measurementState != .idle || !store.routingStatus.isActive)

                        // Max bands stepper
                        HStack(spacing: 8) {
                            Text("Max bands:")
                                .font(.caption)
                                Stepper("", value: $maxBands, in: 8...20)
                                .frame(width: 80)
                            Text("\(maxBands)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 30)
                        }
                    }

                    // Apply correction button (shown when done)
                    if store.measurementState == .done {
                        Button("Apply Correction (\(maxBands) bands)") {
                            store.applyRoomCorrection(maxBands: maxBands)
                        }
                        .buttonStyle(.bordered)

                        // FIR correction controls
                        VStack(alignment: .leading, spacing: 8) {
                            Text("FIR Correction")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("IR length", selection: $store.firCorrectionTapCount) {
                                ForEach([1024, 2048, 4096, 8192, 16384], id: \.self) { taps in
                                    let ms = Double(taps) * 1000.0 / store.streamSampleRate
                                    Text("\(taps) taps (\(Int(round(ms))) ms)").tag(taps)
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)

                            Button("Apply FIR correction (\(store.firCorrectionTapCount) taps)") {
                                store.applyFIRRoomCorrection(tapCount: store.firCorrectionTapCount)
                            }
                            .buttonStyle(.bordered)

                            Text("FIR correction captures narrow room modes that parametric bands cannot address. Longer IRs correct lower frequencies and longer decays but add more latency.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }

                    // Error display
                    if let error = store.measurementError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Loopback Measurement")
            }

            // ── Correction Filters ────────────────────────────────────────
            Section {
                let hasMeasurement = acousticMode == 0
                    ? measuredSeats.contains(0) || (!measuredSeats.isEmpty)
                    : !measuredSeats.isEmpty
                let readyForMulti = acousticMode == 1 && measuredSeats.count >= 2

                if hasMeasurement {
                    VStack(alignment: .leading, spacing: 10) {
                        if acousticMode == 1 && !readyForMulti {
                            Label("Measure at least 2 positions to build an averaged correction.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(acousticMode == 1
                                 ? "Averaged correction from \(measuredSeats.count) positions ready to apply."
                                 : "Measurement complete. Apply correction filters when ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button("Apply Correction Filters") {
                                store.applyRoomCalibration()
                                statusMessage = "Correction filters applied."
                            }
                            .buttonStyle(.bordered)
                            .disabled(acousticMode == 1 && !readyForMulti)

                            Button("Discard All", role: .destructive) {
                                measuredSeats.removeAll()
                                statusMessage = "Ambient shield active — monitoring room silence."
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("No measurement data yet. Run a sweep first.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Correction Filters")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            availableMics = Self.listInputDevices()
            // Wire sweep completion callback
            store.routingCoordinator.pipelineManager.renderPipeline?.onSweepPlaybackComplete = {
                isMeasuring = false
            }
        }
    }

    // MARK: - Input Device Enumeration

    /// Returns all CoreAudio devices that have at least one input stream.
    private static func listInputDevices() -> [(id: AudioDeviceID, name: String)] {
        guard let ids = fetchAllDeviceIDs() else { return [] }

        return ids.compactMap { deviceID in
            // Filter to devices with input streams.
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope:    kAudioDevicePropertyScopeInput,
                mElement:  kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &streamSize)
            guard streamSize > 0 else { return nil }

            // Get the device name.
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.stride)
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &cfName)
            let nameStr = cfName as String
            guard !nameStr.isEmpty else { return nil }
            return (id: deviceID, name: nameStr)
        }
    }
}

/// NSViewControllerRepresentable wrapper for UserGuideSettingsViewController.
private struct UserGuideViewControllerRepresentable: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> UserGuideSettingsViewController {
        UserGuideSettingsViewController()
    }
    func updateNSViewController(_ nsViewController: UserGuideSettingsViewController, context: Context) {}
}

/// AppKit view controller hosting a scrollable, styled manual text view.
final class UserGuideSettingsViewController: NSViewController {

    private let textScrollWrapper = NSScrollView()
    private let manualTextView    = NSTextView()

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 460))
        setupLayout()
    }

    private func setupLayout() {
        textScrollWrapper.hasVerticalScroller   = true
        textScrollWrapper.hasHorizontalScroller = false
        textScrollWrapper.autohidesScrollers     = true
        textScrollWrapper.translatesAutoresizingMaskIntoConstraints = false

        manualTextView.isEditable   = false
        manualTextView.isSelectable = true
        manualTextView.textColor    = .labelColor
        manualTextView.drawsBackground = false
        manualTextView.textContainer?.widthTracksTextView = true
        manualTextView.textContainerInset = NSSize(width: 4, height: 4)

        textScrollWrapper.documentView = manualTextView
        view.addSubview(textScrollWrapper)

        NSLayoutConstraint.activate([
            textScrollWrapper.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            textScrollWrapper.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            textScrollWrapper.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textScrollWrapper.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        manualTextView.textStorage?.setAttributedString(buildGuideContent())
    }

    // MARK: - Attributed Content Builder

    private func buildGuideContent() -> NSAttributedString {
        let result = NSMutableAttributedString()

        func h1(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 18),
                .foregroundColor: NSColor.labelColor
            ]
            result.append(NSAttributedString(string: text + "\n\n", attributes: attrs))
        }
        func h2(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            result.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        func body(_ text: String) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
            result.append(NSAttributedString(string: text + "\n\n", attributes: attrs))
        }
        func code(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.quaternaryLabelColor
            ]
            result.append(NSAttributedString(string: text + "\n\n", attributes: attrs))
        }

        h1("Equaliser-Adv — Complete Operation Manual")

        h2("Overview")
        body("This application provides a system-wide audio processing pipeline for macOS. Audio captured from the system virtual driver is passed through a configurable chain of dynamics and spatial processing stages before being routed to your selected output device.")

        h2("Part 1 — Compare Modes (EQ / Flat / Delta)")
        body("EQ: Full processing chain active — all enabled stages apply.\n\nFlat: EQ bands are bypassed at matched volume so you can hear the unprocessed signal. Useful for A/B comparison. Automatically reverts to EQ mode after 5 minutes.\n\nDelta: Solos the difference signal between the processed and unprocessed audio. You hear only what the dynamics chain is adding or removing — ideal for confirming that de-essing, limiting, or expansion is operating transparently.")

        h2("Part 2 — Dynamics Chain Stages")
        body("Signal flow (left to right in the inline widget):\n\n1. Stereo Widener — Three-band M/S processor. Low band defaults to mono for tight bass; mid and high expand perceived width.\n\n2. LUFS Loudness Match — Measures 3-second integrated K-weighted loudness and continuously corrects gain to hit your target level. Dialogue Gate prevents silent passages from skewing the estimate.\n\n3. De-Esser — Frequency-selective compressor tuned for sibilance (2–10 kHz). Dynamic EQ Mode converts it to a localised dynamic cut, leaving surrounding high-frequency content untouched.\n\n4. Multiband Compressor — Three independent compressor bands split by Linkwitz-Riley crossovers. Gentle = LR4 (24 dB/oct); Steep = LR8 (48 dB/oct). Fixed ratio 4:1 with 6 dB soft-knee.\n\n5. Wideband Compressor — Feed-forward compressor with adjustable ratio, knee, attack, release, and makeup gain.\n\n6. Crest Factor (display only) — Shows the difference between instantaneous peak and RMS level. High values indicate transient-rich content.\n\n7. Expander — Downward expander that attenuates signals below threshold, widening perceived dynamic range.\n\n8. Clipper — Analogue-style wave-shaper. Asymmetry Trim compensates for waveform asymmetry by offsetting gain on the negative half-cycle.\n\n9. Limiter — Look-ahead brickwall limiter. TP Guard adds −1.5 dBFS headroom to prevent inter-sample overs on downstream converters.")

        h2("Part 3 — Spatial & Utility Controls (Inline Column 2)")
        body("Widener: Master enable for the three-band stereo widener.\n\nLUFS Match: Master enable for the loudness normaliser.\n\nPhase Meter: Horizontal centre-pivoted bar. Right deflection (+1) = in-phase / mono. Centre (0) = uncorrelated. Left deflection (−1) = fully out of phase.\n\nGoniometer: Compact vector scope. The dot position represents the current stereo image — X axis = balance, Y axis = phase correlation.\n\nDe-Harsh: Applies a gentle high-shelf tilt filter above 3.5 kHz after the limiter. Reduces digital harshness without dulling the mix.\n\nLoudness Contour: Applies a Fletcher-Munson equal-loudness compensation curve, slightly boosting low bass and high treble at lower listening levels.\n\nTime / Balance Sliders: Time adjusts L/R sample-level delay (0–20 ms) for speaker alignment. Balance applies a non-destructive gain matrix — left pan attenuates the right channel; right pan attenuates the left channel.\n\nBalance Meter: Horizontal centre-pivoted bar showing real-time channel energy difference (L minus R in dB). Centre = equal power.\n\nDC Filter: Removes any DC bias from the input signal before the dynamics chain.\n\nLatency Mode: Music = 128-frame I/O buffer (lowest latency). Movie = 512-frame I/O buffer (better AV sync).\n\nPause Gate: Mutes the output and pauses processing during extended silence to conserve CPU.\n\nSync Buffer: Synchronises the hardware I/O buffer size to the selected Latency Mode on next device configuration.\n\nDither Mode: Off = no dither. TPDF = triangular probability density function dither (recommended for 24-bit masters). Shaped = noise-shaped dither for 16-bit output.")

        h2("Part 4 — Stereo Matrix (Dynamics Menu)")
        body("Stereo Mode: Stereo = full L/R processing. Wide Mono = M/S fold-down with widened side. True Mono = full sum-to-mono before all stages.\n\nBalance: Symmetry balance slider (−1.0 to +1.0). Non-destructive gain scaling — does not clip or compress digital data.\n\nL/R Delay: Per-channel sample delay for room correction and speaker alignment.")

        h2("Part 5 — System Utilities (Dynamics Menu)")
        body("These settings affect system-level behaviour and should generally be configured once and left unchanged:\n\n• DC Offset Filter: Recommended on for most hardware chains.\n• Latency Mode: Music for production; Movie for home theatre.\n• Dither: Use TPDF when downsampling bit-depth.\n• Pause Gate: Useful on desktop systems to prevent idle processing.\n• Sync Buffer: Enable when switching latency modes to apply the change without restarting.\n\nDelta Solo is controlled by the Compare picker on the main screen (EQ / Flat / Delta). When Delta is active, you hear only the net contribution of the dynamics chain.")

        h2("Part 6 — EQ Section")
        body("The main EQ grid provides up to 64 parametric bands per channel. Bands can be operated in Linked mode (single shared curve for L and R) or independent Stereo mode (separate curves per channel).\n\nPresets can be saved, loaded, and exported. Use the Compare picker (EQ / Flat / Delta) to A/B compare against the unprocessed source or to isolate the processing contribution.")

        return result
    }
}

// #Preview("Settings") {
//     SettingsView()
//         .environmentObject(EqualiserStore())
// }

