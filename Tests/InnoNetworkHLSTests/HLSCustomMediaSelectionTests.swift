import Foundation
import Testing

@testable import InnoNetworkHLS

extension HLSDownloaderTests {
    @Test("Custom Media Selection resolves and drives prioritized selection")
    func resolvesAndSelectsCustomMedia() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let schemeURL = try #require(
            URL(string: "https://media.example/media-selection.json")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:4
            #EXT-X-SESSION-DATA:DATA-ID="_hls.media-presentation-settings",FORMAT=JSON,URI="media-selection.json"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="english-home-tv",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",CHARACTERISTICS="example.origin.home,example.medium.tv,example.non-final"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="spanish-away-radio",AUTOSELECT=YES,LANGUAGE="es",CHARACTERISTICS="example.origin.away,example.medium.radio"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="spanish-home-tv",AUTOSELECT=YES,LANGUAGE="es",CHARACTERISTICS="example.origin.home,example.medium.tv"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let session = makeCustomMediaSession()
        defer {
            session.invalidateAndCancel()
            HLSURLProtocol.reset()
        }
        HLSURLProtocol.register(
            .success(
                statusCode: 200,
                data: customMediaSelectionJSON(),
                headers: ["Content-Type": "application/json"]
            ),
            for: schemeURL
        )
        let observer = HLSCustomMediaRequestRecorder()
        let resolver = HLSExternalResourceResolver(
            session: session,
            requestPolicy: HLSRequestPolicy(
                eventObservers: [observer]
            )
        )

        let scheme = try #require(
            try await resolver.resolveCustomMediaSelection(
                in: playlist
            )
        )
        let presentation = try #require(
            scheme.presentation(for: .audio)
        )
        #expect(presentation.offersLanguageSelection)
        #expect(presentation.selectors.map(\.identifier) == ["Origin", "Medium"])
        #expect(
            presentation.selectors[0].localizedName(
                preferredLanguages: ["en-US"]
            ) == "Broadcast origin"
        )
        #expect(
            presentation.decoratedLanguageName(
                "English",
                for: playlist.renditions[0],
                preferredDisplayLanguages: ["en"]
            ) == "English (Non-final)"
        )

        let selected = CustomMediaSelector().select(
            in: playlist,
            groupID: "audio",
            kind: .audio,
            scheme: scheme,
            preferences: HLSCustomMediaSelectionPreferences(
                preferredLanguage: "es",
                selectedCharacteristicsBySelector: [
                    "Origin": "example.origin.home",
                    "Medium": "example.medium.radio",
                ]
            )
        )
        #expect(selected?.name == "spanish-home-tv")
        #expect(
            HLSURLProtocol.capturedRequests().first?
                .value(forHTTPHeaderField: "Accept")
                == "application/json"
        )
        #expect(
            await observer.purposes()
                == [.customMediaSelectionScheme]
        )
    }

    @Test("language remains the highest custom media preference")
    func customMediaLanguageHasHighestPriority() throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="english-home-tv",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",CHARACTERISTICS="example.origin.home,example.medium.tv"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="spanish-away-radio",AUTOSELECT=YES,LANGUAGE="es",CHARACTERISTICS="example.origin.away,example.medium.radio"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
            media.m3u8
            """,
            relativeTo: masterURL
        )
        let scheme = try HLSCustomMediaSelectionDecoder.decode(
            customMediaSelectionJSON(),
            maximumEntryCount: 32
        )

        let selected = CustomMediaSelector().select(
            in: playlist,
            groupID: "audio",
            kind: .audio,
            scheme: scheme,
            preferences: HLSCustomMediaSelectionPreferences(
                preferredLanguage: "es",
                selectedCharacteristicsBySelector: [
                    "Origin": "example.origin.home",
                    "Medium": "example.medium.tv",
                ]
            )
        )

        #expect(selected?.name == "spanish-away-radio")
    }

    @Test("reserved Custom Media Selection declarations must be remote JSON")
    func rejectsInvalidCustomMediaDeclaration() async throws {
        let masterURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )
        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="_hls.media-presentation-settings",VALUE="inline"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: masterURL
        )

        await #expect(
            throws:
                HLSExternalResourceError
                .invalidCustomMediaSelectionDeclaration
        ) {
            try await HLSExternalResourceResolver()
                .resolveCustomMediaSelection(in: playlist)
        }
    }

    @Test(
        "invalid Custom Media Selection schemas are rejected",
        arguments: [
            Data(
                """
                [{"TYPE":"DATA","MEDIA-PRESENTATION-SETTINGS":[]}]
                """.utf8
            ),
            Data(
                """
                [{
                  "TYPE":"AUDIO",
                  "MEDIA-PRESENTATION-SETTINGS":[{
                    "SELECTOR":"Origin",
                    "DISPLAY-NAMES":{},
                    "SETTINGS":[]
                  }]
                }]
                """.utf8
            ),
            Data(
                """
                [{
                  "TYPE":"AUDIO",
                  "MEDIA-PRESENTATION-SETTINGS":[{
                    "SELECTOR":"Origin",
                    "DISPLAY-NAMES":{"en":"Origin"},
                    "SETTINGS":[{"CHARACTERISTIC":"example.home"}]
                  }]
                }]
                """.utf8
            ),
        ]
    )
    func rejectsInvalidCustomMediaSchemas(
        data: Data
    ) {
        #expect(
            throws:
                HLSExternalResourceError
                .invalidCustomMediaSelectionScheme
        ) {
            try HLSCustomMediaSelectionDecoder.decode(
                data,
                maximumEntryCount: 32
            )
        }
    }

    @Test("Custom Media Selection entry counts are bounded")
    func boundsCustomMediaSelectionEntries() {
        #expect(
            throws:
                HLSExternalResourceError
                .tooManyCustomMediaSelectionEntries(limit: 2)
        ) {
            try HLSCustomMediaSelectionDecoder.decode(
                customMediaSelectionJSON(),
                maximumEntryCount: 2
            )
        }
    }

    private func makeCustomMediaSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func customMediaSelectionJSON() -> Data {
        Data(
            """
            [{
              "TYPE": "AUDIO",
              "MEDIA-PRESENTATION-SETTINGS": [
                {
                  "SELECTOR": "Origin",
                  "DISPLAY-NAMES": {
                    "en": "Broadcast origin",
                    "es-419": "Origen de la transmisión"
                  },
                  "SETTINGS": [
                    {
                      "CHARACTERISTIC": "example.origin.home",
                      "DISPLAY-NAMES": {"en": "Home", "es-419": "Local"}
                    },
                    {
                      "CHARACTERISTIC": "example.origin.away",
                      "DISPLAY-NAMES": {"en": "Away", "es-419": "Visitante"}
                    }
                  ]
                },
                {
                  "SELECTOR": "Medium",
                  "DISPLAY-NAMES": {
                    "en": "Audio feed",
                    "es-419": "Fuente de audio"
                  },
                  "SETTINGS": [
                    {
                      "CHARACTERISTIC": "example.medium.tv",
                      "DISPLAY-NAMES": {"en": "Television", "es-419": "Televisión"}
                    },
                    {
                      "CHARACTERISTIC": "example.medium.radio",
                      "DISPLAY-NAMES": {"en": "Radio", "es-419": "Radio"}
                    }
                  ]
                }
              ],
              "LANGUAGE-DECORATION": [{
                "CHARACTERISTIC": "example.non-final",
                "DISPLAY-NAMES": {
                  "en": "${language} (Non-final)",
                  "es-419": "${language} (No definitivo)"
                }
              }]
            }]
            """.utf8
        )
    }
}

private actor HLSCustomMediaRequestRecorder:
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
