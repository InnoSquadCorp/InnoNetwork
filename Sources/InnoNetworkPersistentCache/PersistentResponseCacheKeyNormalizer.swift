import CryptoKit
import Foundation
import InnoNetwork

/// Normalizes per-request cache key headers, blinding sensitive values via
/// HMAC-SHA256 with a per-cache-directory random key. The HMAC key is
/// generated on first use and persisted alongside the index so the cache stays
/// portable across process launches.
struct PersistentCacheDiskKeyNormalizer: Sendable {
    private static let keyFileName = "cache-key-hmac.key"
    private static let expectedKeyByteCount = 32  // SymmetricKeySize.bits256
    private let key: SymmetricKey

    /// Result of opening or creating the on-disk HMAC key.
    ///
    /// `regenerated` is `true` when an existing key file was discarded due to
    /// a read failure (corruption, partial write, file protection edge case)
    /// or an invalid length. Callers must reset any cached entries that were
    /// keyed under the prior HMAC so the cache stays self-consistent.
    struct LoadOrCreateResult {
        let normalizer: PersistentCacheDiskKeyNormalizer
        let regenerated: Bool
    }

    static func loadOrCreate(
        directoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        fileManager: FileManager
    ) throws -> LoadOrCreateResult {
        let keyURL = directoryURL.appendingPathComponent(keyFileName, isDirectory: false)
        if fileManager.fileExists(atPath: keyURL.path) {
            // Best-effort read with length validation. Any failure mode
            // (unreadable, truncated, oversized) routes through the same
            // regenerate-and-reset recovery as a missing key.
            if let data = try? Data(contentsOf: keyURL), data.count == expectedKeyByteCount {
                PersistentResponseCache.applyDataProtection(
                    dataProtectionClass,
                    to: keyURL,
                    fileManager: fileManager
                )
                return LoadOrCreateResult(
                    normalizer: PersistentCacheDiskKeyNormalizer(key: SymmetricKey(data: data)),
                    regenerated: false
                )
            }
            try? fileManager.removeItem(at: keyURL)
            let key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            try bytes.write(to: keyURL, options: .atomic)
            PersistentResponseCache.applyDataProtection(dataProtectionClass, to: keyURL, fileManager: fileManager)
            return LoadOrCreateResult(
                normalizer: PersistentCacheDiskKeyNormalizer(key: key),
                regenerated: true
            )
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: .atomic)
        PersistentResponseCache.applyDataProtection(dataProtectionClass, to: keyURL, fileManager: fileManager)
        return LoadOrCreateResult(
            normalizer: PersistentCacheDiskKeyNormalizer(key: key),
            regenerated: false
        )
    }

    func normalizeHeaders(_ headers: [String]) -> [String] {
        headers.map(normalizeHeader).sorted()
    }

    private func normalizeHeader(_ header: String) -> String {
        guard let separator = header.firstIndex(of: ":") else { return header }
        let name = String(header[..<separator]).lowercased()
        let valueStart = header.index(after: separator)
        let value = String(header[valueStart...])
        guard ResponseCacheHeaderPolicy.sensitiveHeaderNames.contains(name) else {
            return "\(name):\(value)"
        }
        return "\(name):hmac-sha256:\(authenticationCodeHex(for: value))"
    }

    private func authenticationCodeHex(for value: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
