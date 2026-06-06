# Equaliser — Full Operational Manual

---

## Part 1 — Getting Started

### Installation and First Launch

1. Launch Equaliser — the main window opens and the menu bar icon (⚡) appears.
2. If prompted, install the virtual audio driver — this requires your administrator password.
3. Once the driver is active, all system audio is automatically routed through the EQ pipeline.
4. The menu bar icon changes colour to confirm the pipeline is live.

### The Menu Bar

The menu bar icon is the quickest way to control Equaliser without opening the full window. From the menu bar you can:

- Toggle System EQ bypass on and off
- Switch between saved presets
- Open the main window
- Quit the application

---

## Part 2 — The Main Window

The main window is divided into three horizontal zones:

1. **Top strip** — Level meters (left), Gain controls + Compare controls (centre), Dynamics inline panel (right)
2. **RTA graphs** — Dual 31-band Pre-EQ and Post-EQ spectrum analysers
3. **EQ bands** — The parametric equaliser band grid

The **System EQ** and **Meters** toggles in the toolbar (top-right of the window) globally enable or disable the full DSP pipeline and level metering respectively.

### The EQ Bands

Each band column contains:

- **Frequency** (top label) — the centre frequency in Hz or kHz; click to edit directly
- **Gain slider** — drag up to boost, down to cut
- **dB value** (bottom label) — the current gain; click to type a precise value

Click the **gear icon (⚙)** on any band to open the full band popover:

| Parameter | Range | Description |
|-----------|-------|-------------|
| Gain | −36 to +36 dB | Boost or cut at this frequency |
| Frequency | 20 Hz – 20 kHz | Centre frequency of the filter |
| Q / Bandwidth | 0.1 – 100 | Filter width (high Q = narrow, surgical; low Q = wide, gentle) |
| Filter Type | Parametric, High Shelf, Low Shelf, High Pass, Low Pass, Notch, All-Pass | The shape of the filter curve |

**Double-click any slider** to reset it to 0 dB.

### Channel Mode

Above the band sliders, switch between **Linked** (both L/R channels share the same EQ curve) and **Stereo** (independent L/R curves). In Stereo mode, use the **L / R** selector to choose which channel you are editing.

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Tab / Shift+Tab | Move between bands |
| ↑ / ↓ | Adjust gain |
| Enter / Escape | Confirm and exit edit |
| ⌘B | Toggle bypass |
| ⌘S | Save current preset |

---

## Part 3 — Gain Staging and the Signal Path

### Why Gain Staging Matters

The full chain from your Mac to your speakers is:

```
Equaliser (digital) → DAC (digital-to-analogue)
  → Preamplifier / volume control
    → Power amplifier
      → Loudspeakers
```

Every stage introduces gain. Keeping levels appropriate at each digital handoff prevents clipping and noise. The golden rule is: **gain stage earlier, not later** — set the Equaliser output so it never clips the DAC input, then use the analogue volume control on your preamplifier for your listening level.

### Input Gain

Applies a linear gain multiplier **before** any EQ or dynamics processing. Use it when the source material is very loud or very quiet. Recommended starting point: **0 dB** (unity).

### Output Gain

Applies gain **after** all EQ and dynamics, but before the DAC. Think of this as a master trim to compensate for level changes introduced by EQ boosts. If you have applied several large boosts, reduce the output gain to recover headroom before the DAC.

### Practical Headroom Recommendation

Keep the **Peak OUT** meter below **−0.5 dBFS** continuously. The Limiter (Stage 10 in the dynamics chain) enforces a configurable ceiling; set it to **−0.5 dB** and engage **True-Peak Guard** to prevent inter-sample overs (hidden analogue peaks that occur between digital samples during DAC reconstruction). This guarantees a clean electrical signal out of the DAC into your preamplifier's analogue input stage.

---

## Part 4 — The EQ Matrix

### Filter Type Reference

| Type | Description | Typical Use |
|------|-------------|-------------|
| Parametric (Bell) | Symmetric boost/cut bell curve | Frequency-specific corrections |
| High Shelf | Boosts or cuts all frequencies above the corner | Air/brightness adjustments |
| Low Shelf | Boosts or cuts all frequencies below the corner | Bass warmth or thinness |
| High Pass | Rolls off everything below the frequency | Removing rumble, sub-bass below speaker range |
| Low Pass | Rolls off everything above the frequency | Taming harshness above hearing range |
| Notch | Very narrow deep cut | Removing electrical hum (50/60 Hz) |
| All-Pass | Changes phase without affecting amplitude | Phase alignment, group delay correction |

### Bandwidth (Q) Guidance

| Q Value | Description | Effect Width |
|---------|-------------|--------------|
| 0.1 – 0.5 | Very wide | ±2–3 octaves |
| 0.5 – 1.5 | Wide | ~1–2 octaves |
| 1.5 – 4 | Moderate | ~0.5–1 octave |
| 4 – 10 | Narrow | ~0.25 octave |
| 10 – 100 | Very narrow / surgical | Individual resonances |

### General Speaker Tuning Guidance

Common correction targets for typical bookshelf and floor-standing speakers:

- **40–80 Hz** — Slight cut (−1 to −3 dB, broad Q 0.5) to reduce mid-bass warmth from bass reflex ports, which peak in most rooms.
- **2–4 kHz** — Horn-loaded or forward-sounding tweeters may benefit from a small cut (−1 to −2 dB, Q 2) to improve long-term listenability.
- **10–16 kHz** — Gentle boost (+1 to +2 dB, low Q 0.5) can restore air that analogue-chain high-frequency loss reduces.
- **High Pass** — If using a subwoofer, apply a high-pass filter at your chosen crossover frequency (e.g., 80 Hz, LR4 slope) to the main speakers to prevent them straining below their useful bandwidth.

### Subwoofer Integration

- Set the subwoofer's built-in crossover to match your chosen crossover frequency (typically 80 Hz).
- Apply a **Low Pass filter** in Equaliser on a separate channel (if routing the sub separately), or rely on the subwoofer's built-in crossover.
- Use the **Sub-Bass Phase Alignment** (LTI section in the Dynamics panel) to correct phase mismatches at the crossover point between the sub and main speakers.

---

## Part 5 — Level Metering

### The Horizontal Master Meters

The RTA dashboard shows two pairs of horizontal progress bars:

| Row | Measures |
|-----|---------|
| **IN Peak** | Highest peak level entering the EQ chain |
| **IN RMS** | Average (RMS) energy entering the chain |
| **OUT Peak** | Highest peak level leaving the dynamics chain |
| **OUT RMS** | Average energy at the output |

### Reading the Meters

- **Green** — Signal is healthy, well within headroom.
- **Yellow** — Signal is approaching the ceiling (> 70 % full scale).
- **Orange** — Signal is close to clipping (> 90 %).
- **Red** — Signal has clipped (exceeds 0 dBFS or the configured ceiling).

### Clip Indicator

The **CLIP** light in the RTA header turns red and holds for 1.5 seconds whenever a clip is detected. Click it to reset manually. Use it to catch occasional transient overs that happen too fast to see on the bar meters.

### Tracking Transients

The meters are highly responsive. If **Peak IN** reaches −2 dBFS while **Peak OUT** is pinned solidly at your Limiter ceiling (e.g., −0.5 dBFS), the look-ahead limiter is actively shaving transient spikes. This is the correct behaviour — it confirms that the DAC will never receive a clipped overload signal.

---

## Part 6 — The Dynamics Chain

The dynamics processing consists of 10 stages applied in sequence. Each can be individually enabled or bypassed using the toggle in the **Dynamics Inline** panel (the waveform icon ≋ in the top-right of the main window) or configured in detail via the **Dynamics panel** (click ≋ to open it).

### Signal Flow

```
Input Signal
  → [1] Stereo Fold-Down / Mode (optional)
  → [2] DC Offset Filter (optional)
  → [3] Stereo Widener (optional)
  → [4] LUFS Loudness Match (optional)
  → [5] Loudness Contouring (optional)
  → [6] De-Esser
  → [7] Multiband Compressor
  → [8] Wideband Compressor
  → [9] Expander
  → [10] Soft Clipper
  → [De-Harsh Filter] (optional)
  → [Brickwall Limiter]
  → [L/R Balance + Time Delay]
  → [Pause Gate]
  → [TPDF Dither]
  → [LTI Processing Suite]
  → Output Signal
```

### Stage-by-Stage Reference

#### Stage 1 — Stereo Fold-Down

Controls the stereo format of the signal before all other processing.

| Mode | Description |
|------|-------------|
| Stereo | Full stereo signal (default) |
| Wide Mono | Mid-only signal sent to both channels — useful for checking mono compatibility |
| True Mono | L+R summed and halved; identical output on both channels |

#### Stage 2 — DC Offset Filter

A 0.5 Hz single-pole high-pass filter that removes any DC component in the signal. Many vintage recordings and internet streams carry a hidden DC offset. While inaudible, DC offset shifts the audio waveform away from the electrical zero line, forcing amplifier output stages to dissipate energy even during silence. **Recommendation: leave this ON** to protect your amplifier and free up headroom.

#### Stage 3 — Stereo Widener

A three-band M/S processor that independently controls stereo width in three regions using mid/side decomposition:

**Mathematical Model:**
The processor first converts L/R stereo to mid/side representation:
```
M = (L + R) / √2  (mid channel - mono information)
S = (L - R) / √2  (side channel - stereo difference)
```
Each frequency band applies a gain multiplier to the side channel:
```
S' = S × width_factor
```
Then reconstructs to L/R:
```
L' = (M + S') / √2
R' = (M - S') / √2
```

- **Low band (< 200 Hz)** — Default 0.0 (mono). Keeping bass mono is acoustically correct because low frequencies are omnidirectional and a mono bass is essential for proper subwoofer integration.
- **Mid band (200 Hz – 4 kHz)** — Default 1.4. Moderate expansion adds perceived width.
- **High band (> 4 kHz)** — Default 1.25. Gentle expansion adds air and space.

#### Stage 4 — LUFS Loudness Match

Continuously measures the 3-second K-weighted integrated loudness of the signal and applies a smooth gain correction to hit a target in LUFS. Prevents excessively loud content from overdriving subsequent stages.

**Mathematical Model:**
Uses EBU R.128 loudness measurement with K-weighting:
```
L_k = -0.691 + 10 × log₁₀(Σ |X_k(f)|² × G_k(f)²)
```
Where X_k(f) is the FFT bin magnitude and G_k(f) is the K-weighting filter response. The integrated loudness over time T is:
```
L_integrated = -0.691 + 10 × log₁₀((1/T) ∫₀ᵀ 10^(L_k(t)/10) dt)
```
The gain correction is computed as:
```
gain_correction = 10^((target_LUFS - measured_LUFS) / 20)
```
Applied with a first-order IIR smoothing filter for transparent transitions.

| Parameter | Range | Recommendation |
|-----------|-------|---------------|
| Target | −24 to −10 LUFS | −16 LUFS for critical listening; −14 LUFS for casual background listening |
| Dialogue Gate | ON / OFF | ON: raises the gating floor to −60 dBFS, ignoring silence. Better for film/TV content. |

#### Stage 5 — Loudness Contouring

Applies a gentle Fletcher-Munson (equal-loudness) compensation curve: a small bass boost and a small treble lift that counteract the ear's reduced sensitivity at lower listening levels. Enable when listening at quiet levels to restore perceived fullness.

**Mathematical Model:**
Based on ISO 226:2003 equal-loudness contours. The compensation applies frequency-dependent gain:
```
G(f) = 10^(ΔL(f)/20)
```
Where ΔL(f) is the loudness level difference at frequency f between reference and target listening levels. Typical implementation uses a dual-shelving filter:
```
H_bass(f) = (√(1 + (f/f_b)²)) / (√(1 + (f/f_b·Q)²))  (low-frequency boost)
H_treble(f) = (√(1 + (f·Q/f_t)²)) / (√(1 + (f/f_t)²))  (high-frequency boost)
```
Combined response: H_total(f) = H_bass(f) × H_treble(f)

#### Stage 6 — De-Esser

A frequency-selective compressor targeting sibilant frequencies (typically 4–10 kHz). Apply to recordings or streams where "S", "T", and "CH" sounds are harsh or fatiguing.

**Mathematical Model:**
Uses a side-chain filter to isolate the sibilance band:
```
H_sc(f) = 1 / (1 + (f/f_c/Q)² - (f/f_c)²)  (band-pass filter)
```
The compression gain is computed from the filtered side-chain signal:
```
gain_dB = -ratio × max(0, level_sc - threshold)
```
In Dynamic EQ mode, only the sibilance band is attenuated using a dynamic biquad filter:
```
H_dynamic(f, t) = 1 - g(t) × |H_sc(f)|
```
Where g(t) is the time-varying gain reduction. This preserves the full spectral content outside the sibilance band for greater transparency.

| Parameter | Range | Description |
|-----------|-------|-------------|
| Frequency | 2000 – 10000 Hz | Centre of the sibilance band |
| Threshold | −60 to 0 dB | Level above which gain reduction begins |
| Dynamic EQ Mode | ON / OFF | ON: attenuates only the sibilance band, not the full signal — more transparent |

#### Stage 7 — Multiband Compressor

Splits the signal into three frequency bands using Linkwitz-Riley crossovers, then compresses each band independently. Prevents loud bass from triggering unnecessary compression in the midrange.

**Mathematical Model:**
Linkwitz-Riley 4th-order crossovers (LR4) provide perfect magnitude summation:
```
H_Low(f) = 1 / (1 + (f/f_c)⁴)  (low-pass)
H_High(f) = (f/f_c)⁴ / (1 + (f/f_c)⁴)  (high-pass)
H_Mid(f) = H_High_Low × H_Low_High  (band-pass from two cascaded crossovers)
```
Each band applies independent compression:
```
gain_band = 10^(-ratio × max(0, level_band - threshold) / 20)
```
With soft-knee smoothing:
```
effective_threshold = threshold - (knee/2) + sqrt((knee/2)² + (level - threshold + knee/2)²)
```
Attack and release use first-order IIR filters for smooth gain transitions.

| Parameter | Range | Description |
|-----------|-------|-------------|
| Low/Mid crossover | 40 – 250 Hz | Frequency separating the Low and Mid bands |
| Mid/High crossover | 1000 – 8000 Hz | Frequency separating the Mid and High bands |
| Threshold (per band) | −60 to 0 dB | Level above which compression begins in that band |
| Slope | Gentle (LR4, 24 dB/oct) / Steep (LR8, 48 dB/oct) | Crossover steepness |

#### Stage 8 — Wideband Compressor

Feed-forward compressor acting on the full frequency range. Use to tame overall dynamic range after multiband compression.

**Mathematical Model:**
Standard feed-forward compression with peak detection:
```
level_dB = 20 × log₁₀(|x(n)|)
gain_dB = -ratio × max(0, level_dB - effective_threshold)
```
Soft-knee implementation:
```
effective_threshold = threshold - (knee/2) + sqrt((knee/2)² + (level - threshold + knee/2)²)
```
Attack smoothing (first-order IIR):
```
level_smoothed(n) = α_attack × level(n) + (1 - α_attack) × level_smoothed(n-1)
α_attack = exp(-1/(fs × attack_time))
```
Release smoothing:
```
α_release = exp(-1/(fs × release_time))
```
Makeup gain compensates for average gain reduction to maintain perceived loudness.

| Parameter | Range | Recommendation |
|-----------|-------|---------------|
| Threshold | −60 to 0 dB | −16 dB for moderate, −10 dB for light |
| Ratio | 1:1 to 20:1 | 3.5:1 for music; 6:1 for speech |
| Knee | 0 (hard) – 20 dB (soft) | 6 dB soft knee for transparent music compression |
| Attack | 0.1 – 100 ms | 25 ms preserves transient punch |
| Release | 5 – 1000 ms | 150 ms for smooth recovery |
| Makeup Gain | 0 – 24 dB | Compensates for gain lost to compression |

#### Stage 9 — Expander

A downward dynamic-range expander that attenuates signals below a threshold, widening perceived dynamics. Useful for reducing low-level noise between tracks.

**Mathematical Model:**
Inverse of compression - attenuates signals below threshold:
```
gain_dB = -ratio × max(0, threshold - level_dB)
```
The range parameter limits maximum attenuation:
```
gain_dB = max(gain_dB, -range)
```
Soft-knee can be applied similarly to compression for smoother transitions. The expander increases the dynamic range difference between loud and quiet passages, effectively "gating" low-level noise while preserving transients above threshold.

#### Stage 10 — Soft Clipper

An analogue-style wave-shaper that gently rounds transient peaks before the limiter. Rather than hard-clipping, it progressively saturates the signal above the threshold using a smooth sigmoid curve. This reduces the amount of work the limiter must do on sharp transients.

**Mathematical Model:**
Uses a cubic soft-clipping function:
```
y = x - (x³ / 3)  for |x| ≤ 1
y = sign(x) × (2/3)  for |x| > 1
```
With adjustable knee parameter controlling the transition region:
```
y = x × (1 - (|x|/threshold)^(2×knee) / (2×knee+1))
```
The asymmetry trim applies different gains to positive and negative halves:
```
y_positive = y × (1 + asymmetry/20)  for y > 0
y_negative = y × (1 - asymmetry/20)  for y < 0
```
This balances asymmetric waveforms, freeing 1–2 dB of headroom. Recommended value: **+0.5 to +1.5 dB** for acoustic and vintage rock material.

#### Brickwall Limiter

The final protection stage. A look-ahead limiter with a configurable ceiling that guarantees the output cannot exceed the set level.

**Mathematical Model:**
Look-ahead processing delays the signal by the look-ahead time, allowing the limiter to "see" peaks before they arrive:
```
y(n) = x(n - lookahead_samples) × gain(n)
```
Gain computation based on peak detection over the look-ahead window:
```
peak_lookahead = max(|x(n)|, |x(n-1)|, ..., |x(n-lookahead_samples)|)
gain_dB = ceiling_dB - peak_lookahead_dB
```
With True-Peak Guard, 4x oversampling is applied:
```
x_oversampled = upsample(x, factor=4)
peak_true = max(|x_oversampled|)
```
This catches inter-sample peaks that would exceed 0 dBFS after DAC reconstruction. The release envelope uses exponential smoothing:
```
gain(n) = min(gain(n), gain(n-1) + release_rate)
```
Attack is instantaneous for true brickwall behavior.

| Parameter | Range | Recommendation |
|-----------|-------|---------------|
| Ceiling | −6 to 0 dB | **−0.5 dB** (protects DAC input from inter-sample overs) |
| Attack | 0 – 10 ms | 0.1 ms (transparent — the limiter should be heard as little as possible) |
| Release | 5 – 250 ms | 20 ms |
| Look-ahead | 0.5 – 10 ms | 2.0 ms |
| True-Peak Guard | ON / OFF | **Always ON** — engages 4x polyphase oversampling to catch inter-sample peaks and prevent hidden analogue overshoots from clipping the DAC output buffer. |

**Why −0.5 dBFS?** Standard digital limiters operate on discrete sample values. When the DAC performs digital-to-analogue reconstruction, the continuous analogue waveform can peak higher between samples (an inter-sample peak). A −0.5 dBFS ceiling combined with True-Peak Guard provides a mathematically guaranteed safety margin so the analogue signal entering the preamplifier's input never exceeds 0 dBV.

---

## Part 7 — Spectral and Spatial Utilities

### De-Harsh Filter

A high-frequency tilt filter applied after the soft clipper. Gently attenuates frequencies above ~3.5 kHz by a configurable amount (typically −1.5 dB). Use when your tweeter sounds fatiguing after long listening sessions — certain tweeter designs and room acoustics can make the top end appear forward.

**Mathematical Model:**
First-order shelving filter with adjustable tilt:
```
H(f) = (1 + (f/f_c) × tilt) / (1 + (f/f_c))
```
Where tilt controls the high-frequency attenuation (negative values for cut). The filter provides a gentle 6 dB/octave roll-off above the corner frequency, preserving harmonic content while reducing harshness. The tilt parameter allows continuous adjustment from flat to -6 dB at high frequencies.

### Channel Balance

The L/R Channel Balance slider sits below the Gain In / Gain Out controls on the main window. It defaults to centre (100% output on both channels) and scales linearly:

- **Full left** — 100% left channel, 0% right channel
- **Centre** — 100% both channels (default)
- **Full right** — 0% left channel, 100% right channel

Use this when one speaker is physically louder than the other, or when the source material has an unbalanced stereo image.

### Stereo Balance (Advanced)

L/R balance correction. −1.0 = full left, 0.0 = centre, +1.0 = full right. Applied after the dynamics chain as a constant-power gain correction. **Distinct from the Channel Balance slider** — Stereo Balance uses a constant-power panning law and is part of the Symmetry Balance LTI feature designed for room correction workflows.

### L/R Time Delay

Delays the right channel relative to the left (positive value = right delayed). Applied as a post-chain offset. Used for correcting timing mismatches between two speakers at different distances from the listening position.

**Mathematical Model:**
Fractional-sample delay using all-pass interpolation:
```
H(z) = (a + z⁻¹) / (1 + a × z⁻¹)
a = (1 - delay) / (1 + delay)
```
For delays longer than one sample, a combination of integer delay (buffer shift) and fractional all-pass correction is used. The delay in samples is:
```
delay_samples = delay_ms × sample_rate / 1000
```
This ensures phase-coherent time alignment between channels at the crossover frequency, critical for proper stereo imaging.

### Pause Gate

Smoothly silences the output during extended near-silence periods, preventing low-level amplifier hiss and click artefacts when audio resumes. Useful when listening through a vintage amplifier that produces audible hiss.

**Control Order:**
1. Enable Pause Gate
2. Threshold
3. Hold Time
4. Release (Fade-Out)
5. Attack (Fade-In)

**Threshold**
- Range: −120 dBFS to −40 dBFS
- Default: −90 dBFS
- Description: Signal level below which the Pause Gate begins preparing to close.

**Hold Time**
- Range: 0 ms to 5000 ms
- Default: 250 ms
- Description: How long the Pause Gate remains open after signal falls below threshold. Prevents unnecessary gate activity during short interruptions.

**Release (Fade-Out)**
- Range: 0 ms to 5000 ms
- Default: 500 ms
- Description: Controls how quickly audio fades out when playback stops or the Pause Gate closes. A shorter Release creates a rapid mute; a longer Release creates a smoother fade to silence.

**Attack (Fade-In)**
- Range: 0 ms to 500 ms
- Default: 25 ms
- Description: Controls how quickly audio fades back in when playback resumes or the Pause Gate opens. A shorter Attack restores audio almost immediately; a longer Attack creates a smoother fade-in and can help prevent clicks or abrupt transitions. This control directly affects perceived resume responsiveness.

**Recommended Defaults:**
- Threshold: −90 dBFS
- Hold Time: 250 ms
- Release (Fade-Out): 500 ms
- Attack (Fade-In): 25 ms

These settings provide fast resume behavior while maintaining smooth transitions during pause and unpause operations.

### Sync Buffer to Latency Mode

Synchronises the internal processing buffer to the selected latency mode. When enabled, the buffer size adapts to match the chosen mode (Music, Low Latency, or Broadcast), ensuring that all processing stages complete within the allotted hardware buffer window. **Enable this** if you experience audio dropouts or glitching at low latency settings.

---

## Part 8 — LTI Processing Suite

The LTI (Linear Time-Invariant) processing suite contains ten advanced signal processing algorithms. All ten have master bypass toggles in both the Dynamics Inline panel and the Dynamics configuration panel.

### Symmetry Balance

**What it does:** Applies relative gain multipliers to the L and R channels to correct for listening-position asymmetry. Unlike the simple L/R Balance trim, Symmetry Balance is specifically designed for use with a room correction workflow.

**Mathematical Model:**
Constant-power panning law maintains overall loudness while shifting the stereo image:
```
gain_L = cos(θ × π/4)
gain_R = sin(θ × π/4)
```
Where θ ranges from -1 (full left) to +1 (full right). This ensures that:
```
L'² + R'² = L² + R²  (constant power)
```
Unlike linear balance which would reduce total level when off-center, constant-power balance preserves perceived loudness while shifting the image.

**How to calibrate:** Play a mono test tone. Adjust the Balance slider until the tone images perfectly in the centre of the soundstage between your speakers. Lock the setting and enable the toggle.

### Panning Gain Matrix

**What it does:** A bilinear gain matrix that blends a configurable proportion of the left channel into the right, and vice versa. Simulates the natural crossfeed that occurs when listening to stereo speakers (where each ear hears both speakers).

**Mathematical Model:**
2×2 mixing matrix with crossfeed coefficient α:
```
[L']   [1-α   α ] [L]
[R'] = [ α   1-α] [R]
```
Where α ∈ [0, 1] controls the amount of crossfeed. For α = 0.3 (default):
```
L' = 0.7 × L + 0.3 × R
R' = 0.3 × L + 0.7 × R
```
This simulates the acoustic crosstalk that occurs with speakers at approximately 60° separation, where each ear receives sound from both speakers with an inter-aural time difference (ITD) and level difference (ILD).

**Use case:** Particularly useful over headphones to simulate speaker listening. The 0.3 default crossfeed amount is calibrated for a standard 60° stereo loudspeaker placement angle.

### Linear Denoising Engine

**What it does:** Spectral subtraction noise floor reduction. The engine builds a running estimate of the noise power spectrum (measured during quiet passages) and subtracts it from each analysis frame. The threshold sets the estimated noise floor ceiling.

**Mathematical Model:**
Spectral subtraction with over-subtraction factor and spectral floor:
```
|Y(f)|² = |X(f)|² - α × |N(f)|²
```
Where X(f) is the input spectrum, N(f) is the noise estimate, and α is the over-subtraction factor (typically 1-2). To prevent musical artifacts:
```
|Y(f)|² = max(|Y(f)|², β × |X(f)|²)
```
Where β is the spectral floor parameter (typically 0.01-0.1). The noise estimate is updated during quiet passages using exponential smoothing:
```
|N(f)|²(n) = γ × |X(f)|²(n) + (1-γ) × |N(f)|²(n-1)
```
Only updated when the signal level is below the threshold parameter.

**Use case:** Removes low-level HVAC, room noise, and transformer hum from recordings made in live or untreated spaces.

### Speaker Impulse Response Alignment

**What it does:** Applies a fractional-sample delay compensation (sub-millisecond resolution) to time-align the acoustic centres of multi-driver speaker systems.

**Mathematical Model:**
Fractional delay using Lagrange interpolation or all-pass filters:
```
H(z) = z⁻ᴰ  where D = delay_samples + fractional_part
```
For fractional delays, a Thiran all-pass filter provides near-ideal phase response:
```
H(z) = Σₖ₌₀ᴺ aₖ × z⁻ᵏ / Σₖ₌₀ᴺ aₙ₋ₖ × z⁻ᵏ
```
Where coefficients aₖ are computed from the desired delay D and filter order N. This maintains phase linearity across the frequency band, ensuring that all frequencies arrive at the listening position simultaneously.

**Use case:** Most speakers with separate woofers and tweeters have physically different acoustic centres. Adjusting the fine delay aligns their impulse responses at the listening position, improving phase coherence in the crossover region.

**Setup:** Use Room EQ Wizard (REW) with a calibrated measurement microphone to measure the impulse response of each driver separately. Enter the time difference in milliseconds into the Fine Delay field.

### Recursive Crosstalk Cancellation Matrix

**What it does:** An iterative binaural inversion filter that actively reduces inter-channel acoustic leakage — the contamination of the left channel by the right speaker's output and vice versa.

**Mathematical Model:**
Models the acoustic crosstalk path as a 2×2 matrix H:
```
[L_ear]   [H_LL  H_LR] [L_speaker]
[R_ear] = [H_RL  H_RR] [R_speaker]
```
Where H_LL and H_RR are direct paths, H_LR and H_RL are crosstalk paths. The cancellation matrix C is computed as:
```
C = H⁻¹  (matrix inversion)
```
In practice, a regularized inversion is used to avoid instability:
```
C = (HᵀH + λI)⁻¹Hᵀ
```
Where λ is a regularization parameter. The recursive implementation updates the cancellation coefficients iteratively to adapt to room acoustics.

**Use case:** Widens the perceived stereo image at the listening position beyond what the speakers' physical placement provides. Effective at typical room listening distances of 2–3 metres.

### Room Boundary Early Reflection Cancellation

**What it does:** An FIR comb filter tuned to the arrival time of first-order room boundary reflections (floor, ceiling, front wall). The Room Size control sets the estimated first-reflection arrival time in milliseconds.

**Mathematical Model:**
Comb filter with notches at reflection frequencies:
```
H(z) = 1 - α × z⁻ᴰ
```
Where D is the delay in samples corresponding to the reflection arrival time, and α controls the cancellation depth. The notch frequencies are at:
```
f_notch = n × fs / D  for n = 0, 1, 2, ...
```
The filter creates destructive interference at frequencies where the reflection arrives 180° out of phase with the direct sound. Multiple reflections can be addressed by cascading comb filters with different delays.

**Estimating Room Size:** Measure the distance from the listener's head to the nearest reflective surface (typically the floor). Divide by the speed of sound (343 m/s) to get the one-way travel time. Multiply by 2 for the round trip. Example: 1.2 m floor distance → 2.4 m round trip → ~7 ms. Set Room Size to 7 ms.

### HPF Phase Linearisation

**What it does:** An all-pass FIR compensation network that linearises the group delay introduced by high-pass filter networks. When you apply a high-pass filter (e.g., 80 Hz to hand off bass to a subwoofer), the HPF introduces phase shift in the transition band. This correction removes that phase shift, maintaining time-domain accuracy.

**Mathematical Model:**
Standard IIR high-pass filters introduce frequency-dependent group delay:
```
τ_g(f) = -dφ(f)/df
```
Where φ(f) is the phase response. The phase linearisation filter is designed as an all-pass FIR with inverse phase response:
```
H_linearise(f) = e^(-j × φ_hpf(f))
```
Implemented using a linear-phase FIR filter with coefficients computed via frequency sampling or least-squares design. The filter length determines the accuracy of phase correction across the transition band.

**Recommended setting:** Match the Frequency parameter to your high-pass filter's −3 dB frequency (e.g., 80 Hz).

### Multi-Seat Complex Averaging

**What it does:** Combines head-related transfer function (HRTF) estimates from multiple listening positions into a single composite room correction. Rather than optimising for one chair, the correction targets all seats simultaneously.

**Use case:** When multiple listeners regularly use the system from different positions — for example, a sofa with two or three seats in front of the speakers.

### Sub-Bass Phase Alignment

**What it does:** An all-pass filter network that phase-aligns the sub-bass region (below the crossover frequency) with the main speaker bandwidth. Corrects the acoustic phase relationship between the subwoofer and the main speakers at the crossover point.

**Mathematical Model:**
Second-order all-pass filter for phase adjustment:
```
H(s) = (s² - (ω₀/Q) × s + ω₀²) / (s² + (ω₀/Q) × s + ω₀²)
```
Where ω₀ = 2π × f_crossover and Q controls the transition steepness. The phase response is:
```
φ(ω) = -2 × arctan((ω/ω₀) / (Q × (1 - (ω/ω₀)²)))
```
By adjusting Q, the phase at the crossover frequency can be rotated to achieve constructive summation with the main speakers. The goal is +3 dB at the crossover point (coherent sum of two equal-level signals).

**Setup:** Set Crossover to match the subwoofer's crossover frequency (typically 80 Hz). With this engaged, the summation of sub and main speakers at the crossover should be +3 dB coherent (constructive) rather than cancelling. Verify with an RTA measurement of the combined response.

### Zero-Latency Convolution Reverb Engine

**What it does:** Applies a room impulse response (RIR) to the audio signal using uniformly-partitioned FFT convolution. Unlike standard convolution reverb, this implementation adds zero samples of processing latency to the signal path.

**Mathematical Model:**
Convolution in time domain:
```
y(n) = Σₖ₌₀ᴸ⁻¹ h(k) × x(n-k)
```
Implemented using partitioned convolution for efficiency:
```
Y(m) = H(m) × X(m)  (frequency domain multiplication)
```
Where H(m) is the FFT of the impulse response partition and X(m) is the FFT of the input block. Uniform partitioning ensures:
```
latency = partition_size - 1
```
By setting partition_size = 1, zero latency is achieved. The dry/wet mix is:
```
output = (1 - mix) × dry + mix × wet
```
The wet signal is the convolved output, scaled by the mix parameter.

**Use case:** Simulates a specific acoustic space by convolving the dry signal with a measurement of that space. Can be used to make music recorded in a dead studio sound as if it were played in a concert hall, or to apply the measured acoustics of a reference listening room.

**Dry/Wet mix:** Keep low (0.05–0.15) for subtle room character. Higher values produce a reverberant effect. Load a custom impulse response by selecting it in the Reverb settings panel.

---

## Part 9 — Presets

### Factory Presets

| Preset | Description |
|--------|-------------|
| Flat | All bands at 0 dB — reference/bypass equivalent |
| Bass Boost | +3 dB shelf below 200 Hz; subtle low-mid fill |
| Treble Boost | +2 dB shelf above 5 kHz; presence lift |
| Vocal Presence | +2 dB at 3 kHz (Q 1.5); slight cut at 200 Hz |
| Podcast | Narrow cut at 400 Hz; boost at 1–4 kHz; HPF at 80 Hz |
| Rock | Low shelf +2 dB; mid scoop at 400 Hz; presence at 3 kHz |
| Electronic | Sub boost at 50 Hz; tight mid cut; high air |
| Jazz | Warmth cut at 250 Hz; presence at 2–3 kHz; open highs |
| Classical | Near-flat with gentle top-end air and room correction |
| Reference | Flat with HPF at 20 Hz to remove subsonic energy |

### Saving and Managing Presets

1. Dial in your EQ and dynamics settings.
2. Click **Save As…** in the preset menu and give the preset a name.
3. Presets store the full EQ band configuration, dynamics chain settings, and channel mode.

**Recommended workflow:** Keep separate presets for:
- Main speakers (with subwoofer configuration if applicable)
- Headphone listening (typically different EQ signature)
- Critical mixing reference (flat EQ, dynamics OFF)

### Importing Presets

Equaliser supports three import formats:

| Format | Extension | Source |
|--------|-----------|--------|
| Native preset | `.eqpreset` | Exported from another Equaliser installation |
| Room EQ Wizard | `.txt` (filter export) | REW version 5.30 or later |
| EasyEffects | `.json` | Linux EasyEffects preset format |

See [REW Import](./REW-Import.md) for the full Room EQ Wizard import workflow.

---

## Part 10 — Bypass and Compare

### Bypass (System EQ Toggle)

The **System EQ** toggle in the toolbar disables all EQ and dynamics processing. Audio passes through completely unprocessed. Use it to quickly check whether your EQ is helping or hurting.

### Compare Mode

The Compare control switches between three states:

| State | Description |
|-------|-------------|
| EQ | Your full EQ and dynamics chain is active |
| Flat | A bypass state with volume-matched output — pure A/B comparison |
| Δ Delta | Outputs only the *difference* between processed and unprocessed signal, in isolation |

**Delta mode** is particularly useful for verifying what the dynamics chain is doing — if you hear nothing in delta mode, the chain is not modifying the signal (all stages may be bypassed). A timer automatically returns to EQ mode after 5 minutes.

**Use Compare mode honestly.** Louder almost always sounds "better." Compare mode volume-matches the output so you judge the EQ on its actual sonic merits, not on a loudness illusion.

---

## Part 11 — Settings and System Configuration

### Driver

The Equaliser virtual audio driver (a fork of BlackHole) intercepts the system audio stream and routes it through the EQ pipeline before sending it to your chosen output device.

| Capture Mode | Description | When to Use |
|-------------|-------------|-------------|
| Shared Memory | Zero-copy direct memory transfer between processes | Default — lowest CPU, no orange menu bar indicator |
| HAL Input | Standard CoreAudio HAL capture path | Required on older macOS versions without shared memory support |

**Note:** macOS will request microphone permission regardless of capture mode. This is required because the audio routing pipeline must register as an audio input source with CoreAudio. Grant permission for full functionality.

### Devices

| Mode | Description |
|------|-------------|
| Automatic | Equaliser follows the system default output device. Recommended for most users. |
| Manual | You select a specific output device. Required for multi-device setups. |

### System Utilities

| Setting | Recommendation | Reason |
|---------|---------------|--------|
| DC Offset Filter | ON | Protects your amplifier's output stage from constant DC stress |
| Latency Mode | Music | 128-frame I/O for the lowest possible latency |
| Dither | TPDF | Adds a small amount of shaped noise at 24-bit resolution to prevent quantisation distortion at low levels |
| Pause Gate | ON | Silences amplifier hiss during silence between tracks |
| Sync Buffer to Latency Mode | ON when using Movie mode | Aligns CoreAudio I/O buffer to the latency mode setting |

### RTA Diagnostics

Click the **Diag** checkbox in the RTA bar to display:

- **FPS** — frames per second of the RTA display update loop. Should be ~60. Low values indicate CPU throttling.
- **Bands** — number of RTA frequency bands in use (31 in the standard 1/3-octave layout).
- **SR** — latency mode in use (Music or Movie).

---

## Appendix A — Recommended Default Settings

| Stage | Recommended Setting | Reason |
|-------|--------------------|----|
| Output Gain | 0 dB | Unity; use analogue volume on your amplifier for listening level |
| Limiter Ceiling | −0.5 dBFS | Prevents inter-sample overs at the DAC output |
| True-Peak Guard | ON | 4x oversampling inter-sample peak detection |
| DC Offset Filter | ON | Protects your amplifier from constant DC stress |
| High Pass (if using sub) | 80 Hz, LR4 | Prevents main speakers from straining below their useful bandwidth |
| Sub-Bass Phase Align | Match sub crossover | Phase-aligns subwoofer with main speakers at crossover |
| Stereo Widener Low | 0.0 (mono) | Mono bass for correct subwoofer integration |
| Dither | TPDF | 24-bit noise floor dither |
| Pause Gate | ON | Silences amplifier hiss during silence between tracks |

---

## Appendix B — Further Reading

- [How It Works](./How-It-Works.md) — the virtual audio driver and CoreAudio pipeline
- [The EQ Engine](./The-EQ-Engine.md) — biquad mathematics, filter types, and the DSP chain
- [REW Import](./REW-Import.md) — Room EQ Wizard measurement and import workflow
- [EQ Presets Guide](./EQ-Presets-Guide.md) — detailed description of every factory preset
