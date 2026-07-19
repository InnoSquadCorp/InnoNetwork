import Foundation
import InnoNetwork

// Split out of `PersistentResponseCache.swift` so the privacy / caching
// policy gate — `shouldStore`, sensitive request-header detection, and
// `Cache-Control` directive parsing — lives in one place. All helpers stay
// `static`; this file only relocates code, no behaviour changes.
extension PersistentResponseCache {

    static func shouldStore(
        key: DiskKey,
        responseHeaders: [String: String],
        configuration: PersistentResponseCacheConfiguration
    ) -> Bool {
        if !configuration.storesAuthenticatedResponses,
            containsSensitiveRequestHeader(key.headers)
        {
            return false
        }

        let cacheControl = cacheControlDirectives(in: responseHeaders)
        if containsAuthorizationRequestHeader(key.headers),
            !ResponseCacheStoragePolicy.responsePermitsAuthenticatedStorage(cacheControlDirectives: cacheControl)
        {
            return false
        }
        // RFC 9111 §5.2.2.5: `no-store` forbids any cache from storing
        // any part of the response. The `RFC9111CompliantCachePolicy`
        // wrapper already filters this at the request gate, but when a
        // consumer wires `PersistentResponseCache` directly (or composes
        // it under a different policy), this disk-layer guard prevents
        // a `no-store` response from ever touching the filesystem.
        if cacheControl.contains("no-store") || cacheControl.contains("private") {
            return false
        }

        if !configuration.storesSetCookieResponses,
            responseHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame })
        {
            return false
        }

        return true
    }

    static func isFullFsyncUnsupported(_ errorNumber: Int32) -> Bool {
        #if canImport(Darwin)
        errorNumber == EINVAL || errorNumber == EOPNOTSUPP
        #else
        _ = errorNumber
        false
        #endif
    }

    static func containsSensitiveRequestHeader(_ headers: [String]) -> Bool {
        headers.contains(where: ResponseCacheKey.isSensitiveNormalizedHeader)
    }

    static func containsAuthorizationRequestHeader(_ headers: [String]) -> Bool {
        ResponseCacheStoragePolicy.containsAuthorizationKeyHeader(headers)
    }

    static func cacheControlDirectives(in headers: [String: String]) -> Set<String> {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else { return [] }
        return Set(
            HTTPListParser.split(combined)
                .map(HTTPListParser.directiveName(of:))
                .filter { !$0.isEmpty }
        )
    }

    static func varySnapshot(_ varyHeaders: [String: String?]?, matches key: DiskKey) -> Bool {
        guard let varyHeaders else { return true }
        let requestHeaders = key.headers.reduce(into: [String: String]()) { result, header in
            guard let separator = header.firstIndex(of: ":") else { return }
            let name = String(header[..<separator]).lowercased()
            let value = String(header[header.index(after: separator)...])
            result[name] = value
        }
        for (rawName, storedValue) in varyHeaders {
            let name = rawName.lowercased()
            let currentValue = requestHeaders[name]
            switch (storedValue, currentValue) {
            case (nil, nil):
                continue
            case (nil, _), (_, nil):
                return false
            case (let stored?, let current?):
                if current.hasPrefix("hmac-sha256:"), stored.hasPrefix("sha256:") {
                    // Persistent disk keys already include the HMAC-protected
                    // sensitive request header. A legacy unkeyed Vary snapshot
                    // can only be considered after that key matched, and the
                    // HMAC/SHA digest bodies are intentionally incomparable.
                    continue
                }
                if !varyValuesEqualForPersistentLookup(stored: stored, current: current, headerName: name) {
                    return false
                }
            }
        }
        return true
    }

    private static func varyValuesEqualForPersistentLookup(
        stored: String,
        current: String,
        headerName: String
    ) -> Bool {
        if isMultiTokenPersistentVaryHeader(headerName) {
            // Keep parity with core `cachedResponseMatchesVary`: content
            // negotiation lists are compared as normalized token sets.
            return Set(HTTPListParser.split(stored).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                == Set(HTTPListParser.split(current).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
            == current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMultiTokenPersistentVaryHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "accept", "accept-encoding", "accept-language", "accept-charset":
            return true
        default:
            return false
        }
    }
}
