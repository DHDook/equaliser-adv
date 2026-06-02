# Agent Instructions: Fix RTA Bar Scaling in equaliser-adv

## Context

The app has dual 31-band input and output RTA (Real-Time Analyser) graphs. Currently, most bands are
pegged at maximum height during normal playback at low levels. The bars should scale proportionally
to the amplitude of each frequency band, only reaching maximum when clipping occurs (i.e. signal at
or above 0 dBFS).

The root cause is almost certainly one or more of the following:

1. **FFT magnitude values are not normalised** — raw FFT output is used directly without dividing by
   the FFT size or window sum, so all values appear enormous.
2. **Wrong magnitude domain** — linear amplitude values are being mapped to bar height as if they
   were already in dB, or vice versa. Linear FFT magnitudes span many orders of magnitude; without a
   log scale they all cluster near the top.
3. **Reference level mismatch** — the dBFS floor/ceiling used to map the 0–1 bar height is wrong
   (e.g. clamp range is `-1.0 to 1.0` instead of `-80 dBFS to 0 dBFS`).
4. **Missing window compensation** — a Hann or other window reduces energy; without compensating the
   amplitude scale reads ~6 dB too high and non-linearly across bands.
5. **Float vs integer sample scaling** — AVAudioPCMBuffer samples in Swift are already in the range
   `-1.0…1.0`; if the code multiplies them by INT16_MAX (32767) before FFT they will be ~90 dB too
   loud.

---

## Step-by-Step Fix Instructions

### 1. Locate the RTA computation code

Find the file(s) that:
- Tap the audio graph (likely using `AVAudioNode.installTap(onBus:bufferSize:format:block:)`)
- Perform the FFT (likely using `vDSP_fft_zrip` or the Accelerate `DSPSplitComplex` API)
- Produce per-band magnitude values that are fed to the RTA view

Common file names to look for: `RTAEngine.swift`, `AudioEngine.swift`, `SpectrumAnalyser.swift`,
`RTAView.swift`, or any file containing `vDSP_fft`.

---

### 2. Normalise the FFT output by FFT size

After computing the FFT and taking magnitudes, the raw complex magnitudes must be divided by the FFT
length (`N`) to produce a normalised linear magnitude in the range `0…1` for a full-scale sine wave.

**Find code that looks like this:**
```swift
vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
```

**Add normalisation immediately after:**
```swift
// Normalise by FFT size so a full-scale sine reads 1.0
var normFactor = 2.0 / Float(fftSize)   // ×2 because we use the one-sided spectrum
vDSP_vsmul(magnitudes, 1, &normFactor, &magnitudes, 1, vDSP_Length(halfN))
```

> **Note:** If you are using `vDSP_fft_zrip` (real-to-complex), the DC and Nyquist bins are packed
> into the split-complex struct; those two bins should be halved separately or simply excluded from
> display.

---

### 3. Convert to dBFS (logarithmic scale)

A linear magnitude must be converted to decibels before mapping to bar height. A full-scale signal
(magnitude = 1.0 after step 2) must map to 0 dBFS.

**Replace or add after normalisation:**
```swift
// Convert to dBFS: 20 * log10(magnitude), clamp to floor
let dBFloor: Float = -80.0   // anything quieter than -80 dB shows as 0 height

var dBValues = [Float](repeating: dBFloor, count: halfN)
// vDSP_vdbcon converts to 20*log10 when flag=1
vDSP_vdbcon(magnitudes, 1, &dBValues, 1, vDSP_Length(halfN), 1 /* 20*log10 */)

// Clamp values to [dBFloor, 0]
var floor = dBFloor
var ceiling: Float = 0.0
vDSP_vclip(dBValues, 1, &floor, &ceiling, &dBValues, 1, vDSP_Length(halfN))
```

---

### 4. Map dB values to 0–1 bar height

Convert the clamped dBFS values to a normalised height for the UI, where `0.0 = silence` and
`1.0 = clipping (0 dBFS)`.

```swift
// Map [-80, 0] dBFS → [0.0, 1.0]
let dBRange: Float = abs(dBFloor)   // 80.0
var normalised = dBValues.map { ($0 - dBFloor) / dBRange }
// normalised is now 0.0 (silent) … 1.0 (clipping)
```

Pass `normalised` (an array of 31 floats, one per band) to the RTA view.

---

### 5. Aggregate FFT bins into 31 bands

Verify that the FFT bin-to-band mapping is correct. 31-band RTA uses ISO octave-third centre
frequencies (20 Hz … 20 kHz). Each band should average (or take the max of) the FFT bins that fall
within its frequency range.

Pseudocode to check:
```swift
for band in 0..<31 {
    let lowHz  = bandCentreFrequencies[band] / pow(2, 1.0/6.0)
    let highHz = bandCentreFrequencies[band] * pow(2, 1.0/6.0)
    let lowBin  = Int((lowHz  / sampleRate) * Float(fftSize))
    let highBin = Int((highHz / sampleRate) * Float(fftSize))
    // average dBValues[lowBin...highBin] → band level
}
```

A common mistake is mapping all bands to the same bin index, which causes all 31 bars to display the
same (often maximum) value.

---

### 6. Apply a window function and compensate for its gain

If the code applies a window (Hann, Hamming, etc.) before the FFT, the window attenuates the signal
energy. Add a coherent gain compensation factor so amplitudes remain calibrated.

For a Hann window, the coherent gain is 0.5. Compensate by multiplying magnitudes by `1/0.5 = 2.0`:
```swift
// After applying Hann window but before FFT
// Coherent gain of Hann = 0.5, so compensate:
var windowCompensation: Float = 2.0
vDSP_vsmul(windowedSamples, 1, &windowCompensation, &windowedSamples, 1, vDSP_Length(fftSize))
```

Alternatively, absorb this into the normalisation factor in step 2 (`normFactor = 2.0 / (Float(fftSize) * 0.5)`).

---

### 7. Check that AVAudioPCMBuffer samples are used as-is

`AVAudioPCMBuffer` in Swift provides 32-bit float samples already in the range `-1.0…1.0`. Confirm
that no code multiplies these by `32767`, `INT16_MAX`, or any integer scaling constant before
passing them to the FFT. If such multiplication exists, remove it.

```swift
// WRONG — do not do this:
let sample = buffer.floatChannelData![0][i] * 32767

// CORRECT:
let sample = buffer.floatChannelData![0][i]
```

---

### 8. Add clipping indicator

Once scaling is correct, a bar reaching exactly `1.0` (normalised height) means the signal hit
0 dBFS — i.e. clipping. In the RTA view's draw call, colour bars red when `barHeight >= 1.0` (or
when the raw dBFS value >= 0):

```swift
let isClipping = bandLevel >= 0.0  // dBFS
barColor = isClipping ? .red : .green
```

---

### 9. Smooth the bar animation (optional but recommended)

Raw FFT frames update at the tap callback rate and can cause jarring flicker. Apply a simple
exponential moving average:

```swift
let smoothing: Float = 0.8   // 0 = no smoothing, 1 = frozen
smoothedLevels[i] = smoothing * smoothedLevels[i] + (1 - smoothing) * newLevels[i]
```

Use `smoothedLevels` for rendering.

---

## Summary Checklist

The agent should verify each of the following is true after making changes:

- [ ] FFT output is divided by `fftSize` (and `2×` for one-sided spectrum) before any dB conversion.
- [ ] Magnitudes are converted with `20 * log10(magnitude)` (not `10 * log10`).
- [ ] The dB floor is a sensible negative value (e.g. `-80 dBFS`), not `0` or positive.
- [ ] Bar height is mapped as `(dBFS - floor) / abs(floor)` → `0.0…1.0`.
- [ ] `AVAudioPCMBuffer` float samples are **not** scaled by any integer constant before FFT.
- [ ] Each of the 31 bands maps to a distinct, non-overlapping range of FFT bins.
- [ ] Window compensation gain is applied if a window function is used.
- [ ] At silence or near-silence, all bars sit close to zero height.
- [ ] At full-scale (0 dBFS) output, bars reach the top and trigger the clipping indicator.
