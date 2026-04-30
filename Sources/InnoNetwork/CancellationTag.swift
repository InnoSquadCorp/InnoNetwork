import Foundation

/// Caller-defined identifier used to group requests so that
/// ``DefaultNetworkClient/cancelAll(matching:)`` can interrupt only the
/// matching subset.
///
/// Tags are plain strings under the hood; callers pick whatever scheme fits
/// their app — screen names, feature areas, user sessions. Two requests
/// registered with the same `CancellationTag` rawValue are considered
/// equivalent for cancellation purposes.
///
/// ```swift
/// let feed = CancellationTag("feed")
/// async let posts = client.request(GetPosts(), tag: feed)
/// async let banner = client.request(GetBanner(), tag: feed)
///
/// // User leaves the screen:
/// await client.cancelAll(matching: feed)
/// ```
public struct CancellationTag: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension CancellationTag: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
