// GoniometerEngine.swift
// Stereo goniometer: circular Lissajous plot using 45° mid/side rotation.
// Audio thread writes stereo L/R samples; a 30 Hz main-thread timer reads the
// circular buffer, applies the M/S transformation, and publishes dot positions.

import Accelerate
import Combine
import Foundation
import SwiftUI

// MARK: - Stereo Frame Sample

/// A single display-coordinate point in mid/side space.
struct StereoFrameSample: Equatable {
    /// Side (L − R) / √2 — maps to the horizontal axis.
    var x: Float = 0.0
    /// Mid  (L + R) / √2 — maps to the vertical axis.
    var y: Float = 0.0
}

/// A goniometer plot point with age for phosphor-style trail decay.
struct GoniometerTrailPoint: Equatable {
    var x: Float
    var y: Float
    /// Elapsed time since capture, in seconds.
    var age: TimeInterval
}

// MARK: - Goniometer Buffer Engine

/// Captures stereo audio from the render thread via a lock-free SPSC circular
/// buffer.  A 30 Hz timer on the main actor reads the most recent window,
/// applies the 45° MS rotation and publishes the result for the UI.
@MainActor
final class GoniometerBufferEngine: ObservableObject, @unchecked Sendable {

    // MARK: Configuration

    /// Number of PCM frames kept in the circular buffer (power of 2).
    private let capacity = 16_384

    /// Number of frames extracted and displayed each refresh cycle.
    let renderWindowSize = 512

    /// Trail persistence — points older than this are discarded.
    let trailDecayDuration: TimeInterval = 1.0

    private let refreshInterval: TimeInterval = 1.0 / 30.0

    // MARK: Circular buffers — written by audio thread

    nonisolated(unsafe) private var circularL: [Float]
    nonisolated(unsafe) private var circularR: [Float]
    /// Write head advanced exclusively by the audio thread.
    nonisolated(unsafe) private var writeHead: Int = 0

    // MARK: Published state

    @Published var trailPoints: [GoniometerTrailPoint] = []

    // MARK: Timer

    private var cancellable: AnyCancellable?

    // MARK: - Init

    init() {
        circularL = [Float](repeating: 0, count: 16_384)
        circularR = [Float](repeating: 0, count: 16_384)
    }

    // MARK: - Audio Thread API

    /// Write interleaved stereo frames into the circular buffer.
    /// Called exclusively from the CoreAudio render thread — must be real-time safe.
    @inline(__always)
    nonisolated func writeStereoInterleaved(
        left:   UnsafePointer<Float>,
        right:  UnsafePointer<Float>,
        frames: Int
    ) {
        guard frames > 0 else { return }
        let cap = 16_384
        let wh  = writeHead
        for i in 0..<frames {
            let slot = (wh + i) & (cap - 1)
            circularL[slot] = left[i]
            circularR[slot] = right[i]
        }
        // Store-release: audio-thread writes are visible before we advance the head.
        writeHead = (wh + frames) & (cap - 1)
    }

    // MARK: - Main Actor API

    /// Process the latest window from the circular buffer.
    /// Called from the 30 Hz refresh timer on the main thread.
    func tick() {
        let cap = capacity
        let n   = renderWindowSize
        let wh  = writeHead

        var rawL = [Float](repeating: 0, count: n)
        var rawR = [Float](repeating: 0, count: n)
        var start = wh - n
        if start < 0 { start += cap }
        for i in 0..<n {
            let idx  = (start + i) & (cap - 1)
            rawL[i]  = circularL[idx]
            rawR[i]  = circularR[idx]
        }

        // 45° clockwise rotation: X = (L − R) / √2,  Y = (L + R) / √2
        var side = [Float](repeating: 0, count: n)
        var mid  = [Float](repeating: 0, count: n)
        vDSP_vsub(rawR, 1, rawL, 1, &side, 1, vDSP_Length(n))   // L - R
        vDSP_vadd(rawL, 1, rawR, 1, &mid,  1, vDSP_Length(n))   // L + R
        var inv_sqrt2: Float = 1.0 / sqrt(2.0)
        vDSP_vsmul(side, 1, &inv_sqrt2, &side, 1, vDSP_Length(n))
        vDSP_vsmul(mid,  1, &inv_sqrt2, &mid,  1, vDSP_Length(n))

        for i in trailPoints.indices {
            trailPoints[i].age += refreshInterval
        }
        trailPoints.removeAll { $0.age >= trailDecayDuration }

        for i in stride(from: 0, to: n, by: 4) {
            trailPoints.append(GoniometerTrailPoint(x: side[i], y: mid[i], age: 0))
        }
        let maxTrail = 4_096
        if trailPoints.count > maxTrail {
            trailPoints.removeFirst(trailPoints.count - maxTrail)
        }
    }

    // MARK: - Lifecycle

    func startRefresh() {
        guard cancellable == nil else { return }
        cancellable = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stopRefresh() {
        cancellable?.cancel()
        cancellable = nil
    }

    func clearTrail() {
        trailPoints.removeAll()
    }
}

// MARK: - Stereo Goniometer View

/// Circular Lissajous plot driven by `GoniometerBufferEngine`.
/// Renders a phosphor-style dot cloud inside a unit circle.
struct StereoGoniometerView: View {
    @ObservedObject var engine: GoniometerBufferEngine
    var isBypassed: Bool = false

    var body: some View {
        VStack(spacing: 3) {
            Text("Goniometer")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack {
                // Background
                Circle()
                    .fill(Color(.controlBackgroundColor))
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)

                // Cross-hair lines
                CrossHairLines()
                    .opacity(0.2)

                Canvas { ctx, size in
                    let cx = size.width  / 2
                    let cy = size.height / 2
                    let r  = min(cx, cy) * 0.95
                    let decay = engine.trailDecayDuration
                    let bypassAlpha: CGFloat = isBypassed ? 0.25 : 1.0

                    for pt in engine.trailPoints {
                        let px = CGFloat(pt.x) * r + cx
                        let py = cy - CGFloat(pt.y) * r
                        let dx = px - cx, dy = py - cy
                        guard dx * dx + dy * dy <= r * r else { continue }

                        let ageFactor = CGFloat(max(0, 1.0 - pt.age / decay))
                        guard ageFactor > 0.01 else { continue }

                        let norm = min(1, sqrt(pt.x * pt.x + pt.y * pt.y))
                        let col  = goniometerDotColour(amplitude: norm)
                            .opacity(0.15 + 0.85 * ageFactor * bypassAlpha)

                        let dotSize = 1.0 + ageFactor
                        ctx.fill(
                            Path(ellipseIn: CGRect(
                                x: px - dotSize, y: py - dotSize,
                                width: dotSize * 2, height: dotSize * 2
                            )),
                            with: .color(col)
                        )
                    }
                }
                .clipShape(Circle())

                // L/R/M labels
                GoniometerLabels()
                    .opacity(0.4)
            }
            .frame(width: 110, height: 110)
        }
        .onAppear  { engine.startRefresh() }
        .onDisappear { engine.stopRefresh() }
    }

    private func goniometerDotColour(amplitude: Float) -> Color {
        let a = CGFloat(max(0, min(1, amplitude)))
        if a < 0.5  { return Color(red: 0.2, green: 0.8, blue: 0.4).opacity(0.75) }
        if a < 0.75 { return Color(red: 0.9, green: 0.8, blue: 0.1).opacity(0.75) }
        return Color(red: 1.0, green: 0.35, blue: 0.1).opacity(0.8)
    }
}

// MARK: - Cross-Hair Lines

private struct CrossHairLines: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let dash = StrokeStyle(lineWidth: 0.5, dash: [4, 3])
            let col  = Color.secondary

            // Vertical (mono/mid axis)
            var vPath = Path()
            vPath.move(to: CGPoint(x: cx, y: 0))
            vPath.addLine(to: CGPoint(x: cx, y: size.height))
            ctx.stroke(vPath, with: .color(col), style: dash)

            // Horizontal (side axis)
            var hPath = Path()
            hPath.move(to: CGPoint(x: 0, y: cy))
            hPath.addLine(to: CGPoint(x: size.width, y: cy))
            ctx.stroke(hPath, with: .color(col), style: dash)

            // Diagonal ±45° guides
            let d = min(cx, cy)
            for sign: CGFloat in [-1, 1] {
                var dPath = Path()
                dPath.move(to: CGPoint(x: cx - d, y: cy - sign * d))
                dPath.addLine(to: CGPoint(x: cx + d, y: cy + sign * d))
                ctx.stroke(dPath, with: .color(col.opacity(0.4)), style: dash)
            }
        }
    }
}

// MARK: - Goniometer Labels

private struct GoniometerLabels: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let font = Font.system(size: 7, weight: .semibold)
            Group {
                Text("M").font(font).foregroundStyle(.secondary)
                    .position(x: w / 2, y: 6)
                Text("L").font(font).foregroundStyle(.secondary)
                    .position(x: 6, y: h / 2)
                Text("R").font(font).foregroundStyle(.secondary)
                    .position(x: w - 6, y: h / 2)
            }
        }
    }
}
