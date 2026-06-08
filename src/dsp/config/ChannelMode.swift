/// How audio channels are processed — determines whether one or two EQ chains are active.
enum ChannelMode: String, Codable, Sendable, CaseIterable {
    /// One configuration applied to both L and R channels.
    case linked

    /// Independent L and R configurations.
    case stereo

    /// Mid (sum) and Side (difference) edited independently
    /// using leftState for Mid, rightState for Side
    case midSide
}