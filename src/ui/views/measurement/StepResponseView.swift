// StepResponseView.swift
// Step response visualization (Part 6.3)

import SwiftUI

struct StepResponseView: View {
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
                drawStepResponse(context: context, size: size)
            }
            .frame(height: 200)
        }
        .padding()
    }

    private func drawStepResponse(context: GraphicsContext, size: CGSize) {
        guard !impulseResponse.isEmpty else { return }

        let width = size.width
        let height = size.height
        let padding: CGFloat = 40

        // Compute step response (cumulative sum of impulse response)
        let maxSamples = Int((zoomRange / 1000.0) * sampleRate)
        let samplesToPlot = min(maxSamples, impulseResponse.count)

        var stepResponse: [Float] = []
        var cumulative: Float = 0.0
        for i in 0..<samplesToPlot {
            cumulative += impulseResponse[i]
            stepResponse.append(cumulative)
        }

        // Plot area
        let plotWidth = width - 2 * padding
        let plotHeight = height - 2 * padding

        // Find min/max for scaling
        let minVal = stepResponse.min() ?? 0.0
        let maxVal = stepResponse.max() ?? 1.0
        let range = maxVal - minVal

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

        // Draw step response
        var path = Path()
        for (i, value) in stepResponse.enumerated() {
            let x = padding + CGFloat(i) / CGFloat(samplesToPlot) * plotWidth
            let normalizedY = range > 0 ? (value - minVal) / range : 0.5
            let y = origin.y - CGFloat(normalizedY) * plotHeight

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.green))

        // Draw labels
        context.draw(Text("0 ms").font(.caption), at: CGPoint(x: padding, y: height - padding + 5))
        context.draw(Text("\(Int(zoomRange)) ms").font(.caption), at: CGPoint(x: width - padding - 30, y: height - padding + 5))
        context.draw(Text("Step").font(.caption), at: CGPoint(x: padding - 25, y: padding))
    }
}
