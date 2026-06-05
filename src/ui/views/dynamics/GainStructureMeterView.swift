import SwiftUI

// MARK: - Gain Structure Meter View

/// Displays the total gain reduction applied by each stage of the dynamics processor
/// in a compact vertical stack.
struct GainStructureMeterView: View {
    @EnvironmentObject private var store: EqualiserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Gain Structure")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    gainRow("DE", store.deEsserGainReductionDB)
                    gainRow("MB-L", store.mbLowGainReductionDB)
                    gainRow("MB-M", store.mbMidGainReductionDB)
                    gainRow("MB-H", store.mbHighGainReductionDB)
                    gainRow("Comp", store.compressorGainReductionDB)
                    gainRow("Exp", store.expanderGainReductionDB)
                    gainRow("Clip", store.clipperGainReductionDB)
                    gainRow("Lim", store.limiterGainReductionDB)
                }
            }
        }
    }

    @ViewBuilder
    private func gainRow(_ label: String, _ value: Float) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            let absValue = abs(value)
            let color: Color = absValue < 0.1 ? .green : (absValue < 3 ? .yellow : .orange)

            RoundedRectangle(cornerRadius: 1)
                .fill(color.opacity(0.6))
                .frame(height: 6)
                .frame(maxWidth: .infinity)

            Text(String(format: "%.1f", value))
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
