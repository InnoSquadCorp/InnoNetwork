import CryptoKit
import Foundation

struct HLSContentIdentity: Codable, Equatable, Sendable {
    let finalURLSHA256: String
    let playlistSHA256: String
    let entityTagSHA256: String?
    let lastModifiedSHA256: String?

    init(
        finalURL: URL,
        playlistData: Data,
        response: URLResponse?
    ) {
        self.finalURLSHA256 = HLSContentFingerprint.sha256(
            finalURL.absoluteString
        )
        self.playlistSHA256 = HLSContentFingerprint.sha256(
            playlistData
        )
        if let httpResponse = response as? HTTPURLResponse {
            self.entityTagSHA256 = Self.headerFingerprint(
                httpResponse.value(forHTTPHeaderField: "ETag")
            )
            self.lastModifiedSHA256 = Self.headerFingerprint(
                httpResponse.value(forHTTPHeaderField: "Last-Modified")
            )
        } else {
            self.entityTagSHA256 = nil
            self.lastModifiedSHA256 = nil
        }
    }

    private static func headerFingerprint(
        _ value: String?
    ) -> String? {
        guard
            let normalized = value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !normalized.isEmpty
        else {
            return nil
        }
        return HLSContentFingerprint.sha256(normalized)
    }
}

struct HLSResolvedPlaylistDocument: Sendable {
    let playlist: HLSPlaylist
    let identity: HLSContentIdentity
    let contents: String
    let dateRangeFingerprints: [String: String]
    let variables: [String: String]
}

package enum HLSContentFingerprint {
    package static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    package static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    package static func sha256(
        contentsOf url: URL
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024),
            !data.isEmpty
        {
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    private static func hex<Digest: Sequence>(
        _ digest: Digest
    ) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
