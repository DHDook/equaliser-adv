---
name: RTA pipeline wiring
description: How the dual 31-band RTA ring buffers are connected from the audio render thread to the SwiftUI analyser view.
---

## Data flow

```
RenderPipeline (audio thread)
  → context.writeRTAInput(frameCount:)        after provideFrames
  → context.writeRTAOutput(from:frameCount:)  after updateOutputMeters
        ↓
RenderCallbackContext
  nonisolated(unsafe) var rtaInputBuffer:  LockFreeAudioRingBuffer?
  nonisolated(unsafe) var rtaOutputBuffer: LockFreeAudioRingBuffer?
        ↓
AdvancedDualSpectrumAnalyzer  (EqualiserStore.rtaAnalyzer)
  inputRingBuffer / outputRingBuffer  — written by render thread, read by analyser
  20 Hz Timer → FFT → 31 ISO 1/3-oct bands → ballistics → @Published arrays
        ↓
RTADashboardView / RTAMeterBridge  (SwiftUI, main thread)
```

## Wiring call

`EqualiserStore.wireRTAAnalyzer()` calls `renderPipeline?.setRTABuffers(input:output:)`.
Must be called after a pipeline is started (e.g. inside `reconfigureRouting` completion or wherever `PipelineManager` makes `renderPipeline` non-nil).

**Why LockFreeAudioRingBuffer:** SPSC power-of-two mask ring; write side is lock-free for real-time safety; read side drains on a background timer, not the audio thread.

**Why:** Avoids the previous approach of polling GR atomics at 60 Hz in SwiftUI state — the ring buffer + 20 Hz analyser timer only wakes up when audio is flowing, and its FFT cost is off the main thread.
