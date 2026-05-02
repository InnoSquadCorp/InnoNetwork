import CryptoKit
import Foundation
import os

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
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        // Sort query items so semantically-equal requests with reordered query
        // strings (e.g. `?a=1&b=2` vs `?b=2&a=1`) collapse to a single cache
        // slot. Stable secondary sort by value keeps repeated names well-defined.
        if let items = components.queryItems, items.count > 1 {
            components.queryItems = items.sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return (lhs.value ?? "") < (rhs.value ?? "")
            }
        }
        return components.url?.absoluteString
    }
}


/// Public registry for cache-key sensitive header names.
///
/// `ResponseCacheKey` fingerprints values of headers in this registry with
/// SHA-256 instead of including raw values, so credentials and similar secrets
/// never appear in stored cache keys. Built-in defaults cover common
/// authentication/identity headers; callers can register custom names for
/// proprietary identity headers.
public enum ResponseCacheHeaderPolicy {
    /// Registers `name` (case-insensitive) as a sensitive header. Subsequent
    /// cache-key derivations fingerprint values for this header. Calls are
    /// thread-safe and idempotent.
    public static func registerSensitiveHeader(_ name: String) {
        HeaderValueNormalizer.registerSensitiveHeader(name)
    }

    /// Removes a previously registered sensitive header. Built-in defaults
    /// cannot be removed.
    public static func unregisterSensitiveHeader(_ name: String) {
        HeaderValueNormalizer.unregisterSensitiveHeader(name)
    }

    /// Returns the union of built-in and user-registered sensitive header
    /// names, all lowercased. Useful for diagnostics and tests.
    public static var sensitiveHeaderNames: Set<String> {
        HeaderValueNormalizer.allSensitiveHeaderNames()
    }
}


enum HeaderValueNormalizer {
    static let defaultSensitiveHeaderNames: Set<String> = [
        "authorization",
        "cookie",
        "proxy-authorization",
        "x-api-key",
        "x-auth-token",
    ]

    private static let extraSensitiveHeaders = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func registerSensitiveHeader(_ name: String) {
        let lowered = name.lowercased()
        guard !defaultSensitiveHeaderNames.contains(lowered) else { return }
        extraSensitiveHeaders.withLock { _ = $0.insert(lowered) }
    }

    static func unregisterSensitiveHeader(_ name: String) {
        let lowered = name.lowercased()
        extraSensitiveHeaders.withLock { _ = $0.remove(lowered) }
    }

    static func allSensitiveHeaderNames() -> Set<String> {
        extraSensitiveHeaders.withLock { defaultSensitiveHeaderNames.union($0) }
    }

    static func isSensitive(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if defaultSensitiveHeaderNames.contains(lowered) { return true }
        return extraSensitiveHeaders.withLock { $0.contains(lowered) }
    }

    static func normalizedValue(name: String, value: String) -> String {
        isSensitive(name) ? fingerprint(value) : value
    }

    /// Threat model: SHA-256 of the raw header value is collision-resistant
    /// but **not** keyed. An attacker who can read on-disk cache keys (e.g.
    /// shared keychain, lost-device exfiltration) can confirm whether a
    /// guessed credential matches the value that produced the cache entry,
    /// because the fingerprint is reproducible. This is acceptable for the
    /// in-process cache — the raw value lives in memory anyway — but for
    /// the persistent cache the fingerprint should ideally be HMAC-keyed
    /// with a per-installation salt stored next to the index. The salting
    /// pass is tracked as a v5 hardening item; for 4.0.x we keep the
    /// unkeyed fingerprint and rely on disk-level encryption (`Data
    /// Protection: Complete` on Apple platforms) for at-rest secrecy.
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

    /// Approximate in-memory size of the cached payload in bytes. Includes the
    /// body, response headers, the vary-snapshot, and a fixed allowance for
    /// the stored timestamp and other Swift overhead. The `InMemoryResponseCache`
    /// adds key-side bytes (URL/method/key headers) on top before comparing
    /// against `maxBytes`.
    package var byteCost: Int {
        let headersCost = headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        let varyCost =
            varyHeaders?.reduce(0) { partial, entry in
                partial + entry.key.utf8.count + (entry.value?.utf8.count ?? 0)
            } ?? 0
        // Date stride covers `storedAt`; constant overhead covers the boxed
        // optional `varyHeaders` and the `requiresRevalidation` flag.
        return data.count + headersCost + varyCost + MemoryLayout<Date>.stride + 16
    }
}


package extension ResponseCacheKey {
    /// Approximate in-memory size of the key in bytes. Used by
    /// `InMemoryResponseCache` to charge key bytes against `maxBytes`.
    var byteCost: Int {
        method.utf8.count + url.utf8.count + headers.reduce(0) { $0 + $1.utf8.count }
    }
}


/// Async response cache abstraction used by the built-in cache policy.
public protocol ResponseCache: Sendable {
    func get(_ key: ResponseCacheKey) async -> CachedResponse?
    func set(_ key: ResponseCacheKey, _ value: CachedResponse) async
    func invalidate(_ key: ResponseCacheKey) async
}


/// In-memory `ResponseCache` implementation with a byte cap and O(1) LRU
/// bookkeeping.
///
/// Every `get`, `set`, and `invalidate` is O(1) regardless of the working set
/// size, backed by a doubly-linked list of nodes plus a dictionary for direct
/// lookup. Eviction charges against the sum of cached body bytes, response
/// headers, the vary snapshot, and the key bytes, so `maxBytes` reflects an
/// approximation of real memory usage rather than just body bytes.
public actor InMemoryResponseCache: ResponseCache {
    private final class Node {
        let key: ResponseCacheKey
        var value: CachedResponse
        var cost: Int
        var prev: Node?
        var next: Node?

        init(key: ResponseCacheKey, value: CachedResponse, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let maxBytes: Int
    private var nodes: [ResponseCacheKey: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var currentBytes = 0

    public init(maxBytes: Int = 5 * 1024 * 1024) {
        self.maxBytes = max(1, maxBytes)
    }

    public func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        guard let node = nodes[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    public func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        let entryCost = key.byteCost + value.byteCost
        if let existing = nodes[key] {
            currentBytes -= existing.cost
            existing.value = value
            existing.cost = entryCost
            currentBytes += entryCost
            moveToHead(existing)
        } else {
            let node = Node(key: key, value: value, cost: entryCost)
            nodes[key] = node
            currentBytes += entryCost
            insertAtHead(node)
        }
        evictIfNeeded()
    }

    public func invalidate(_ key: ResponseCacheKey) async {
        guard let node = nodes.removeValue(forKey: key) else { return }
        currentBytes -= node.cost
        unlink(node)
        if currentBytes < 0 { currentBytes = 0 }
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if head === node { head = next }
        if tail === node { tail = prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertAtHead(node)
    }

    private func evictIfNeeded() {
        while currentBytes > maxBytes, let last = tail {
            nodes.removeValue(forKey: last.key)
            currentBytes -= last.cost
            unlink(last)
        }
        // Storage/order desync guard: if the dictionary is empty, clear the
        // list and reset the byte counter so a subsequent insert starts from a
        // known-good state even after an internal accounting error.
        if nodes.isEmpty {
            head = nil
            tail = nil
            currentBytes = 0
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
        if !varyValuesEqual(stored: storedValue, current: currentValue, headerName: header) {
            return false
        }
    }
    return true
}

private func varyValuesEqual(stored: String?, current: String?, headerName: String) -> Bool {
    switch (stored, current) {
    case (nil, nil):
        return true
    case (nil, _), (_, nil):
        return false
    case (let storedValue?, let currentValue?):
        if isMultiTokenVaryHeader(headerName) {
            return varyTokenSet(storedValue) == varyTokenSet(currentValue)
        }
        // Trim RFC 7230 OWS so byte-for-byte differences in incidental
        // whitespace (e.g. `gzip` vs ` gzip`) do not break vary matching.
        return storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            == currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func isMultiTokenVaryHeader(_ name: String) -> Bool {
    switch name.lowercased() {
    case "accept", "accept-encoding", "accept-language", "accept-charset":
        return true
    default:
        return false
    }
}

private func varyTokenSet(_ raw: String) -> Set<String> {
    Set(
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    )
}


package extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
