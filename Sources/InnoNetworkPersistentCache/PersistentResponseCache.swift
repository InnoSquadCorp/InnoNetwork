import CryptoKit
import Foundation
import InnoNetwork

public struct PersistentResponseCacheConfiguration: Sendable, Equatable {
    public let directoryURL: URL
    public let maxBytes: Int
    public let maxEntries: Int
    public let maxEntryBytes: Int
    public let storesAuthenticatedResponses: Bool
    public let storesSetCookieResponses: Bool

    public init(
        directoryURL: URL,
        maxBytes: Int = 50 * 1024 * 1024,
        maxEntries: Int = 1_000,
        maxEntryBytes: Int = 5 * 1024 * 1024,
        storesAuthenticatedResponses: Bool = false,
        storesSetCookieResponses: Bool = false
    ) {
        self.directoryURL = directoryURL
        self.maxBytes = max(1, maxBytes)
        self.maxEntries = max(1, maxEntries)
        self.maxEntryBytes = max(1, maxEntryBytes)
        self.storesAuthenticatedResponses = storesAuthenticatedResponses
        self.storesSetCookieResponses = storesSetCookieResponses
    }
}

public actor PersistentResponseCache: ResponseCache {
    private static let formatVersion = 1

    private struct DiskKey: Codable, Hashable, Sendable {
        let method: String
        let url: String
        let headers: [String]

        init(_ key: ResponseCacheKey) {
            self.method = key.method
            self.url = key.url
            self.headers = key.headers
        }
    }

    private struct Index: Codable, Sendable {
        var version: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable, Sendable {
        let key: DiskKey
        let statusCode: Int
        let headers: [String: String]
        let storedAt: Date
        let requiresRevalidation: Bool
        let varyHeaders: [String: String?]?
        let bodyFileName: String
        let byteCost: Int
        var lastAccessedAt: Date
    }

    private let configuration: PersistentResponseCacheConfiguration
    private let fileManager: FileManager
    private let bodiesDirectoryURL: URL
    private let indexURL: URL
    private var index: Index

    public init(
        configuration: PersistentResponseCacheConfiguration,
        fileManager: FileManager = .default
    ) throws {
        self.configuration = configuration
        self.fileManager = fileManager
        self.bodiesDirectoryURL = configuration.directoryURL.appendingPathComponent("bodies", isDirectory: true)
        self.indexURL = configuration.directoryURL.appendingPathComponent("index.json", isDirectory: false)

        try fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
        self.index = try Self.loadIndex(
            from: indexURL,
            directoryURL: configuration.directoryURL,
            fileManager: fileManager
        )
    }

    public func get(_ key: ResponseCacheKey) async -> CachedResponse? {
        let diskKey = DiskKey(key)
        let id = Self.identifier(for: diskKey)
        guard var entry = index.entries[id] else { return nil }
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(entry.bodyFileName, isDirectory: false)

        do {
            let data = try Data(contentsOf: bodyURL)
            entry.lastAccessedAt = Date()
            index.entries[id] = entry
            try persistIndex()
            return CachedResponse(
                data: data,
                statusCode: entry.statusCode,
                headers: entry.headers,
                storedAt: entry.storedAt,
                requiresRevalidation: entry.requiresRevalidation,
                varyHeaders: entry.varyHeaders
            )
        } catch {
            removeEntry(id: id, entry: entry)
            try? persistIndex()
            return nil
        }
    }

    public func set(_ key: ResponseCacheKey, _ value: CachedResponse) async {
        guard shouldStore(key: key, response: value), value.data.count <= configuration.maxEntryBytes else {
            await invalidate(key)
            return
        }

        let diskKey = DiskKey(key)
        let id = Self.identifier(for: diskKey)
        let bodyFileName = "\(id).body"
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(bodyFileName, isDirectory: false)
        let byteCost =
            value.data.count
            + value.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        let entry = Entry(
            key: diskKey,
            statusCode: value.statusCode,
            headers: value.headers,
            storedAt: value.storedAt,
            requiresRevalidation: value.requiresRevalidation,
            varyHeaders: value.varyHeaders,
            bodyFileName: bodyFileName,
            byteCost: byteCost,
            lastAccessedAt: Date()
        )

        do {
            try value.data.write(to: bodyURL, options: .atomic)
            if let old = index.entries[id] {
                removeBody(fileName: old.bodyFileName)
            }
            index.entries[id] = entry
            evictIfNeeded()
            try persistIndex()
        } catch {
            removeBody(fileName: bodyFileName)
        }
    }

    public func invalidate(_ key: ResponseCacheKey) async {
        let id = Self.identifier(for: DiskKey(key))
        if let entry = index.entries.removeValue(forKey: id) {
            removeBody(fileName: entry.bodyFileName)
            try? persistIndex()
        }
    }

    public func removeAll() async {
        index.entries.removeAll()
        try? fileManager.removeItem(at: bodiesDirectoryURL)
        try? fileManager.createDirectory(at: bodiesDirectoryURL, withIntermediateDirectories: true)
        try? persistIndex()
    }

    private func shouldStore(key: ResponseCacheKey, response: CachedResponse) -> Bool {
        if !configuration.storesAuthenticatedResponses,
            key.headers.contains(where: { $0.lowercased().hasPrefix("authorization:") })
        {
            return false
        }

        if !configuration.storesSetCookieResponses,
            response.headers.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame })
        {
            return false
        }

        return true
    }

    private func evictIfNeeded() {
        while index.entries.count > configuration.maxEntries || totalBytes > configuration.maxBytes {
            guard let victim = index.entries.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
                return
            }
            removeEntry(id: victim.key, entry: victim.value)
        }
    }

    private var totalBytes: Int {
        index.entries.values.reduce(0) { $0 + $1.byteCost }
    }

    private func removeEntry(id: String, entry: Entry) {
        index.entries.removeValue(forKey: id)
        removeBody(fileName: entry.bodyFileName)
    }

    private func removeBody(fileName: String) {
        let bodyURL = bodiesDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: bodyURL)
    }

    private func persistIndex() throws {
        let data = try JSONEncoder.persistentCache.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private static func loadIndex(
        from indexURL: URL,
        directoryURL: URL,
        fileManager: FileManager
    ) throws -> Index {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return Index(version: formatVersion, entries: [:])
        }

        do {
            let index = try JSONDecoder.persistentCache.decode(Index.self, from: Data(contentsOf: indexURL))
            guard index.version == formatVersion else {
                try? fileManager.removeItem(at: directoryURL)
                try fileManager.createDirectory(
                    at: directoryURL.appendingPathComponent("bodies", isDirectory: true),
                    withIntermediateDirectories: true
                )
                return Index(version: formatVersion, entries: [:])
            }
            return index
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            try fileManager.createDirectory(
                at: directoryURL.appendingPathComponent("bodies", isDirectory: true),
                withIntermediateDirectories: true
            )
            return Index(version: formatVersion, entries: [:])
        }
    }

    private static func identifier(for key: DiskKey) -> String {
        let data = try? JSONEncoder.persistentCache.encode(key)
        let digest = SHA256.hash(data: data ?? Data())
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var persistentCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var persistentCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
