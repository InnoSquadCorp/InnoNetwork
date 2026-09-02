import Foundation
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("localized rendition names resolve with HLS fallback semantics")
    func resolvesLocalizedRenditionNames() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let namesURL = try #require(
            URL(string: "https://media.example/rendition-names.json")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="_hls.localized-rendition-names",URI="rendition-names.json"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="en.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Director's commentary",LANGUAGE="en",URI="commentary.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        let session = URLSession(configuration: configuration)
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
                      "Director's commentary": {
                        "en": "Director's commentary",
                        "de": "Kommentar des Regisseurs"
                      }
                    }
                    """.utf8
                ),
                headers: ["Content-Type": "application/json"]
            ),
            for: namesURL
        )
        let observer = HLSLocalizedRenditionNameRequestRecorder()
        let resolver = HLSExternalResourceResolver(
            session: session,
            requestPolicy: HLSRequestPolicy(
                eventObservers: [observer]
            )
        )

        let catalog = try #require(
            try await resolver.resolveLocalizedRenditionNames(
                in: playlist
            )
        )
        let primary = try #require(
            playlist.renditions.first { $0.name == "English" }
        )
        let commentary = try #require(
            playlist.renditions.first {
                $0.name == "Director's commentary"
            }
        )

        #expect(catalog.availableLanguages == ["de", "en"])
        #expect(
            catalog.localizedName(
                for: commentary,
                preferredLanguages: ["de-DE"]
            ) == "Kommentar des Regisseurs"
        )
        #expect(
            catalog.localizedName(
                for: commentary,
                preferredLanguages: ["fr"]
            ) == commentary.name
        )
        #expect(
            catalog.localizedName(
                for: primary,
                preferredLanguages: ["de"]
            ) == primary.name
        )
        #expect(
            await observer.purposes()
                == [.localizedRenditionNames]
        )
        #expect(
            HLSURLProtocol.capturedRequests().first?
                .value(forHTTPHeaderField: "Accept")
                == "application/json"
        )
    }

    @Test("localized rendition-name declaration remains explicit")
    func validatesLocalizedRenditionNameDeclaration() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let resolver = HLSExternalResourceResolver()
        let absent = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let inline = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="_hls.localized-rendition-names",VALUE="{}"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: masterURL
        )

        #expect(
            try await resolver.resolveLocalizedRenditionNames(
                in: absent
            ) == nil
        )
        await #expect(
            throws: HLSExternalResourceError
                .invalidLocalizedRenditionNameDeclaration
        ) {
            try await resolver.resolveLocalizedRenditionNames(
                in: inline
            )
        }
    }

    @Test("localized rendition-name schema and entries are bounded")
    func validatesLocalizedRenditionNameSchema() throws {
        for data in [
            Data("{}".utf8),
            Data(#"{"Commentary":{"en-US":"Commentary"}}"#.utf8),
            Data(#"{"Commentary":{"en":" "}}"#.utf8),
            Data(#"{"Commentary":{"en":"One","EN":"Two"}}"#.utf8),
        ] {
            #expect(
                throws: HLSExternalResourceError
                    .invalidLocalizedRenditionNames
            ) {
                try HLSLocalizedRenditionNameDecoder.decode(
                    data,
                    maximumEntryCount: 10
                )
            }
        }

        #expect(
            throws:
                HLSExternalResourceError
                .tooManyLocalizedRenditionNameEntries(limit: 2)
        ) {
            try HLSLocalizedRenditionNameDecoder.decode(
                Data(
                    #"{"Commentary":{"en":"One","de":"Two"}}"#.utf8
                ),
                maximumEntryCount: 2
            )
        }
    }
}

private actor HLSLocalizedRenditionNameRequestRecorder:
    HLSRequestEventObserving
{
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
