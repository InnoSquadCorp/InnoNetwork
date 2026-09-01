import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("chapter catalogs preserve order and follow the final JSON URL")
    func resolvesChapterCatalog() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let chapterURL = try #require(
            URL(string: "https://media.example/chapters.json")
        )
        let redirectedURL = try #require(
            URL(string: "https://cdn.example/catalog/chapters.json")
        )
        let imageURL = try #require(
            URL(string: "https://cdn.example/catalog/images/one.jpg")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.chapters",URI="chapters.json"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .redirect(statusCode: 302, location: redirectedURL),
            for: chapterURL
        )
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: Data(
                    """
                    [
                      {
                        "chapter": 1,
                        "start-time": 0,
                        "titles": [{"language":"en","title":"Opening"}],
                        "images": [{
                          "image-category":"thumbnail",
                          "pixel-width":160,
                          "pixel-height":90,
                          "url":"images/one.jpg"
                        }],
                        "metadata": [{
                          "key":"com.example.details",
                          "language":"en",
                          "value":{"featured":true,"scores":[1,2.5,null]}
                        }]
                      },
                      {
                        "chapter": 2.5,
                        "start-time": 5,
                        "duration": 3,
                        "titles": [{"language":"und","title":"2"}]
                      }
                    ]
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: redirectedURL
        )
        let observer = ChapterRequestRecorder()
        let resolver = HLSExternalResourceResolver(
            session: session,
            requestPolicy: HLSRequestPolicy(eventObservers: [observer])
        )

        let catalog = try #require(
            try await resolver.resolveChapterCatalog(in: playlist)
        )

        #expect(catalog.chapters.count == 2)
        #expect(catalog.chapters[0].chapterNumber == 1)
        #expect(catalog.chapters[0].startTime == 0)
        #expect(catalog.chapters[0].duration == 5)
        #expect(
            catalog.chapters[0].titles
                == [HLSChapterTitle(language: "en", title: "Opening")]
        )
        #expect(
            catalog.chapters[0].images
                == [
                    HLSChapterImage(
                        category: "thumbnail",
                        pixelWidth: 160,
                        pixelHeight: 90,
                        url: imageURL
                    )
                ]
        )
        #expect(
            catalog.chapters[0].metadata
                == [
                    HLSChapterMetadata(
                        key: "com.example.details",
                        language: "en",
                        value: .object([
                            "featured": .boolean(true),
                            "scores": .array([
                                .number(1), .number(2.5), .null,
                            ]),
                        ])
                    )
                ]
        )
        #expect(catalog.chapters[1].chapterNumber == 2.5)
        #expect(catalog.chapters[1].duration == 3)
        #expect(await observer.purposes() == [.chapterData])
    }

    @Test("an absent chapter declaration avoids external work")
    func absentDeclaration() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }

        let catalog = try await HLSExternalResourceResolver(
            session: session
        ).resolveChapterCatalog(in: playlist)

        #expect(catalog == nil)
        #expect(HLSURLProtocol.capturedRequests().isEmpty)
    }

    @Test("reserved chapter declarations require one remote JSON document")
    func validatesDeclaration() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.chapters",VALUE="inline"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let session = makeSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }

        await #expect(
            throws: HLSExternalResourceError.invalidChapterDeclaration
        ) {
            try await HLSExternalResourceResolver(
                session: session
            ).resolveChapterCatalog(in: playlist)
        }
        #expect(HLSURLProtocol.capturedRequests().isEmpty)
    }

    @Test("chapter schema rejects ambiguous identity and timing")
    func validatesSchema() throws {
        let documentURL = try #require(
            URL(string: "https://media.example/chapters.json")
        )
        let invalidDocuments = [
            #"[{"start-time":0,"titles":[{"language":"en","title":"One"},{"language":"EN","title":"Two"}]}]"#,
            #"[{"start-time":0,"metadata":[{"key":"id","language":"en","value":1},{"key":"id","language":"EN","value":2}]}]"#,
            #"[{"start-time":2},{"start-time":1}]"#,
            #"[{"start-time":0,"images":[{"image-category":"thumb","pixel-width":0,"pixel-height":1,"url":"one.jpg"}]}]"#,
            #"[{"start-time":0,"images":[{"image-category":"thumb","pixel-width":1,"pixel-height":1,"url":"file:///tmp/one.jpg"}]}]"#,
            #"[{"start-time":0,"images":[{"image-category":"thumb","pixel-width":1,"pixel-height":1,"url":"http://media.example/one.jpg"}]}]"#,
            #"[{"start-time":0,"metadata":[{"key":"id","value":null}]}]"#,
            #"[{"start-time":0,"titles":[{"language":"en","title":"   "}]}]"#,
        ]

        for document in invalidDocuments {
            #expect(
                throws: HLSExternalResourceError.invalidChapterData
            ) {
                try HLSChapterDecoder.decode(
                    Data(document.utf8),
                    relativeTo: documentURL,
                    maximumChapterCount: 10,
                    maximumEntryCount: 100
                )
            }
        }
    }

    @Test("chapter and nested metadata limits fail typed")
    func enforcesBoundaries() throws {
        let documentURL = try #require(
            URL(string: "https://media.example/chapters.json")
        )
        let twoChapters = Data(
            #"[{"start-time":0},{"start-time":1}]"#.utf8
        )
        #expect(
            throws: HLSExternalResourceError.tooManyChapters(limit: 1)
        ) {
            try HLSChapterDecoder.decode(
                twoChapters,
                relativeTo: documentURL,
                maximumChapterCount: 1,
                maximumEntryCount: 100
            )
        }

        let titledChapter = Data(
            #"[{"start-time":0,"titles":[{"language":"en","title":"One"}]}]"#
                .utf8
        )
        #expect(
            throws: HLSExternalResourceError.tooManyChapterEntries(limit: 1)
        ) {
            try HLSChapterDecoder.decode(
                titledChapter,
                relativeTo: documentURL,
                maximumChapterCount: 1,
                maximumEntryCount: 1
            )
        }

        let admittedNestedValue =
            String(repeating: "[", count: 16)
            + "1"
            + String(repeating: "]", count: 16)
        let admittedNestedDocument = Data(
            "[{\"start-time\":0,\"metadata\":[{\"key\":\"id\",\"value\":\(admittedNestedValue)}]}]"
                .utf8
        )
        #expect(
            try HLSChapterDecoder.decode(
                admittedNestedDocument,
                relativeTo: documentURL,
                maximumChapterCount: 1,
                maximumEntryCount: 100
            ).chapters.count == 1
        )

        let excessiveNestedValue =
            String(repeating: "[", count: 17)
            + "1"
            + String(repeating: "]", count: 17)
        let excessiveNestedDocument = Data(
            "[{\"start-time\":0,\"metadata\":[{\"key\":\"id\",\"value\":\(excessiveNestedValue)}]}]"
                .utf8
        )
        #expect(
            throws:
                HLSExternalResourceError
                .chapterMetadataDepthExceeded(limit: 16)
        ) {
            try HLSChapterDecoder.decode(
                excessiveNestedDocument,
                relativeTo: documentURL,
                maximumChapterCount: 1,
                maximumEntryCount: 100
            )
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor ChapterRequestRecorder: HLSRequestEventObserving {
    private var recordedPurposes: [HLSRequestPurpose] = []

    func hlsRequestDidEmit(_ event: HLSRequestEvent) {
        guard case .requestStarted(let context) = event else { return }
        recordedPurposes.append(context.purpose)
    }

    func purposes() -> [HLSRequestPurpose] {
        recordedPurposes
    }
}
