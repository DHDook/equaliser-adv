/// Constants for the EQ layer system.
enum EQLayerConstants {
    /// Maximum number of EQ layers per channel.
    /// Pre-allocated at pipeline init. Unused layers are passthrough (zero CPU cost).
    static let maxLayerCount = 4

    /// Well-known layer indices.
    /// Layer 0 is always the user EQ.
    static let userEQLayerIndex = 0

    /// Room correction parametric bands (layer 1).
    static let roomCorrectionLayerIndex = 1

    /// Subwoofer EQ bands (layer 2) — applied only to the mono low-band signal in bass management.
    static let subEQLayerIndex = 2

    // Future layer indices (reserved for future use):
    // static let headphoneCorrectionLayerIndex = 3
    // static let genreLayerIndex = 3
}