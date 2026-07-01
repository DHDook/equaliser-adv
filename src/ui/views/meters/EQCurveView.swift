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
    @State private var showPhase:      Bool = false
    @State private var showGroupDelay: Bool = false

    // MARK: - Constants
    private let plotHeight:  CGFloat = 100   // total canvas height in points
    private let maxDB:       Double  =  15   // ±15 dB display range
    private let freqMin:     Double  =  20
    private let freqMax:     Double  = 20_000
    private let resolution:  Int     = 512   // number of x sample points

    var body: some View {
        let snapshot = CurveSnapshot(store: store)

        ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in
                drawBackground(ctx: ctx, size: size)
                drawGrid(ctx: ctx, size: size)
                drawFreqLabels(ctx: ctx, size: size)
                if !store.isBypassed {
                    drawCurve(ctx: ctx, size: size, snapshot: snapshot)
                    if showGroupDelay {
                        drawGroupDelayOverlay(ctx: ctx, size: size, snapshot: snapshot)
                    }
                    if showPhase {
                        drawPhaseOverlay(ctx: ctx, size: size, snapshot: snapshot)
                    }
                } else {
                    drawBypassedLabel(ctx: ctx, size: size)
                }
                drawZeroLine(ctx: ctx, size: size)
            }
            .frame(height: plotHeight)
            .background(EQGraphBackground())
            .cornerRadius(4)
            .opacity(metersEnabled ? 1.0 : 0.4)
            .id(snapshot.changeToken &+ (showPhase ? 1 : 0) &+ (showGroupDelay ? 2 : 0))

            HStack(spacing: 4) {
                // Group delay toggle
                Button(action: { showGroupDelay.toggle() }) {
                    Text("GD")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(showGroupDelay ? Color.primary : Color.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(showGroupDelay
                                    ? Color.orange.opacity(0.18)
                                    : Color.secondary.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)

                // Phase toggle (existing)
                Button(action: { showPhase.toggle() }) {
                    Text("φ")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(showPhase ? Color.primary : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(showPhase
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.secondary.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            .padding(.trailing, 6)
        }
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
            path.move(to: CGPoint(x: 0, y: max(8, min(size.height - 4, y))))
            path.addLine(to: CGPoint(x: size.width, y: max(8, min(size.height - 4, y))))
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
                    at: CGPoint(x: 4, y: max(8, min(size.height - 4, y)) - 14),
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
            path.addLine(to: CGPoint(x: x, y: size.height - 32)) // leave room for freq labels
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

    private func drawPhaseOverlay(ctx: GraphicsContext, size: CGSize, snapshot: CurveSnapshot) {
        guard !snapshot.phaseResponseDeg.isEmpty else { return }

        let N = snapshot.phaseResponseDeg.count
        let maxDeg = 180.0   // ±180° full axis range
        let freqs  = snapshot.phaseFrequencies

        // Draw phase axis labels on right side (degrees)
        for deg in [-180.0, -90.0, 0.0, 90.0, 180.0] {
            let y = yForPhase(deg, height: size.height, maxDeg: maxDeg)
            // Subtle tick mark on the right edge
            var tick = Path()
            tick.move(to: CGPoint(x: size.width - 6, y: y))
            tick.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(tick, with: .color(.purple.opacity(0.4)), lineWidth: 0.5)
            if deg != 0 {
                let label = deg > 0 ? "+\(Int(deg))°" : "\(Int(deg))°"
                ctx.draw(
                    Text(label)
                        .font(.system(size: 6, design: .monospaced))
                        .foregroundStyle(.purple.opacity(0.55)),
                    at: CGPoint(x: size.width - 8, y: y),
                    anchor: .trailing
                )
            }
        }

        // Draw the phase zero line (light purple dashed)
        let zeroY = yForPhase(0, height: size.height, maxDeg: maxDeg)
        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        ctx.stroke(zeroLine, with: .color(.purple.opacity(0.25)),
                   style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))

        // Draw the phase curve
        var phasePath = Path()
        for i in 0..<N {
            let t = Double(i) / Double(N - 1)
            let x = CGFloat(t) * size.width
            let y = yForPhase(snapshot.phaseResponseDeg[i], height: size.height, maxDeg: maxDeg)
            if i == 0 { phasePath.move(to: CGPoint(x: x, y: y)) }
            else       { phasePath.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(phasePath,
                   with: .color(.purple.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1.0))
    }

    private func yForPhase(_ deg: Double, height: CGFloat, maxDeg: Double) -> CGFloat {
        let clamped = max(-maxDeg, min(maxDeg, deg))
        let norm = clamped / maxDeg   // +1.0 (top) … −1.0 (bottom)
        let verticalPadding: CGFloat = 8
        let availableHeight = height - (verticalPadding * 2)
        return verticalPadding + availableHeight * 0.5 * (1.0 - norm)
    }

    private func drawGroupDelayOverlay(ctx: GraphicsContext, size: CGSize, snapshot: CurveSnapshot) {
        // Determine the display range: auto-scale to the maximum group delay in the data
        let allDelays = ([snapshot.eqGroupDelayMs]
            + snapshot.channelGroupDelayMs.values.map { $0 })
            .flatMap { $0 }
        guard !allDelays.isEmpty else { return }

        let rawMax = allDelays.filter { $0.isFinite && $0 >= 0 }.max() ?? 20.0
        let maxMs  = max(5.0, ceil(rawMax * 1.15 / 5.0) * 5.0)  // round up to next 5 ms, min 5 ms

        let N = snapshot.phaseFrequencies.count
        let freqs = snapshot.phaseFrequencies

        // Right-axis labels (ms)
        let labelSteps: [Double]
        if maxMs <= 10 {
            labelSteps = [0, 5, 10]
        } else if maxMs <= 30 {
            labelSteps = [0, 10, 20, 30]
        } else {
            let step = ceil(maxMs / 4 / 5) * 5
            labelSteps = stride(from: 0.0, through: maxMs, by: step).map { $0 }
        }

        for ms in labelSteps {
            let y = yForGroupDelay(ms, height: size.height, maxMs: maxMs)
            var tick = Path()
            tick.move(to: CGPoint(x: size.width - 4, y: y))
            tick.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(tick, with: .color(.orange.opacity(0.4)), lineWidth: 0.5)
            ctx.draw(
                Text(String(format: "%.0f", ms))
                    .font(.system(size: 6, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.55)),
                at: CGPoint(x: size.width - 6, y: y),
                anchor: .trailing
            )
        }

        // Draw EQ group delay (orange, solid)
        if !snapshot.eqGroupDelayMs.isEmpty {
            var path = Path()
            for i in 0..<N {
                let t = Double(i) / Double(N - 1)
                let x = CGFloat(t) * size.width
                let y = yForGroupDelay(snapshot.eqGroupDelayMs[i], height: size.height, maxMs: maxMs)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else       { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.orange.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1.0))
        }

        // Draw per-channel group delay curves (orange variants, dashed)
        let channelColors: [Color] = [
            .orange, .yellow, .mint, .cyan, .indigo, .pink, .teal, .brown
        ]
        for (idx, delays) in snapshot.channelGroupDelayMs.sorted(by: { $0.key < $1.key }) {
            guard delays.count == N else { continue }
            let color = channelColors[idx % channelColors.count]
            var path = Path()
            for i in 0..<N {
                let t = Double(i) / Double(N - 1)
                let x = CGFloat(t) * size.width
                let y = yForGroupDelay(delays[i], height: size.height, maxMs: maxMs)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else       { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(color.opacity(0.65)),
                       style: StrokeStyle(lineWidth: 1.0, dash: [3, 3]))
        }
    }

    private func yForGroupDelay(_ ms: Double, height: CGFloat, maxMs: Double) -> CGFloat {
        // Group delay maps from bottom (0 ms) to top (maxMs ms) — inverted from dB
        let clamped = max(0, min(maxMs, ms))
        let norm = clamped / maxMs   // 0.0 (bottom) … 1.0 (top)
        let verticalPadding: CGFloat = 8
        let availableHeight = height - (verticalPadding * 2)
        return verticalPadding + availableHeight * (1.0 - norm)
    }

    // MARK: - Coordinate Helpers

    private func xForFreq(_ freq: Double, width: CGFloat) -> CGFloat {
        let t = (log10(freq) - log10(freqMin)) / (log10(freqMax) - log10(freqMin))
        return CGFloat(t) * width
    }

    private func yForDB(_ db: Double, height: CGFloat) -> CGFloat {
        let clamped = max(-maxDB, min(maxDB, db))
        let norm = clamped / maxDB          // +1.0 … −1.0
        let verticalPadding: CGFloat = 8
        let availableHeight = height - (verticalPadding * 2)
        return verticalPadding + availableHeight * 0.5 * (1.0 - norm) // 0 = top, height = bottom
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
            // Use the live correction gains from the processor (Chunk 11) at the correct
            // shelf frequencies (60 Hz bass, 9000 Hz treble, set by Chunk 5).
            if snapshot.contourEnabled && (snapshot.contourBassGainDB != 0 || snapshot.contourTrebleGainDB != 0) {
                for (type, freq, gain) in [
                    (FilterType.lowShelf,  60.0,   snapshot.contourBassGainDB),
                    (FilterType.highShelf, 9000.0, snapshot.contourTrebleGainDB)
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
    let changeToken:        Int

    // ── NEW properties ──────────────────────────────────────────────────

    /// Unwrapped phase response of the EQ band cascade in degrees at `phaseFrequencies`.
    /// Computed in init; empty if no active non-bypassed bands.
    let phaseResponseDeg:   [Double]

    /// Group delay in milliseconds of the EQ band cascade at `phaseFrequencies`.
    let eqGroupDelayMs:     [Double]

    /// Per-output-channel group delay in milliseconds (keyed by channel index).
    /// Includes crossover, per-channel delays, and all-pass corrections.
    let channelGroupDelayMs: [Int: [Double]]

    /// Shared frequency grid used for phase and group delay arrays.
    let phaseFrequencies:   [Double]   // log-spaced 20 Hz – 20 kHz, 256 points

    /// Current contour bass gain (dB) for the magnitude overlay (from Chunk 11).
    let contourBassGainDB:  Double
    /// Current contour treble gain (dB) for the magnitude overlay.
    let contourTrebleGainDB: Double

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

        // ── Phase and group delay frequency grid ──────────────────────────
        let N = 256
        let logMin = log10(20.0);  let logMax = log10(20_000.0)
        let freqs: [Double] = (0..<N).map { i in
            pow(10.0, logMin + Double(i) / Double(N - 1) * (logMax - logMin))
        }
        self.phaseFrequencies = freqs

        // ── EQ band phase response (degrees, unwrapped) ──────────────────
        // Compute per-band phase accumulation then unwrap
        var rawPhases = [Double](repeating: 0.0, count: N)
        let sr = Double(store.streamSampleRate)

        for i in 0..<N {
            let f = freqs[i]
            let w = 2.0 * Double.pi * f / sr
            let cosW = cos(w);  let sinW  = sin(w)
            let cos2W = cos(2*w); let sin2W = sin(2*w)
            var ph = 0.0

            for bandIdx in 0..<cfg.activeBandCount {
                let band = cfg.bands[bandIdx]
                guard !band.bypass else { continue }
                let sections = BiquadMath.calculateSections(
                    type: band.filterType, sampleRate: sr,
                    frequency: Double(band.frequency), q: Double(band.q),
                    gain: Double(band.gain), slope: band.slope)
                for c in sections {
                    let numRe = c.b0 + c.b1*cosW  + c.b2*cos2W
                    let numIm = -(c.b1*sinW + c.b2*sin2W)
                    let denRe = 1.0  + c.a1*cosW  + c.a2*cos2W
                    let denIm = -(c.a1*sinW + c.a2*sin2W)
                    ph += atan2(numIm, numRe) - atan2(denIm, denRe)
                }
            }
            rawPhases[i] = ph
        }

        // Unwrap
        var unwrapped = rawPhases
        for i in 1..<unwrapped.count {
            var diff = unwrapped[i] - unwrapped[i-1]
            while diff >  Double.pi { diff -= 2.0 * Double.pi }
            while diff < -Double.pi { diff += 2.0 * Double.pi }
            unwrapped[i] = unwrapped[i-1] + diff
        }
        self.phaseResponseDeg = unwrapped.map { $0 * 180.0 / Double.pi }

        // ── EQ band group delay (ms) ──────────────────────────────────────
        // Numerical finite-difference of unwrapped phase
        var gdMs = [Double](repeating: 0.0, count: N)
        for i in 1..<(N - 1) {
            let dPhaseRad = (rawPhases[i+1] - rawPhases[i-1])
            let dOmega    = 2.0 * Double.pi * (freqs[i+1] - freqs[i-1]) / sr
            if abs(dOmega) > 1e-12 {
                gdMs[i] = -dPhaseRad / dOmega / sr * 1000.0
            }
        }
        // Edge points: copy neighbours
        gdMs[0] = gdMs[1];  gdMs[N-1] = gdMs[N-2]
        self.eqGroupDelayMs = gdMs

        // ── Per-output-channel group delay (ms) ──────────────────────────
        var chGD = [Int: [Double]]()
        if store.outputChannelMatrix.isEnabled {
            for (idx, channel) in store.outputChannelMatrix.channels.enumerated()
                where channel.isEnabled
            {
                let (sections, firKernel) = store.activeCrossoverCoefficients(for: channel.source)
                let delays = CrossoverGroupDelayEngine.channelGroupDelay(
                    crossoverSections: sections,
                    crossoverFIRKernel: firKernel,
                    eqBands: channel.eq.bands,
                    frequencies: freqs,
                    sampleRate: sr
                )
                // Add physical delay (channel.delayMs is constant across all frequencies)
                chGD[idx] = delays.map { $0 + Double(channel.delayMs) }
            }
        }
        self.channelGroupDelayMs = chGD

        // ── Contour gains from live processor state (Chunk 11) ────────────
        let contourPreview = store.routingCoordinator.pipelineManager
            .renderPipeline?.callbackContext?.dynamicsProcessor.previewContourGains()
            ?? (bass: 0, treble: 0)
        self.contourBassGainDB   = Double(contourPreview.bass)
        self.contourTrebleGainDB = Double(contourPreview.treble)

        // ── Change token ──────────────────────────────────────────────────
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
        h = h &* 31 &+ chGD.values.flatMap { $0 }.reduce(0) { $0 &+ Int($1 * 100) }
        self.changeToken = h
    }

    /// Test-accessible initialiser. Computes phase, group delay, and change token
    /// from the supplied bands; uses default values for all other fields.
    init(
        bands: [EQBandConfiguration],
        activeBandCount: Int,
        sampleRate: Double,
        isBypassed: Bool,
        contourEnabled: Bool,
        deharshEnabled: Bool,
        deharshTiltDB: Double,
        contourBassGainDB: Double,
        contourTrebleGainDB: Double
    ) {
        self.bands              = bands
        self.activeBandCount    = activeBandCount
        self.sampleRate         = sampleRate
        self.isBypassed         = isBypassed
        self.contourEnabled     = contourEnabled
        self.deharshEnabled     = deharshEnabled
        self.deharshTiltDB      = deharshTiltDB
        self.contourBassGainDB  = contourBassGainDB
        self.contourTrebleGainDB = contourTrebleGainDB
        self.channelGroupDelayMs = [:]
        self.phaseFrequencies   = (0..<256).map { i in
            pow(10.0, log10(20.0) + Double(i) / 255.0 * (log10(20_000.0) - log10(20.0)))
        }

        // Compute phase and group delay from supplied bands
        let N = 256
        let freqs = self.phaseFrequencies
        var rawPhases = [Double](repeating: 0.0, count: N)

        for i in 0..<N {
            let f = freqs[i]
            let w = 2.0 * Double.pi * f / sampleRate
            let cosW = cos(w); let sinW  = sin(w)
            let cos2W = cos(2*w); let sin2W = sin(2*w)
            var ph = 0.0
            for bandIdx in 0..<activeBandCount {
                let band = bands[bandIdx]
                guard !band.bypass else { continue }
                let sections = BiquadMath.calculateSections(
                    type: band.filterType, sampleRate: sampleRate,
                    frequency: Double(band.frequency), q: Double(band.q),
                    gain: Double(band.gain), slope: band.slope)
                for c in sections {
                    let numRe = c.b0 + c.b1*cosW  + c.b2*cos2W
                    let numIm = -(c.b1*sinW + c.b2*sin2W)
                    let denRe = 1.0  + c.a1*cosW  + c.a2*cos2W
                    let denIm = -(c.a1*sinW + c.a2*sin2W)
                    ph += atan2(numIm, numRe) - atan2(denIm, denRe)
                }
            }
            rawPhases[i] = ph
        }

        var unwrapped = rawPhases
        for i in 1..<unwrapped.count {
            var diff = unwrapped[i] - unwrapped[i-1]
            while diff >  Double.pi { diff -= 2.0 * Double.pi }
            while diff < -Double.pi { diff += 2.0 * Double.pi }
            unwrapped[i] = unwrapped[i-1] + diff
        }
        self.phaseResponseDeg = unwrapped.map { $0 * 180.0 / Double.pi }

        var gdMs = [Double](repeating: 0.0, count: N)
        for i in 1..<(N - 1) {
            let dPhaseRad = rawPhases[i+1] - rawPhases[i-1]
            let dOmega    = 2.0 * Double.pi * (freqs[i+1] - freqs[i-1]) / sampleRate
            if abs(dOmega) > 1e-12 { gdMs[i] = -dPhaseRad / dOmega / sampleRate * 1000.0 }
        }
        gdMs[0] = gdMs[1]; gdMs[N-1] = gdMs[N-2]
        self.eqGroupDelayMs = gdMs

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
