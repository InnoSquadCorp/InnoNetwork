import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("Session Data resolves inline, JSON, and raw content")
    func resolvesExternalSessionData() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let jsonURL = try #require(
            URL(string: "https://media.example/metadata.json")
        )
        let rawURL = try #require(
            URL(string: "https://media.example/artwork.bin")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="title",VALUE="Example"
            #EXT-X-SESSION-DATA:DATA-ID="metadata",URI="metadata.json"
            #EXT-X-SESSION-DATA:DATA-ID="artwork",URI="artwork.bin",FORMAT=RAW
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let session = makeExternalResourceSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(#"{"title":"Example"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            ),
            for: jsonURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data([0x00, 0x01, 0x02]),
                headers: [
                    "Content-Type": "application/octet-stream"
                ]
            ),
            for: rawURL
        )
        let observer = HLSExternalRequestRecorder()
        let resolver = HLSExternalResourceResolver(
            session: session,
            requestPolicy: HLSRequestPolicy(
                eventObservers: [observer]
            )
        )

        #expect(
            try await resolver.resolveSessionData(
                playlist.sessionData[0]
            ) == .string("Example")
        )
        #expect(
            try await resolver.resolveSessionData(
                playlist.sessionData[1]
            ) == .json(Data(#"{"title":"Example"}"#.utf8))
        )
        #expect(
            try await resolver.resolveSessionData(
                playlist.sessionData[2]
            ) == .raw(Data([0x00, 0x01, 0x02]))
        )
        #expect(
            HLSURLProtocol.capturedRequests()
                .compactMap(\.url) == [jsonURL, rawURL]
        )
        #expect(
            HLSURLProtocol.capturedRequests().map {
                $0.value(forHTTPHeaderField: "Accept")
            } == ["application/json", "application/octet-stream"]
        )
        #expect(
            await observer.purposes() == [.sessionData, .sessionData]
        )
    }

    @Test("interstitial asset lists preserve declared order and duration")
    func resolvesInterstitialAssetList() async throws {
        let listURL = try #require(
            URL(string: "https://ads.example/list.json")
        )
        let firstURL = try #require(
            URL(string: "https://ads.example/first.m3u8")
        )
        let secondURL = try #require(
            URL(string: "https://ads.example/second.m3u8")
        )
        let session = makeExternalResourceSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {
                      "ASSETS": [
                        {"URI":"https://ads.example/first.m3u8","DURATION":6},
                        {"URI":"https://ads.example/second.m3u8","DURATION":4.5}
                      ],
                      "SKIP-CONTROL": {
                        "OFFSET": 5,
                        "DURATION": 20
                      }
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: listURL
        )
        let observer = HLSExternalRequestRecorder()
        let resolver = HLSExternalResourceResolver(
            session: session,
            requestPolicy: HLSRequestPolicy(
                eventObservers: [observer]
            )
        )

        let resolution = try await resolver.resolveInterstitial(
            HLSInterstitial(
                source: .assetList(listURL),
                skipControl: HLSInterstitialSkipControl(
                    offset: 2,
                    duration: 5,
                    labelID: "Exit_Label"
                )
            )
        )

        #expect(
            resolution.assets == [
                HLSInterstitialAsset(url: firstURL, duration: 6),
                HLSInterstitialAsset(url: secondURL, duration: 4.5),
            ]
        )
        #expect(
            resolution.skipControl
                == HLSInterstitialSkipControl(
                    offset: 5,
                    duration: 20,
                    labelID: "Exit_Label"
                )
        )
        #expect(
            await observer.purposes() == [.interstitialAssetList]
        )
    }

    @Test("direct interstitial assets require no external request")
    func resolvesDirectInterstitialAsset() async throws {
        let assetURL = try #require(
            URL(string: "https://ads.example/direct.m3u8")
        )
        let session = makeExternalResourceSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }

        let assets = try await HLSExternalResourceResolver(
            session: session
        ).resolveInterstitialAssets(
            HLSInterstitial(source: .asset(assetURL))
        )

        #expect(
            assets == [
                HLSInterstitialAsset(
                    url: assetURL,
                    duration: nil
                )
            ]
        )
        #expect(HLSURLProtocol.capturedRequests().isEmpty)
    }

    @Test("external metadata enforces JSON and byte boundaries")
    func enforcesExternalResourceBoundaries() async throws {
        let invalidJSONURL = try #require(
            URL(string: "https://media.example/invalid.json")
        )
        let largeRawURL = try #require(
            URL(string: "https://media.example/large.bin")
        )
        let session = makeExternalResourceSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data("not-json".utf8),
                headers: [:]
            ),
            for: invalidJSONURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(repeating: 0x01, count: 9),
                headers: ["Content-Length": "9"]
            ),
            for: largeRawURL
        )
        let resolver = HLSExternalResourceResolver(
            session: session,
            configuration: HLSExternalResourcePack(
                maximumSessionDataBytes: 8
            )
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .invalidSessionDataJSON
        ) {
            try await resolver.resolveSessionData(
                HLSSessionData(
                    dataID: "json",
                    language: nil,
                    content: .remote(
                        invalidJSONURL,
                        format: .json
                    ),
                    extensionAttributeNames: []
                )
            )
        }
        await #expect(
            throws:
                HLSExternalResourceError
                .responseTooLarge(limit: 8)
        ) {
            try await resolver.resolveSessionData(
                HLSSessionData(
                    dataID: "raw",
                    language: nil,
                    content: .remote(
                        largeRawURL,
                        format: .raw
                    ),
                    extensionAttributeNames: []
                )
            )
        }
    }

    @Test("interstitial asset lists enforce schema and count")
    func enforcesInterstitialAssetListBoundaries() async throws {
        let malformedURL = try #require(
            URL(string: "https://ads.example/malformed.json")
        )
        let crowdedURL = try #require(
            URL(string: "https://ads.example/crowded.json")
        )
        let session = makeExternalResourceSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    #"{"ASSETS":[{"URI":"relative.m3u8","DURATION":1}]}"#
                        .utf8
                ),
                headers: [:]
            ),
            for: malformedURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    {"ASSETS":[
                      {"URI":"https://ads.example/one.m3u8","DURATION":1},
                      {"URI":"https://ads.example/two.m3u8","DURATION":1}
                    ]}
                    """.utf8
                ),
                headers: [:]
            ),
            for: crowdedURL
        )
        let resolver = HLSExternalResourceResolver(
            session: session,
            configuration: HLSExternalResourcePack(
                maximumInterstitialAssetCount: 1
            )
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .invalidInterstitialAssetList
        ) {
            try await resolver.resolveInterstitialAssets(
                HLSInterstitial(
                    source: .assetList(malformedURL)
                )
            )
        }
        await #expect(
            throws:
                HLSExternalResourceError
                .tooManyInterstitialAssets(limit: 1)
        ) {
            try await resolver.resolveInterstitialAssets(
                HLSInterstitial(
                    source: .assetList(crowdedURL)
                )
            )
        }
    }

    @Test("external resources preserve HTTP status classification")
    func preservesExternalResourceHTTPStatus() async throws {
        let resourceURL = try #require(
            URL(string: "https://media.example/unavailable.json")
        )
        let session = makeExternalResourceSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 503,
                data: Data(),
                headers: [:]
            ),
            for: resourceURL
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .invalidResponseStatus(503)
        ) {
            try await HLSExternalResourceResolver(
                session: session
            ).resolveSessionData(
                HLSSessionData(
                    dataID: "metadata",
                    language: nil,
                    content: .remote(
                        resourceURL,
                        format: .json
                    ),
                    extensionAttributeNames: []
                )
            )
        }
    }

    @Test("external resource settings stay within conversion-safe bounds")
    func clampsExternalResourceSettings() {
        let settings = HLSExternalResourcePack(
            maximumSessionDataBytes: .max,
            maximumCustomMediaSelectionEntryCount: .max,
            maximumInterstitialAssetListBytes: .max,
            maximumInterstitialAssetCount: .max,
            maximumDateRangeResourceBytes: .max,
            maximumScheduledDateRangeCount: .max,
            maximumDateRangeScheduleDepth: .max,
            requestTimeout: .greatestFiniteMagnitude
        ).resolvedSettings

        #expect(settings.maximumSessionDataBytes == 2 * 1_024 * 1_024)
        #expect(
            settings.maximumCustomMediaSelectionEntryCount
                == 1_000
        )
        #expect(
            settings.maximumInterstitialAssetListBytes
                == 2 * 1_024 * 1_024
        )
        #expect(settings.maximumInterstitialAssetCount == 1_000)
        #expect(
            settings.maximumDateRangeResourceBytes
                == 2 * 1_024 * 1_024
        )
        #expect(settings.maximumScheduledDateRangeCount == 1_000)
        #expect(settings.maximumDateRangeScheduleDepth == 3)
        #expect(settings.requestTimeout == 300)
    }

    private func makeExternalResourceSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor HLSExternalRequestRecorder: HLSRequestEventObserving {
    private var recordedPurposes: [HLSRequestPurpose] = []

    func hlsRequestDidEmit(_ event: HLSRequestEvent) {
        guard case .requestStarted(let context) = event else {
            return
        }
        recordedPurposes.append(context.purpose)
    }

    func purposes() -> [HLSRequestPurpose] {
        recordedPurposes
    }
}
