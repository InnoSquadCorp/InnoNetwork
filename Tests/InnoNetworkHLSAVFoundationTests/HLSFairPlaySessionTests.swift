#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS FairPlay session", .serialized)
@MainActor
struct HLSFairPlaySessionTests {
    @Test("session validates, attaches, and detaches protected assets")
    func attachmentLifecycle() throws {
        let session = try HLSFairPlaySession(
            delegate: ContentKeyDelegate(),
            delegateQueue: DispatchQueue(
                label: "com.innonetwork.tests.fairplay"
            )
        )
        let sourceURL = try #require(
            URL(string: "https://media.example/protected.m3u8")
        )

        let asset = try session.makeAsset(sourceURL: sourceURL)

        #expect(asset.url == sourceURL)
        #expect(
            session.contentKeySession.keySystem
                == .fairPlayStreaming
        )
        #expect(
            session.contentKeySession.contentKeyRecipients
                .contains { recipient in
                    (recipient as AnyObject) === asset
                }
        )

        try session.detach(asset)
        #expect(
            !session.contentKeySession.contentKeyRecipients
                .contains { recipient in
                    (recipient as AnyObject) === asset
                }
        )
        #expect(throws: HLSFairPlaySessionError.foreignAsset) {
            try session.detach(asset)
        }
        session.expire()
    }

    @Test("session rejects unsafe sources and post-expiration assets")
    func admissionAndExpiration() throws {
        let session = try HLSFairPlaySession(
            delegate: ContentKeyDelegate(),
            delegateQueue: DispatchQueue(
                label: "com.innonetwork.tests.fairplay.admission"
            )
        )
        #expect(throws: HLSFairPlaySessionError.insecureSourceURL) {
            try session.makeAsset(
                sourceURL: #require(
                    URL(string: "http://media.example/protected.m3u8")
                )
            )
        }
        #expect(throws: HLSFairPlaySessionError.invalidSourceURL) {
            try session.makeAsset(
                sourceURL: #require(
                    URL(
                        string:
                            "https://user:password@media.example/protected.m3u8"
                    )
                )
            )
        }

        session.expire()
        session.expire()
        #expect(throws: HLSFairPlaySessionError.sessionExpired) {
            try session.makeAsset(
                sourceURL: #require(
                    URL(string: "https://media.example/protected.m3u8")
                )
            )
        }
    }

    @Test("expired-session report storage rejects symlinks")
    func storageAdmission() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InnoNetworkHLSFairPlayTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let target = root.appendingPathComponent(
            "target",
            isDirectory: true
        )
        let link = root.appendingPathComponent(
            "link",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        #expect(
            throws:
                HLSFairPlaySessionError
                .invalidStorageDirectory
        ) {
            try HLSFairPlaySession(
                delegate: ContentKeyDelegate(),
                delegateQueue: DispatchQueue(
                    label:
                        "com.innonetwork.tests.fairplay.storage"
                ),
                storageDirectoryURL: link
            )
        }
    }

    @Test("FairPlay failures have actionable diagnostics")
    func diagnostics() {
        let error = HLSFairPlaySessionError.sessionExpired
        #expect(!error.localizedDescription.isEmpty)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }

    @MainActor
    @Test("stored movpkg assets attach before offline playback")
    func attachesStoredAsset() throws {
        let delegate = ContentKeyDelegate()
        let session = try HLSFairPlaySession(
            delegate: delegate,
            delegateQueue: DispatchQueue(
                label: "com.innonetwork.tests.fairplay.offline"
            )
        )
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("movpkg")
        let storedAsset = try HLSStoredAsset(
            id: "stored-fairplay-asset",
            location: location
        )

        let asset = try session.makeAsset(storedAsset: storedAsset)

        #expect(asset.url == location.standardizedFileURL)
        try session.detach(asset)
    }
}

private final class ContentKeyDelegate:
    NSObject,
    AVContentKeySessionDelegate,
    @unchecked Sendable
{
    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVContentKeyRequest
    ) {}
}
#endif
