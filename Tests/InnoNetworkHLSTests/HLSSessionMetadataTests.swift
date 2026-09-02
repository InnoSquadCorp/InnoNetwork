import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS session metadata")
struct HLSSessionMetadataTests {
    @Test("session data and keys are typed without loading key bytes")
    func parsesSessionMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/path/master.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:5
            #EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="Example",LANGUAGE="en",X-CATEGORY="display"
            #EXT-X-SESSION-DATA:DATA-ID="com.example.title",URI="../ko.json",LANGUAGE="ko"
            #EXT-X-SESSION-DATA:DATA-ID="com.example.artwork",URI="artwork.bin",FORMAT=RAW
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="keys/main.bin",IV=0x1,X-KEY-ID="main"
            #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://license.example/content",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1/2"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(playlist.sessionData.count == 3)
        #expect(playlist.sessionData[0].dataID == "com.example.title")
        #expect(playlist.sessionData[0].language == "en")
        #expect(
            playlist.sessionData[0].content
                == .value("Example")
        )
        #expect(
            playlist.sessionData[0].extensionAttributeNames
                == ["X-CATEGORY"]
        )
        #expect(
            playlist.sessionData[1].content
                == .remote(
                    try #require(
                        URL(string: "https://media.example/ko.json")
                    ),
                    format: .json
                )
        )
        #expect(
            playlist.sessionData[2].content
                == .remote(
                    try #require(
                        URL(
                            string:
                                "https://media.example/path/artwork.bin"
                        )
                    ),
                    format: .raw
                )
        )

        #expect(playlist.sessionKeys.count == 2)
        #expect(playlist.sessionKeys[0].method == "AES-128")
        #expect(playlist.sessionKeys[0].isIdentityFormat)
        #expect(
            playlist.sessionKeys[0].initializationVector?.count == 16
        )
        #expect(
            playlist.sessionKeys[0].extensionAttributeNames
                == ["X-KEY-ID"]
        )
        #expect(
            playlist.sessionKeys[1].keyFormat
                == "com.apple.streamingkeydelivery"
        )
        #expect(
            playlist.sessionKeys[1].keyFormatVersions == [1, 2]
        )
        #expect(!playlist.sessionKeys[1].isIdentityFormat)
    }

    @Test("distinct URI attribute values remain distinct session keys")
    func distinctSessionKeyURIsAreAllowed() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let playlist = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="one.bin"
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="./one.bin"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(playlist.sessionKeys.count == 2)
        #expect(playlist.sessionKeys[0].url == playlist.sessionKeys[1].url)
    }

    @Test("session metadata diagnostics remain value redacted")
    func sessionDiagnosticsAreValueRedacted() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-VERSION:5
            #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://license.example/content?token=secret",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(inspection.isValid)
        #expect(inspection.diagnostics.isEmpty)
        let diagnostic = String(reflecting: inspection.diagnostics)
        #expect(!diagnostic.contains("license.example"))
        #expect(!diagnostic.contains("secret"))
    }

    @Test(
        "invalid session metadata is rejected",
        arguments: [
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="id",VALUE="one",URI="two.json"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="id"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID=id,VALUE="one"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="id",VALUE="one",LANGUAGE="en"
            #EXT-X-SESSION-DATA:DATA-ID="id",VALUE="two",LANGUAGE="en"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-KEY:METHOD=NONE,URI="key.bin"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-KEY:METHOD="AES-128",URI="key.bin"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="one.bin"
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="one.bin"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:2
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="key.bin",IV=0x100000000000000000000000000000000
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:2
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="key.bin",IV="0x00000000000000000000000000000001"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:5
            #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="key.bin",KEYFORMAT="format",KEYFORMATVERSIONS="1/0"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:5
            #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="key.bin",KEYFORMAT="format",KEYFORMATVERSIONS="1/x"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="id",VALUE="one"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="id",URI="value.json",FORMAT="JSON"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="id",URI="value.json",FORMAT=XML
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="key.bin",KEYFORMAT="format"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:1
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="key.bin",IV=0x1
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:2
            #EXT-X-SESSION-KEY:METHOD=AES-256-GCM,URI="key.bin",IV=0x1
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
        ]
    )
    func rejectsInvalidSessionMetadata(
        source: String
    ) throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                source,
                relativeTo: sourceURL
            )
        }
    }

    @Test("missing session attributes have line-addressable findings")
    func missingSessionAttributesAreStructured() throws {
        let sourceURL = try #require(
            URL(string: "https://media.example/master.m3u8")
        )

        let inspection = PlaylistResolver().inspect(
            """
            #EXTM3U
            #EXT-X-SESSION-DATA:VALUE="one"
            #EXT-X-SESSION-KEY:METHOD=AES-128
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            media.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(!inspection.isValid)
        #expect(
            inspection.diagnostics.contains {
                $0.code == .missingRequiredAttribute
                    && $0.lineNumber == 2
            }
        )
        #expect(
            inspection.diagnostics.contains {
                $0.code == .missingRequiredAttribute
                    && $0.lineNumber == 3
            }
        )
    }
}
