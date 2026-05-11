import Foundation

// MARK: - Directive-aware preparation
//
// The public surface lives on
// ``ResponseCachePolicy/rfc9111Compliant(wrapping:)`` itself — the enum
// case doubles as the construction site. Callers write
// `.rfc9111Compliant(wrapping: .cacheFirst(maxAge: ...))` directly. See
// the case's docstring on ``ResponseCachePolicy`` for the directive
// semantics.

package extension ResponseCachePolicy {
    /// Implements ``prepare(cached:now:)`` for the
    /// ``ResponseCachePolicy/rfc9111Compliant(wrapping:)`` case.
    ///
    /// The helper applies `no-store`, `must-revalidate`, and `max-age`
    /// directive overrides on top of the inner policy's decision rather
    /// than reimplementing freshness math, so wrapping inherits future
    /// changes to the inner policy automatically.
    func prepareWithRFC9111(
        inner: ResponseCachePolicy,
        cached: CachedResponse?,
        now: Date
    ) -> CachePreparation {
        guard let cached else { return inner.prepare(cached: nil, now: now) }

        let directives = RFC9111CacheControlDirectives(headers: cached.headers)
        if directives.noStore {
            return .revalidate(nil)
        }

        let adjustedInner = inner.applyingMaxAge(serverMaxAge: directives.maxAgeSeconds)
        let preparation = adjustedInner.prepare(cached: cached, now: now)

        if directives.mustRevalidate, case .returnStaleAndRevalidate(let entry) = preparation {
            return .revalidate(entry)
        }
        return preparation
    }

    /// Returns a copy of the policy with `maxAge` clamped to
    /// `min(self.maxAge, serverMaxAge)`. Cases that do not carry a
    /// freshness window (`.disabled`, `.networkOnly`) are returned
    /// unchanged. Nested adapter cases are unwrapped once so the override
    /// hits the freshness-bearing leaf.
    func applyingMaxAge(serverMaxAge: TimeInterval?) -> ResponseCachePolicy {
        guard let serverMaxAge, serverMaxAge >= 0 else { return self }
        let serverDuration = Duration.seconds(serverMaxAge)
        switch self {
        case .disabled, .networkOnly:
            return self
        case .cacheFirst(let maxAge):
            return .cacheFirst(maxAge: min(maxAge, serverDuration))
        case .staleWhileRevalidate(let maxAge, let staleWindow):
            return .staleWhileRevalidate(maxAge: min(maxAge, serverDuration), staleWindow: staleWindow)
        case .rfc9111Compliant(let inner):
            return inner.applyingMaxAge(serverMaxAge: serverMaxAge)
        }
    }
}

// MARK: - Directive parsing

/// Parsed projection of the `Cache-Control` header directives that the
/// adapter cares about. Header names are matched case-insensitively;
/// directive names are normalised to lowercase per RFC 9111 §5.2.
struct RFC9111CacheControlDirectives: Sendable, Equatable {
    let noStore: Bool
    let mustRevalidate: Bool
    let maxAgeSeconds: TimeInterval?

    init(headers: [String: String]) {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else {
            self.noStore = false
            self.mustRevalidate = false
            self.maxAgeSeconds = nil
            return
        }

        var noStore = false
        var mustRevalidate = false
        var maxAge: TimeInterval?
        for element in HTTPListParser.split(combined) {
            let name = HTTPListParser.directiveName(of: element)
            switch name {
            case "no-store":
                noStore = true
            case "must-revalidate":
                mustRevalidate = true
            case "max-age":
                // `s-maxage` is intentionally not honoured: it targets shared
                // caches and InnoNetwork's response cache is private-by-default.
                if let value = Self.directiveValue(of: element),
                    let seconds = Self.parseDeltaSeconds(value)
                {
                    maxAge = seconds
                }
            default:
                continue
            }
        }
        self.noStore = noStore
        self.mustRevalidate = mustRevalidate
        self.maxAgeSeconds = maxAge
    }

    /// Returns the raw value portion of a single Cache-Control element
    /// (everything after the first `=`, with surrounding whitespace and
    /// at most one pair of surrounding quotes trimmed). Returns `nil`
    /// when the element has no `=` (presence-only directive).
    private static func directiveValue(of element: String) -> String? {
        guard let equals = element.firstIndex(of: "=") else { return nil }
        let raw = element[element.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Parses an RFC 9111 §1.2.2 `delta-seconds` (unsigned decimal).
    /// Negative or non-numeric values are rejected — servers occasionally
    /// emit `max-age=-1` to mean "stale immediately" but RFC 9111 leaves
    /// the behaviour undefined; the safest interpretation is to ignore
    /// the directive and let the inner policy decide.
    private static func parseDeltaSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return TimeInterval(trimmed)
    }
}
