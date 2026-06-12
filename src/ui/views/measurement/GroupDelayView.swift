// GroupDelayView.swift
// Group delay visualization (Part 6.4)

import SwiftUI

struct GroupDelayView: View {
    let complexResponse: [(frequency: Double, real: Double, imag: Double)]
    @State private var autoRange: Bool = true
    @State private var maxDelay: Double = 20.0  // ms

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Controls
            HStack {
                Toggle("Auto-range", isOn: $autoRange)
                    .font(.caption)

                if !autoRange {
                    Text("Max delay:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $maxDelay, in: 5...50, step: 5)
                        .frame(width: 100)
                    Text("\(Int(maxDelay)) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 35)
                }
            }

            // Plot
            Canvas { context, size in
                drawGroupDelay(context: context, size: size)
            }
            .frame(height: 200)
        }
        .padding()
    }

    private func drawGroupDelay(context: GraphicsContext, size: CGSize) {
        guard !complexResponse.isEmpty else { return }

        let width = size.width
        let height = size.height
        let padding: CGFloat = 40

        // Compute group delay
        let groupDelay = computeGroupDelay(complexResponse)

        // Plot area
        let plotWidth = width - 2 * padding
        let plotHeight = height - 2 * padding

        // Determine y-axis range
        let minDelay = groupDelay.map { $0.delayMs }.min() ?? 0
        let maxDelayVal = autoRange ? (groupDelay.map { $0.delayMs }.max() ?? 20) : maxDelay
        let delayRange = maxDelayVal - minDelay

        // Draw axes
        let origin = CGPoint(x: padding, y: height - padding)
        let xAxisEnd = CGPoint(x: width - padding, y: height - padding)
        let yAxisEnd = CGPoint(x: padding, y: padding)

        context.stroke(Path { path in
            path.move(to: origin)
            path.addLine(to: xAxisEnd)
        }, with: .color(.secondary))

        context.stroke(Path { path in
            path.move(to: origin)
            path.addLine(to: yAxisEnd)
        }, with: .color(.secondary))

        // Draw group delay curve (log frequency axis)
        var path = Path()
        for (i, point) in groupDelay.enumerated() {
            let logFreq = log10(point.frequency)
            let minLogFreq = log10(20.0)
            let maxLogFreq = log10(20000.0)
            let x = padding + CGFloat((logFreq - minLogFreq) / (maxLogFreq - minLogFreq)) * plotWidth

            let normalizedDelay = delayRange > 0 ? (point.delayMs - minDelay) / delayRange : 0.5
            let y = origin.y - CGFloat(normalizedDelay) * plotHeight

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.orange))

        // Draw frequency labels
        context.draw(Text("20 Hz").font(.caption), at: CGPoint(x: padding, y: height - padding + 5))
        context.draw(Text("20 kHz").font(.caption), at: CGPoint(x: width - padding - 30, y: height - padding + 5))
        context.draw(Text("Delay (ms)").font(.caption), at: CGPoint(x: padding - 45, y: padding))
    }

    /// Computes group delay from complex frequency response.
    /// Group delay = -d(phase)/d(omega)
    private func computeGroupDelay(_ response: [(frequency: Double, real: Double, imag: Double)]) -> [(frequency: Double, delayMs: Double)] {
        guard response.count >= 2 else { return [] }

        var result: [(frequency: Double, delayMs: Double)] = []
        var unwrappedPhase: [Double] = []

        // Unwrap phase
        for (i, point) in response.enumerated() {
            let phase = atan2(point.imag, point.real)
            if i > 0 {
                let prevPhase = unwrappedPhase[i - 1]
                let diff = phase - prevPhase
                // Unwrap: if difference > π, subtract 2π; if < -π, add 2π
                if diff > .pi {
                    unwrappedPhase.append(phase - 2 * .pi)
                } else if diff < -.pi {
                    unwrappedPhase.append(phase + 2 * .pi)
                } else {
                    unwrappedPhase.append(phase)
                }
            } else {
                unwrappedPhase.append(phase)
            }
        }

        // Compute group delay via finite difference
        for i in 0..<response.count {
            if i == 0 || i == response.count - 1 {
                result.append((response[i].frequency, 0.0))
                continue
            }

            let freq = response[i].frequency
            let prevFreq = response[i - 1].frequency
            let nextFreq = response[i + 1].frequency

            let prevPhase = unwrappedPhase[i - 1]
            let nextPhase = unwrappedPhase[i + 1]

            // Central difference for derivative
            let dPhase = (nextPhase - prevPhase)
            let dOmega = 2 * .pi * (nextFreq - prevFreq)

            let groupDelay = dOmega != 0 ? -dPhase / dOmega : 0.0
            let delayMs = groupDelay * 1000.0  // Convert seconds to ms

            result.append((freq, delayMs))
        }

        return result
    }
}
