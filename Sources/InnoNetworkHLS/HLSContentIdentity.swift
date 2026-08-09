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
    let variables: [String: String]
}

enum HLSContentFingerprint {
    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
