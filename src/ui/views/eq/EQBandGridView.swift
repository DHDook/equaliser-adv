import SwiftUI

/// Grid of EQ band sliders with keyboard navigation.
struct EQBandGridView: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var editingBand: Int? = nil

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<store.bandCount, id: \.self) { index in
                        EQBandSliderView(
                            index: index,
                            bandNumber: index + 1,
                            band: store.eqConfiguration.bands[index],
                            gain: Binding(
                                get: { store.eqConfiguration.bands[index].gain },
                                set: { store.updateBandGain(index: index, gain: $0) }
                            ),
                            frequencyUpdate: { value in
                                store.updateBandFrequency(index: index, frequency: AudioConstants.clampFrequency(value))
                            },
                            qUpdate: { value in
                                let clamped = BandwidthConverter.clampQ(value)
                                store.updateBandQ(index: index, q: clamped)
                            },
                            filterTypeUpdate: { store.updateBandFilterType(index: index, filterType: $0) },
                            slopeUpdate: { store.updateBandSlope(index: index, slope: $0) },
                            bypassUpdate: { store.updateBandBypass(index: index, bypass: $0) },
                            onDelete: store.bandCount > 1 ? { store.removeBand(at: index) } : nil,
                            isDynamicUpdate: { store.updateBandDynamicMode(index: index, isDynamic: $0) },
                            dynamicParamsUpdate: { store.updateBandDynamicParams(index: index, params: $0) },
                            onNavigateLeft: {
                                navigateToBand(index - 1)
                            },
                            onNavigateRight: {
                                navigateToBand(index + 1)
                            },
                            startEditing: editingBand == index
                        )
                        .frame(width: 72)
                    }
                }
                .frame(minWidth: max(0, proxy.size.width - 24), maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func navigateToBand(_ index: Int) {
        guard index >= 0 && index < store.bandCount else { return }
        editingBand = index
    }
}