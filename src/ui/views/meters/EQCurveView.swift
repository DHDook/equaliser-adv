// EQCurveView.swift
// Standard EQ transfer function plot.
// X axis: frequency, log-spaced 20 Hz – 20 kHz.
// Y axis: amplitude in dB, ±maxDB centred on 0.
// Curve = net magnitude response of all active, non-bypassed EQ bands.
// Optional overlays for loudness contour and de-harsh tilt.

import SwiftUI

struct EQCurveView: View {
    @EnvironmentObject var store: EqualiserStore
    var metersEnabled: Bool   // dims the view when meters are globally off

    // MARK: - Constants
    private let plotHeight:  CGFloat = 100   // total canvas height in points
    private let maxDB:       Double  =  15   // ±15 dB display range
    private let freqMin:     Double  =  20
    private let freqMax:     Double  = 20_000
    private let resolution:  Int     = 512   // number of x sample points

    var body: some View {
        let snapshot = CurveSnapshot(store: store)

        Canvas { ctx, size in
            drawBackground(ctx: ctx, size: size)
            drawGrid(ctx: ctx, size: size)
            drawFreqLabels(ctx: ctx, size: size)
            if !store.isBypassed {
                drawCurve(ctx: ctx, size: size, snapshot: snapshot)
            } else {
                drawBypassedLabel(ctx: ctx, size: size)
            }
            drawZeroLine(ctx: ctx, size: size)
        }
        .frame(height: plotHeight)
        .background(EQGraphBackground())
        .cornerRadius(4)
        .opacity(metersEnabled ? 1.0 : 0.4)
        // Redraw whenever EQ config changes
        .id(snapshot.changeToken)
    }

    // MARK: - Drawing Functions

    private func drawBackground(ctx: GraphicsContext, size: CGSize) {
        // Background is handled by EQGraphBackground() - no work needed here
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        // Horizontal dB lines
        let dbLines: [Double] = [-12, -9, -6, -3, 0, 3, 6, 9, 12]

        for db in dbLines {
            let y = yForDB(db, height: size.height)
            let isZero = db == 0
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(path,
                       with: .color(.secondary.opacity(isZero ? 0.55 : 0.18)),
                       style: StrokeStyle(
                           lineWidth: isZero ? 1.0 : 0.5,
                           dash: isZero ? [] : [3, 4]))

            // Label (left side, inside plot)
            if db != 0 {
                let label = db > 0 ? "+\(Int(db))" : "\(Int(db))"
                ctx.draw(
                    Text(label)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.6)),
                    at: CGPoint(x: 20, y: y - 6),
                    anchor: .topLeading
                )
            }
        }

        // Vertical frequency lines
        let freqLines: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

        for f in freqLines {
            let x = xForFreq(f, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height - 14)) // leave room for freq labels
            ctx.stroke(path,
                       with: .color(.secondary.opacity(0.15)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
        }
    }

    private func drawFreqLabels(ctx: GraphicsContext, size: CGSize) {
        let labelFreqs: [(Double, String)] = [
            (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
            (1_000, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k"), (20_000, "20k")
        ]
        for (f, label) in labelFreqs {
            let x = xForFreq(f, width: size.width)
            let isRightmost = f == 20_000
            let isLeftmost = f == 20

            let anchor: UnitPoint
            if isRightmost {
                anchor = .trailing
            } else if isLeftmost {
                anchor = .leading
            } else {
                anchor = .center
            }

            let xOffset: CGFloat
            if isRightmost {
                xOffset = -4
            } else if isLeftmost {
                xOffset = 4
            } else {
                xOffset = 0
            }

            ctx.draw(
                Text(label)
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary.opacity(0.5)),
                at: CGPoint(x: x + xOffset, y: size.height - 12),
                anchor: anchor
            )
        }
    }

    private func drawZeroLine(ctx: GraphicsContext, size: CGSize) {
        // Zero line is already drawn in drawGrid with heavier weight
    }

    private func drawBypassedLabel(ctx: GraphicsContext, size: CGSize) {
        ctx.draw(
            Text("EQ Bypassed")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.5)),
            at: CGPoint(x: size.width / 2, y: size.height / 2),
            anchor: .center
        )
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize, snapshot: CurveSnapshot) {
        let dbs = computeCurve(snapshot: snapshot,
                               resolution: resolution,
                               freqMin: freqMin,
                               freqMax: freqMax)
        guard dbs.count == resolution else { return }

        // --- Filled area below the curve ---
        let zeroY = yForDB(0, height: size.height)

        var fillPath = Path()
        for i in 0..<resolution {
            let t  = Double(i) / Double(resolution - 1)
            let x  = CGFloat(t) * size.width
            let y  = yForDB(dbs[i], height: size.height)
            if i == 0 { fillPath.move(to: CGPoint(x: x, y: y)) }
            else       { fillPath.addLine(to: CGPoint(x: x, y: y)) }
        }
        // Close back along 0 dB line
        fillPath.addLine(to: CGPoint(x: size.width, y: zeroY))
        fillPath.addLine(to: CGPoint(x: 0,          y: zeroY))
        fillPath.closeSubpath()

        ctx.fill(fillPath, with: .color(Color.accentColor.opacity(0.12)))

        // --- Stroke curve ---
        var strokePath = Path()
        for i in 0..<resolution {
            let t = Double(i) / Double(resolution - 1)
            let x = CGFloat(t) * size.width
            let y = yForDB(dbs[i], height: size.height)
            if i == 0 { strokePath.move(to: CGPoint(x: x, y: y)) }
            else       { strokePath.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(strokePath,
                   with: .color(Color.accentColor.opacity(0.90)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Coordinate Helpers

    private func xForFreq(_ freq: Double, width: CGFloat) -> CGFloat {
        let t = (log10(freq) - log10(freqMin)) / (log10(freqMax) - log10(freqMin))
        return CGFloat(t) * width
    }

    private func yForDB(_ db: Double, height: CGFloat) -> CGFloat {
        let clamped = max(-maxDB, min(maxDB, db))
        let norm = clamped / maxDB          // +1.0 … −1.0
        return height * 0.5 * (1.0 - norm) // 0 = top, height = bottom
    }

    // MARK: - Magnitude Response Computation

    private func computeCurve(snapshot: CurveSnapshot,
                              resolution: Int,
                              freqMin: Double,
                              freqMax: Double) -> [Double] {
        let sr = snapshot.sampleRate
        let logMin = log10(freqMin)
        let logMax = log10(freqMax)

        return (0..<resolution).map { i in
            let t   = Double(i) / Double(resolution - 1)
            let f   = pow(10.0, logMin + t * (logMax - logMin))
            let w   = 2.0 * Double.pi * f / sr
            let cosW  = cos(w),  sinW  = sin(w)
            let cos2W = cos(2*w), sin2W = sin(2*w)

            var totalDB = 0.0

            // --- EQ bands ---
            for bandIdx in 0..<snapshot.activeBandCount {
                let band = snapshot.bands[bandIdx]
                guard !band.bypass else { continue }

                let sections = BiquadMath.calculateSections(
                    type:       band.filterType,
                    sampleRate: sr,
                    frequency:  Double(band.frequency),
                    q:          Double(band.q),
                    gain:       Double(band.gain),
                    slope:      band.slope
                )

                for c in sections {
                    let nRe = c.b0 + c.b1 * cosW  + c.b2 * cos2W
                    let nIm = -(c.b1 * sinW) - c.b2 * sin2W
                    let dRe = 1.0  + c.a1 * cosW  + c.a2 * cos2W
                    let dIm = -(c.a1 * sinW) - c.a2 * sin2W
                    let magSq = (nRe*nRe + nIm*nIm) / max(1e-30, dRe*dRe + dIm*dIm)
                    totalDB += 10.0 * log10(max(1e-30, magSq))
                }
            }

            // --- Loudness contour (if enabled) ---
            if snapshot.contourEnabled {
                for (type, freq, gain) in [
                    (FilterType.lowShelf,  80.0,   3.0),
                    (FilterType.highShelf, 6000.0, 1.5)
                ] {
                    let c = BiquadMath.calculateCoefficients(
                        type: type, sampleRate: sr, frequency: freq,
                        q: 0.7071067811865476, gain: gain)
                    let nRe = c.b0 + c.b1*cosW  + c.b2*cos2W
                    let nIm = -(c.b1*sinW) - c.b2*sin2W
                    let dRe = 1.0  + c.a1*cosW  + c.a2*cos2W
                    let dIm = -(c.a1*sinW) - c.a2*sin2W
                    let magSq = (nRe*nRe + nIm*nIm) / max(1e-30, dRe*dRe + dIm*dIm)
                    totalDB += 10.0 * log10(max(1e-30, magSq))
                }
            }

            // --- De-harsh tilt (if enabled) ---
            if snapshot.deharshEnabled {
                let c = BiquadMath.calculateCoefficients(
                    type: .highShelf, sampleRate: sr, frequency: 3500.0,
                    q: 0.7071067811865476, gain: snapshot.deharshTiltDB)
                let nRe = c.b0 + c.b1*cosW  + c.b2*cos2W
                let nIm = -(c.b1*sinW) - c.b2*sin2W
                let dRe = 1.0  + c.a1*cosW  + c.a2*cos2W
                let dIm = -(c.a1*sinW) - c.a2*sin2W
                let magSq = (nRe*nRe + nIm*nIm) / max(1e-30, dRe*dRe + dIm*dIm)
                totalDB += 10.0 * log10(max(1e-30, magSq))
            }

            return totalDB
        }
    }
}

// MARK: - Curve Snapshot

struct CurveSnapshot {
    let bands:              [EQBandConfiguration]
    let activeBandCount:    Int
    let sampleRate:         Double
    let isBypassed:         Bool
    let contourEnabled:     Bool
    let deharshEnabled:     Bool
    let deharshTiltDB:      Double
    // Change token: a hash of the values above so .id() triggers redraw
    let changeToken:        Int

    @MainActor
    init(store: EqualiserStore) {
        let cfg = store.eqConfiguration
        self.bands           = cfg.bands
        self.activeBandCount = cfg.activeBandCount
        self.sampleRate      = Double(store.streamSampleRate)
        self.isBypassed      = store.isBypassed
        self.contourEnabled  = store.dynamicsConfig.advanced.loudnessContourEnabled
        self.deharshEnabled  = store.dynamicsConfig.advanced.deharshFilterEnabled
        self.deharshTiltDB   = Double(store.dynamicsConfig.advanced.deharshTiltAmountDB)

        // Simple hash for change detection
        var h = 0
        for b in bands.prefix(activeBandCount) {
            h = h &* 31 &+ Int(b.frequency * 100)
            h = h &* 31 &+ Int(b.gain * 100)
            h = h &* 31 &+ Int(b.q * 100)
            h = h &* 31 &+ b.filterType.rawValue
            h = h &* 31 &+ (b.bypass ? 1 : 0)
        }
        h = h &* 31 &+ (contourEnabled ? 1 : 0)
        h = h &* 31 &+ (deharshEnabled ? 1 : 0)
        h = h &* 31 &+ (isBypassed ? 1 : 0)
        self.changeToken = h
    }
}

// MARK: - Background

private struct EQGraphBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(colorScheme == .dark
                  ? Color(white: 0.11)
                  : Color(white: 0.72))
    }
}
