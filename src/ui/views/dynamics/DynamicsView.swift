// DynamicsView.swift
// Controls for the dual-stage dynamics processor: soft clipper + brickwall limiter.

import SwiftUI

// MARK: - Main View

/// Panel for configuring the soft clipper and brickwall limiter.
/// Reads and writes through `EqualiserStore.dynamicsConfig` so all changes
/// are propagated atomically to the audio thread while running.
struct DynamicsView: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var gainReductionDB: Float = 0.0

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Dynamics")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Form {
                softClipperSection
                limiterSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 440)
        .onReceive(
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
        ) { _ in
            gainReductionDB = store.limiterGainReductionDB
        }
    }

    // MARK: - Soft Clipper Section

    private var softClipperSection: some View {
        Section {
            Toggle("Enabled", isOn: softClipperEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

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
                leftEndLabel: "Hard",
                rightEndLabel: "Soft",
                isDisabled: !store.dynamicsConfig.softClipper.isEnabled
            )

        } header: {
            Text("Soft Clipper")
        } footer: {
            Text("Analogue-style wave-shaper. Gently rounds transient peaks before the brickwall limiter, reducing the harshness of subsequent limiting. Disabled by default.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Limiter Section

    private var limiterSection: some View {
        Section {
            Toggle("Enabled", isOn: limiterEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            DynamicsSliderRow(
                label: "Ceiling",
                value: limiterCeiling,
                range: -6.0...0.0,
                step: 0.1,
                formatValue: { String(format: "%.1f dB", $0) },
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

            GainReductionMeterRow(gainReductionDB: gainReductionDB)
                .opacity(store.dynamicsConfig.limiter.isEnabled ? 1.0 : 0.4)

        } header: {
            Text("Brickwall Limiter")
        } footer: {
            Text("Look-ahead true peak limiter with a 2 ms anticipation window. Guarantees the output cannot exceed the ceiling. Enabled by default as a clipping safeguard.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bindings

    private var softClipperEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.softClipper.isEnabled },
            set: { enabled in
                var sc = store.dynamicsConfig.softClipper
                sc.isEnabled = enabled
                store.updateSoftClipper(sc)
            }
        )
    }

    private var softClipperDrive: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.driveDB) },
            set: { val in
                var sc = store.dynamicsConfig.softClipper
                sc.driveDB = Float(val)
                store.updateSoftClipper(sc)
            }
        )
    }

    private var softClipperThreshold: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.thresholdDB) },
            set: { val in
                var sc = store.dynamicsConfig.softClipper
                sc.thresholdDB = Float(val)
                store.updateSoftClipper(sc)
            }
        )
    }

    private var softClipperKnee: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.softClipper.kneeSmooth) },
            set: { val in
                var sc = store.dynamicsConfig.softClipper
                sc.kneeSmooth = Float(val)
                store.updateSoftClipper(sc)
            }
        )
    }

    private var limiterEnabled: Binding<Bool> {
        Binding(
            get: { store.dynamicsConfig.limiter.isEnabled },
            set: { enabled in
                var lim = store.dynamicsConfig.limiter
                lim.isEnabled = enabled
                store.updateLimiter(lim)
            }
        )
    }

    private var limiterCeiling: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.ceilingDB) },
            set: { val in
                var lim = store.dynamicsConfig.limiter
                lim.ceilingDB = Float(val)
                store.updateLimiter(lim)
            }
        )
    }

    private var limiterRelease: Binding<Double> {
        Binding(
            get: { Double(store.dynamicsConfig.limiter.releaseMs) },
            set: { val in
                var lim = store.dynamicsConfig.limiter
                lim.releaseMs = Float(val)
                store.updateLimiter(lim)
            }
        )
    }
}

// MARK: - Slider Row

/// A labelled slider row with a formatted value display on the right.
/// Optional endpoint labels appear below the slider track (e.g. "Hard" / "Soft").
private struct DynamicsSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatValue: (Double) -> String
    var leftEndLabel: String? = nil
    var rightEndLabel: String? = nil
    var isDisabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .leading)

                Slider(value: $value, in: range, step: step)
                    .controlSize(.small)

                Text(formatValue(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 68, alignment: .trailing)
            }

            if leftEndLabel != nil || rightEndLabel != nil {
                HStack {
                    // Align with the slider track (offset for label column)
                    Spacer().frame(minWidth: 64 + 8)
                    Text(leftEndLabel ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(rightEndLabel ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer().frame(minWidth: 68 + 8)
                }
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isDisabled)
    }
}

// MARK: - Gain Reduction Meter

/// Horizontal bar showing the brickwall limiter's current gain reduction.
/// Polls at 30 fps via the parent view's timer. Colour shifts from green → yellow → orange → red
/// as reduction depth increases.
private struct GainReductionMeterRow: View {
    let gainReductionDB: Float

    /// Magnitude of reduction (always ≥ 0; 0 = no reduction).
    private var reductionMagnitude: Double {
        Double(max(0.0, -gainReductionDB))
    }

    /// Full-scale range for the visual bar: 0 to −12 dB.
    private static let displayRangeDB: Double = 12.0

    private var fillFraction: Double {
        min(reductionMagnitude / Self.displayRangeDB, 1.0)
    }

    private var meterColor: Color {
        switch reductionMagnitude {
        case ..<1.0:  return .green
        case ..<3.0:  return .yellow
        case ..<6.0:  return .orange
        default:      return .red
        }
    }

    private var isActive: Bool { reductionMagnitude > 0.05 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Gain Reduction")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .leading)

                Spacer()

                Text(String(format: "%.1f dB", gainReductionDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? .primary : .secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.4))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(meterColor)
                        .frame(width: geo.size.width * fillFraction, height: 6)
                        .animation(.linear(duration: 1.0 / 30.0), value: fillFraction)
                }
            }
            .frame(height: 6)

            // dB scale labels
            HStack {
                Spacer().frame(minWidth: 64 + 8)
                Text("0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("−3")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("−6")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("−12 dB")
                    .font(.caption2)
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
