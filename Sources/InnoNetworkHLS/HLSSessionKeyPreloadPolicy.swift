/// Controls whether a download uses multivariant `EXT-X-SESSION-KEY`
/// declarations to prepare identity AES-128 key bytes early.
public enum HLSSessionKeyPreloadPolicy: Equatable, Sendable {
    /// Preserves demand-driven key loading after media selection.
    case disabled

    /// Preloads a bounded set of identity AES-128 session keys while media
    /// playlists are being resolved.
    case identityAES128
}
