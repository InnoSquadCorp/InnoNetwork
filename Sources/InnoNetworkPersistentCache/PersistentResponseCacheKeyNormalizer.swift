import Crypto
import Foundation
import InnoNetwork
import OSLog

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Security)
import Security

/// Synchronous Security.framework boundary used by the persistent-cache key
/// loader. Keeping the adapter at the SecItem operation level lets tests
/// exercise OSStatus handling without touching the process Keychain.
struct PersistentCacheKeychainOperations {
    let copyMatching: (_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    let delete: (_ query: [String: Any]) -> OSStatus
    let add: (_ attributes: [String: Any]) -> OSStatus

    static var live: Self {
        Self(
            copyMatching: { query in
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                return (status, item as? Data)
            },
            delete: { query in
                SecItemDelete(query as CFDictionary)
            },
            add: { attributes in
                SecItemAdd(attributes as CFDictionary, nil)
            }
        )
    }
}
#endif

/// Normalizes persistent cache identities, blinding the raw URL query and
/// sensitive header values via HMAC-SHA256 with a per-cache-directory random
/// key. The HMAC key is generated on first use and persisted alongside the
/// index so the cache stays portable across process launches.
struct PersistentCacheDiskKeyNormalizer: Sendable {
    static let keyFileName = "cache-key-hmac.key"
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
        storage: PersistentResponseCache.AnchoredStorage? = nil,
        keyFileReader: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> LoadOrCreateResult {
        switch keyStorage {
        case .file:
            if let storage {
                return try loadOrCreateFromAnchoredFile(
                    storage: storage
                )
            }
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
                fileManager: fileManager,
                storage: storage
            )
            #else
            // Security framework unavailable on this platform — fall back
            // to file storage so configuration stays portable.
            logger.warning(
                "PersistentResponseCache requested keychain key storage, but Security is unavailable; using file key storage instead."
            )
            if let storage {
                return try loadOrCreateFromAnchoredFile(storage: storage)
            }
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

        let regenerated = try hasPersistedCacheWithoutKey(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
        return try createAndStoreKey(
            at: keyURL,
            dataProtectionClass: dataProtectionClass,
            fileManager: fileManager,
            regenerated: regenerated
        )
    }

    private static func loadOrCreateFromAnchoredFile(
        storage: PersistentResponseCache.AnchoredStorage
    ) throws -> LoadOrCreateResult {
        if let information = try storage.rootEntryInformation(named: keyFileName) {
            let isRegularSingleLink =
                information.st_mode & S_IFMT == S_IFREG
                && information.st_nlink == 1
            guard isRegularSingleLink else {
                storage.removeRootEntry(named: keyFileName)
                return try createAndStoreKey(
                    storage: storage,
                    regenerated: true
                )
            }

            let data = try storage.readRootFile(
                named: keyFileName,
                maximumByteCount: expectedKeyByteCount
            )
            if data.count == expectedKeyByteCount {
                storage.applyProtectionToRootFile(named: keyFileName)
                return LoadOrCreateResult(
                    normalizer: PersistentCacheDiskKeyNormalizer(key: SymmetricKey(data: data)),
                    regenerated: false
                )
            }

            storage.removeRootEntry(named: keyFileName)
            return try createAndStoreKey(
                storage: storage,
                regenerated: true
            )
        }

        let regenerated = try hasPersistedCacheWithoutKey(
            directoryURL: storage.rootURL,
            fileManager: .default,
            storage: storage
        )
        return try createAndStoreKey(
            storage: storage,
            regenerated: regenerated
        )
    }

    private static func createAndStoreKey(
        storage: PersistentResponseCache.AnchoredStorage,
        regenerated: Bool
    ) throws -> LoadOrCreateResult {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try storage.writeRootFile(data, named: keyFileName)
        return LoadOrCreateResult(
            normalizer: PersistentCacheDiskKeyNormalizer(key: key),
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
    static func loadOrCreateFromKeychain(
        directoryURL: URL,
        service: String,
        accessGroup: String?,
        fileManager: FileManager,
        storage: PersistentResponseCache.AnchoredStorage? = nil,
        keychainOperations: PersistentCacheKeychainOperations = .live
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

        let copyResult = keychainOperations.copyMatching(query)
        let regenerated: Bool
        switch copyResult.status {
        case errSecSuccess:
            guard let data = copyResult.data else {
                throw NetworkError.configuration(
                    reason: .invalidRequest(
                        "Keychain returned success without persistent cache HMAC key data."
                    ))
            }
            if data.count == expectedKeyByteCount {
                return LoadOrCreateResult(
                    normalizer: PersistentCacheDiskKeyNormalizer(key: SymmetricKey(data: data)),
                    regenerated: false
                )
            }

            // A successful read with an invalid length is deterministic
            // evidence of corruption. Only this successful-read path may
            // replace an existing item; transient Keychain errors must leave
            // both the item and persisted cache state untouched.
            var deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
            ]
            if let accessGroup {
                deleteQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            let deleteStatus = keychainOperations.delete(deleteQuery)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw keychainError(operation: "replace", status: deleteStatus)
            }
            regenerated = true

        case errSecItemNotFound:
            regenerated = try hasPersistedCacheWithoutKey(
                directoryURL: directoryURL,
                fileManager: fileManager,
                storage: storage
            )

        default:
            throw keychainError(operation: "read", status: copyResult.status)
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

        let addStatus = keychainOperations.add(addAttributes)
        guard addStatus == errSecSuccess else {
            throw keychainError(operation: "persist", status: addStatus)
        }

        // Regeneration semantics mirror the file backend: any existing
        // on-disk cache rows keyed under the prior HMAC are now
        // unreachable. Signal a reset when either a wrong-length item was
        // overwritten, or when cache state is already on disk without a
        // matching key — both cases produce HMAC mismatch for stored
        // entries.
        return LoadOrCreateResult(
            normalizer: PersistentCacheDiskKeyNormalizer(key: newKey),
            regenerated: regenerated
        )
    }

    private static func keychainError(operation: String, status: OSStatus) -> NetworkError {
        NetworkError.configuration(
            reason: .invalidRequest(
                "Failed to \(operation) persistent cache HMAC key in Keychain (status: \(status))."
            ))
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

    private static func hasPersistedCacheWithoutKey(
        directoryURL: URL,
        fileManager: FileManager,
        storage: PersistentResponseCache.AnchoredStorage? = nil
    ) throws -> Bool {
        if let storage {
            if try storage.rootEntryInformation(named: "index.json") != nil {
                return true
            }
            return try storage.bodyEntryNames().contains { name in
                guard let information = try storage.bodyEntryInformation(named: name) else {
                    return false
                }
                return information.st_mode & S_IFMT == S_IFREG
            }
        }

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

    /// Replaces the complete raw query with one HMAC value. Hashing the raw
    /// percent-encoded bytes as a single ordered string preserves duplicate
    /// keys, ordering, empty items, and encoding distinctions without storing
    /// query names or values in `index.json`.
    func normalizeURL(_ url: String) -> String {
        guard let querySeparator = url.firstIndex(of: "?") else { return url }
        let queryStart = url.index(after: querySeparator)
        let queryEnd = url[queryStart...].firstIndex(of: "#") ?? url.endIndex
        let rawQuery = String(url[queryStart..<queryEnd])
        let baseURL = String(url[..<querySeparator])
        let digest = authenticationCodeHex(
            for: "persistent-cache-query-v1\0\(rawQuery)"
        )
        return "\(baseURL)?__innonetwork_query_hmac_sha256=\(digest)"
    }

    private func normalizeHeader(_ header: String) -> String {
        guard let separator = header.firstIndex(of: ":") else { return header }
        let name = String(header[..<separator]).lowercased()
        let valueStart = header.index(after: separator)
        let trimmedValue = String(header[valueStart...]).trimmingCharacters(in: .whitespaces)
        guard ResponseCacheKey.isSensitiveNormalizedHeader(header) else {
            return "\(name):\(trimmedValue)"
        }
        return "\(name):hmac-sha256:\(authenticationCodeHex(for: trimmedValue))"
    }

    private func authenticationCodeHex(for value: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
