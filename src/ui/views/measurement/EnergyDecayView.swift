// EnergyDecayView.swift
// ETC (Energy-Time Curve) and Waterfall visualization (Part 6.5)

import SwiftUI

struct EnergyDecayView: View {
    let impulseResponse: [Float]
    let sampleRate: Double
    @State private var showWaterfall: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // View toggle
            Picker("View", selection: $showWaterfall) {
                Text("ETC").tag(false)
                Text("Waterfall").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            if showWaterfall {
                WaterfallPlot(impulseResponse: impulseResponse, sampleRate: sampleRate)
            } else {
                ETCPlot(impulseResponse: impulseResponse, sampleRate: sampleRate)
            }
        }
        .padding()
    }
}

struct ETCPlot: View {
    let impulseResponse: [Float]
    let sampleRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Energy-Time Curve")
                .font(.headline)

            Canvas { context, size in
                drawETC(context: context, size: size)
            }
            .frame(height: 200)
        }
    }

    private func drawETC(context: GraphicsContext, size: CGSize) {
        guard !impulseResponse.isEmpty else { return }

        let width = size.width
        let height = size.height
        let padding: CGFloat = 40

        // Compute ETC (envelope of impulse response)
        let etc = computeETC(impulseResponse)

        // Plot area
        let plotWidth = width - 2 * padding
        let plotHeight = height - 2 * padding

        // Find range
        let minDB = etc.map { $0.levelDB }.min() ?? -60
        let maxDB = etc.map { $0.levelDB }.max() ?? 0
        let dbRange = maxDB - minDB

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

        // Draw ETC curve
        var path = Path()
        for (i, point) in etc.enumerated() {
            let x = padding + CGFloat(point.timeMs / 500.0) * plotWidth  // 0-500 ms window
            let normalizedDB = dbRange > 0 ? (point.levelDB - minDB) / dbRange : 0.5
            let y = origin.y - CGFloat(normalizedDB) * plotHeight

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.purple))

        // Draw labels
        context.draw(Text("0 ms").font(.caption), at: CGPoint(x: padding, y: height - padding + 5))
        context.draw(Text("500 ms").font(.caption), at: CGPoint(x: width - padding - 30, y: height - padding + 5))
        context.draw(Text("Level (dB)").font(.caption), at: CGPoint(x: padding - 45, y: padding))
    }

    private func computeETC(_ ir: [Float]) -> [(timeMs: Double, levelDB: Double)] {
        // Simple squared magnitude envelope (Hilbert transform would be better)
        var envelope: [(timeMs: Double, levelDB: Double)] = []
        var smoothed: Float = 0.0
        let smoothingFactor: Float = 0.1

        for (i, sample) in ir.enumerated() {
            let timeMs = Double(i) / sampleRate * 1000.0
            smoothed = smoothed * (1.0 - smoothingFactor) + abs(sample) * smoothingFactor
            let levelDB = smoothed > 0 ? 20.0 * log10(Double(smoothed)) : -120.0
            envelope.append((timeMs, levelDB))
        }

        return envelope
    }
}

struct WaterfallPlot: View {
    let impulseResponse: [Float]
    let sampleRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waterfall (Frequency vs Time)")
                .font(.headline)

            Canvas { context, size in
                drawWaterfall(context: context, size: size)
            }
            .frame(height: 250)
        }
    }

    private func drawWaterfall(context: GraphicsContext, size: CGSize) {
        guard !impulseResponse.isEmpty else { return }

        let width = size.width
        let height = size.height
        let padding: CGFloat = 40

        // Compute waterfall data using FFT
        let timeSlices = 20
        let samplesPerSlice = max(1, impulseResponse.count / timeSlices)
        let fftSize = 2048  // Fixed FFT size for frequency resolution

        // Plot area
        let plotWidth = width - 2 * padding
        let plotHeight = height - 2 * padding

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

        // Compute and draw waterfall heatmap
        let fftEngine = FFTEngine(fftSize: fftSize)
        let halfSize = fftSize / 2

        for sliceIndex in 0..<timeSlices {
            let startIndex = sliceIndex * samplesPerSlice
            let endIndex = min(startIndex + fftSize, impulseResponse.count)
            guard endIndex > startIndex else { break }

            // Extract slice and apply window
            var slice = Array(impulseResponse[startIndex..<endIndex])
            let window = blackmanHarrisWindow(size: slice.count)
            for i in 0..<slice.count {
                slice[i] *= window[i]
            }

            // Zero-pad to FFT size
            if slice.count < fftSize {
                slice.append(contentsOf: Array(repeating: Float(0), count: fftSize - slice.count))
            }

            // Compute FFT
            let fftResult = fftEngine.forwardFFT(input: slice)

            // Convert to magnitude in dB
            var magnitudes: [Float] = []
            for i in 0..<halfSize {
                let real: Float = fftResult.real[i]
                let imag: Float = fftResult.imag[i]
                let magnitude = sqrt(real * real + imag * imag)
                let magnitudeDB = magnitude > 0 ? 20.0 * log10(Double(magnitude)) : -120.0
                magnitudes.append(Float(magnitudeDB))
            }

            // Find range for this slice
            let minDB = magnitudes.min() ?? -60
            let maxDB = magnitudes.max() ?? 0
            let dbRange = maxDB - minDB

            // Draw horizontal line for this time slice
            let y = origin.y - CGFloat(Double(sliceIndex) / Double(timeSlices)) * plotHeight

            for (freqIndex, magnitudeDB) in magnitudes.enumerated() {
                let frequency = Double(freqIndex) * sampleRate / Double(fftSize)
                guard frequency >= 20.0 && frequency <= 20000.0 else { continue }

                let normalizedFreq = log10(frequency / 20.0) / log10(20000.0 / 20.0)
                let x = padding + CGFloat(normalizedFreq) * plotWidth

                let normalizedDB = dbRange > 0 ? (magnitudeDB - minDB) / dbRange : 0.5
                let intensity = CGFloat(normalizedDB)

                // Draw pixel with color based on intensity
                let color = Color(hue: 0.7 - intensity * 0.7, saturation: 0.8, brightness: 0.5 + intensity * 0.5)
                let rect = CGRect(x: x, y: y, width: 2, height: plotHeight / CGFloat(timeSlices) - 1)
                context.fill(Path(rect), with: .color(color))
            }
        }

        // Draw labels
        context.draw(Text("20 Hz").font(.caption), at: CGPoint(x: padding, y: height - padding + 5))
        context.draw(Text("20 kHz").font(.caption), at: CGPoint(x: width - padding - 30, y: height - padding + 5))
        context.draw(Text("Time").font(.caption), at: CGPoint(x: padding - 25, y: padding))
    }

    private func blackmanHarrisWindow(size: Int) -> [Float] {
        var window: [Float] = []
        let n = Float(size - 1)
        for i in 0..<size {
            let iFloat = Float(i)
            let w = 0.35875 - 0.48829 * cos(2.0 * .pi * iFloat / n) +
                      0.14128 * cos(4.0 * .pi * iFloat / n) -
                      0.01168 * cos(6.0 * .pi * iFloat / n)
            window.append(Float(w))
        }
        return window
    }
}
