import SwiftUI

struct LevelMetersView: View {
    let meterStore: MeterStore
    
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            StereoMeterGroup(
                title: "Peak In",
                meterStore: meterStore,
                leftType: .inputPeakLeft,
                rightType: .inputPeakRight,
                showScale: true
            )
            StereoMeterGroup(
                title: "Peak Out",
                meterStore: meterStore,
                leftType: .outputPeakLeft,
                rightType: .outputPeakRight,
                showScale: true
            )
            
            StereoMeterGroupRMS(
                title: "RMS In",
                meterStore: meterStore,
                leftType: .inputRMSLeft,
                rightType: .inputRMSRight,
                showScale: true
            )
            StereoMeterGroupRMS(
                title: "RMS Out",
                meterStore: meterStore,
                leftType: .outputRMSLeft,
                rightType: .outputRMSRight,
                showScale: true
            )
        }
    }
}

struct GainControlsView: View {
    let inputGain: Float
    let outputGain: Float
    let onInputGainChange: (Float) -> Void
    let onOutputGainChange: (Float) -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                Text("Gain In")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                GainStepperControl(
                    gain: inputGain,
                    onGainChange: onInputGainChange
                )
            }
            
            VStack(spacing: 6) {
                Text("Gain Out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                GainStepperControl(
                    gain: outputGain,
                    onGainChange: onOutputGainChange
                )
            }
        }
    }
}

struct ChannelBalanceSlider: View {
    @Binding var balance: Float

    var body: some View {
        VStack(spacing: 0) {
            Text("Balance")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track (always gray)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 4)

                    // Thumb
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .offset(x: thumbOffset(in: geometry.size))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newValue = valueAt(position: value.location, in: geometry.size)
                            // Sticky center behavior
                            let centerThreshold = 0.05
                            if abs(newValue) < centerThreshold {
                                balance = 0.0
                            } else {
                                balance = Float(newValue)
                            }
                        }
                )
            }
            .frame(height: 20)
            .frame(width: 120)

            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("L")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(leftPercentage)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("R")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rightPercentage)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 120)
        }
    }

    private var leftPercentage: String {
        let b = Double(balance)
        let pct: Double
        if b <= 0 {
            pct = 100.0
        } else {
            pct = 100.0 * (1.0 - b)
        }
        return "\(Int(pct))%"
    }

    private var rightPercentage: String {
        let b = Double(balance)
        let pct: Double
        if b >= 0 {
            pct = 100.0
        } else {
            pct = 100.0 * (1.0 + b)
        }
        return "\(Int(pct))%"
    }

    private func thumbOffset(in size: CGSize) -> CGFloat {
        let normalizedValue = (Double(balance) + 1.0) / 2.0
        return size.width * CGFloat(normalizedValue) - 6
    }

    private func valueAt(position: CGPoint, in size: CGSize) -> Double {
        let normalizedPosition = max(0, min(1, position.x / size.width))
        return (normalizedPosition * 2.0) - 1.0
    }
}

struct MasterVolumeSlider: View {
    @Binding var volume: Float
    @Binding var isMuted: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Volume")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track (always gray)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 4)

                    // Thumb
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .offset(x: thumbOffset(in: geometry.size))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newValue = valueAt(position: value.location, in: geometry.size)
                            volume = Float(newValue)
                        }
                )
            }
            .frame(height: 20)
            .frame(width: 120)

            HStack(spacing: 4) {
                Toggle(isOn: $isMuted) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Text("Mute")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(volumePercentage)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            .frame(width: 120)
        }
    }

    private var volumePercentage: String {
        let percentage = Int(volume * 100)
        return "\(percentage)%"
    }

    private func thumbOffset(in size: CGSize) -> CGFloat {
        let normalizedValue = Double(volume) // 0.0 to 1.0
        return size.width * CGFloat(normalizedValue) - 6
    }

    private func valueAt(position: CGPoint, in size: CGSize) -> Double {
        let normalizedPosition = max(0, min(1, position.x / size.width))
        return normalizedPosition // 0.0 to 1.0
    }
}

struct StereoMeterGroup: View {
    let title: String
    let meterStore: MeterStore
    let leftType: MeterType
    let rightType: MeterType
    var showScale: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
            HStack(alignment: .top, spacing: 4) {
                if showScale {
                    MeterScaleView(height: MeterConstants.meterHeight)
                }
                PeakMeter(
                    channelLabel: "L",
                    meterStore: meterStore,
                    meterType: leftType
                )
                PeakMeter(
                    channelLabel: "R",
                    meterStore: meterStore,
                    meterType: rightType
                )
            }
        }
    }
}

struct PeakMeter: View {
    let channelLabel: String
    let meterStore: MeterStore
    let meterType: MeterType
    
    var body: some View {
        VStack(spacing: 4) {
            PeakMeterNSView(meterStore: meterStore, meterType: meterType)
                .frame(width: 18, height: 126)
            
            Text(channelLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct RMSMeter: View {
    let channelLabel: String
    let meterStore: MeterStore
    let meterType: MeterType
    
    var body: some View {
        VStack(spacing: 4) {
            RMSMeterNSView(meterStore: meterStore, meterType: meterType)
                .frame(width: 14, height: 126)
            
            Text(channelLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct StereoMeterGroupRMS: View {
    let title: String
    let meterStore: MeterStore
    let leftType: MeterType
    let rightType: MeterType
    var showScale: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
            HStack(alignment: .top, spacing: 4) {
                if showScale {
                    MeterScaleView(height: MeterConstants.meterHeight)
                }
                RMSMeter(
                    channelLabel: "L",
                    meterStore: meterStore,
                    meterType: leftType
                )
                RMSMeter(
                    channelLabel: "R",
                    meterStore: meterStore,
                    meterType: rightType
                )
            }
        }
    }
}
