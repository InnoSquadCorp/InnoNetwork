import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension PersistentResponseCache {
    /// Retains descriptors for the caller-selected cache root and the
    /// cache-owned body directory. Every managed entry is accessed relative
    /// to these descriptors, so replacing either visible path after open
    /// cannot redirect cache I/O outside the admitted directories.
    final class AnchoredStorage: Sendable {
        enum FileAccessError: Error, Sendable, Equatable {
            case cannotOpen(errno: Int32)
            case cannotInspect(errno: Int32)
            case notRegularFile
        }

        let rootDescriptor: Int32
        let bodiesDescriptor: Int32
        let rootURL: URL
        let bodiesURL: URL
        let dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass

        private init(
            rootDescriptor: Int32,
            bodiesDescriptor: Int32,
            rootURL: URL,
            bodiesURL: URL,
            dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass
        ) {
            self.rootDescriptor = rootDescriptor
            self.bodiesDescriptor = bodiesDescriptor
            self.rootURL = rootURL
            self.bodiesURL = bodiesURL
            self.dataProtectionClass = dataProtectionClass
        }

        deinit {
            close(bodiesDescriptor)
            close(rootDescriptor)
        }

        static func open(
            directoryURL: URL,
            dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
            fileManager: FileManager
        ) throws -> AnchoredStorage {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let canonicalRootURL = directoryURL.resolvingSymlinksInPath().standardizedFileURL
            let rootDescriptor: Int32 = canonicalRootURL.withUnsafeFileSystemRepresentation {
                representation -> Int32 in
                guard let representation else { return -1 }
                return systemOpen(
                    representation,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard rootDescriptor >= 0 else { throw posixError() }
            do {
                try requireDirectory(rootDescriptor)
                return try openOrCreateBodiesDirectory(
                    rootDescriptor: rootDescriptor,
                    rootURL: canonicalRootURL,
                    dataProtectionClass: dataProtectionClass
                )
            } catch {
                close(rootDescriptor)
                throw error
            }
        }

        private static func openOrCreateBodiesDirectory(
            rootDescriptor: Int32,
            rootURL: URL,
            dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass
        ) throws -> AnchoredStorage {
            let bodiesName = "bodies"
            let mkdirResult = bodiesName.withCString {
                mkdirat(rootDescriptor, $0, S_IRWXU)
            }
            if mkdirResult != 0, errno != EEXIST {
                throw posixError()
            }

            let bodiesDescriptor = bodiesName.withCString {
                openat(
                    rootDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard bodiesDescriptor >= 0 else { throw posixError() }
            do {
                try requireDirectory(bodiesDescriptor)
                applyStoragePolicy(
                    dataProtectionClass,
                    toFileDescriptor: rootDescriptor,
                    excludesFromBackup: false
                )
                applyStoragePolicy(
                    dataProtectionClass,
                    toFileDescriptor: bodiesDescriptor,
                    excludesFromBackup: true
                )
                return AnchoredStorage(
                    rootDescriptor: rootDescriptor,
                    bodiesDescriptor: bodiesDescriptor,
                    rootURL: rootURL,
                    bodiesURL: rootURL.appendingPathComponent(bodiesName, isDirectory: true),
                    dataProtectionClass: dataProtectionClass
                )
            } catch {
                close(bodiesDescriptor)
                throw error
            }
        }

        func readIndexData() throws -> Data {
            do {
                return try readData(
                    directoryDescriptor: rootDescriptor,
                    name: "index.json"
                )
            } catch let error as FileAccessError {
                switch error {
                case .cannotOpen(let errorCode):
                    throw IndexFileAccessError.cannotOpenFile(errno: errorCode)
                case .cannotInspect(let errorCode):
                    throw IndexFileAccessError.cannotInspectFile(errno: errorCode)
                case .notRegularFile:
                    throw IndexFileAccessError.notRegularFile
                }
            }
        }

        func readRootFile(named name: String, maximumByteCount: Int? = nil) throws -> Data {
            try readData(
                directoryDescriptor: rootDescriptor,
                name: name,
                maximumByteCount: maximumByteCount
            )
        }

        func readBodyData(
            fileName: String,
            maximumByteCount: Int
        ) throws -> Data {
            do {
                return try readData(
                    directoryDescriptor: bodiesDescriptor,
                    name: fileName,
                    maximumByteCount: maximumByteCount
                )
            } catch let error as FileAccessError {
                switch error {
                case .cannotOpen(let errorCode):
                    throw BodyFileAccessError.cannotOpenFile(errno: errorCode)
                case .cannotInspect(let errorCode):
                    throw BodyFileAccessError.cannotInspectFile(errno: errorCode)
                case .notRegularFile:
                    throw BodyFileAccessError.notRegularFile
                }
            }
        }

        func inspectBody(fileName: String) throws -> Int {
            let opened: (descriptor: Int32, information: stat)
            do {
                opened = try Self.openRegularFile(
                    directoryDescriptor: bodiesDescriptor,
                    name: fileName,
                    flags: O_RDONLY
                )
            } catch let error as FileAccessError {
                switch error {
                case .cannotOpen(let errorCode):
                    throw BodyFileAccessError.cannotOpenFile(errno: errorCode)
                case .cannotInspect(let errorCode):
                    throw BodyFileAccessError.cannotInspectFile(errno: errorCode)
                case .notRegularFile:
                    throw BodyFileAccessError.notRegularFile
                }
            }
            defer { close(opened.descriptor) }
            guard
                opened.information.st_size >= 0,
                let size = Int(exactly: opened.information.st_size)
            else {
                throw BodyFileAccessError.invalidReference
            }
            return size
        }

        func writeIndex(_ data: Data, durable: Bool) throws {
            try writeAtomically(
                data,
                destinationName: "index.json",
                directoryDescriptor: rootDescriptor,
                durable: durable
            )
        }

        func writeRootFile(_ data: Data, named name: String) throws {
            try writeAtomically(
                data,
                destinationName: name,
                directoryDescriptor: rootDescriptor,
                durable: false
            )
        }

        func writeBody(_ data: Data, fileName: String) throws {
            try writeAtomically(
                data,
                destinationName: fileName,
                directoryDescriptor: bodiesDescriptor,
                durable: false
            )
        }

        @discardableResult
        func removeRootEntry(named name: String) -> Bool {
            let unlinkResult = name.withCString { unlinkat(rootDescriptor, $0, 0) }
            if unlinkResult == 0 { return true }
            guard errno == EISDIR || errno == EPERM else { return false }
            return name.withCString { unlinkat(rootDescriptor, $0, AT_REMOVEDIR) } == 0
        }

        @discardableResult
        func removeBody(fileName: String) -> Bool {
            fileName.withCString { unlinkat(bodiesDescriptor, $0, 0) } == 0
        }

        func resetBodies() throws {
            for name in try bodyEntryNames() {
                let unlinkResult = name.withCString {
                    unlinkat(bodiesDescriptor, $0, 0)
                }
                if unlinkResult != 0, errno == EISDIR || errno == EPERM {
                    _ = name.withCString {
                        unlinkat(bodiesDescriptor, $0, AT_REMOVEDIR)
                    }
                }
            }
        }

        func rootEntryInformation(named name: String) throws -> stat? {
            try Self.entryInformation(directoryDescriptor: rootDescriptor, name: name)
        }

        func bodyEntryInformation(named name: String) throws -> stat? {
            try Self.entryInformation(directoryDescriptor: bodiesDescriptor, name: name)
        }

        func bodyEntryNames() throws -> [String] {
            let duplicateDescriptor = ".".withCString {
                openat(
                    bodiesDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard duplicateDescriptor >= 0 else { throw Self.posixError() }
            guard let directory = fdopendir(duplicateDescriptor) else {
                let errorCode = errno
                close(duplicateDescriptor)
                throw Self.posixError(errorCode)
            }
            defer { closedir(directory) }

            var names: [String] = []
            while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes -> String in
                    guard let baseAddress = bytes.baseAddress else { return "" }
                    return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
                }
                if name != ".", name != ".." {
                    names.append(name)
                }
            }
            return names
        }

        func applyProtectionToExistingFiles(keyFileName: String?) {
            applyProtectionIfRegular(
                directoryDescriptor: rootDescriptor,
                name: "index.json"
            )
            if let keyFileName {
                applyProtectionIfRegular(
                    directoryDescriptor: rootDescriptor,
                    name: keyFileName
                )
            }
            guard let names = try? bodyEntryNames() else { return }
            for name in names {
                applyProtectionIfRegular(
                    directoryDescriptor: bodiesDescriptor,
                    name: name
                )
            }
        }

        func applyProtectionToRootFile(named name: String) {
            applyProtectionIfRegular(
                directoryDescriptor: rootDescriptor,
                name: name
            )
        }

        private func applyProtectionIfRegular(
            directoryDescriptor: Int32,
            name: String
        ) {
            guard
                let opened = try? Self.openRegularFile(
                    directoryDescriptor: directoryDescriptor,
                    name: name,
                    flags: O_RDONLY
                )
            else { return }
            defer { close(opened.descriptor) }
            Self.applyStoragePolicy(
                dataProtectionClass,
                toFileDescriptor: opened.descriptor,
                excludesFromBackup: true
            )
        }

        private func readData(
            directoryDescriptor: Int32,
            name: String,
            maximumByteCount: Int? = nil
        ) throws -> Data {
            let opened = try Self.openRegularFile(
                directoryDescriptor: directoryDescriptor,
                name: name,
                flags: O_RDONLY
            )
            defer { close(opened.descriptor) }
            guard lseek(opened.descriptor, 0, SEEK_SET) >= 0 else {
                throw Self.posixError()
            }

            let readLimit: Int?
            if let maximumByteCount {
                guard maximumByteCount < Int.max else {
                    throw BodyFileAccessError.invalidReference
                }
                readLimit = maximumByteCount + 1
            } else {
                readLimit = nil
            }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while readLimit.map({ result.count < $0 }) ?? true {
                let remaining = readLimit.map { $0 - result.count } ?? buffer.count
                let requestedCount = min(buffer.count, remaining)
                let count = systemRead(opened.descriptor, &buffer, requestedCount)
                if count == 0 { return result }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                result.append(contentsOf: buffer.prefix(count))
            }
            return result
        }

        private func writeAtomically(
            _ data: Data,
            destinationName: String,
            directoryDescriptor: Int32,
            durable: Bool
        ) throws {
            let temporaryName = ".\(destinationName).tmp-\(UUID().uuidString)"
            let opened = try Self.openRegularFile(
                directoryDescriptor: directoryDescriptor,
                name: temporaryName,
                flags: O_WRONLY | O_CREAT | O_EXCL
            )
            let originalDevice = opened.information.st_dev
            let originalInode = opened.information.st_ino
            var shouldCleanup = true
            defer {
                close(opened.descriptor)
                if shouldCleanup {
                    _ = temporaryName.withCString {
                        unlinkat(directoryDescriptor, $0, 0)
                    }
                }
            }

            Self.applyStoragePolicy(
                dataProtectionClass,
                toFileDescriptor: opened.descriptor,
                excludesFromBackup: true
            )
            try Self.writeAll(data, to: opened.descriptor)
            if durable, Self.syncFileDescriptor(opened.descriptor) != 0 {
                throw Self.posixError()
            }
            guard
                let currentInformation = try Self.entryInformation(
                    directoryDescriptor: directoryDescriptor,
                    name: temporaryName
                ),
                currentInformation.st_dev == originalDevice,
                currentInformation.st_ino == originalInode,
                currentInformation.st_mode & S_IFMT == S_IFREG,
                currentInformation.st_nlink == 1
            else {
                throw Self.posixError(EBUSY)
            }
            let renameResult = temporaryName.withCString { oldName in
                destinationName.withCString { newName in
                    renameat(directoryDescriptor, oldName, directoryDescriptor, newName)
                }
            }
            guard renameResult == 0 else { throw Self.posixError() }
            shouldCleanup = false
            if durable, Self.syncFileDescriptor(directoryDescriptor) != 0 {
                throw Self.posixError()
            }
        }

        private static func openRegularFile(
            directoryDescriptor: Int32,
            name: String,
            flags: Int32
        ) throws -> (descriptor: Int32, information: stat) {
            let descriptor = name.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else {
                throw FileAccessError.cannotOpen(errno: errno)
            }
            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                let errorCode = errno
                close(descriptor)
                throw FileAccessError.cannotInspect(errno: errorCode)
            }
            guard
                information.st_mode & S_IFMT == S_IFREG,
                information.st_nlink == 1
            else {
                close(descriptor)
                throw FileAccessError.notRegularFile
            }
            return (descriptor, information)
        }

        private static func entryInformation(
            directoryDescriptor: Int32,
            name: String
        ) throws -> stat? {
            var information = stat()
            let result = name.withCString {
                fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 { return information }
            if errno == ENOENT { return nil }
            throw posixError()
        }

        private static func requireDirectory(_ descriptor: Int32) throws {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else { throw posixError() }
            guard information.st_mode & S_IFMT == S_IFDIR else { throw posixError(ENOTDIR) }
        }

        private static func writeAll(_ data: Data, to descriptor: Int32) throws {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = systemWrite(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    guard count > 0 else { throw posixError(EIO) }
                    offset += count
                }
            }
        }

        private static func applyStoragePolicy(
            _ dataProtectionClass: PersistentResponseCacheConfiguration.DataProtectionClass,
            toFileDescriptor descriptor: Int32,
            excludesFromBackup: Bool
        ) {
            #if canImport(Darwin)
            if excludesFromBackup, let backupExclusionValue {
                backupExclusionValue.withUnsafeBytes { bytes in
                    _ = "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
                        fsetxattr(
                            descriptor,
                            name,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            0
                        )
                    }
                }
            }

            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            _ = fcntl(
                descriptor,
                F_SETPROTECTIONCLASS,
                dataProtectionClass.protectionClassValue
            )
            #else
            _ = dataProtectionClass
            #endif
            #else
            _ = (dataProtectionClass, descriptor, excludesFromBackup)
            #endif
        }

        @discardableResult
        private static func syncFileDescriptor(_ descriptor: Int32) -> Int32 {
            PersistentResponseCache.syncFileDescriptor(descriptor)
        }

        private static func posixError(_ code: Int32 = errno) -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        #if canImport(Darwin)
        private static let backupExclusionValue: Data? = try? PropertyListSerialization.data(
            fromPropertyList: "com.apple.backupd",
            format: .binary,
            options: 0
        )
        #endif
    }
}

private func systemOpen(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, flags)
    #elseif canImport(Glibc)
    Glibc.open(path, flags)
    #endif
}

private func systemRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.read(descriptor, buffer, count)
    #endif
}

private func systemWrite(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.write(descriptor, buffer, count)
    #endif
}

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
extension PersistentResponseCacheConfiguration.DataProtectionClass {
    fileprivate var protectionClassValue: Int32 {
        switch self {
        case .complete:
            return 1
        case .completeUnlessOpen:
            return 2
        case .completeUntilFirstUserAuthentication:
            return 3
        case .none:
            return 4
        }
    }
}
#endif
