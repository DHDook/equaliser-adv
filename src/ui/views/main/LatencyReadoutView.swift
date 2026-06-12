// LatencyReadoutView.swift
// Pipeline latency readout (Part 9.3)
//
// Displays the total algorithmic latency of all currently-enabled stages.

import SwiftUI

struct LatencyReadoutView: View {
    let totalLatencyMs: Double
    let alignmentDelayMs: Double
    let sampleRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline Latency")
                .font(.headline)

            HStack {
                Text("Algorithmic:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(String(format: "%.1f", totalLatencyMs)) ms")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            if alignmentDelayMs > 0 {
                HStack {
                    Text("Alignment Delay:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", alignmentDelayMs)) ms")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }

            Divider()

            Text("If using with video, your AV receiver or display's audio delay/lip-sync setting may need adjustment by the algorithmic latency amount.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
