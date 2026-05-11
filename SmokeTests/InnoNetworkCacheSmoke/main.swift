import Foundation
import InnoNetwork
import InnoNetworkPersistentCache

// MARK: - InnoNetworkCacheSmoke
//
// Local-only smoke for the persistent response cache. Unlike the
// network-bound smokes, this exercise is self-contained — it constructs
// a temporary cache directory, stores a synthetic response, reads it
// back, and confirms the roundtrip preserves payload + headers.
//
// Runs unconditionally (no env flag) because it never touches the
// network. Exits 0 on success, 1 on any roundtrip mismatch.

private let workspace = FileManager.default.temporaryDirectory
    .appendingPathComponent("InnoNetworkCacheSmoke", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    try? FileManager.default.removeItem(at: workspace)
    exit(1)
}

defer { try? FileManager.default.removeItem(at: workspace) }

do {
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
} catch {
    fail("could not create workspace: \(error)")
}

let configuration = PersistentResponseCacheConfiguration(
    directoryURL: workspace,
    maxBytes: 64 * 1024 * 1024
)

let cache: PersistentResponseCache
do {
    cache = try PersistentResponseCache(configuration: configuration)
} catch {
    fail("could not construct PersistentResponseCache: \(error)")
}

let key = ResponseCacheKey(
    method: "GET",
    url: "https://api.example.com/v1/users/42",
    headers: ["Accept": "application/json"]
)
let payload = Data("{\"id\":42,\"name\":\"Smoke\"}".utf8)
let cached = CachedResponse(
    data: payload,
    statusCode: 200,
    headers: [
        "Content-Type": "application/json",
        "ETag": "\"abc123\"",
        "Cache-Control": "max-age=3600",
    ],
    storedAt: Date(),
    requiresRevalidation: false,
    varyHeaders: nil
)

print("▶︎ store      \(key.url) (\(payload.count) bytes)")
await cache.set(key, cached)

guard let roundtripped = await cache.get(key) else {
    fail("cache lookup returned nil for the just-stored key")
}

guard roundtripped.data == payload else {
    fail("cache roundtrip mutated the payload bytes")
}

guard roundtripped.statusCode == 200 else {
    fail("cache roundtrip mutated the status code: \(roundtripped.statusCode)")
}

guard roundtripped.etag == "\"abc123\"" else {
    fail("cache roundtrip dropped or mutated the ETag header")
}

print("✓ roundtrip  payload + headers preserved")

let stats = await cache.statistics()
print("   entries=\(stats.entryCount) bytes=\(stats.byteCount)")

await cache.invalidate(key)
let afterInvalidate = await cache.get(key)
guard afterInvalidate == nil else {
    fail("cache returned a stale entry after invalidate()")
}

print("✓ invalidate  lookup returns nil")
print("InnoNetworkCacheSmoke OK")
