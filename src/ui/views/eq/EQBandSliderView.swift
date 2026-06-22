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
                .foregroundStyle(band.isDynamic ? .accent : .tertiary)
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
                        onClose: { isShowingDetail = false }
                    )
                    .frame(width: 240)
                }
                Spacer(minLength: 0)
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete band")
                }
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

    let gainUpdate: (Float) -> Void
    let frequencyUpdate: (Float) -> Void
    let qUpdate: (Float) -> Void
    let filterTypeUpdate: (FilterType) -> Void
    let slopeUpdate: (FilterSlope) -> Void
    let bypassUpdate: (Bool) -> Void
    let isDynamicUpdate: (Bool) -> Void
    let dynamicParamsUpdate: (DynamicBandParams) -> Void
    let onClose: () -> Void

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

    @State private var gainText: String = ""
    @State private var frequencyText: String = ""
    @State private var bandwidthText: String = ""
    @State private var thresholdText: String = ""
    @State private var ratioText: String = ""
    @State private var attackText: String = ""
    @State private var releaseText: String = ""
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case gain, frequency, bandwidth, threshold, ratio, attack, release
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
         onClose: @escaping () -> Void) {
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
        _gainText = State(initialValue: String(format: "%.1f", band.gain))
        _frequencyText = State(initialValue: String(format: "%.0f", band.frequency))
        _bandwidthText = State(initialValue: "")
        _thresholdText = State(initialValue: String(format: "%.1f", band.dynamicParams.thresholdDB))
        _ratioText = State(initialValue: String(format: "%.1f", band.dynamicParams.ratio))
        _attackText = State(initialValue: String(format: "%.0f", band.dynamicParams.attackMs))
        _releaseText = State(initialValue: String(format: "%.0f", band.dynamicParams.releaseMs))
        self.gainUpdate = gainUpdate
        self.frequencyUpdate = frequencyUpdate
        self.qUpdate = qUpdate
        self.filterTypeUpdate = filterTypeUpdate
        self.slopeUpdate = slopeUpdate
        self.bypassUpdate = bypassUpdate
        self.isDynamicUpdate = isDynamicUpdate
        self.dynamicParamsUpdate = dynamicParamsUpdate
        self.onClose = onClose
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
                isDynamicUpdate(newValue)
                commitDynamicParams()
            }

            // Frequency
            HStack {
                Text("Frequency (Hz)")
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

            // Gain
            HStack {
                Text("Gain (dB)")
                Spacer()
                TextField("0.0", text: $gainText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .gain)
                    .onSubmit {
                        if let value = Float(gainText) {
                            let clamped = AudioConstants.clampGain(value)
                            gain = clamped
                            gainText = String(format: "%.1f", clamped)
                            gainUpdate(clamped)
                        }
                        focusedField = .bandwidth
                    }
                    .onKeyPress(.upArrow) {
                        adjustGain(by: 0.1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        adjustGain(by: -0.1)
                        return .handled
                    }
            }

            // Bandwidth / Q Factor
            // UI displays bandwidth or Q based on user preference, but model stores Q.
            // Conversion happens at the boundary.
            HStack {
                Text(bandwidthLabel)
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
            .onAppear {
                bandwidthText = BandwidthConverter.formatForInput(q: q, mode: store.bandwidthDisplayMode)
            }
            .onChange(of: store.bandwidthDisplayMode) { _, newMode in
                bandwidthText = BandwidthConverter.formatForInput(q: q, mode: newMode)
            }

            // Dynamic EQ parameters (shown only when mode == Dynamic)
            if isDynamic {
                Divider()

                // Threshold (dB)
                HStack {
                    Text("Threshold (dB)")
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

                // Ratio
                HStack {
                    Text("Ratio")
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

                // Attack (ms)
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

                // Release (ms)
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

            Picker("Slope", selection: $slope) {
                ForEach(FilterSlope.allCases, id: \.self) { s in
                    Text(s.displayName)
                        .tag(s)
                }
            }
            .pickerStyle(.menu)
            .disabled(filterType == .allPass)
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

    private func commitDynamicParams() {
        let params = DynamicBandParams(
            thresholdDB: thresholdDB,
            ratio: ratio,
            attackMs: attackMs,
            releaseMs: releaseMs
        )
        dynamicParamsUpdate(params)
    }
}
