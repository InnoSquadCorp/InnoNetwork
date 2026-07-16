import CryptoKit
import Foundation

/// Maps a public URLSession identifier to one bounded filesystem component.
///
/// Conventional lowercase reverse-DNS identifiers retain their existing
/// directory layout. Values that could create nested paths, escape the storage
/// root, exceed a conservative component length, collide with the encoded
/// namespace, or alias by case on a case-insensitive filesystem use a
/// deterministic SHA-256 component instead. The original identifier remains
/// unchanged for Foundation's background-session identity.
package enum DownloadSessionStorageKey {
    private static let encodedPrefix = "~"
    private static let maximumRawByteCount = 128

    package static func component(for sessionIdentifier: String) -> String {
        guard isSafeRawComponent(sessionIdentifier) else {
            return encodedPrefix
                + SHA256.hash(data: Data(sessionIdentifier.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return sessionIdentifier
    }

    private static func isSafeRawComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
            value != ".",
            value != "..",
            value.utf8.count <= maximumRawByteCount
        else {
            return false
        }

        return value.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39,  // 0...9
                0x61...0x7A,  // a...z
                0x2D, 0x2E, 0x5F:  // -, ., _
                true
            default:
                false
            }
        }
    }
}
