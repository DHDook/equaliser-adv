---
name: DynamicsInlineView polling removed
description: The 60 Hz Timer and all ballistic GR @State vars were stripped from DynamicsInlineView; the view is now bypass-toggles only.
---

The old `DynamicsInlineView` drove a 60 Hz `Timer.publish` and carried ~20 `@State` vars for ballistic GR smoothing, peak-hold, phase correlation, and balance. All of those were removed.

**What it does now:** Two columns of mini toggle rows (col2Toggle) — column1 for De-Esser/M-Band/Comp./Expander/Clipper/Limiter and column2 for Widener/LUFS/De-Harsh/Contour/DC Filter. Header row has the ? definitions popover and the `waveform.path` button that opens the full `DynamicsView` panel.

**Why:** CPU reduction (60 Hz SwiftUI redraws every time the window is open, even when idle). Meter visualisation moved to the dedicated RTADashboardView (20 Hz, render-thread ring buffers).

**How to apply:** Do not re-add a Timer or ballistic state to DynamicsInlineView. If per-processor GR display is needed in the inline widget, wire it through the existing `AdvancedDualSpectrumAnalyzer` or a dedicated `@Observable` published from the render thread at a lower rate.
