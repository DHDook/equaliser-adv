// RTAView.swift
// Dual 31-band real-time spectrum analyser.
// Left pane = Pre-EQ (input); Right pane = Post-EQ (output).
// Solid colour bars: green → yellow → orange → red as amplitude rises.
// When metersEnabled is false the bars render at zero height.

import AppKit
import Combine
import SwiftUI

// MARK: - Dashboard

struct RTADashboardView: View {
    @ObservedObject var analyzer: AdvancedDualSpectrumAnalyzer
    @EnvironmentObject private var store: EqualiserStore
    var metersEnabled: Bool = true

    @State private var hoveredBandIndex: Int  = -1
    @State private var hoverPane: Int         = -1   // 0 = input, 1 = output

    private var isBypassed: Bool { store.isBypassed }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                pane(
                    title: "Pre-EQ",
                    bands: displayBands(from: analyzer.inputBands),
                    showPeaks: analyzer.showInputPeaks,
                    isBypassed: false,
                    targetPoints: [],
                    paneIndex: 0
                )
                pane(
                    title: "Post-EQ",
                    bands: displayBands(from: analyzer.outputBands),
                    showPeaks: analyzer.showOutputPeaks,
                    isBypassed: isBypassed,
                    targetPoints: analyzer.targetLinePoints,
                    paneIndex: 1
                )
            }
            .padding(.horizontal, 8)
            if analyzer.showDiagnostics {
                diagnosticsRow
            }
        }
        .padding(.top, 0)
        .padding(.bottom, 2)
        .onAppear { store.wireRTAAnalyzer() }
    }

    private func displayBands(from bands: [BandData]) -> [BandData] {
        metersEnabled ? bands : Array(repeating: BandData(), count: bands.count)
    }

    // MARK: - Single Spectrum Pane

    @ViewBuilder
    private func pane(
        title: String,
        bands: [BandData],
        showPeaks: Bool,
        isBypassed: Bool,
        targetPoints: [Float],
        paneIndex: Int
    ) -> some View {
        let hIdx = hoverPane == paneIndex ? hoveredBandIndex : -1
        let minDb = analyzer.minDb

        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if paneIndex == 0 {
                    Toggle("In Peaks", isOn: $analyzer.showInputPeaks)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 8))
                        .controlSize(.mini)
                }
                if paneIndex == 1 {
                    Toggle("Out Peaks", isOn: $analyzer.showOutputPeaks)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 8))
                        .controlSize(.mini)
                    Toggle("Diag", isOn: $analyzer.showDiagnostics)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 8))
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RTAGraphBackground()

                    BackgroundGridLines(minDb: minDb, maxDb: 0)
                        .opacity(isBypassed ? 0.12 : 0.45)
                        .cornerRadius(4)
                        .clipped()

                    Canvas { ctx, size in
                        let count = bands.count
                        guard count > 0 else { return }
                        let barW  = size.width / 46.0
                        let gap   = barW / 2.0

                        // Bars
                        for i in 0..<count {
                            let norm = CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(
                                bands[i].currentValue, min: minDb, max: 0))
                            let h = max(0, norm * size.height)
                            let x = CGFloat(i) * (barW + gap)
                            let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                            let col: Color = isBypassed
                                ? Color(white: 0.45).opacity(0.5)
                                : RTADashboardView.levelColor(norm: Float(norm))
                            ctx.fill(Path(rect), with: .color(col))
                        }

                        // Peak indicators
                        if showPeaks && !isBypassed {
                            for i in 0..<count {
                                let pNorm = CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(
                                    bands[i].peakValue, min: minDb, max: 0))
                                guard pNorm > 0.002 else { continue }
                                let py = max(0, size.height - pNorm * size.height - 1.5)
                                let x  = CGFloat(i) * (barW + gap)
                                let col: Color = bands[i].peakValue >= 0.0 ? .red : .yellow
                                ctx.fill(Path(CGRect(x: x, y: py, width: barW, height: 2)),
                                         with: .color(col))
                            }
                        }

                        // Hover highlight
                        if hIdx >= 0 && hIdx < count {
                            let x = CGFloat(hIdx) * (barW + gap)
                            ctx.fill(
                                Path(CGRect(x: x, y: 0, width: barW, height: size.height)),
                                with: .color(.white.opacity(0.08))
                            )
                        }

                        // Target curve (post-EQ pane only)
                        guard !targetPoints.isEmpty, targetPoints.count == count else { return }
                        var tPath = Path()
                        for i in 0..<count {
                            let normT = isBypassed
                                ? CGFloat(AdvancedDualSpectrumAnalyzer.normaliseDbStatic(0, min: minDb, max: 0))
                                : CGFloat(targetPoints[i])
                            let xc = CGFloat(i) * (barW + gap) + barW / 2
                            let yc = size.height - size.height * normT
                            if i == 0 { tPath.move(to: CGPoint(x: xc, y: yc)) }
                            else       { tPath.addLine(to: CGPoint(x: xc, y: yc)) }
                        }
                        if isBypassed {
                            ctx.stroke(tPath, with: .color(.gray.opacity(0.4)),
                                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                        } else {
                            ctx.stroke(tPath, with: .linearGradient(
                                Gradient(colors: [.orange, .pink]),
                                startPoint: CGPoint(x: 0, y: size.height / 2),
                                endPoint:   CGPoint(x: size.width, y: size.height / 2)
                            ), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let barW = geo.size.width / 46.0
                            let gap  = barW / 2.0
                            hoveredBandIndex = min(30, max(0, Int(loc.x / (barW + gap))))
                            hoverPane        = paneIndex
                        case .ended:
                            hoveredBandIndex = -1
                            hoverPane        = -1
                        }
                    }

                    // Hover tooltip
                    if hIdx >= 0 && hIdx < bands.count {
                        hoverTooltip(band: bands[hIdx], freq: analyzer.centerFrequencies[hIdx])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 140)

            // Frequency labels below each bar
            FreqLabelsCanvas(frequencies: analyzer.centerFrequencies)
                .frame(height: 30)
        }
    }

    // MARK: - Level Color (static so Canvas closure captures the function reference)

    static func levelColor(norm: Float) -> Color {
        let n = max(0, min(1, norm))
        if n < 0.65 {
            return .green
        } else if n < 0.82 {
            let t = CGFloat((n - 0.65) / 0.17)
            return Color(red: t, green: 1.0, blue: 0.0)
        } else if n < 0.92 {
            let t = CGFloat((n - 0.82) / 0.10)
            return Color(red: 1.0, green: 1.0 - t * 0.5, blue: 0.0)
        } else {
            let t = CGFloat(min(1.0, (n - 0.92) / 0.08))
            return Color(red: 1.0, green: 0.5 - t * 0.5, blue: 0.0)
        }
    }

    // MARK: - Hover Tooltip

    @ViewBuilder
    private func hoverTooltip(band: BandData, freq: Float) -> some View {
        let freqStr = freq >= 1000
            ? String(format: "%.1f kHz", freq / 1000)
            : String(format: "%.0f Hz", freq)
        let lvlStr = String(format: "%.1f dB", band.currentValue)
        Text("\(freqStr)  \(lvlStr)")
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.top, 0)
        .padding(.bottom, 2)
            .background(Color.black.opacity(0.72))
            .cornerRadius(3)
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
    }

    // MARK: - Diagnostics Row

    private var diagnosticsRow: some View {
        HStack(spacing: 16) {
            Text("FPS: \(analyzer.currentFps)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(analyzer.currentFps >= 18 ? .secondary : Color.orange)
            Text("Bands: \(analyzer.centerFrequencies.count)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}

// MARK: - Frequency Labels Canvas

/// Draws a rotated frequency label under each RTA bar.
struct FreqLabelsCanvas: View {
    let frequencies: [Float]

    var body: some View {
        Canvas { ctx, size in
            let count = frequencies.count
            guard count > 0 else { return }
            let barW = size.width / 46.0
            let gap  = barW / 2.0

            for i in 0..<count {
                let xCenter = CGFloat(i) * (barW + gap) + barW / 2
                let label   = freqLabel(frequencies[i])
                ctx.withCGContext { cg in
                    cg.saveGState()
                    cg.translateBy(x: xCenter + barW / 2, y: size.height - 2)
                    cg.rotate(by: -.pi / 2)
                    (label as NSString).draw(
                        at: CGPoint(x: 2, y: -barW / 2),
                        withAttributes: [
                            .font: NSFont.systemFont(ofSize: 6, weight: .regular),
                            .foregroundColor: NSColor.tertiaryLabelColor
                        ]
                    )
                    cg.restoreGState()
                }
            }
        }
    }

    private func freqLabel(_ hz: Float) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == Float(Int(k))
                ? "\(Int(k))k"
                : String(format: "%.1fk", k)
        }
        return hz == Float(Int(hz)) ? "\(Int(hz))" : String(format: "%.1f", hz)
    }
}

// MARK: - Background Grid Lines

struct BackgroundGridLines: View {
    let minDb: Float
    let maxDb: Float

    private let referenceLines: [Float] = [0, -10, -20, -30, -40, -50, -60, -70, -80]

    var body: some View {
        Canvas { ctx, size in
            let range = maxDb - minDb
            for db in referenceLines {
                guard db >= minDb && db <= maxDb else { continue }
                let norm = CGFloat((db - minDb) / range)
                let y    = size.height - norm * size.height
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(
                    path,
                    with: .color(.secondary.opacity(db == 0 ? 0.50 : 0.20)),
                    style: StrokeStyle(lineWidth: db == 0 ? 0.8 : 0.5, dash: db == 0 ? [] : [3, 3])
                )
            }
        }
    }
}
// MARK: - RTA Graph Background

/// Darker grey plot background that adapts to light and dark appearance.
private struct RTAGraphBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(colorScheme == .dark
                  ? Color(white: 0.11)
                  : Color(white: 0.72))
    }
}
