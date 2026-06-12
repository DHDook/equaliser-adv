// ImpulseResponseView.swift
// Impulse response visualization (Part 6.2)

import SwiftUI

struct ImpulseResponseView: View {
    let impulseResponse: [Float]
    let sampleRate: Double
    @State private var zoomRange: Double = 50.0  // ms

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Zoom control
            HStack {
                Text("Time window:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $zoomRange, in: 10...500, step: 10)
                    .frame(width: 150)
                Text("\(Int(zoomRange)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }

            // Plot
            Canvas { context, size in
                drawImpulseResponse(context: context, size: size)
            }
            .frame(height: 200)
        }
        .padding()
    }

    private func drawImpulseResponse(context: GraphicsContext, size: CGSize) {
        guard !impulseResponse.isEmpty else { return }

        let width = size.width
        let height = size.height
        let padding: CGFloat = 40

        // Plot area
        let plotWidth = width - 2 * padding
        let plotHeight = height - 2 * padding

        // Time axis (0 to zoomRange ms)
        let maxSamples = Int((zoomRange / 1000.0) * sampleRate)
        let samplesToPlot = min(maxSamples, impulseResponse.count)

        // Find max amplitude for scaling
        let maxAmp = impulseResponse.prefix(samplesToPlot).map { abs($0) }.max() ?? 1.0
        let scale = maxAmp > 0 ? 1.0 / maxAmp : 1.0

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

        // Draw zero line
        let zeroY = origin.y - plotHeight / 2
        context.stroke(Path { path in
            path.move(to: CGPoint(x: padding, y: zeroY))
            path.addLine(to: CGPoint(x: width - padding, y: zeroY))
        }, with: .color(.secondary.opacity(0.5)))

        // Draw impulse response
        var path = Path()
        for i in 0..<samplesToPlot {
            let x = padding + CGFloat(i) / CGFloat(samplesToPlot) * plotWidth
            let y = zeroY - CGFloat(impulseResponse[i] * scale) * (plotHeight / 2)

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.blue))

        // Draw labels
        context.draw(Text("0 ms").font(.caption), at: CGPoint(x: padding, y: height - padding + 5))
        context.draw(Text("\(Int(zoomRange)) ms").font(.caption), at: CGPoint(x: width - padding - 30, y: height - padding + 5))
        context.draw(Text("Amplitude").font(.caption), at: CGPoint(x: padding - 35, y: padding))
    }
}
