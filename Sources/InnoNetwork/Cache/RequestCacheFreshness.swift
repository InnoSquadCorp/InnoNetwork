import Foundation

package extension ResponseCachePolicy {
    var honorsRequestFreshness: Bool {
        switch self {
        case .requestFreshness: true
        case .rfc9111Compliant(let inner), .staleIfError(let inner), .requestOnlyIfCached(let inner):
            inner.honorsRequestFreshness
        case .disabled, .networkOnly, .cacheFirst, .staleWhileRevalidate: false
        }
    }

    func permitsRequestFreshness(_ request: URLRequest, cached: CachedResponse, now: Date) -> Bool {
        guard honorsRequestFreshness else { return true }
        let directives = RequestCacheFreshness(request: request)
        guard !directives.requiresValidation else { return false }
        guard directives.maxAge != nil || directives.minFresh != nil else { return true }
        let age = RFC9111ResponseAge.clamp(max(0, now.timeIntervalSince(cached.storedAt)) + cached.rfc9111InitialAge)
        // Request freshness constraints use corrected age and cannot extend
        // either the caller's ceiling or the origin's freshness lifetime.
        guard
            let lifetime = ResponseCachePolicy.rfc9111Compliant(wrapping: self).effectiveFreshnessLifetime(for: cached),
            age < lifetime
        else { return false }
        if let maxAge = directives.maxAge, age > maxAge { return false }
        if let minFresh = directives.minFresh, minFresh > lifetime - age { return false }
        return true
    }

    func prepare(cached: CachedResponse?, request: URLRequest, now: Date) -> CachePreparation {
        let preparation = prepare(cached: cached, now: now)
        switch preparation {
        case .returnCached(let entry), .returnStaleAndRevalidate(let entry):
            return permitsRequestFreshness(request, cached: entry, now: now) ? preparation : .revalidate(entry)
        default: return preparation
        }
    }
}

private struct RequestCacheFreshness {
    var requiresValidation = false
    var maxAge: TimeInterval?
    var minFresh: TimeInterval?

    init(request: URLRequest) {
        var seen: Set<String> = []
        for element in HTTPListParser.split(request.value(forHTTPHeaderField: "Cache-Control") ?? "") {
            let name = HTTPListParser.directiveName(of: element)
            if name == "no-cache" { requiresValidation = true }
            guard name == "max-age" || name == "min-fresh" else { continue }
            guard seen.insert(name).inserted, let equals = element.firstIndex(of: "=") else {
                requiresValidation = true
                continue
            }
            var value = String(element[element.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
                requiresValidation = true
                continue
            }
            let seconds = min(Double(value) ?? .infinity, RFC9111ResponseAge.maximumDeltaSeconds)
            if name == "max-age" {
                maxAge = seconds
                if seconds == 0 { requiresValidation = true }
            } else {
                minFresh = seconds
            }
        }
    }
}
