import AppKit
import SwiftUI

/// Tab identifier for Settings window.
enum SettingsTab: String {
    case display = "display"
    case driver = "driver"
    case userGuide = "userGuide"
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
        }
        .frame(width: 640, height: 500)
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
        textScrollWrapper.autohideScrollers     = true
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

#Preview("Settings") {
    SettingsView()
        .environmentObject(EqualiserStore())
}

