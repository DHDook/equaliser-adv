// TruePeakMeterView.swift
// Continuous true-peak meter (Part 9.2)
//
// Displays the true-peak level (dBTP) from the oversampled signal.

import SwiftUI

struct TruePeakMeterView: View {
    let truePeakDB: Float
    let isOversampled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("True Peak")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isOversampled {
                    Text("(approx)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Meter bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.3))

                    // Danger zone (-1 dBTP and above)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red.opacity(0.5))
                        .frame(width: geometry.size.width * 0.1)

                    // Level indicator
                    RoundedRectangle(cornerRadius: 2)
                        .fill(levelColor)
                        .frame(width: geometry.size.width * levelWidth)
                }
            }
            .frame(height: 4)

            // dBTP readout
            Text("\(String(format: "%.1f", truePeakDB)) dBTP")
                .font(.caption2)
                .foregroundStyle(levelColor)
                .monospacedDigit()
        }
    }

    private var levelWidth: CGFloat {
        // Map -20 dBTP to 0 dBTP to 0-1 range
        let clampedDB = max(-20.0, min(0.0, Double(truePeakDB)))
        return CGFloat((clampedDB + 20.0) / 20.0)
    }

    private var levelColor: Color {
        if truePeakDB >= -1.0 {
            return .red
        } else if truePeakDB >= -6.0 {
            return .orange
        } else if truePeakDB >= -12.0 {
            return .yellow
        } else {
            return .green
        }
    }
}
