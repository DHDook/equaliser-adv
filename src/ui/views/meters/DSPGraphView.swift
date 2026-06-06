// DSPGraphView.swift
// Full-width DSP signal-flow strip showing the active processing chain
// with live per-stage gain-reduction overlays.
// Audio thread data is polled at 30 FPS via TimelineView.

import SwiftUI
import AppKit

struct DSPGraphView: View {
    @EnvironmentObject var store: EqualiserStore
    var metersEnabled: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let safeGR: (Float) -> Float = { metersEnabled ? $0 : 0 }
            
            DSPGraphCanvas(
                metersEnabled: metersEnabled,
                isBypassed: store.isBypassed,
                inputGain: store.inputGain,
                outputGain: store.outputGain,
                preEQPeak: store.preEQPeakDB,
                postEQPeak: store.postEQPeakDB,
                deEsserGR: safeGR(store.deEsserGainReductionDB),
                mbLowGR: safeGR(store.mbLowGainReductionDB),
                mbMidGR: safeGR(store.mbMidGainReductionDB),
                mbHighGR: safeGR(store.mbHighGainReductionDB),
                compGR: safeGR(store.compressorGainReductionDB),
                expGR: safeGR(store.expanderGainReductionDB),
                clipGR: safeGR(store.clipperGainReductionDB),
                limGR: safeGR(store.limiterGainReductionDB),
                clipperEngaged: metersEnabled && store.clipperEngaged,
                // --- Per-stage enabled flags ---
                wideEnabled: store.dynamicsConfig.stereoWidener.isEnabled,
                lufsEnabled: store.dynamicsConfig.loudnessMatch.isEnabled,
                deEsserEnabled: store.dynamicsConfig.deEsser.isEnabled,
                mbEnabled: store.dynamicsConfig.multibandCompressor.isEnabled,
                compEnabled: store.dynamicsConfig.compressor.isEnabled,
                expEnabled: store.dynamicsConfig.expander.isEnabled,
                clipEnabled: store.dynamicsConfig.softClipper.isEnabled,
                limEnabled: store.dynamicsConfig.limiter.isEnabled
            )
        }
        .frame(height: 64)
        .background(DSPGraphBackground())
        .cornerRadius(4)
    }
}

// MARK: - Background (matches RTAGraphBackground style)

private struct DSPGraphBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(colorScheme == .dark
                  ? Color(white: 0.11)
                  : Color(white: 0.72))
    }
}

// MARK: - Canvas

/// Pure-draw view. All values are injected as value types so Canvas
/// captures no reference types on the audio thread.
private struct DSPGraphCanvas: View {
    let metersEnabled: Bool
    let isBypassed: Bool
    let inputGain: Float
    let outputGain: Float
    let preEQPeak: Float
    let postEQPeak: Float
    let deEsserGR: Float
    let mbLowGR: Float
    let mbMidGR: Float
    let mbHighGR: Float
    let compGR: Float
    let expGR: Float
    let clipGR: Float
    let limGR: Float
    let clipperEngaged: Bool
    let wideEnabled: Bool
    let lufsEnabled: Bool
    let deEsserEnabled: Bool
    let mbEnabled: Bool
    let compEnabled: Bool
    let expEnabled: Bool
    let clipEnabled: Bool
    let limEnabled: Bool

    var body: some View {
        Canvas { ctx, size in
            drawGraph(ctx: ctx, size: size)
        }
    }

    // MARK: - Main draw function

    private func drawGraph(ctx: GraphicsContext, size: CGSize) {
        // Step 1: Bypass dimming
        var masterAlpha: CGFloat = 1.0
        if isBypassed { masterAlpha = 0.3 }

        ctx.withCGContext { cg in
            cg.setAlpha(masterAlpha)
            
            // Step 2: Connector line
            let midY: CGFloat = size.height * 0.42
            let lineColor = Color(NSColor.tertiaryLabelColor).opacity(0.6)
            let linePath = Path { p in
                p.move(to: CGPoint(x: 16, y: midY))
                p.addLine(to: CGPoint(x: size.width - 16, y: midY))
            }
            ctx.stroke(linePath, with: .color(lineColor), lineWidth: 1)

            // Step 3: Node definitions array
            let nodes: [NodeDef] = [
                NodeDef(slot: 0,  label: "IN",    isAlwaysOn: true,  isEnabled: true,        grValue: nil,    isEQNode: false, nodeColor: .secondaryLabelColor),
                NodeDef(slot: 1,  label: "Gain",  isAlwaysOn: true,  isEnabled: true,        grValue: nil,    isEQNode: false, nodeColor: .secondaryLabelColor),
                NodeDef(slot: 2,  label: "DC",    isAlwaysOn: true,  isEnabled: true,        grValue: nil,    isEQNode: false, nodeColor: .secondaryLabelColor),
                NodeDef(slot: 3,  label: "Wide",  isAlwaysOn: false, isEnabled: wideEnabled, grValue: nil,    isEQNode: false, nodeColor: .systemGreen),
                NodeDef(slot: 4,  label: "LUFS",  isAlwaysOn: false, isEnabled: lufsEnabled, grValue: nil,    isEQNode: false, nodeColor: .systemGreen),
                NodeDef(slot: 5,  label: "EQ",    isAlwaysOn: true,  isEnabled: !isBypassed, grValue: nil,    isEQNode: true,  nodeColor: .systemBlue),
                NodeDef(slot: 6,  label: "D-Ess", isAlwaysOn: false, isEnabled: deEsserEnabled, grValue: deEsserGR, isEQNode: false, nodeColor: .systemGreen),
                NodeDef(slot: 7,  label: "M-Bnd", isAlwaysOn: false, isEnabled: mbEnabled,   grValue: nil,    isEQNode: false, nodeColor: .systemGreen),
                NodeDef(slot: 8,  label: "Comp",  isAlwaysOn: false, isEnabled: compEnabled,  grValue: compGR, isEQNode: false, nodeColor: .systemGreen),
                NodeDef(slot: 9,  label: "Exp",   isAlwaysOn: false, isEnabled: expEnabled,   grValue: expGR,  isEQNode: false, nodeColor: .systemGreen),
                NodeDef(slot: 10, label: "Clip",  isAlwaysOn: false, isEnabled: clipEnabled,  grValue: clipGR, isEQNode: false, nodeColor: .systemGreen),
                NodeDef(slot: 11, label: "Lim",   isAlwaysOn: false, isEnabled: limEnabled,   grValue: limGR,  isEQNode: false, nodeColor: .systemOrange),
                NodeDef(slot: 12, label: "OUT",   isAlwaysOn: true,  isEnabled: true,         grValue: nil,    isEQNode: false, nodeColor: .secondaryLabelColor),
            ]

            // Step 4: Draw each node
            for node in nodes {
                let x = nodeXCenter(slot: node.slot, width: size.width)
                let circleRadius: CGFloat = 7

                // Circle
                let circleRect = CGRect(x: x - circleRadius, y: midY - circleRadius,
                                        width: circleRadius * 2, height: circleRadius * 2)
                if node.isEnabled || node.isAlwaysOn {
                    ctx.fill(Path(ellipseIn: circleRect),
                             with: .color(Color(node.nodeColor).opacity(0.85)))
                } else {
                    // Bypassed: hollow dashed circle
                    ctx.stroke(Path(ellipseIn: circleRect),
                               with: .color(Color(node.nodeColor).opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }

                // Label above circle
                let labelY = midY - circleRadius - 12
                ctx.draw(
                    Text(node.label)
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(Color(node.isEnabled || node.isAlwaysOn
                            ? node.nodeColor
                            : NSColor.tertiaryLabelColor)),
                    at: CGPoint(x: x, y: labelY),
                    anchor: .center
                )

                // Special case: Multiband (slot 7) - 3 bars
                if node.slot == 7 && node.isEnabled && metersEnabled {
                    let mbBarWidth: CGFloat = 3
                    let mbGap: CGFloat = 1
                    let mbStartX = x - (mbBarWidth * 1.5 + mbGap)
                    
                    for (i, (gr, _)) in [(mbLowGR, "L"), (mbMidGR, "M"), (mbHighGR, "H")].enumerated() {
                        let bx = mbStartX + CGFloat(i) * (mbBarWidth + mbGap)
                        let barH = grBarHeight(gr: gr)
                        let barRect = CGRect(x: bx, y: midY + circleRadius + 2, width: mbBarWidth, height: barH)
                        ctx.fill(Path(barRect), with: .color(grColor(gr: gr).opacity(0.8)))
                    }
                }
                // GR bar for single-bar nodes
                else if let gr = node.grValue, metersEnabled {
                    let barH = grBarHeight(gr: gr)
                    let barTop = midY + circleRadius + 2
                    let barRect = CGRect(x: x - 5, y: barTop, width: 10, height: barH)
                    ctx.fill(Path(barRect), with: .color(grColor(gr: gr).opacity(0.8)))
                    
                    // Value text below bar
                    let valueY = barTop + 18
                    ctx.draw(
                        Text(String(format: "%.1f", abs(gr)))
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x, y: valueY),
                        anchor: .center
                    )
                }

                // Special case: Clipper engaged flash (slot 10)
                if node.slot == 10 && clipperEngaged && clipEnabled {
                    let flashRect = circleRect.insetBy(dx: -2, dy: -2)
                    ctx.stroke(Path(ellipseIn: flashRect),
                               with: .color(Color.yellow.opacity(0.9)),
                               lineWidth: 1.5)
                }

                // Special case: Gain nodes (slots 1 and 12)
                if node.slot == 1 {
                    let gainText = String(format: "%+.1f dB", inputGain)
                    let valueY = midY + circleRadius + 18
                    ctx.draw(
                        Text(gainText)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x, y: valueY),
                        anchor: .center
                    )
                }
                if node.slot == 12 {
                    let gainText = String(format: "%+.1f dB", outputGain)
                    let valueY = midY + circleRadius + 18
                    ctx.draw(
                        Text(gainText)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x, y: valueY),
                        anchor: .center
                    )
                }

                // Special case: EQ node (slot 5)
                if node.slot == 5 && abs(preEQPeak) < 89 {
                    let eqX = nodeXCenter(slot: 5, width: size.width)
                    
                    // Pre-EQ peak (left of node)
                    let preText = String(format: "%.1f dB", preEQPeak)
                    ctx.draw(
                        Text(preText)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.tertiary),
                        at: CGPoint(x: eqX - 20, y: midY + 12),
                        anchor: .trailing
                    )
                    
                    // Post-EQ peak (right of node)
                    let postText = String(format: "%.1f dB", postEQPeak)
                    ctx.draw(
                        Text(postText)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.tertiary),
                        at: CGPoint(x: eqX + 4, y: midY + 12),
                        anchor: .leading
                    )
                    
                    // Delta below node
                    let delta = postEQPeak - preEQPeak
                    let deltaText = String(format: "%+.1f", delta)
                    let deltaY = midY + circleRadius + 18
                    ctx.draw(
                        Text(deltaText)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(NSColor.systemBlue).opacity(0.8)),
                        at: CGPoint(x: eqX, y: deltaY),
                        anchor: .center
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func nodeXCenter(slot: Int, width: CGFloat) -> CGFloat {
        let usable = width - 32
        let step = usable / CGFloat(12)
        return 16 + CGFloat(slot) * step
    }

    private func grBarHeight(gr: Float, maxHeight: CGFloat = 16) -> CGFloat {
        let clamped = max(0, min(18, abs(gr)))
        return CGFloat(clamped / 18) * maxHeight
    }

    private func grColor(gr: Float) -> Color {
        let abs = abs(gr)
        if abs < 1 { return .green }
        if abs < 3 { return .yellow }
        if abs < 6 { return .orange }
        return .red
    }
}

// MARK: - Node Definition

private struct NodeDef {
    let slot: Int
    let label: String
    let isAlwaysOn: Bool
    let isEnabled: Bool
    let grValue: Float?
    let isEQNode: Bool
    let nodeColor: NSColor
}
