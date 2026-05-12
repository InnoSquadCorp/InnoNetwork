import Crypto
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Split out of `PersistentResponseCache.swift` so body read/write, index
// persistence, fsync helpers, identifier hashing, and data-protection
// application live together. All helpers stay `static`; this file only
// relocates code, no behaviour changes.
extension PersistentResponseCache {

    /// Read a body file off the actor's executor. Wrapping the synchronous
    /// `Data(contentsOf:)` in a detached task lets the cache actor service
    /// other requests while slow flash satisfies the read.
    static func readBodyData(at url: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: url) }.value
    }

    /// Write a body file off the actor's executor and apply the configured
    /// data-protection class. `FileManager.default` is documented as
    /// thread-safe for the read/write/attribute APIs we use here, so the
    /// detached task always uses the singleton — overriding the actor's
    /// `fileManager` only affects on-actor metadata, not body bytes.
    static func writeBodyData(
        _ data: Data,
        to url: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass
    ) async throws {
        try await Task.detached {
            try data.write(to: url, options: .atomic)
            applyDataProtection(dataProtectionClass, to: url, fileManager: .default)
        }.value
    }

    static func persistIndex(
        _ index: Index,
        to indexURL: URL,
        directoryURL: URL,
        configuration: PersistentResponseCacheConfiguration,
        fileManager: FileManager,
        durable: Bool = true
    ) throws {
        let data = try JSONEncoder.persistentCache.encode(index)
        try data.write(to: indexURL, options: .atomic)
        applyDataProtection(configuration.dataProtectionClass, to: indexURL, fileManager: fileManager)
        guard durable, configuration.persistenceFsyncPolicy == .always else { return }
        fsyncFile(at: indexURL)
        fsyncDirectory(at: directoryURL)
    }

    static func removeBody(fileName: String, in bodiesDirectoryURL: URL, fileManager: FileManager) {
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: bodyURL)
    }

    static func fileSize(at url: URL, fileManager: FileManager) -> Int? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    static func fsyncFile(at url: URL) {
        let fd = url.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return open(rep, O_RDONLY | O_CLOEXEC)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = syncFileDescriptor(fd)
    }

    static func fsyncDirectory(at url: URL) {
        let fd = url.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return open(rep, O_RDONLY | O_CLOEXEC)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = syncFileDescriptor(fd)
    }

    @discardableResult
    static func syncFileDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        if fcntl(fd, F_FULLFSYNC, 0) == 0 {
            return 0
        }
        let fullFsyncErrno = errno
        guard isFullFsyncUnsupported(fullFsyncErrno) else {
            errno = fullFsyncErrno
            return -1
        }
        #endif
        return fsync(fd)
    }

    /// Apply the configured data-protection class to `url`. Module-internal
    /// so ``PersistentCacheDiskKeyNormalizer`` — which lives in its own
    /// file — can request the same protection on the HMAC key it manages
    /// alongside the cache.
    static func applyDataProtection(
        _ dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        to url: URL,
        fileManager: FileManager
    ) {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try? fileManager.setAttributes(
            [.protectionKey: dataProtectionClass.fileProtectionType],
            ofItemAtPath: url.path
        )
        #else
        _ = (dataProtectionClass, url, fileManager)
        #endif
    }

    static func identifier(for key: DiskKey, encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(key)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func identifier(
        for key: DiskKey,
        varyHeaders: [String: String?]?,
        encoder: JSONEncoder
    ) throws -> String {
        guard let varyHeaders else {
            return try identifier(for: key, encoder: encoder)
        }
        let normalizedVaryHeaders = varyHeaders.reduce(into: [String: String?]()) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        let data = try encoder.encode(VariantDiskKey(key: key, varyHeaders: normalizedVaryHeaders))
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
