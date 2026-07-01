import SwiftUI

/// A fully parametric EQ band column.
struct EQBandSliderView: View {
    let index: Int
    let bandNumber: Int   // 1-based display label; computed by parent from ForEach index
    let band: EQBandConfiguration
    @Binding var gain: Float
    let frequencyUpdate: (Float) -> Void
    let qUpdate: (Float) -> Void
    let filterTypeUpdate: (FilterType) -> Void
    let slopeUpdate: (FilterSlope) -> Void
    let bypassUpdate: (Bool) -> Void
    var onDelete: (() -> Void)? = nil
    var isDynamicUpdate: ((Bool) -> Void)? = nil
    var dynamicParamsUpdate: ((DynamicBandParams) -> Void)? = nil
    var onNavigateLeft: (() -> Void)? = nil
    var onNavigateRight: (() -> Void)? = nil
    var startEditing: Bool = false
    /// Called when the user taps "Load IR…" for a .fir band.
    var onLoadFIRKernel: (() -> Void)? = nil
    /// Called when the user taps "Clear" for a .fir band.
    var onClearFIRKernel: (() -> Void)? = nil
    /// True when the EQ is in linear-phase mode (needed to show the FIR warning).
    var isLinearPhaseActive: Bool = false
    var constantQUpdate: ((Bool) -> Void)? = nil
    var linkwitzTargetHzUpdate: ((Float?) -> Void)? = nil

    @State private var isShowingDetail = false
    @State private var dragStartGain: Float? = nil

    var body: some View {
        VStack(spacing: 8) {
            header
            slider
                .frame(height: 175)
            InlineEditableValue(
                value: gain,
                displayFormatter: { $0 >= 0 ? String(format: "+%.1f", $0) : String(format: "%.1f", $0) },
                inputFormatter: { String(format: "%.1f", $0) },
                width: 56,
                alignment: .center,
                onCommit: { newGain in
                    gain = AudioConstants.clampGain(newGain)
                },
                onNavigateLeft: onNavigateLeft,
                onNavigateRight: onNavigateRight,
                startEditing: startEditing,
                onAdjust: AudioConstants.clampGain
            )
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .bold))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete band")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.08))
        )
        .opacity(band.bypass ? 0.35 : 1)
        .frame(width: 68)
    }

    private var header: some View {
        VStack(alignment: .center, spacing: 4) {
            Text("\(bandNumber)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(band.isDynamic ? Color.accentColor : Color.secondary)
                .monospacedDigit()

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    isShowingDetail = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingDetail, arrowEdge: .top) {
                    EQBandDetailPopover(
                        band: band,
                        gainUpdate: { newGain in
                            gain = AudioConstants.clampGain(newGain)
                        },
                        frequencyUpdate: frequencyUpdate,
                        qUpdate: qUpdate,
                        filterTypeUpdate: filterTypeUpdate,
                        slopeUpdate: slopeUpdate,
                        bypassUpdate: bypassUpdate,
                        isDynamicUpdate: { isDynamic in
                            isDynamicUpdate?(isDynamic)
                        },
                        dynamicParamsUpdate: { params in
                            dynamicParamsUpdate?(params)
                        },
                        onClose: { isShowingDetail = false },
                        onLoadFIRKernel: onLoadFIRKernel,
                        onClearFIRKernel: onClearFIRKernel,
                        isLinearPhaseActive: isLinearPhaseActive,
                        constantQUpdate: constantQUpdate,
                        linkwitzTargetHzUpdate: linkwitzTargetHzUpdate
                    )
                    .frame(width: 240)
                }
                Spacer(minLength: 0)
            }

            InlineEditableValue(
                value: band.frequency,
                displayFormatter: { String(format: "%.0f Hz", $0) },
                inputFormatter: { String(format: "%.0f", $0) },
                width: 56,
                alignment: .center,
                onCommit: frequencyUpdate,
                delta: 10,
                onAdjust: AudioConstants.clampFrequency
            )
        }
    }

    private var slider: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let normalizedGain = CGFloat((gain - AudioConstants.minGain) / (AudioConstants.maxGain - AudioConstants.minGain))
            let thumbOffset = (0.5 - normalizedGain) * height

            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.25))
                    .frame(width: 8, height: height)

                Rectangle()
                    .fill(Color.gray.opacity(0.8))
                    .frame(width: 12, height: 1)
                    .offset(x: -15)

                // Tick marks every 6 dB from -30 to +30 (excluding 0 and edges)
                ForEach([-30, -24, -18, -12, -6, 6, 12, 18, 24, 30], id: \.self) { db in
                    Rectangle()
                        .fill(Color.gray.opacity(0.35))
                        .frame(width: 10, height: 1)
                        .offset(x: -15, y: (0.5 - CGFloat((Float(db) - AudioConstants.minGain) / (AudioConstants.maxGain - AudioConstants.minGain))) * height)
                }

                // Single fill from bottom to thumb (always green, gray when near zero)
                let fillHeight = CGFloat((gain - AudioConstants.minGain) / (AudioConstants.maxGain - AudioConstants.minGain)) * height
                let fillOffset = height - fillHeight / 2

                RoundedRectangle(cornerRadius: 2)
                    .fill(fillColor)
                    .frame(width: 8, height: fillHeight)
                    .offset(y: fillOffset - height / 2)
                    .animation(.easeOut(duration: 0.08), value: gain)

                Circle()
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 16, height: 16)
                    .offset(y: thumbOffset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStartGain == nil {
                                    dragStartGain = gain
                                }
                                let translation = value.translation.height
                                let gainRange = AudioConstants.maxGain - AudioConstants.minGain
                                let gainDelta = Float(-translation / height * CGFloat(gainRange))
                                let newGain = (dragStartGain ?? 0) + gainDelta
                                gain = AudioConstants.clampGain(newGain)
                            }
                            .onEnded { _ in
                                dragStartGain = nil
                            }
                    )
                    .onTapGesture(count: 2) {
                        gain = 0
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fillColor: Color {
        .blue
    }
}

struct EQBandDetailPopover: View {
    @EnvironmentObject var store: EqualiserStore

    let band: EQBandConfiguration
    let gainUpdate: (Float) -> Void
    let frequencyUpdate: (Float) -> Void
    let qUpdate: (Float) -> Void
    let filterTypeUpdate: (FilterType) -> Void
    let slopeUpdate: (FilterSlope) -> Void
    let bypassUpdate: (Bool) -> Void
    let isDynamicUpdate: (Bool) -> Void
    let dynamicParamsUpdate: (DynamicBandParams) -> Void
    let onClose: () -> Void
    var onLoadFIRKernel: (() -> Void)? = nil
    var onClearFIRKernel: (() -> Void)? = nil
    var constantQUpdate: ((Bool) -> Void)? = nil
    var linkwitzTargetHzUpdate: ((Float?) -> Void)? = nil
    /// True when the EQ is in linear-phase mode. Shown as a hint when .fir is selected
    /// without linear-phase mode active.
    var isLinearPhaseActive: Bool = false

    @State private var gain: Float
    @State private var frequency: Float
    @State private var q: Float
    @State private var filterType: FilterType
    @State private var slope: FilterSlope
    @State private var bypass: Bool
    @State private var isDynamic: Bool
    @State private var thresholdDB: Float
    @State private var ratio: Float
    @State private var attackMs: Float
    @State private var releaseMs: Float
    @State private var rangeDB: Float
    @State private var direction: String
    @State private var boostThresholdDB: Float
    @State private var boostRatio: Float
    @State private var maxBoostDB: Float

    @State private var gainText: String = ""
    @State private var frequencyText: String = ""
    @State private var bandwidthText: String = ""
    @State private var thresholdText: String = ""
    @State private var ratioText: String = ""
    @State private var attackText: String = ""
    @State private var releaseText: String = ""
    @State private var rangeText: String = ""
    @State private var boostThresholdText: String = ""
    @State private var boostRatioText: String = ""
    @State private var maxBoostText: String = ""
    @State private var dynamicToggleError: String? = nil
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case gain, frequency, bandwidth, threshold, ratio, attack, release, range, boostThreshold, boostRatio, maxBoost
    }

    init(band: EQBandConfiguration,
         gainUpdate: @escaping (Float) -> Void,
         frequencyUpdate: @escaping (Float) -> Void,
         qUpdate: @escaping (Float) -> Void,
         filterTypeUpdate: @escaping (FilterType) -> Void,
         slopeUpdate: @escaping (FilterSlope) -> Void,
         bypassUpdate: @escaping (Bool) -> Void,
         isDynamicUpdate: @escaping (Bool) -> Void,
         dynamicParamsUpdate: @escaping (DynamicBandParams) -> Void,
         onClose: @escaping () -> Void,
         onLoadFIRKernel: (() -> Void)? = nil,
         onClearFIRKernel: (() -> Void)? = nil,
         isLinearPhaseActive: Bool = false,
         constantQUpdate: ((Bool) -> Void)? = nil,
         linkwitzTargetHzUpdate: ((Float?) -> Void)? = nil) {
        _gain = State(initialValue: band.gain)
        _frequency = State(initialValue: band.frequency)
        _q = State(initialValue: band.q)
        _filterType = State(initialValue: band.filterType)
        _slope = State(initialValue: band.slope)
        _bypass = State(initialValue: band.bypass)
        _isDynamic = State(initialValue: band.isDynamic)
        _thresholdDB = State(initialValue: band.dynamicParams.thresholdDB)
        _ratio = State(initialValue: band.dynamicParams.ratio)
        _attackMs = State(initialValue: band.dynamicParams.attackMs)
        _releaseMs = State(initialValue: band.dynamicParams.releaseMs)
        _rangeDB = State(initialValue: band.dynamicParams.rangeDB)
        _direction = State(initialValue: band.dynamicParams.direction)
        _boostThresholdDB = State(initialValue: band.dynamicParams.boostThresholdDB)
        _boostRatio = State(initialValue: band.dynamicParams.boostRatio)
        _maxBoostDB = State(initialValue: band.dynamicParams.maxBoostDB)
        _gainText = State(initialValue: String(format: "%.1f", band.gain))
        _frequencyText = State(initialValue: String(format: "%.0f", band.frequency))
        _bandwidthText = State(initialValue: "")
        _thresholdText = State(initialValue: String(format: "%.1f", band.dynamicParams.thresholdDB))
        _ratioText = State(initialValue: String(format: "%.1f", band.dynamicParams.ratio))
        _attackText = State(initialValue: String(format: "%.0f", band.dynamicParams.attackMs))
        _releaseText = State(initialValue: String(format: "%.0f", band.dynamicParams.releaseMs))
        _rangeText = State(initialValue: String(format: "%.0f", band.dynamicParams.rangeDB))
        _boostThresholdText = State(initialValue: String(format: "%.1f", band.dynamicParams.boostThresholdDB))
        _boostRatioText = State(initialValue: String(format: "%.1f", band.dynamicParams.boostRatio))
        _maxBoostText = State(initialValue: String(format: "%.1f", band.dynamicParams.maxBoostDB))
        self.gainUpdate = gainUpdate
        self.frequencyUpdate = frequencyUpdate
        self.qUpdate = qUpdate
        self.filterTypeUpdate = filterTypeUpdate
        self.slopeUpdate = slopeUpdate
        self.bypassUpdate = bypassUpdate
        self.isDynamicUpdate = isDynamicUpdate
        self.dynamicParamsUpdate = dynamicParamsUpdate
        self.onClose = onClose
        self.band = band
        self.onLoadFIRKernel = onLoadFIRKernel
        self.onClearFIRKernel = onClearFIRKernel
        self.isLinearPhaseActive = isLinearPhaseActive
        self.constantQUpdate = constantQUpdate
        self.linkwitzTargetHzUpdate = linkwitzTargetHzUpdate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Band Options")
                .font(.caption)

            // Mode picker
            Picker("Mode", selection: $isDynamic) {
                Text("Parametric").tag(false)
                Text("Dynamic").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: isDynamic) { _, newValue in
                if newValue {
                    // Check if we're at the 16-band cap
                    let currentDynamicCount = store.eqConfiguration.bands.filter { $0.isDynamic }.count
                    if currentDynamicCount >= DynamicEQConfig.maxDynamicEQBands {
                        dynamicToggleError = "Up to 16 bands can be Dynamic at once — turn off Dynamic on another band first."
                        // Revert the toggle
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isDynamic = false
                        }
                        return
                    }
                }
                isDynamicUpdate(newValue)
                commitDynamicParams()
                dynamicToggleError = nil
            }

            // Error message for 8-band cap
            if let error = dynamicToggleError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Channel-mode constraint caption
            if isDynamic && store.channelMode != .linked {
                Text("Dynamic EQ currently applies identically to all channels, even in Stereo/Mid-Side mode.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Frequency
            HStack {
                Text(filterType == .linkwitzTransform ? "Resonance (f0)" : "Frequency (Hz)")
                Spacer()
                TextField("1000", text: $frequencyText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .frequency)
                    .onSubmit {
                        if let value = Float(frequencyText) {
                            let clamped = AudioConstants.clampFrequency(value)
                            frequency = clamped
                            frequencyText = String(format: "%.0f", clamped)
                            frequencyUpdate(clamped)
                        }
                        focusedField = .gain
                    }
                    .onKeyPress(.upArrow) {
                        adjustFrequency(by: 10)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        adjustFrequency(by: -10)
                        return .handled
                    }
            }
            .disabled(filterType == .fir)

            // Gain
            HStack {
                Text(filterType == .linkwitzTransform ? "Target Q (Qp)" : "Gain (dB)")
                Spacer()
                TextField(filterType == .linkwitzTransform ? "0.58" : "0.0", text: $gainText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .gain)
                    .onSubmit {
                        if let value = Float(gainText) {
                            let clamped: Float
                            if filterType == .linkwitzTransform {
                                clamped = max(0.1, min(5.0, value))  // Qp: 0.1–5.0, never zero
                            } else {
                                clamped = AudioConstants.clampGain(value)
                            }
                            gain = clamped
                            gainText = filterType == .linkwitzTransform
                                ? String(format: "%.2f", clamped)
                                : String(format: "%.1f", clamped)
                            gainUpdate(clamped)
                        }
                        focusedField = .bandwidth
                    }
                    .onKeyPress(.upArrow) {
                        adjustGain(by: filterType == .linkwitzTransform ? 0.01 : 0.1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        adjustGain(by: filterType == .linkwitzTransform ? -0.01 : -0.1)
                        return .handled
                    }
            }
            .disabled(filterType == .fir)

            // Linkwitz-Transform: Target Frequency (fp)
            if filterType == .linkwitzTransform {
                let effectiveFp = band.linkwitzTargetHz ?? (band.frequency * 0.7)
                HStack {
                    Text("Target Freq (fp)")
                    Spacer()
                    Text(String(format: "%.0f Hz", effectiveFp))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(
                        get: { Double(effectiveFp) },
                        set: { v in
                            let clamped = Float(max(10.0, min(v, Double(frequency) * 0.99)))
                            linkwitzTargetHzUpdate?(clamped)
                        }
                    ), in: 10.0...500.0, step: 1.0)
                    .labelsHidden()
                }
                .help("Target resonance frequency. Leave near the default (f0 × 0.7) for a Butterworth-aligned extension, or set to your desired −3 dB point.")
            }

            // Bandwidth / Q Factor
            // UI displays bandwidth or Q based on user preference, but model stores Q.
            // Conversion happens at the boundary.
            HStack {
                Text(filterType == .linkwitzTransform ? "Box Q (Q0)" : bandwidthLabel)
                Spacer()
                TextField("1.0", text: $bandwidthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .bandwidth)
                    .onSubmit {
                        // parseInput returns the raw value in the mode's unit:
                        // .octaves → bandwidth in octaves, .qFactor → Q factor
                        if let inputValue = BandwidthConverter.parseInput(bandwidthText, mode: store.bandwidthDisplayMode) {
                            let qValue: Float
                            switch store.bandwidthDisplayMode {
                            case .octaves:
                                let clampedBandwidth = BandwidthConverter.clampBandwidth(inputValue)
                                qValue = BandwidthConverter.bandwidthToQ(clampedBandwidth)
                            case .qFactor:
                                qValue = BandwidthConverter.clampQ(inputValue)
                            }
                            q = qValue
                            bandwidthText = BandwidthConverter.formatForInput(q: qValue, mode: store.bandwidthDisplayMode)
                            qUpdate(qValue)
                        }
                    }
                    .onKeyPress(.upArrow) {
                        adjustBandwidth(by: 0.01)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        adjustBandwidth(by: -0.01)
                        return .handled
                    }
            }
            .disabled(filterType == .fir)
            .onAppear {
                bandwidthText = BandwidthConverter.formatForInput(q: q, mode: store.bandwidthDisplayMode)
            }
            .onChange(of: store.bandwidthDisplayMode) { _, newMode in
                bandwidthText = BandwidthConverter.formatForInput(q: q, mode: newMode)
            }

            // Constant-Q toggle — parametric bands only
            if filterType == .parametric {
                Toggle("Constant-Q", isOn: Binding(
                    get: { band.constantQ },
                    set: { v in constantQUpdate?(v) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("When on, bandwidth stays fixed regardless of gain (Orfanidis constant-Q). When off, bandwidth narrows as gain approaches zero (standard RBJ proportional-Q).")
            }

            // Linkwitz-Transform info caption
            if filterType == .linkwitzTransform {
                Text("Redesigns a sealed-box speaker's roll-off. f0/Q0 = existing alignment, fp/Qp = target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Dynamic EQ parameters (shown only when mode == Dynamic)
            if isDynamic {
                Divider()

                // Direction picker
                Picker("Direction", selection: $direction) {
                    Text("Cut").tag("cutOnly")
                    Text("Boost").tag("boostOnly")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented)
                .onChange(of: direction) { _, _ in
                    commitDynamicParams()
                }

                // Threshold (dB) - label changes based on direction
                HStack {
                    Text(direction == "boostOnly" ? "Boost Threshold (dB)" : "Cut Threshold (dB)")
                    Spacer()
                    TextField("-20", text: $thresholdText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .threshold)
                        .onSubmit {
                            if let value = Float(thresholdText) {
                                let clamped = clampThreshold(value)
                                thresholdDB = clamped
                                thresholdText = String(format: "%.1f", clamped)
                                commitDynamicParams()
                            }
                        }
                        .onKeyPress(.upArrow) {
                            adjustThreshold(by: 1.0)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            adjustThreshold(by: -1.0)
                            return .handled
                        }
                }

                // Ratio - label changes based on direction
                HStack {
                    Text(direction == "boostOnly" ? "Boost Ratio" : "Cut Ratio")
                    Spacer()
                    TextField("2.0", text: $ratioText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .ratio)
                        .onSubmit {
                            if let value = Float(ratioText) {
                                let clamped = clampRatio(value)
                                ratio = clamped
                                ratioText = String(format: "%.1f", clamped)
                                commitDynamicParams()
                            }
                        }
                        .onKeyPress(.upArrow) {
                            adjustRatio(by: 0.1)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            adjustRatio(by: -0.1)
                            return .handled
                        }
                }

                // Attack (ms) - shared for both cut and boost
                HStack {
                    Text("Attack (ms)")
                    Spacer()
                    TextField("10", text: $attackText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .attack)
                        .onSubmit {
                            if let value = Float(attackText) {
                                let clamped = clampAttack(value)
                                attackMs = clamped
                                attackText = String(format: "%.0f", clamped)
                                commitDynamicParams()
                            }
                        }
                        .onKeyPress(.upArrow) {
                            adjustAttack(by: 1.0)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            adjustAttack(by: -1.0)
                            return .handled
                        }
                }

                // Release (ms) - shared for both cut and boost
                HStack {
                    Text("Release (ms)")
                    Spacer()
                    TextField("100", text: $releaseText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .release)
                        .onSubmit {
                            if let value = Float(releaseText) {
                                let clamped = clampRelease(value)
                                releaseMs = clamped
                                releaseText = String(format: "%.0f", clamped)
                                commitDynamicParams()
                            }
                        }
                        .onKeyPress(.upArrow) {
                            adjustRelease(by: 10.0)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            adjustRelease(by: -10.0)
                            return .handled
                        }
                }

                // Range (dB) - only for cut side
                if direction != "boostOnly" {
                    HStack {
                        Text("Range (dB)")
                        Spacer()
                        TextField("-24", text: $rangeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .range)
                            .onSubmit {
                                if let value = Float(rangeText) {
                                    let clamped = clampRange(value)
                                    rangeDB = clamped
                                    rangeText = String(format: "%.0f", clamped)
                                    commitDynamicParams()
                                }
                            }
                            .onKeyPress(.upArrow) {
                                adjustRange(by: 1.0)
                                return .handled
                            }
                            .onKeyPress(.downArrow) {
                                adjustRange(by: -1.0)
                                return .handled
                            }
                    }
                }

                // Max Boost (dB) - only for boost side
                if direction != "cutOnly" {
                    HStack {
                        Text("Max Boost (dB)")
                        Spacer()
                        TextField("6.0", text: $maxBoostText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .maxBoost)
                            .onSubmit {
                                if let value = Float(maxBoostText) {
                                    let clamped = clampMaxBoost(value)
                                    maxBoostDB = clamped
                                    maxBoostText = String(format: "%.1f", clamped)
                                    commitDynamicParams()
                                }
                            }
                            .onKeyPress(.upArrow) {
                                adjustMaxBoost(by: 0.5)
                                return .handled
                            }
                            .onKeyPress(.downArrow) {
                                adjustMaxBoost(by: -0.5)
                                return .handled
                            }
                    }
                }
            }

            Divider()

            Picker("Filter Type", selection: $filterType) {
                ForEach(FilterType.allCasesInUIOrder, id: \.self) { type in
                    Text(type.displayName)
                        .tag(type)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: filterType) { _, newValue in
                filterTypeUpdate(newValue)
            }

            // FIR kernel load controls — shown when filterType == .fir
            if filterType == .fir {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = band.firKernelDisplayName {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No IR loaded")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 6) {
                        Button("Load IR…") {
                            onLoadFIRKernel?()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        if band.firKernelDisplayName != nil {
                            Button("Clear") {
                                onClearFIRKernel?()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    if !isLinearPhaseActive {
                        Text("⚠ FIR bands require Linear Phase mode")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            }

            Picker("Slope", selection: $slope) {
                ForEach(FilterSlope.allCases, id: \.self) { s in
                    Text(s.displayName)
                        .tag(s)
                }
            }
            .pickerStyle(.menu)
            .disabled(filterType == .allPass || filterType == .fir)
            .onChange(of: slope) { _, newValue in
                slopeUpdate(newValue)
            }

            Toggle("Bypass Band", isOn: $bypass)
                .onChange(of: bypass) { _, newValue in
                    bypassUpdate(newValue)
                }
        }
        .padding(16)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onAppear {
            focusedField = .frequency
        }
    }

    private var bandwidthLabel: String {
        switch store.bandwidthDisplayMode {
        case .octaves:
            return "Bandwidth (oct)"
        case .qFactor:
            return "Q Factor"
        }
    }

    private func adjustGain(by delta: Float) {
        let current = Float(gainText) ?? gain
        let newGain = AudioConstants.clampGain(current + delta)
        gain = newGain
        gainText = String(format: "%.1f", newGain)
        gainUpdate(newGain)
    }

    private func adjustFrequency(by delta: Float) {
        let current = Float(frequencyText) ?? frequency
        let newFreq = AudioConstants.clampFrequency(current + delta)
        frequency = newFreq
        frequencyText = String(format: "%.0f", newFreq)
        frequencyUpdate(newFreq)
    }

    private func adjustBandwidth(by delta: Float) {
        guard let current = BandwidthConverter.parseInput(bandwidthText, mode: store.bandwidthDisplayMode) else { return }
        let newValue = current + delta

        let qValue: Float
        switch store.bandwidthDisplayMode {
        case .octaves:
            let clamped = BandwidthConverter.clampBandwidth(newValue)
            qValue = BandwidthConverter.bandwidthToQ(clamped)
        case .qFactor:
            qValue = BandwidthConverter.clampQ(newValue)
        }

        q = qValue
        bandwidthText = BandwidthConverter.formatForInput(q: qValue, mode: store.bandwidthDisplayMode)
        qUpdate(qValue)
    }

    // MARK: - Dynamic EQ helpers

    private func clampThreshold(_ value: Float) -> Float {
        max(-60.0, min(0.0, value))
    }

    private func clampRatio(_ value: Float) -> Float {
        max(1.0, min(10.0, value))
    }

    private func clampAttack(_ value: Float) -> Float {
        max(1.0, min(100.0, value))
    }

    private func clampRelease(_ value: Float) -> Float {
        max(10.0, min(1000.0, value))
    }

    private func clampRange(_ value: Float) -> Float {
        max(-24.0, min(0.0, value))
    }

    private func clampMaxBoost(_ value: Float) -> Float {
        max(0.0, min(12.0, value))
    }

    private func adjustThreshold(by delta: Float) {
        let current = Float(thresholdText) ?? thresholdDB
        let clamped = clampThreshold(current + delta)
        thresholdDB = clamped
        thresholdText = String(format: "%.1f", clamped)
        commitDynamicParams()
    }

    private func adjustRatio(by delta: Float) {
        let current = Float(ratioText) ?? ratio
        let clamped = clampRatio(current + delta)
        ratio = clamped
        ratioText = String(format: "%.1f", clamped)
        commitDynamicParams()
    }

    private func adjustAttack(by delta: Float) {
        let current = Float(attackText) ?? attackMs
        let clamped = clampAttack(current + delta)
        attackMs = clamped
        attackText = String(format: "%.0f", clamped)
        commitDynamicParams()
    }

    private func adjustRelease(by delta: Float) {
        let current = Float(releaseText) ?? releaseMs
        let clamped = clampRelease(current + delta)
        releaseMs = clamped
        releaseText = String(format: "%.0f", clamped)
        commitDynamicParams()
    }

    private func adjustRange(by delta: Float) {
        let current = Float(rangeText) ?? rangeDB
        let clamped = clampRange(current + delta)
        rangeDB = clamped
        rangeText = String(format: "%.0f", clamped)
        commitDynamicParams()
    }

    private func adjustMaxBoost(by delta: Float) {
        let current = Float(maxBoostText) ?? maxBoostDB
        let clamped = clampMaxBoost(current + delta)
        maxBoostDB = clamped
        maxBoostText = String(format: "%.1f", clamped)
        commitDynamicParams()
    }

    private func commitDynamicParams() {
        let params = DynamicBandParams(
            thresholdDB: thresholdDB,
            ratio: ratio,
            attackMs: attackMs,
            releaseMs: releaseMs,
            rangeDB: rangeDB,
            direction: direction,
            boostThresholdDB: boostThresholdDB,
            boostRatio: boostRatio,
            maxBoostDB: maxBoostDB
        )
        dynamicParamsUpdate(params)
    }
}
