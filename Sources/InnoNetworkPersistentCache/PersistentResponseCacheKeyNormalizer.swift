import Crypto
import Foundation
import InnoNetwork
import OSLog

#if canImport(Security)
import Security
#endif

/// Normalizes per-request cache key headers, blinding sensitive values via
/// HMAC-SHA256 with a per-cache-directory random key. The HMAC key is
/// generated on first use and persisted alongside the index so the cache stays
/// portable across process launches.
struct PersistentCacheDiskKeyNormalizer: Sendable {
    private static let keyFileName = "cache-key-hmac.key"
    private static let expectedKeyByteCount = 32  // SymmetricKeySize.bits256
    private static let logger = Logger(subsystem: "innosquad.network.cache", category: "KeyStorage")
    private let key: SymmetricKey

    /// Result of opening or creating the on-disk HMAC key.
    ///
    /// `regenerated` is `true` when an existing, readable key file had an
    /// invalid length, or when the key file is missing while persisted cache
    /// metadata/body files remain. Callers must reset any cached entries that
    /// were keyed under the prior HMAC so the cache stays self-consistent.
    /// Read failures are surfaced without replacing the key because they can
    /// be transient (for example, while protected data is unavailable).
    struct LoadOrCreateResult {
        let normalizer: PersistentCacheDiskKeyNormalizer
        let regenerated: Bool
    }

    static func loadOrCreate(
        directoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        keyStorage: PersistentResponseCacheConfiguration.KeyStorage = .file,
        fileManager: FileManager,
        keyFileReader: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> LoadOrCreateResult {
        switch keyStorage {
        case .file:
            return try loadOrCreateFromFile(
                directoryURL: directoryURL,
                dataProtectionClass: dataProtectionClass,
                fileManager: fileManager,
                keyFileReader: keyFileReader
            )
        case .keychain(let service, let accessGroup):
            #if canImport(Security)
            return try loadOrCreateFromKeychain(
                directoryURL: directoryURL,
                service: service,
                accessGroup: accessGroup,
                fileManager: fileManager
            )
            #else
            // Security framework unavailable on this platform — fall back
            // to file storage so configuration stays portable.
            logger.warning(
                "PersistentResponseCache requested keychain key storage, but Security is unavailable; using file key storage instead."
            )
            return try loadOrCreateFromFile(
                directoryURL: directoryURL,
                dataProtectionClass: dataProtectionClass,
                fileManager: fileManager,
                keyFileReader: keyFileReader
            )
            #endif
        }
    }

    private static func loadOrCreateFromFile(
        directoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        fileManager: FileManager,
        keyFileReader: @Sendable (URL) throws -> Data
    ) throws -> LoadOrCreateResult {
        let keyURL = directoryURL.appendingPathComponent(keyFileName, isDirectory: false)
        if fileManager.fileExists(atPath: keyURL.path) {
            // A directory, symbolic link, or other known non-regular entry at
            // the key path is deterministic structural corruption, not a
            // transient protected-data read failure. Recover it without ever
            // following a link outside the cache directory.
            let resourceValues = try? keyURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if resourceValues?.isSymbolicLink == true || resourceValues?.isRegularFile == false {
                try? fileManager.removeItem(at: keyURL)
                return try createAndStoreKey(
                    at: keyURL,
                    dataProtectionClass: dataProtectionClass,
                    fileManager: fileManager,
                    regenerated: true
                )
            }

            // A failed read does not prove the key is corrupt. Protected data
            // can be temporarily unavailable while a device is locked, and
            // permissions or coordinated file access can fail transiently.
            // Surface that error without deleting either the key or cache.
            let data = try keyFileReader(keyURL)
            if data.count == expectedKeyByteCount {
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

            // A successful read with an invalid length is deterministic
            // evidence that the stored key cannot be used. Regenerate it and
            // let the caller reset entries keyed under the prior HMAC.
            try? fileManager.removeItem(at: keyURL)
            return try createAndStoreKey(
                at: keyURL,
                dataProtectionClass: dataProtectionClass,
                fileManager: fileManager,
                regenerated: true
            )
        }

        let regenerated = hasPersistedCacheWithoutKey(directoryURL: directoryURL, fileManager: fileManager)
        return try createAndStoreKey(
            at: keyURL,
            dataProtectionClass: dataProtectionClass,
            fileManager: fileManager,
            regenerated: regenerated
        )
    }

    private static func createAndStoreKey(
        at keyURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        fileManager: FileManager,
        regenerated: Bool
    ) throws -> LoadOrCreateResult {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: .atomic)
        PersistentResponseCache.applyDataProtection(dataProtectionClass, to: keyURL, fileManager: fileManager)
        return LoadOrCreateResult(
            normalizer: PersistentCacheDiskKeyNormalizer(key: key),
            regenerated: regenerated
        )
    }

    #if canImport(Security)
    private static func loadOrCreateFromKeychain(
        directoryURL: URL,
        service: String,
        accessGroup: String?,
        fileManager: FileManager
    ) throws -> LoadOrCreateResult {
        let account = keychainAccount(for: directoryURL)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // macOS defaults to the legacy file-based keychain unless the
        // caller opts into the data-protection keychain. iOS/tvOS/
        // watchOS/visionOS are already on the data-protection
        // keychain implicitly, but adding the attribute is a no-op
        // there. Opting in uniformly keeps the storage backend
        // consistent across platforms — the file keychain on macOS
        // would otherwise prompt the user on unlock and persist
        // entries in a format the iOS-style attributes
        // (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) do not
        // fully constrain.
        query[kSecUseDataProtectionKeychain as String] = true
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if copyStatus == errSecSuccess,
            let data = item as? Data,
            data.count == expectedKeyByteCount
        {
            return LoadOrCreateResult(
                normalizer: PersistentCacheDiskKeyNormalizer(key: SymmetricKey(data: data)),
                regenerated: false
            )
        }

        // Any non-success / wrong-length read regenerates the key. Wipe
        // the existing item so the subsequent add does not race against a
        // pre-existing entry of a different length.
        let priorItemPresent = copyStatus != errSecItemNotFound
        if priorItemPresent {
            var deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
            ]
            if let accessGroup {
                deleteQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            _ = SecItemDelete(deleteQuery as CFDictionary)
        }

        let newKey = SymmetricKey(size: .bits256)
        let newKeyData = newKey.withUnsafeBytes { Data($0) }
        var addAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: newKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            addAttributes[kSecAttrAccessGroup as String] = accessGroup
        }

        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "Failed to persist persistent cache HMAC key to Keychain (status: \(addStatus))."
                ))
        }

        // Regeneration semantics mirror the file backend: any existing
        // on-disk cache rows keyed under the prior HMAC are now
        // unreachable. Signal a reset when either a wrong-length item was
        // overwritten, or when cache state is already on disk without a
        // matching key — both cases produce HMAC mismatch for stored
        // entries.
        let regenerated =
            priorItemPresent
            || hasPersistedCacheWithoutKey(directoryURL: directoryURL, fileManager: fileManager)
        return LoadOrCreateResult(
            normalizer: PersistentCacheDiskKeyNormalizer(key: newKey),
            regenerated: regenerated
        )
    }

    /// Scope the keychain account to the cache directory so two caches in
    /// the same process — sharing the same `service` value — do not
    /// alias onto the same key.
    private static func keychainAccount(for directoryURL: URL) -> String {
        let canonical = directoryURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "InnoNetworkPersistentCache.\(hex)"
    }
    #endif

    private static func hasPersistedCacheWithoutKey(directoryURL: URL, fileManager: FileManager) -> Bool {
        let indexURL = directoryURL.appendingPathComponent("index.json", isDirectory: false)
        if fileManager.fileExists(atPath: indexURL.path) {
            return true
        }

        let bodiesURL = directoryURL.appendingPathComponent("bodies", isDirectory: true)
        guard
            let bodyURLs = try? fileManager.contentsOfDirectory(
                at: bodiesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }

        return bodyURLs.contains { bodyURL in
            let isRegularFile =
                (try? bodyURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isRegularFile
        }
    }

    func normalizeHeaders(_ headers: [String]) -> [String] {
        headers.map(normalizeHeader).sorted()
    }

    private func normalizeHeader(_ header: String) -> String {
        guard let separator = header.firstIndex(of: ":") else { return header }
        let name = String(header[..<separator]).lowercased()
        let valueStart = header.index(after: separator)
        let trimmedValue = String(header[valueStart...]).trimmingCharacters(in: .whitespaces)
        guard ResponseCacheHeaderPolicy.sensitiveHeaderNames.contains(name) else {
            return "\(name):\(trimmedValue)"
        }
        return "\(name):hmac-sha256:\(authenticationCodeHex(for: trimmedValue))"
    }

    private func authenticationCodeHex(for value: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
