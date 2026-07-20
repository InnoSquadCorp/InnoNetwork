import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkPersistentCache

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Security)
import Security
#endif


@Suite("Persistent Response Cache Tests")
struct PersistentResponseCacheTests {
    static let authenticatedCacheHeaders = ["Cache-Control": "public, max-age=60"]

    func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-persistent-cache-\(UUID().uuidString)", isDirectory: true)
    }

    func existingBodyURLs(in directory: URL) throws -> [URL] {
        let bodiesURL = directory.appendingPathComponent("bodies", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: bodiesURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "body" }
        .sorted { $0.path < $1.path }
    }

    func bodySnapshots(in directory: URL) throws -> [String: Data] {
        try Dictionary(
            uniqueKeysWithValues: existingBodyURLs(in: directory).map { url in
                (url.lastPathComponent, try Data(contentsOf: url))
            }
        )
    }

    func indexEntryCount(in directory: URL) throws -> Int {
        let index = try indexObject(in: directory)
        guard let entries = index["entries"] as? [String: Any] else {
            throw testFixtureError("Missing persistent cache index entries")
        }
        return entries.count
    }

    func rewriteFirstIndexEntryHeaders(in directory: URL, headers: [String: String]) throws {
        var index = try indexObject(in: directory)
        guard var entries = index["entries"] as? [String: Any],
            let entryID = entries.keys.sorted().first,
            var entry = entries[entryID] as? [String: Any]
        else {
            throw testFixtureError("Missing persistent cache entry to rewrite")
        }

        entry["headers"] = headers
        entries[entryID] = entry
        index["entries"] = entries

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL, options: .atomic)
    }

    func rewriteFirstIndexEntryBodyFileName(
        in directory: URL,
        bodyFileName: String
    ) throws {
        var index = try indexObject(in: directory)
        guard var entries = index["entries"] as? [String: Any],
            let entryID = entries.keys.sorted().first,
            var entry = entries[entryID] as? [String: Any]
        else {
            throw testFixtureError("Missing persistent cache entry to rewrite")
        }

        entry["bodyFileName"] = bodyFileName
        entries[entryID] = entry
        index["entries"] = entries

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL, options: .atomic)
    }

    func rewriteIndexEntryAccessTime(
        in directory: URL,
        url: String,
        lastAccessedAt: String
    ) throws {
        var index = try indexObject(in: directory)
        guard var entries = index["entries"] as? [String: Any] else {
            throw testFixtureError("Missing persistent cache index entries")
        }
        guard
            let entryID = entries.first(where: { _, value in
                guard let entry = value as? [String: Any],
                    let key = entry["key"] as? [String: Any],
                    let entryURL = key["url"] as? String
                else {
                    return false
                }
                return entryURL == url
            })?.key,
            var entry = entries[entryID] as? [String: Any]
        else {
            throw testFixtureError("Missing persistent cache entry for \(url)")
        }

        entry["lastAccessedAt"] = lastAccessedAt
        entries[entryID] = entry
        index["entries"] = entries

        let indexURL = directory.appendingPathComponent("index.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try data.write(to: indexURL, options: .atomic)
    }

    func indexObject(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: indexURL(in: directory))
        guard let index = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw testFixtureError("Persistent cache index is not a JSON object")
        }
        return index
    }

    func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json", isDirectory: false)
    }

    func hmacKeyURL(in directory: URL) -> URL {
        directory.appendingPathComponent("cache-key-hmac.key", isDirectory: false)
    }

    func backupExclusionIsApplied(to url: URL) throws -> Bool {
        #if os(macOS)
        // Foundation writes the standard backup-exclusion xattr on macOS but
        // `resourceValues` reports `false` because the key is iOS-oriented.
        // Query the xattr directly because `attributesOfItem` can briefly
        // return a stale extended-attribute dictionary after `removexattr`.
        let result: (length: Int, errorCode: Int32) = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return (-1, EINVAL) }
            return "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
                let length = getxattr(path, name, nil, 0, 0, 0)
                return (length, length < 0 ? errno : 0)
            }
        }
        if result.length >= 0 {
            return true
        }
        if result.errorCode == ENOATTR {
            return false
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.errorCode))
        #else
        return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        #endif
    }

    func removeBackupExclusion(from url: URL) throws {
        #if os(macOS)
        // Foundation's metadata write can settle just after `setResourceValues`
        // returns on a contended hosted runner. Establish a stable absent
        // precondition instead of racing that write with a single removexattr.
        var consecutiveAbsentObservations = 0
        for attempt in 0..<10 {
            let result: (status: Int32, errorCode: Int32) = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return (-1, EINVAL) }
                return "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
                    let status = removexattr(path, name, 0)
                    return (status, status == 0 ? 0 : errno)
                }
            }
            if result.status != 0, result.errorCode != ENOATTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.errorCode))
            }
            if try backupExclusionIsApplied(to: url) == false {
                consecutiveAbsentObservations += 1
                if consecutiveAbsentObservations == 2 {
                    return
                }
            } else {
                consecutiveAbsentObservations = 0
            }
            if attempt < 9 {
                usleep(5_000)
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        #else
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try resourceURL.setResourceValues(values)
        #endif
    }

    func createHardLink(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return link(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func testFixtureError(_ message: String) -> NSError {
        NSError(domain: "PersistentResponseCacheTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#if canImport(Security)
final class StubPersistentCacheKeychain {
    private let copyStatus: OSStatus
    private let copiedData: Data?
    private let deleteStatus: OSStatus
    private let addStatus: OSStatus

    private(set) var copyCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var addCallCount = 0
    private(set) var addedKeyData: Data?

    init(
        copyStatus: OSStatus,
        copiedData: Data? = nil,
        deleteStatus: OSStatus = errSecSuccess,
        addStatus: OSStatus = errSecSuccess
    ) {
        self.copyStatus = copyStatus
        self.copiedData = copiedData
        self.deleteStatus = deleteStatus
        self.addStatus = addStatus
    }

    var operations: PersistentCacheKeychainOperations {
        PersistentCacheKeychainOperations(
            copyMatching: { _ in
                self.copyCallCount += 1
                return (self.copyStatus, self.copiedData)
            },
            delete: { _ in
                self.deleteCallCount += 1
                return self.deleteStatus
            },
            add: { attributes in
                self.addCallCount += 1
                self.addedKeyData = attributes[kSecValueData as String] as? Data
                return self.addStatus
            }
        )
    }
}
#endif

final class PersistentCacheProtectionWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [String: [FileProtectionType]] = [:]

    func record(_ protectionType: FileProtectionType, path: String) {
        lock.lock()
        writes[path, default: []].append(protectionType)
        lock.unlock()
    }

    func protectionWrites(for path: String) -> [FileProtectionType] {
        lock.lock()
        let pathWrites = writes[path] ?? []
        lock.unlock()
        return pathWrites
    }
}

final class PersistentCacheMaintenanceFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [PersistentResponseCache.MaintenanceOperation] = []

    func record(_ operation: PersistentResponseCache.MaintenanceOperation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }

    func snapshot() -> [PersistentResponseCache.MaintenanceOperation] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }
}

final class PersistentCacheRecordingFileManager: FileManager, @unchecked Sendable {
    private let recorder: PersistentCacheProtectionWriteRecorder

    init(recorder: PersistentCacheProtectionWriteRecorder) {
        self.recorder = recorder
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if let protectionType = attributes[.protectionKey] as? FileProtectionType {
            recorder.record(protectionType, path: path)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

actor TransientPersistentCacheBodyReader {
    private(set) var attemptCount = 0

    func read(
        fileName: String,
        in directoryURL: URL,
        maximumByteCount: Int
    ) async throws -> Data {
        attemptCount += 1
        if attemptCount == 1 {
            throw PersistentResponseCache.BodyFileAccessError.cannotOpenFile(errno: EACCES)
        }
        return try await PersistentResponseCache.readBodyData(
            fileName: fileName,
            in: directoryURL,
            maximumByteCount: maximumByteCount
        )
    }
}

struct PersistentCacheUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

actor FailingPersistentCacheURLSessionState {
    private var count = 0

    func record() {
        count += 1
    }

    var requestCount: Int { count }
}

final class FailingPersistentCacheURLSession: URLSessionProtocol, Sendable {
    private let state = FailingPersistentCacheURLSessionState()

    var requestCount: Int {
        get async { await state.requestCount }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        await state.record()
        throw NetworkError.configuration(reason: .invalidRequest("persistent cache test should not hit transport"))
    }
}
