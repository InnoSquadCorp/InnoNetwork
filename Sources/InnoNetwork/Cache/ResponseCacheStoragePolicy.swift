import Foundation

package enum ResponseCacheStoragePolicy {
    private static let authenticatedStoragePermissionDirectives: Set<String> = [
        "must-revalidate",
        "public",
        "s-maxage",
    ]

    package static func responsePermitsAuthenticatedStorage(cacheControlDirectives: Set<String>) -> Bool {
        !authenticatedStoragePermissionDirectives.isDisjoint(with: cacheControlDirectives)
    }

    package static func containsAuthorizationRequestHeader(_ headers: [String: String]) -> Bool {
        headers.keys.contains {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }
    }

    package static func containsAuthorizationKeyHeader(_ headers: [String]) -> Bool {
        headers.contains { header in
            guard let separator = header.firstIndex(of: ":") else { return false }
            let name = String(header[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.caseInsensitiveCompare("Authorization") == .orderedSame
        }
    }
}
