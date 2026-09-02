import Foundation
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("entry playlist adaptation is typed and observation is redacted")
    func adaptsEntryPlaylistWithRedactedEvents() async throws {
        let playlistURL = try #require(
            URL(
                string:
                    "https://media.example/entry.m3u8?token=secret"
            )
        )
        let session = makeRequestPolicySession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: playlistURL
        )
        let recorder = HLSRequestEventRecorder()
        let policy = HLSRequestPolicy(
            eventObservers: [recorder]
        ) { request, context in
            var request = request
            if context.purpose == .entryPlaylist {
                request.setValue(
                    "entry",
                    forHTTPHeaderField: "X-HLS-Purpose"
                )
            }
            return request
        }

        let playlist = try await PlaylistResolver(
            session: session,
            requestPolicy: policy
        ).resolve(from: playlistURL)

        #expect(playlist.kind == .media)
        let request = try #require(
            HLSURLProtocol.capturedRequests().first
        )
        #expect(
            request.value(forHTTPHeaderField: "X-HLS-Purpose")
                == "entry"
        )
        let events = await recorder.events()
        #expect(events.count == 2)
        guard
            case .requestStarted(let startedContext) = events[0],
            case .responseReceived(
                let responseContext,
                statusCode: 200
            ) = events[1]
        else {
            Issue.record("Expected a typed start and response event.")
            return
        }
        #expect(startedContext == responseContext)
        #expect(startedContext.purpose == .entryPlaylist)
        #expect(startedContext.resourceIndex == nil)
        #expect(startedContext.retryIndex == 0)

        let diagnostic = String(reflecting: events)
        #expect(!diagnostic.contains("https://"))
        #expect(!diagnostic.contains("secret"))
    }

    @Test("adapter failures expose only stable redacted classification")
    func redactsAdapterFailures() async throws {
        let playlistURL = try #require(
            URL(string: "https://media.example/entry.m3u8?token=secret")
        )
        let session = makeRequestPolicySession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        let recorder = HLSRequestEventRecorder()
        let policy = HLSRequestPolicy(
            eventObservers: [recorder]
        ) { _, _ in
            throw SecretAdapterError(
                message: "Bearer private-token-value"
            )
        }

        await #expect(throws: SecretAdapterError.self) {
            try await PlaylistResolver(
                session: session,
                requestPolicy: policy
            ).resolve(from: playlistURL)
        }

        let events = await recorder.events()
        #expect(events.count == 2)
        guard
            case .requestFailed(
                let context,
                failure: .adaptation
            ) = events.last
        else {
            Issue.record("Expected a redacted adaptation failure.")
            return
        }
        #expect(context.purpose == .entryPlaylist)
        let diagnostic = String(reflecting: events)
        #expect(!diagnostic.contains("private-token-value"))
        #expect(!diagnostic.contains("token=secret"))
        #expect(HLSURLProtocol.capturedRequests().isEmpty)
    }

    @Test("steering and selected playlist requests keep distinct purposes")
    func distinguishesSteeringAndMediaPlaylists() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let steeringURL = try #require(
            URL(string: "https://steering.example/manifest.json")
        )
        let mediaURL = try #require(
            URL(string: "https://media.example/media.m3u8")
        )
        let session = makeRequestPolicySession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-CONTENT-STEERING:SERVER-URI="\(steeringURL.absoluteString)",PATHWAY-ID="A"
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,PATHWAY-ID="A"
                    media.m3u8

                    """.utf8
                ),
                headers: [:]
            ),
            for: masterURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "VERSION": 1,
                      "TTL": 30,
                      "PATHWAY-PRIORITY": ["A"]
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: steeringURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    #EXTM3U
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST

                    """.utf8
                ),
                headers: [:]
            ),
            for: mediaURL
        )
        let recorder = HLSRequestEventRecorder()

        let preparation = try await HLSDownloader(
            session: session,
            requestPolicy: HLSRequestPolicy(
                eventObservers: [recorder]
            )
        ).prepare(sourceURL: masterURL)

        #expect(preparation.mediaPlaylistURL == mediaURL)
        let purposes = await recorder.startedContexts().map(\.purpose)
        #expect(
            purposes
                == [
                    .entryPlaylist,
                    .contentSteeringManifest,
                    .mediaPlaylist,
                ]
        )
    }

    private func makeRequestPolicySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

actor HLSRequestEventRecorder: HLSRequestEventObserving {
    private var recordedEvents: [HLSRequestEvent] = []

    func hlsRequestDidEmit(_ event: HLSRequestEvent) {
        recordedEvents.append(event)
    }

    func events() -> [HLSRequestEvent] {
        recordedEvents
    }

    func startedContexts() -> [HLSRequestContext] {
        recordedEvents.compactMap { event in
            guard case .requestStarted(let context) = event else {
                return nil
            }
            return context
        }
    }
}

private struct SecretAdapterError: Error {
    let message: String
}
