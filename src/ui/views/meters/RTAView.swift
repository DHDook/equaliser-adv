// RTAView.swift
// Dual 31-band real-time spectrum analyser views + horizontal master meters.

import Combine
import SwiftUI

// MARK: - Meter Bridge

/// Bridges the MeterStore observer system to four normalised (0–1) level fractions
/// for the RTA horizontal master meter rows.
@MainActor
final class RTAMeterBridge: ObservableObject {
    @Published var inputPeakFraction:  Float = 0
    @Published var outputPeakFraction: Float = 0
    @Published var inputRmsFraction:   Float = 0
    @Published var outputRmsFraction:  Float = 0
    @Published var inputIsClipping:    Bool  = false
    @Published var outputIsClipping:   Bool  = false

    private let ipL = RTASingleObserver(), ipR = RTASingleObserver()
    private let opL = RTASingleObserver(), opR = RTASingleObserver()
    private let irL = RTASingleObserver(), irR = RTASingleObserver()
    private let orL = RTASingleObserver(), orR = RTASingleObserver()

    func register(with meterStore: MeterStore) {
        meterStore.addObserver(ipL, for: .inputPeakLeft)
        meterStore.addObserver(ipR, for: .inputPeakRight)
        meterStore.addObserver(opL, for: .outputPeakLeft)
        meterStore.addObserver(opR, for: .outputPeakRight)
        meterStore.addObserver(irL, for: .inputRMSLeft)
        meterStore.addObserver(irR, for: .inputRMSRight)
        meterStore.addObserver(orL, for: .outputRMSLeft)
        meterStore.addObserver(orR, for: .outputRMSRight)

        ipL.onUpdate = { [weak self] v, _, c in
            self?.inputPeakFraction = max(self?.inputPeakFraction ?? 0, v)
            if c { self?.inputIsClipping = true }
        }
        ipR.onUpdate = { [weak self] v, _, _ in
            self?.inputPeakFraction = max(self?.inputPeakFraction ?? 0, v)
        }
        opL.onUpdate = { [weak self] v, _, c in
            self?.outputPeakFraction = max(self?.outputPeakFraction ?? 0, v)
            if c { self?.outputIsClipping = true }
        }
        opR.onUpdate = { [weak self] v, _, _ in
            self?.outputPeakFraction = max(self?.outputPeakFraction ?? 0, v)
        }
        irL.onUpdate = { [weak self] v, _, _ in self?.inputRmsFraction  = max(self?.inputRmsFraction  ?? 0, v) }
        irR.onUpdate = { [weak self] v, _, _ in self?.inputRmsFraction  = max(self?.inputRmsFraction  ?? 0, v) }
        orL.onUpdate = { [weak self] v, _, _ in self?.outputRmsFraction = max(self?.outputRmsFraction ?? 0, v) }
        orR.onUpdate = { [weak self] v, _, _ in self?.outputRmsFraction = max(self?.outputRmsFraction ?? 0, v) }
    }
}

/// Minimal MeterObserver that forwards updates via a closure.
@MainActor
private final class RTASingleObserver: MeterObserver {
    var onUpdate: ((Float, Float, Bool) -> Void)?

    nonisolated func meterUpdated(value: Float, hold: Float, clipping: Bool) {
        let v = value, h = hold, c = clipping
        Task { @MainActor [weak self] in self?.onUpdate?(v, h, c) }
    }
}

// MARK: - Dashboard

/// Full dual-RTA dashboard: horizontal master level meters + dual 31-band spectrum canvases.
struct RTADashboardView: View {
    @ObservedObject var analyzer: AdvancedDualSpectrumAnalyzer
    @StateObject private var meterBridge = RTAMeterBridge()
    @EnvironmentObject private var store: EqualiserStore

    var body: some View {
        VStack(spacing: 5) {
            // Top zone: horizontal peak/RMS meters
            HStack(spacing: 20) {
                HorizontalMasterMeterRow(
                    label: "IN",
                    peakFraction: meterBridge.inputPeakFraction,
                    rmsFraction:  meterBridge.inputRmsFraction,
                    isClipping:   meterBridge.inputIsClipping
                )
                HorizontalMasterMeterRow(
                    label: "OUT",
                    peakFraction: meterBridge.outputPeakFraction,
                    rmsFraction:  meterBridge.outputRmsFraction,
                    isClipping:   meterBridge.outputIsClipping
                )
            }
            .padding(.horizontal, 8)

            // Bottom zone: dual 31-band canvases
            HStack(spacing: 8) {
                rtaCanvas(
                    bands:     analyzer.inputBands,
                    showPeaks: analyzer.showInputPeaks,
                    barColour: .cyan.opacity(0.75),
                    label:     "Pre-EQ"
                )
                rtaCanvas(
                    bands:     analyzer.outputBands,
                    showPeaks: analyzer.showOutputPeaks,
                    barColour: .green.opacity(0.75),
                    label:     "Post-EQ"
                )
            }
            .frame(height: 128)
            .padding(.horizontal, 8)

            // Shared frequency axis labels
            FrequencyAxisLabels(bandCount: analyzer.centerFrequencies.count)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
        .onAppear {
            meterBridge.register(with: store.meterStore)
            store.wireRTAAnalyzer()
        }
    }

    @ViewBuilder
    private func rtaCanvas(
        bands: [BandData],
        showPeaks: Bool,
        barColour: Color,
        label: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            BackgroundGridLines(minDb: analyzer.minDb, maxDb: analyzer.maxDb)

            Canvas { ctx, size in
                let count = bands.count
                guard count > 0 else { return }
                let barW = size.width  / CGFloat(count)
                let gap  = barW * 0.20

                for i in 0..<count {
                    let norm = CGFloat(analyzer.normaliseDb(bands[i].currentValue))
                    let h    = max(1, norm * size.height)
                    let rect = CGRect(
                        x:      CGFloat(i) * barW + gap / 2,
                        y:      size.height - h,
                        width:  barW - gap,
                        height: h
                    )
                    ctx.fill(Path(rect), with: .color(barColour))

                    if showPeaks {
                        let pNorm = CGFloat(analyzer.normaliseDb(bands[i].peakValue))
                        if pNorm > 0 {
                            let py = max(0, size.height - pNorm * size.height - 1.5)
                            let pr = CGRect(x: CGFloat(i) * barW + gap / 2, y: py,
                                           width: barW - gap, height: 2)
                            ctx.fill(Path(pr), with: .color(.white.opacity(0.80)))
                        }
                    }
                }
            }

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
        .background(Color.black.opacity(0.22))
        .cornerRadius(4)
    }
}

// MARK: - Horizontal Master Meter Row

struct HorizontalMasterMeterRow: View {
    let label:        String
    let peakFraction: Float
    let rmsFraction:  Float
    let isClipping:   Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(isClipping ? .red : .secondary)
                .frame(width: 26, alignment: .trailing)

            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(peakColour)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, peakFraction))))
                    }
                }
                .frame(height: 5)
                .animation(.linear(duration: 0.04), value: peakFraction)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.10))
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, rmsFraction))))
                    }
                }
                .frame(height: 3)
                .animation(.linear(duration: 0.08), value: rmsFraction)
            }
        }
    }

    private var peakColour: Color {
        if isClipping     { return .red    }
        if peakFraction > 0.90 { return .orange }
        if peakFraction > 0.70 { return .yellow }
        return .green
    }
}

// MARK: - Background Grid Lines

struct BackgroundGridLines: View {
    let minDb: Float
    let maxDb: Float

    private let referenceLines: [Float] = [0, -10, -20, -30, -40, -50]

    var body: some View {
        Canvas { ctx, size in
            let range = maxDb - minDb
            for db in referenceLines {
                let norm = CGFloat((db - minDb) / range)
                let y    = size.height - norm * size.height
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(
                    path,
                    with: .color(.secondary.opacity(db == 0 ? 0.35 : 0.14)),
                    style: StrokeStyle(
                        lineWidth: db == 0 ? 0.75 : 0.5,
                        dash: db == 0 ? [] : [3, 3]
                    )
                )
            }
        }
    }
}

// MARK: - Frequency Axis Labels

struct FrequencyAxisLabels: View {
    let bandCount: Int

    private let labels: [(text: String, index: Int)] = [
        ("20", 0), ("100", 7), ("1k", 17), ("10k", 27), ("20k", 30)
    ]

    var body: some View {
        GeometryReader { geo in
            let totalBands = max(bandCount - 1, 1)
            ForEach(labels, id: \.text) { item in
                let x = (CGFloat(item.index) / CGFloat(totalBands)) * geo.size.width
                Text(item.text)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .position(x: x, y: geo.size.height / 2)
            }
        }
        .frame(height: 12)
    }
}
