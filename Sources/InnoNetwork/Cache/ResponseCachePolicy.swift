import CryptoKit
import Foundation

/// Opt-in response caching policy for request/response APIs.
public enum ResponseCachePolicy: Sendable, Equatable {
    /// No cache reads or writes; identical to having no cache configured.
    case disabled
    /// Always hit the network. Cache reads and writes are both skipped, so
    /// the cache stays untouched—useful when callers want fresh data without
    /// polluting an existing cache.
    case networkOnly
    /// Serve from cache while entries are within `maxAge`. Stale entries fall
    /// through to the network and RFC-cacheable GET responses may be written back.
    /// Entries flagged as `requiresRevalidation` (e.g. responses carrying
    /// `Cache-Control: no-cache`) are revalidated even while inside `maxAge`.
    case cacheFirst(maxAge: Duration)
    /// Serve fresh entries directly. Within the `staleWindow` past `maxAge`,
    /// return the cached entry immediately and revalidate in the background.
    /// Entries flagged as `requiresRevalidation` skip the fast path and force
    /// revalidation on every request even within `maxAge`.
    case staleWhileRevalidate(maxAge: Duration, staleWindow: Duration)
}


/// Stable cache key for response bodies stored by ``ResponseCache``.
public struct ResponseCacheKey: Hashable, Sendable {
    public let method: String
    public let url: String
    public let headers: [String]

    public init(method: String, url: String, headers: [String: String] = [:]) {
        self.method = method.uppercased()
        self.url = url
        self.headers = Self.normalizedHeaders(headers)
    }

    package init?(request: URLRequest) {
        guard let url = Self.normalizedURLString(request.url) else { return nil }
        // `Authorization` is intentionally part of the cache key so that
        // user-scoped responses are not shared across identities. Token
        // rotations therefore produce new keys and the cache acts per-identity.
        // `Accept-Language` intentionally remains part of the key: many APIs
        // localize representations without changing the URL.
        let excludedHeaderNames: Set<String> = [
            "accept-encoding",
            "content-type",
            "date",
            "if-modified-since",
            "if-none-match",
            "user-agent",
        ]
        let headers =
            (request.allHTTPHeaderFields ?? [:])
            .filter { !excludedHeaderNames.contains($0.key.lowercased()) }
        self.init(method: request.httpMethod ?? "GET", url: url, headers: headers)
    }

    private static func normalizedHeaders(_ headers: [String: String]) -> [String] {
        headers
            .map { header in
                let name = header.key.lowercased()
                let value = HeaderValueNormalizer.normalizedValue(name: name, value: header.value)
                return "\(name):\(value)"
            }
            .sorted()
    }

    private static func normalizedURLString(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        return components.url?.absoluteString
    }
}


private enum HeaderValueNormalizer {
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization"
    ]

    static func normalizedValue(name: String, value: String) -> String {
        sensitiveHeaderNames.contains(name.lowercased()) ? fingerprint(value) : value
    }

    private static func fingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}


/// Cached HTTP response payload and metadata.
public struct CachedResponse: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let storedAt: Date
    /// Whether a cached entry must be revalidated before reuse even while it
    /// is still inside the caller-provided freshness window.
    public let requiresRevalidation: Bool
    /// Snapshot of the request headers that were present when this response
    /// was stored, restricted to the names listed in the response `Vary`
    /// header. `nil` means the response did not carry a `Vary` header (so
    /// vary matching is skipped on lookup); an empty dictionary is reserved
    /// for `Vary` headers that resolve to no concrete names. The values are
    /// optional so a vary header that was absent on the original request
    /// stays distinguishable from one that was present and empty.
    public let varyHeaders: [String: String?]?

    public init(
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        storedAt: Date = Date(),
        requiresRevalidation: Bool = false,
        varyHeaders: [String: String?]? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.storedAt = storedAt
        self.requiresRevalidation = requiresRevalidation
        self.varyHeaders = varyHeaders
    }

    public var etag: String? {
        headers.first { $0.key.caseInsensitiveCompare("ETag") == .orderedSame }?.value
    }

    package func response(for request: URLRequest) -> HTTPURLResponse? {
        guard let url = request.url else { return nil }
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )
    }

    package var byteCost: Int {
        data.count + headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }
}


/// Async response cache abstraction used by the built-in cache policy.
public protocol ResponseCache: Sendable {
    func get(_ key: ResponseCacheKey) async -> CachedResponse?
    func set(_ key: ResponseCacheKey, _ value: CachedResponse) async
    func invalidate(_ key: ResponseCacheKey) async
}


/// In-memory `ResponseCache` implementation with a simple byte cap.
///
/// LRU bookkeeping is backed by an array, so each `set`/`touch`/`invalidate`
/// is O(n) in the number of stored entries. This is acceptable for the
/// default 5 MB cap (typically a few hundred entries) but degrades on much
/// larger working sets. Provide a custom `ResponseCache` backed by an
/// ordered dictionary if you raise `maxBytes` significantly.
public actor InMemoryResponseCache: ResponseCache {
    private let maxBytes: Int
    private var storage: [ResponseCacheKey: CachedResponse] = [:]
    private var order: [ResponseCacheKey] = []
    private var currentBytes = 0

    public init(maxBytes: Int = 5 * 1024 * 1024) {
        self.maxBytes = max(1, maxBytes)
    }

    public func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    public func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        if let existing = storage[key] {
            currentBytes -= existing.byteCost
        }
        storage[key] = value
        currentBytes += value.byteCost
        touch(key)
        evictIfNeeded()
    }

    public func invalidate(_ key: ResponseCacheKey) async {
        if let existing = storage.removeValue(forKey: key) {
            currentBytes -= existing.byteCost
        }
        order.removeAll { $0 == key }
    }

    private func touch(_ key: ResponseCacheKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while currentBytes > maxBytes, let first = order.first {
            order.removeFirst()
            if let removed = storage.removeValue(forKey: first) {
                currentBytes -= removed.byteCost
            }
        }
    }
}


package enum CachePreparation: Sendable {
    case bypass
    case returnCached(CachedResponse)
    case revalidate(CachedResponse?)
    case returnStaleAndRevalidate(CachedResponse)
}


package extension ResponseCachePolicy {
    var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        case .networkOnly, .cacheFirst, .staleWhileRevalidate:
            return true
        }
    }

    var allowsConditionalRevalidation: Bool {
        switch self {
        case .cacheFirst, .staleWhileRevalidate:
            return true
        case .disabled, .networkOnly:
            return false
        }
    }

    /// Whether the policy may persist responses into the cache.
    /// `networkOnly` skips both reads and writes so it does not pollute the
    /// cache even though it is otherwise "enabled".
    var allowsCacheWrite: Bool {
        switch self {
        case .cacheFirst, .staleWhileRevalidate:
            return true
        case .disabled, .networkOnly:
            return false
        }
    }

    func prepare(cached: CachedResponse?, now: Date = Date()) -> CachePreparation {
        switch self {
        case .disabled:
            return .bypass
        case .networkOnly:
            return .revalidate(nil)
        case .cacheFirst(let maxAge):
            guard let cached else { return .revalidate(nil) }
            guard !cached.requiresRevalidation else { return .revalidate(cached) }
            return cached.age(since: now) <= maxAge.timeInterval ? .returnCached(cached) : .revalidate(cached)
        case .staleWhileRevalidate(let maxAge, let staleWindow):
            guard let cached else { return .revalidate(nil) }
            guard !cached.requiresRevalidation else { return .revalidate(cached) }
            let age = cached.age(since: now)
            if age <= maxAge.timeInterval {
                return .returnCached(cached)
            }
            if age <= maxAge.timeInterval + staleWindow.timeInterval {
                return .returnStaleAndRevalidate(cached)
            }
            return .revalidate(cached)
        }
    }
}


private extension CachedResponse {
    func age(since now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(storedAt))
    }
}


// MARK: - Vary handling

package enum VaryEvaluation: Sendable, Equatable {
    /// The response carried `Vary: *`. The cache must not store this entry
    /// because no number of request-header copies can reliably distinguish
    /// future variants.
    case wildcardSkipsCache
    /// No `Vary` header on the response, or one that resolves to no concrete
    /// header names after normalization. The response can be cached without
    /// any vary snapshot.
    case noVary
    /// The response named at least one varying request header. The associated
    /// dictionary maps each lowercased header name to its current request
    /// value (nil when the request did not include the header).
    case vary([String: String?])
}

package func evaluateVary(
    responseHeaders: [String: String],
    request: URLRequest
) -> VaryEvaluation {
    let varyValue = responseHeaders.first { $0.key.caseInsensitiveCompare("Vary") == .orderedSame }?.value
    guard let varyValue, !varyValue.isEmpty else {
        return .noVary
    }
    let entries =
        varyValue
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if entries.contains(where: { $0 == "*" }) {
        return .wildcardSkipsCache
    }
    if entries.isEmpty {
        return .noVary
    }
    var snapshot: [String: String?] = [:]
    for header in entries {
        let lowered = header.lowercased()
        let normalizedValue = request.value(forHTTPHeaderField: header).map {
            HeaderValueNormalizer.normalizedValue(name: lowered, value: $0)
        }
        snapshot.updateValue(normalizedValue, forKey: lowered)
    }
    return .vary(snapshot)
}

/// Returns `true` when the `Vary` header on a 304 Not Modified response
/// differs from the one that was active when `cached` was stored.
///
/// A 304 confirms that the stored representation is still fresh, but its
/// own `Vary` header does *not* automatically describe the stored
/// representation — it describes the variant the origin would have
/// served on a full 200. When those differ, re-keying the stored entry
/// against the new `Vary` snapshot would silently move it to a different
/// cache dimension, so the executor must keep the existing snapshot and
/// only refresh freshness instead of rewriting the entry.
///
/// Comparison is case-insensitive on header *names* only; whitespace
/// around tokens is trimmed. A 304 that does not carry a `Vary` header
/// is treated as "no revision" — the caller preserves the cached
/// snapshot.
package func notModifiedRevisesVary(
    cached: CachedResponse,
    notModifiedHeaders: [AnyHashable: Any]?
) -> Bool {
    guard let notModifiedHeaders else { return false }
    let newVaryRaw =
        notModifiedHeaders.first {
            ($0.key as? String).map { $0.caseInsensitiveCompare("Vary") == .orderedSame } ?? false
        }?.value as? String
    guard let newVaryRaw, !newVaryRaw.isEmpty else { return false }

    let oldVaryRaw =
        cached.headers.first { $0.key.caseInsensitiveCompare("Vary") == .orderedSame }?.value

    func normalizedTokens(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(
            raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
    return normalizedTokens(newVaryRaw) != normalizedTokens(oldVaryRaw)
}

package func cachedResponseMatchesVary(
    _ cached: CachedResponse,
    request: URLRequest
) -> Bool {
    guard let storedVary = cached.varyHeaders else {
        return true
    }
    for (header, storedValue) in storedVary {
        let currentValue = request.value(forHTTPHeaderField: header).map {
            HeaderValueNormalizer.normalizedValue(name: header, value: $0)
        }
        if currentValue != storedValue {
            return false
        }
    }
    return true
}


package extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
