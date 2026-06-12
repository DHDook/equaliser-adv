/// Per-channel EQ state containing one or more layers.
///
/// Layers are processed in series (index 0 first).
/// This is a pure value type — safe to copy between threads.
struct ChannelEQState: Codable, Sendable {
    /// Ordered list of EQ layers. Processed in series (index 0 first).
    /// Layer 0: User EQ
    /// Layer 1: Room correction
    /// Layer 2: Subwoofer EQ (applied only to mono low-band signal in bass management)
    /// Layer 3: Reserved for future use
    var layers: [EQLayerState]

    /// Convenience: the primary user EQ layer (always index 0).
    var userEQ: EQLayerState {
        get { layers[0] }
        set { layers[0] = newValue }
    }

    /// Convenience: the room correction layer (index 1).
    var roomCorrection: EQLayerState {
        get { layers[1] }
        set { layers[1] = newValue }
    }

    /// Convenience: the subwoofer EQ layer (index 2).
    /// Applied only to the mono low-band signal in bass management, not to main L/R chain.
    var subEQ: EQLayerState {
        get { layers[2] }
        set { layers[2] = newValue }
    }

    /// Creates a default channel state with the specified number of bands.
    /// - Parameter bandCount: Number of active bands (default from EQConfiguration).
    /// - Returns: A new ChannelEQState with user EQ, room correction, and sub EQ layers.
    static func `default`(bandCount: Int = EQConfiguration.defaultBandCount) -> ChannelEQState {
        ChannelEQState(layers: [
            .userEQ(bandCount: bandCount),
            .passthrough(label: "Room Correction"),
            .subEQ(bandCount: 4),
            .passthrough(label: "Reserved")
        ])
    }

    /// Creates a channel state from an existing layer.
    /// - Parameter layer: The layer to use (becomes layer 0).
    /// - Returns: A new ChannelEQState with the given layer.
    static func from(layer: EQLayerState) -> ChannelEQState {
        ChannelEQState(layers: [layer, .passthrough(label: "Room Correction"), .subEQ(bandCount: 4), .passthrough(label: "Reserved")])
    }
}