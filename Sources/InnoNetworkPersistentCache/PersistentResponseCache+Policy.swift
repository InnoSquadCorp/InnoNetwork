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
        if cacheControl.contains("private") {
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
        let sensitiveHeaderNames = ResponseCacheHeaderPolicy.sensitiveHeaderNames
        return headers.contains { header in
            guard let separator = header.firstIndex(of: ":") else { return false }
            let name = String(header[..<separator]).lowercased()
            return sensitiveHeaderNames.contains(name)
        }
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
}
