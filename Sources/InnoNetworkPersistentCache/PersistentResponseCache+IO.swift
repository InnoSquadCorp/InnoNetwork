import Crypto
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Split out of `PersistentResponseCache.swift` so body read/write, index
// persistence, fsync helpers, identifier hashing, and data-protection
// application live together. All helpers stay `static` so cache-owned file
// admission is shared by live reads/writes and the open-time recovery path.
extension PersistentResponseCache {

    /// Module-internal filesystem boundary used to make protected-data and
    /// transient I/O recovery deterministic in tests without widening the
    /// public cache API.
    struct StorageIO: Sendable {
        let indexReader: @Sendable (URL) throws -> Data
        let bodyInspector: @Sendable (_ fileName: String, _ directoryURL: URL) throws -> Int
        let bodyReader:
            @Sendable (_ fileName: String, _ directoryURL: URL, _ maximumByteCount: Int) async throws -> Data

        init(
            indexReader: @escaping @Sendable (URL) throws -> Data = {
                try PersistentResponseCache.readIndexData(at: $0)
            },
            bodyInspector: @escaping @Sendable (_ fileName: String, _ directoryURL: URL) throws -> Int = {
                try PersistentResponseCache.inspectBodyFile(fileName: $0, in: $1)
            },
            bodyReader:
                @escaping @Sendable (
                    _ fileName: String,
                    _ directoryURL: URL,
                    _ maximumByteCount: Int
                ) async throws -> Data = {
                    try await PersistentResponseCache.readBodyData(
                        fileName: $0,
                        in: $1,
                        maximumByteCount: $2
                    )
                }
        ) {
            self.indexReader = indexReader
            self.bodyInspector = bodyInspector
            self.bodyReader = bodyReader
        }
    }

    enum IndexFileAccessError: Error, Sendable, Equatable {
        case cannotOpenDirectory(errno: Int32)
        case cannotOpenFile(errno: Int32)
        case cannotInspectFile(errno: Int32)
        case notRegularFile
    }

    enum BodyFileAccessError: Error, Sendable, Equatable {
        case invalidReference
        case cannotOpenDirectory(errno: Int32)
        case cannotOpenFile(errno: Int32)
        case cannotInspectFile(errno: Int32)
        case notRegularFile
    }

    /// Reads the index only after a descriptor-relative, no-follow admission
    /// check. O_NONBLOCK ensures a tampered FIFO/device entry cannot hang the
    /// synchronous cache initializer before its file type is inspected.
    static func readIndexData(at indexURL: URL) throws -> Data {
        let directoryURL = indexURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let directoryDescriptor: Int32 = directoryURL.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return -1 }
            return open(representation, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw IndexFileAccessError.cannotOpenDirectory(errno: errno)
        }
        defer { close(directoryDescriptor) }

        let fileDescriptor = indexURL.lastPathComponent.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileDescriptor >= 0 else {
            throw IndexFileAccessError.cannotOpenFile(errno: errno)
        }

        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0 else {
            let errorCode = errno
            close(fileDescriptor)
            throw IndexFileAccessError.cannotInspectFile(errno: errorCode)
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            close(fileDescriptor)
            throw IndexFileAccessError.notRegularFile
        }

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    /// Returns a cache-owned body URL only when `fileName` exactly matches
    /// the format emitted by `set`: a lowercase SHA-256 identifier, a UUID,
    /// and the `.body` suffix. Persisted index contents are untrusted input;
    /// validating the basename here prevents traversal through a corrupt or
    /// tampered `bodyFileName` field.
    static func validatedBodyURL(fileName: String, in bodiesDirectoryURL: URL) throws -> URL {
        let bytes = Array(fileName.utf8)
        let expectedByteCount = 64 + 1 + 36 + 5
        guard bytes.count == expectedByteCount else {
            throw BodyFileAccessError.invalidReference
        }
        guard
            bytes[..<64].allSatisfy({ byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            })
        else {
            throw BodyFileAccessError.invalidReference
        }
        guard bytes[64] == UInt8(ascii: "-") else {
            throw BodyFileAccessError.invalidReference
        }

        let uuidStart = 65
        let uuidEnd = uuidStart + 36
        let uuidString = String(decoding: bytes[uuidStart..<uuidEnd], as: UTF8.self)
        guard
            let uuid = UUID(uuidString: uuidString),
            uuid.uuidString == uuidString,
            String(decoding: bytes[uuidEnd...], as: UTF8.self) == ".body"
        else {
            throw BodyFileAccessError.invalidReference
        }

        let standardizedDirectoryURL = bodiesDirectoryURL.standardizedFileURL
        let directoryValues = try standardizedDirectoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
            directoryValues.isDirectory == true,
            directoryValues.isSymbolicLink != true
        else {
            throw BodyFileAccessError.invalidReference
        }

        let bodyURL =
            standardizedDirectoryURL
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard bodyURL.deletingLastPathComponent() == standardizedDirectoryURL else {
            throw BodyFileAccessError.invalidReference
        }
        return bodyURL
    }

    /// Read a body file off the actor's executor. Wrapping the synchronous
    /// descriptor read in a detached task lets the cache actor service other
    /// requests while slow flash satisfies the read. `openat` anchors the
    /// lookup to the already-opened bodies directory and `O_NOFOLLOW` rejects
    /// both directory and body-file symlinks.
    static func readBodyData(
        fileName: String,
        in bodiesDirectoryURL: URL,
        maximumByteCount: Int
    ) async throws -> Data {
        guard maximumByteCount > 0 else {
            throw BodyFileAccessError.invalidReference
        }
        _ = try validatedBodyURL(fileName: fileName, in: bodiesDirectoryURL)
        return try await Task.detached {
            let openedFile = try openRegularBodyFile(
                fileName: fileName,
                in: bodiesDirectoryURL
            )
            let fileHandle = FileHandle(fileDescriptor: openedFile.descriptor, closeOnDealloc: true)
            defer { try? fileHandle.close() }

            // Read at most the configured limit plus one sentinel byte. The
            // caller uses that extra byte to classify the body as oversized,
            // while a file that grows after the open-time size check cannot
            // force an unbounded allocation here.
            var data = Data()
            let chunkSize = 64 * 1024
            while data.count < maximumByteCount {
                let remainingByteCount = maximumByteCount - data.count
                let nextByteCount = min(chunkSize, remainingByteCount)
                guard
                    let chunk = try fileHandle.read(upToCount: nextByteCount),
                    !chunk.isEmpty
                else {
                    return data
                }
                data.append(chunk)
            }
            if let overflowByte = try fileHandle.read(upToCount: 1) {
                data.append(overflowByte)
            }
            return data
        }.value
    }

    /// Write a body file off the actor's executor and apply the configured
    /// data-protection class. `FileManager.default` is documented as
    /// thread-safe for the read/write/attribute APIs we use here, so the
    /// detached task always uses the singleton — overriding the actor's
    /// `fileManager` only affects on-actor metadata, not body bytes.
    static func writeBodyData(
        _ data: Data,
        fileName: String,
        in bodiesDirectoryURL: URL,
        dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass
    ) async throws {
        let url = try validatedBodyURL(fileName: fileName, in: bodiesDirectoryURL)
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
        guard let bodyURL = try? validatedBodyURL(fileName: fileName, in: bodiesDirectoryURL) else {
            return
        }
        // `removeItem` unlinks a symbolic link itself rather than following
        // it to the destination. Keeping the injected FileManager here also
        // preserves the cache's testability and existing storage abstraction.
        try? fileManager.removeItem(at: bodyURL)
    }

    static func inspectBodyFile(
        fileName: String,
        in bodiesDirectoryURL: URL
    ) throws -> Int {
        let openedFile = try openRegularBodyFile(
            fileName: fileName,
            in: bodiesDirectoryURL
        )
        defer { close(openedFile.descriptor) }
        guard
            openedFile.status.st_size >= 0,
            let size = Int(exactly: openedFile.status.st_size)
        else {
            throw BodyFileAccessError.invalidReference
        }
        return size
    }

    private static func openRegularBodyFile(
        fileName: String,
        in bodiesDirectoryURL: URL
    ) throws -> (descriptor: Int32, status: stat) {
        _ = try validatedBodyURL(fileName: fileName, in: bodiesDirectoryURL)
        let standardizedDirectoryURL = bodiesDirectoryURL.standardizedFileURL
        let directoryDescriptor = standardizedDirectoryURL.withUnsafeFileSystemRepresentation {
            representation -> Int32 in
            guard let representation else { return -1 }
            return open(representation, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            let errorCode = errno
            throw BodyFileAccessError.cannotOpenDirectory(errno: errorCode)
        }
        defer { close(directoryDescriptor) }

        let fileDescriptor = fileName.withCString { representation in
            openat(
                directoryDescriptor,
                representation,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileDescriptor >= 0 else {
            let errorCode = errno
            throw BodyFileAccessError.cannotOpenFile(errno: errorCode)
        }

        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0 else {
            let errorCode = errno
            close(fileDescriptor)
            throw BodyFileAccessError.cannotInspectFile(errno: errorCode)
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            close(fileDescriptor)
            throw BodyFileAccessError.notRegularFile
        }
        return (descriptor: fileDescriptor, status: fileStatus)
    }

    /// Returns `true` only when an I/O operation proved the path is absent.
    /// Every other error can be transient (protected data, permissions,
    /// coordinated access, or storage I/O) and must not be treated as
    /// corruption.
    static func isMissingFileError(_ error: Error) -> Bool {
        if let accessError = error as? IndexFileAccessError {
            switch accessError {
            case .cannotOpenDirectory(let errorCode),
                .cannotOpenFile(let errorCode),
                .cannotInspectFile(let errorCode):
                return errorCode == ENOENT
            case .notRegularFile:
                return false
            }
        }

        if let accessError = error as? BodyFileAccessError {
            switch accessError {
            case .cannotOpenDirectory(let errorCode),
                .cannotOpenFile(let errorCode),
                .cannotInspectFile(let errorCode):
                return errorCode == ENOENT
            case .invalidReference, .notRegularFile:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }

    /// Index entries with a deterministic path/type violation can be reset.
    /// Access, Data Protection, and storage-I/O failures remain retryable and
    /// must preserve every cache-owned artifact.
    static func shouldResetIndex(after error: Error) -> Bool {
        guard let accessError = error as? IndexFileAccessError else { return false }
        switch accessError {
        case .notRegularFile:
            return true
        case .cannotOpenDirectory(let errorCode),
            .cannotOpenFile(let errorCode),
            .cannotInspectFile(let errorCode):
            return errorCode == ELOOP || errorCode == ENOTDIR || errorCode == EISDIR
        }
    }

    /// Classify only deterministic structural failures as scrub-worthy. All
    /// other errors preserve the entry so a later unlock or transient storage
    /// recovery can retry the same body.
    static func shouldScrubBody(after error: Error) -> Bool {
        if let accessError = error as? BodyFileAccessError {
            switch accessError {
            case .invalidReference, .notRegularFile:
                return true
            case .cannotOpenDirectory(let errorCode),
                .cannotOpenFile(let errorCode),
                .cannotInspectFile(let errorCode):
                return errorCode == ENOENT || errorCode == ENOTDIR || errorCode == ELOOP
            }
        }

        if isMissingFileError(error) {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(ENOTDIR) || nsError.code == Int(ELOOP))
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

    /// Apply the cache-owned storage policy to `url`. Backup exclusion is
    /// unconditional on Darwin because cache contents are reproducible;
    /// iOS-family platforms additionally receive the configured data-
    /// protection class. Module-internal so the HMAC key uses the same policy.
    static func applyDataProtection(
        _ dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        to url: URL,
        fileManager: FileManager
    ) {
        applyDataProtection(
            dataProtectionClass,
            to: url,
            fileManager: fileManager,
            excludesFromBackup: true
        )
    }

    static func applyDataProtection(
        _ dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
        to url: URL,
        fileManager: FileManager,
        excludesFromBackup: Bool
    ) {
        let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard resourceValues?.isSymbolicLink != true else { return }

        #if canImport(Darwin)
        if excludesFromBackup {
            var resourceURL = url
            var backupResourceValues = URLResourceValues()
            backupResourceValues.isExcludedFromBackup = true
            try? resourceURL.setResourceValues(backupResourceValues)
        }
        #endif

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
