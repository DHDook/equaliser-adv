/// Per-channel EQ state containing one or more layers.
///
/// Layers are processed in series (index 0 first).
/// This is a pure value type — safe to copy between threads.
struct ChannelEQState: Codable, Sendable {
    /// Ordered list of EQ layers. Processed in series (index 0 first).
    /// Layer 0: User EQ
    /// Layer 1: Room correction
    /// Layer 2: Reserved for future use
    var layers: [EQLayerState]

    /// Convenience: the primary user EQ layer (always index 0).
    var userEQ: EQLayerState {
        get { layers.indices.contains(0) ? layers[0] : .userEQ(bandCount: EQConfiguration.defaultBandCount) }
        set {
            while layers.count <= 0 { layers.append(.userEQ(bandCount: EQConfiguration.defaultBandCount)) }
            layers[0] = newValue
        }
    }

    /// Convenience: the room correction layer (index 1).
    var roomCorrection: EQLayerState {
        get { layers.indices.contains(1) ? layers[1] : .passthrough(label: "Room Correction") }
        set {
            while layers.count <= 1 { layers.append(.passthrough(label: "Room Correction")) }
            layers[1] = newValue
        }
    }

    /// Creates a default channel state with the specified number of bands.
    /// - Parameter bandCount: Number of active bands (default from EQConfiguration).
    /// - Returns: A new ChannelEQState with user EQ and room correction layers.
    static func `default`(bandCount: Int = EQConfiguration.defaultBandCount) -> ChannelEQState {
        ChannelEQState(layers: [
            .userEQ(bandCount: bandCount),
            .passthrough(label: "Room Correction"),
            .passthrough(label: "Reserved")
        ])
    }

    /// Creates a channel state from an existing layer.
    /// - Parameter layer: The layer to use (becomes layer 0).
    /// - Returns: A new ChannelEQState with the given layer.
    static func from(layer: EQLayerState) -> ChannelEQState {
        ChannelEQState(layers: [layer, .passthrough(label: "Room Correction"), .passthrough(label: "Reserved")])
    }
}