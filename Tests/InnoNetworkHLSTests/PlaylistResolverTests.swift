import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS playlist resolution")
struct PlaylistResolverTests {
    @Test("playlist variables resolve URI, quoted, and hexadecimal values")
    func resolvesPlaylistVariables() throws {
        let masterURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        let master = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:NAME="directory",VALUE="video"
            #EXT-X-DEFINE:NAME="codec",VALUE="avc1.4d401f"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="{$directory}/subs.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="{$codec}",SUBTITLES="subs"
            {$directory}/index.m3u8
            """,
            relativeTo: masterURL
        )

        #expect(
            master.variants.first?.url.absoluteString
                == "https://cdn.example/media/video/index.m3u8"
        )
        #expect(master.variants.first?.codecs == ["avc1.4d401f"])
        #expect(
            master.renditions.first?.url?.absoluteString
                == "https://cdn.example/media/video/subs.m3u8"
        )

        let mediaURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let media = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:NAME="key",VALUE="keys/content.key"
            #EXT-X-DEFINE:NAME="iv",VALUE="0x1"
            #EXT-X-KEY:METHOD=AES-128,URI="{$key}",IV={$iv}
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: mediaURL
        )

        #expect(
            media.media?.resources.first?.encryption?.keyURL.absoluteString
                == "https://cdn.example/media/keys/content.key"
        )
        #expect(
            media.media?.resources.first?.encryption?
                .initializationVector.last == 1
        )
    }

    @Test("query variables use decoded values and require protocol version 11")
    func resolvesQueryParameterVariables() throws {
        let sourceURL = try #require(
            URL(
                string:
                    "https://cdn.example/index.m3u8?token=signed%2Fvalue"
            )
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:11
            #EXT-X-DEFINE:QUERYPARAM="token"
            #EXTINF:1,
            segment.ts?token={$token}
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(
            result.media?.resources.first?.url.absoluteString
                == "https://cdn.example/segment.ts?token=signed/value"
        )
        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-VERSION:10
                #EXT-X-DEFINE:QUERYPARAM="token"
                #EXTINF:1,
                segment.ts?token={$token}
                #EXT-X-ENDLIST
                """,
                relativeTo: sourceURL
            )
        }
    }

    @Test("invalid variable declarations and references are rejected")
    func rejectsInvalidPlaylistVariables() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/index.m3u8")
        )
        let invalidPlaylists = [
            """
            #EXTM3U
            #EXT-X-DEFINE:NAME="versioned",VALUE="segment"
            #EXTINF:1,
            {$versioned}.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:NAME="duplicate",VALUE="one"
            #EXT-X-DEFINE:NAME="duplicate",VALUE="two"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:NAME="missing-value"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:IMPORT="parent"
            #EXTINF:1,
            {$parent}.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXTINF:1,
            {$later}.ts
            #EXT-X-DEFINE:NAME="later",VALUE="segment"
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-VERSION:8
            #EXT-X-DEFINE:NAME="bad name",VALUE="segment"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
        ]

        for playlist in invalidPlaylists {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    playlist,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("expanded playlists remain bounded and omit definitions")
    func boundsVariableExpansion() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/index.m3u8?token=secret")
        )
        let expansion = try HLSVariableSubstituter.expand(
            """
            #EXTM3U
            #EXT-X-VERSION:11
            #EXT-X-DEFINE:QUERYPARAM="token"
            #EXTINF:1,
            segment.ts?token={$token}
            #EXT-X-ENDLIST
            """,
            sourceURL: sourceURL,
            multivariantVariables: nil,
            maximumBytes: 1_024
        )
        #expect(!expansion.contents.contains("EXT-X-DEFINE"))
        #expect(expansion.contents.contains("token=secret"))

        #expect(throws: HLSDownloadError.self) {
            try HLSVariableSubstituter.expand(
                """
                #EXTM3U
                #EXT-X-VERSION:8
                #EXT-X-DEFINE:NAME="large",VALUE="1234567890"
                #EXTINF:1,
                {$large}{$large}{$large}.ts
                #EXT-X-ENDLIST
                """,
                sourceURL: sourceURL,
                multivariantVariables: nil,
                maximumBytes: 32
            )
        }
    }

    @Test("multivariant playlist resolves relative URLs and attributes")
    func resolvesMultivariantPlaylist() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="Stereo",DEFAULT=YES,AUTOSELECT=YES
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="한국어",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subs/ko.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=900000,AVERAGE-BANDWIDTH=800000,RESOLUTION=854x480,CODECS="avc1.4d401f,mp4a.40.2",FRAME-RATE=29.97,VIDEO-RANGE=PQ,AUDIO="stereo",SUBTITLES="subs"
            480/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=4200000,AVERAGE-BANDWIDTH=3900000,RESOLUTION=1920x1080
            /1080/index.m3u8
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(result.kind == .multivariant)
        #expect(result.variants.count == 2)
        #expect(
            result.variants[0].url.absoluteString
                == "https://cdn.example/media/480/index.m3u8"
        )
        #expect(result.variants[0].averageBandwidth == 800_000)
        #expect(result.variants[0].width == 854)
        #expect(result.variants[0].height == 480)
        #expect(result.variants[0].audioGroupID == "stereo")
        #expect(result.variants[0].subtitleGroupID == "subs")
        #expect(result.variants[0].codecs == ["avc1.4d401f", "mp4a.40.2"])
        #expect(result.variants[0].frameRate == 29.97)
        #expect(result.variants[0].videoRange == "PQ")
        #expect(result.renditions.count == 2)
        #expect(result.renditions[0].kind == .audio)
        #expect(result.renditions[0].url == nil)
        #expect(result.renditions[1].kind == .subtitles)
        #expect(result.renditions[1].language == "ko")
        #expect(
            result.renditions[1].url?.absoluteString
                == "https://cdn.example/media/subs/ko.m3u8"
        )
        #expect(
            result.variants[1].url.absoluteString
                == "https://cdn.example/1080/index.m3u8"
        )
    }

    @Test("I-frame variants are parsed separately for trick play")
    func resolvesIFrameVariants() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="angles",NAME="Main",URI="video/main.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=4000000,VIDEO="angles"
            primary/index.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=240000,AVERAGE-BANDWIDTH=200000,SCORE=4.5,RESOLUTION=1920x1080,CODECS="avc1.640028",SUPPLEMENTAL-CODECS="dvh1.08.07/db4h",VIDEO-RANGE=PQ,VIDEO="angles",STABLE-VARIANT-ID="iframe.main",PATHWAY-ID="CDN-A",URI="trick/index.m3u8"
            """,
            relativeTo: sourceURL
        )

        let variant = try #require(result.iFrameVariants.first)
        #expect(result.kind == .multivariant)
        #expect(result.iFrameVariants.count == 1)
        #expect(
            variant.url.absoluteString
                == "https://cdn.example/media/trick/index.m3u8"
        )
        #expect(variant.bandwidth == 240_000)
        #expect(variant.averageBandwidth == 200_000)
        #expect(variant.score == 4.5)
        #expect(variant.width == 1_920)
        #expect(variant.height == 1_080)
        #expect(variant.videoGroupID == "angles")
        #expect(variant.codecs == ["avc1.640028"])
        #expect(variant.supplementalCodecs == ["dvh1.08.07/db4h"])
        #expect(variant.frameRate == nil)
        #expect(variant.videoRange == "PQ")
        #expect(variant.stableID == "iframe.main")
        #expect(variant.pathwayID == "CDN-A")
    }

    @Test("invalid I-frame stream declarations are rejected")
    func rejectsInvalidIFrameVariants() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let invalidTags = [
            "#EXT-X-I-FRAME-STREAM-INF:URI=\"iframe.m3u8\"",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,URI=iframe.m3u8",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,FRAME-RATE=30,URI=\"iframe.m3u8\"",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,AUDIO=\"audio\",URI=\"iframe.m3u8\"",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,VIDEO=\"missing\",URI=\"iframe.m3u8\"",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,AVERAGE-BANDWIDTH=-1,URI=\"iframe.m3u8\"",
        ]

        for tag in invalidTags {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=1000000
                    primary.m3u8
                    \(tag)
                    """,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("HLS 2nd Edition rendition and variant metadata is typed")
    func resolvesSecondEditionMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-VERSION:13
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English AD",LANGUAGE="en",ASSOC-LANGUAGE="en-US",STABLE-RENDITION-ID="audio.main",INSTREAM-ID="main.audio",DEFAULT=YES,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video,public.machine-generated",CHANNELS="6/JOC",BIT-DEPTH=24,SAMPLE-RATE=48000,URI="audio.m3u8"
            #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="angles",NAME="Main",STABLE-RENDITION-ID="video.main",URI="angle.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog",URI="subs.m3u8"
            #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="NONE",NAME="English CC",LANGUAGE="en",INSTREAM-ID="SERVICE1"
            #EXT-X-STREAM-INF:BANDWIDTH=4000000,AVERAGE-BANDWIDTH=3500000,SCORE=9.5,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L153.b0,mp4a.40.2",SUPPLEMENTAL-CODECS="dvh1.08.07/db4h",VIDEO-RANGE=PQ,HDCP-LEVEL=TYPE-1,ALLOWED-CPC="com.example.drm:SMART-TV/PC,urn:uuid:abcd:HW",REQ-VIDEO-LAYOUT="CH-STEREO/PROJ-HEQU,CH-MONO",AUDIO="audio",VIDEO="angles",SUBTITLES="subs",CLOSED-CAPTIONS="NONE",STABLE-VARIANT-ID="variant.main",PATHWAY-ID="CDN-A"
            video.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,CLOSED-CAPTIONS=NONE
            no-captions.m3u8
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )
        let audio = try #require(
            result.renditions.first { $0.kind == .audio }
        )
        let video = try #require(
            result.renditions.first { $0.kind == .video }
        )
        let captions = try #require(
            result.renditions.first {
                $0.kind == .closedCaptions
            }
        )
        let variant = try #require(result.variants.first)

        #expect(result.protocolVersion == 13)
        #expect(result.hasIndependentSegments)
        #expect(audio.associatedLanguage == "en-US")
        #expect(audio.stableID == "audio.main")
        #expect(audio.instreamID == "main.audio")
        #expect(
            audio.characteristics
                == [
                    "public.accessibility.describes-video",
                    "public.machine-generated",
                ]
        )
        #expect(audio.isMachineGenerated)
        #expect(!audio.isTranslated)
        #expect(
            audio.mediaCharacteristics
                == [
                    HLSMediaCharacteristic(
                        rawValue: "public.accessibility.describes-video"
                    ),
                    .machineGenerated,
                ]
        )
        #expect(audio.channels == "6/JOC")
        #expect(audio.audioBitDepth == 24)
        #expect(audio.audioSampleRate == 48_000)
        #expect(video.stableID == "video.main")
        #expect(captions.instreamID == "SERVICE1")
        #expect(captions.url == nil)
        #expect(variant.score == 9.5)
        #expect(
            variant.supplementalCodecs
                == ["dvh1.08.07/db4h"]
        )
        #expect(variant.videoGroupID == "angles")
        #expect(variant.hdcpLevel == .type1)
        #expect(
            variant.allowedContentProtectionConfigurations
                == [
                    HLSAllowedContentProtectionConfiguration(
                        keyFormat: "com.example.drm",
                        labels: ["SMART-TV", "PC"]
                    ),
                    HLSAllowedContentProtectionConfiguration(
                        keyFormat: "urn:uuid:abcd",
                        labels: ["HW"]
                    ),
                ]
        )
        #expect(
            variant.requiredVideoLayouts
                == [
                    HLSRequiredVideoLayout(
                        channelLayout: .stereoscopic,
                        projection: .halfEquirectangular
                    ),
                    HLSRequiredVideoLayout(
                        channelLayout: .monoscopic
                    ),
                ]
        )
        #expect(
            variant.closedCaptions
                == .group("NONE")
        )
        #expect(variant.stableID == "variant.main")
        #expect(variant.pathwayID == "CDN-A")
        #expect(
            result.variants[1].closedCaptions
                == .explicitlyNone
        )
    }

    @Test("malformed HLS 2nd Edition metadata is rejected")
    func rejectsMalformedSecondEditionMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        for tag in [
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Duplicate",NAME="Again""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Bad stable",STABLE-RENDITION-ID="not valid""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Padded stable",STABLE-RENDITION-ID=" padded""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Bad default",DEFAULT=YES,AUTOSELECT=NO"#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=audio,NAME="Unquoted group""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Quoted default",DEFAULT="YES""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Quoted depth",BIT-DEPTH="24""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Unquoted URI",URI=audio.m3u8"#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Bad channels",CHANNELS=" 2""#,
            #"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Bad channels",CHANNELS="2",URI="subs.m3u8""#,
            #"#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions",NAME="Bad CC",INSTREAM-ID="SERVICE64""#,
        ] {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    \(tag)
                    #EXT-X-STREAM-INF:BANDWIDTH=1000
                    video.m3u8
                    """,
                    relativeTo: sourceURL
                )
            }
        }

        for streamAttributes in [
            "BANDWIDTH=1000,SCORE=0",
            "BANDWIDTH=1000,SCORE=1e3",
            "BANDWIDTH=1000,AVERAGE-BANDWIDTH=0",
            #"BANDWIDTH="1000""#,
            "BANDWIDTH=1000,CODECS=avc1.4d401f",
            "BANDWIDTH=1000,STABLE-VARIANT-ID=unquoted",
            "BANDWIDTH=1000,PATHWAY-ID=A",
            #"BANDWIDTH=1000,STABLE-VARIANT-ID="not valid""#,
            #"BANDWIDTH=1000,CODECS="avc1.4d401f"#,
            "BANDWIDTH=1000,HDCP-LEVEL=TYPE-2",
            #"BANDWIDTH=1000,ALLOWED-CPC="com.example:bad""#,
            #"BANDWIDTH=1000,REQ-VIDEO-LAYOUT="CH-MONO/CH-STEREO""#,
        ] {
            let streamLine: String
            if streamAttributes
                == #"BANDWIDTH=1000,CODECS="avc1.4d401f""#
            {
                streamLine =
                    "#EXT-X-STREAM-INF:"
                    + streamAttributes
                    + #",CODECS="duplicate""#
            } else {
                streamLine =
                    "#EXT-X-STREAM-INF:" + streamAttributes
            }
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    \(streamLine)
                    video.m3u8
                    """,
                    relativeTo: sourceURL
                )
            }
        }

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-VERSION:12
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="In-band",INSTREAM-ID="main.audio"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                video.m3u8
                """,
                relativeTo: sourceURL
            )
        }

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-VERSION:6
                #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="captions",NAME="English",INSTREAM-ID="SERVICE1"
                #EXT-X-STREAM-INF:BANDWIDTH=1000,CLOSED-CAPTIONS="captions"
                video.m3u8
                """,
                relativeTo: sourceURL
            )
        }

        let backwardCompatibleMetadata = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stable",STABLE-RENDITION-ID="audio.main",BIT-DEPTH=24,SAMPLE-RATE=48000
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio",SCORE=1.5,SUPPLEMENTAL-CODECS="dvh1.08.07/db4h",STABLE-VARIANT-ID="variant.main",PATHWAY-ID="CDN-A"
            video.m3u8
            """,
            relativeTo: sourceURL
        )
        #expect(backwardCompatibleMetadata.protocolVersion == nil)
        #expect(backwardCompatibleMetadata.renditions[0].stableID == "audio.main")
        #expect(backwardCompatibleMetadata.variants[0].score == 1.5)
    }

    @Test("unsupported video capabilities make variants ineligible")
    func skipsUnsupportedVideoCapabilities() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-VERSION:12
            #EXT-X-STREAM-INF:BANDWIDTH=1000,VIDEO-RANGE=FUTURE
            unsupported-range.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000,REQ-VIDEO-LAYOUT="CH-HOLOGRAPHIC"
            unsupported-layout.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=3000,VIDEO-RANGE=SDR
            supported.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(result.variants.count == 1)
        #expect(result.variants[0].bandwidth == 3_000)
        #expect(
            result.variants[0].url.absoluteString
                == "https://cdn.example/media/supported.m3u8"
        )
    }

    @Test("required video layout uses an exact attribute and requires version 12")
    func validatesRequiredVideoLayoutVersion() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=1000,REQ-VIDEO-LAYOUT="CH-MONO"
                video.m3u8
                """,
                relativeTo: sourceURL
            )
        }

        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="REQ-VIDEO-LAYOUT=future"
            video.m3u8
            """,
            relativeTo: sourceURL
        )

        #expect(result.variants.count == 1)
    }

    @Test("invalid rendition declarations are rejected")
    func rejectsInvalidRenditions() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        for rendition in [
            #"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Missing URI""#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Bad Bool",DEFAULT=MAYBE"#,
            #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Forced",FORCED=YES"#,
        ] {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    \(rendition)
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="audio"
                    video.m3u8
                    """,
                    relativeTo: sourceURL
                )
            }
        }

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=1000,FRAME-RATE=-1
                video.m3u8
                """,
                relativeTo: sourceURL
            )
        }
    }

    @Test("empty or malformed capability attributes are rejected")
    func rejectsInvalidCapabilityAttributes() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/master.m3u8")
        )
        for attribute in [
            #"CODECS="""#,
            #"CODECS="avc1.4d401f,,mp4a.40.2""#,
            #"VIDEO-RANGE="""#,
        ] {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=1000,\(attribute)
                    video.m3u8
                    """,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("media playlist has no variants")
    func recognizesMediaPlaylist() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXTINF:6,
            segment-1.ts
            #EXT-X-ENDLIST
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(result.kind == .media)
        #expect(result.variants.isEmpty)
        #expect(result.mediaContainer == .mpegTransportStream)
        #expect(result.mediaContainer?.fileExtension == "ts")
    }

    @Test("media sequence, mutability, and segment bitrates are typed")
    func resolvesMediaPlaylistMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:42
            #EXT-X-DISCONTINUITY-SEQUENCE:7
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-BITRATE:1200
            #EXTINF:6,
            segment-1.ts
            #EXT-X-BITRATE:900
            #EXT-X-BYTERANGE:100@0
            #EXTINF:6,
            segment-2.ts
            #EXTINF:6,
            segment-3.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(result.targetDuration == 6)
        #expect(result.mediaSequence == 42)
        #expect(result.discontinuitySequence == 7)
        #expect(result.mediaPlaylistType == .videoOnDemand)
        #expect(
            result.segmentBitrates
                == [
                    HLSSegmentBitrate(
                        segmentIndex: 0,
                        kilobitsPerSecond: 1_200
                    ),
                    HLSSegmentBitrate(
                        segmentIndex: 2,
                        kilobitsPerSecond: 900
                    ),
                ]
        )
    }

    @Test("invalid media playlist metadata is rejected")
    func rejectsInvalidMediaPlaylistMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        for declaration in [
            """
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-MEDIA-SEQUENCE:2
            """,
            """
            #EXT-X-DISCONTINUITY
            #EXT-X-DISCONTINUITY-SEQUENCE:1
            """,
            "#EXT-X-PLAYLIST-TYPE:LIVE",
            "#EXT-X-BITRATE:-1",
            """
            #EXT-X-ENDLIST
            #EXT-X-ENDLIST
            """,
        ] {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    \(declaration)
                    #EXTINF:1,
                    segment.ts
                    """,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("fragmented MP4 playlist reports its output container")
    func recognizesFragmentedMP4Playlist() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6,
            segment-1.m4s
            #EXT-X-ENDLIST
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(result.kind == .media)
        #expect(result.mediaContainer == .fragmentedMP4)
        #expect(result.mediaContainer?.fileExtension == "mp4")
        #expect(
            result.media?.resources == [
                .initialization(
                    try #require(
                        URL(
                            string:
                                "https://cdn.example/media/init.mp4"
                        )
                    )
                ),
                .segment(
                    try #require(
                        URL(
                            string:
                                "https://cdn.example/media/segment-1.m4s"
                        )
                    ),
                    duration: 6
                ),
            ]
        )
    }

    @Test("encrypted media and explicit byte ranges remain modeled")
    func recognizesEncryptedMediaAndByteRanges() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXT-X-BYTERANGE:1024@0
            #EXTINF:6,
            media.ts
            #EXT-X-KEY:METHOD=NONE
            #EXT-X-ENDLIST
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(result.media?.encryptionMethod == "AES-128")
        #expect(
            result.media?.resources.last?.byteRange
                == HLSByteRange(offset: 0, length: 1_024)
        )
    }

    @Test("identity AES-128 wins across parallel key formats")
    func selectsIdentityAES128AcrossParallelKeyFormats() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let fairPlay =
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://asset\",KEYFORMAT=\"com.apple.streamingkeydelivery\""
        let packagedAES128 =
            "#EXT-X-KEY:METHOD=AES-128,URI=\"packaged-key.bin\",KEYFORMAT=\"com.example.wrapped-key\""
        let identity =
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x1"
        let keyURL = try #require(
            URL(string: "https://cdn.example/media/key.bin")
        )

        for alternative in [fairPlay, packagedAES128] {
            for declarations in [
                "\(alternative)\n\(identity)",
                "\(identity)\n\(alternative)",
            ] {
                let result = try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    \(declarations)
                    #EXTINF:1,
                    segment.ts
                    #EXT-X-ENDLIST
                    """,
                    relativeTo: sourceURL
                )
                let encryption = try #require(
                    result.media?.resources.last?.encryption
                )

                #expect(result.media?.encryptionMethod == "AES-128")
                #expect(result.media?.unsupportedEncryptionMethod == nil)
                #expect(encryption.keyURL == keyURL)
                #expect(
                    encryption.initializationVector
                        == Data(repeating: 0, count: 15) + Data([1])
                )
                try HLSMediaPlaylistValidator.validate(
                    try #require(result.media)
                )
            }
        }
    }

    @Test("non-identity AES-128 remains typed unsupported")
    func recognizesUnsupportedAES128KeyFormat() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="packaged-key.bin",KEYFORMAT="com.example.wrapped-key"
            #EXTINF:1,
            protected.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(result.media?.encryptionMethod == "AES-128")
        #expect(result.media?.unsupportedEncryptionMethod == "AES-128")
        #expect(result.media?.resources.last?.encryption == nil)
        #expect(
            throws: HLSDownloadError.encryptedPlaylistUnsupported(
                method: "AES-128"
            )
        ) {
            try HLSMediaPlaylistValidator.validate(
                try #require(result.media)
            )
        }
    }

    @Test("a later declaration replaces the same key format")
    func replacesSameKeyFormatDeclaration() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let identityAES128 =
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\""
        let identitySampleAES =
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"sample.key\",KEYFORMAT=\"identity\""

        for (declarations, expectedMethod) in [
            ("\(identityAES128)\n\(identitySampleAES)", "SAMPLE-AES"),
            ("\(identitySampleAES)\n\(identityAES128)", nil),
        ] {
            let result = try PlaylistResolver().resolve(
                """
                #EXTM3U
                \(declarations)
                #EXTINF:1,
                segment.ts
                #EXT-X-ENDLIST
                """,
                relativeTo: sourceURL
            )
            let media = try #require(result.media)

            #expect(media.unsupportedEncryptionMethod == expectedMethod)
            if let expectedMethod {
                #expect(media.resources.last?.encryption == nil)
                #expect(
                    throws:
                        HLSDownloadError
                        .encryptedPlaylistUnsupported(
                            method: expectedMethod
                        )
                ) {
                    try HLSMediaPlaylistValidator.validate(media)
                }
            } else {
                #expect(media.resources.last?.encryption != nil)
                try HLSMediaPlaylistValidator.validate(media)
            }
        }
    }

    @Test("an earlier unsupported encrypted resource is not masked")
    func preservesEarlierUnsupportedEncryption() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXTINF:1,
            protected.ts
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXTINF:1,
            fallback.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(result.media?.encryptionMethod == "SAMPLE-AES")
        #expect(result.media?.unsupportedEncryptionMethod == "SAMPLE-AES")
        #expect(result.media?.resources.first?.encryption == nil)
        #expect(result.media?.resources.last?.encryption != nil)
        #expect(
            throws: HLSDownloadError.encryptedPlaylistUnsupported(
                method: "SAMPLE-AES"
            )
        ) {
            try HLSMediaPlaylistValidator.validate(
                try #require(result.media)
            )
        }
    }

    @Test("parallel key formats apply independently to initialization maps")
    func appliesParallelKeyFormatsToInitializationMaps() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let fairPlay =
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://asset\",KEYFORMAT=\"com.apple.streamingkeydelivery\""
        let identity =
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x1"
        let keyURL = try #require(
            URL(string: "https://cdn.example/media/key.bin")
        )

        for declarations in [
            "\(fairPlay)\n\(identity)",
            "\(identity)\n\(fairPlay)",
        ] {
            let result = try PlaylistResolver().resolve(
                """
                #EXTM3U
                \(declarations)
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:1,
                segment.m4s
                #EXT-X-ENDLIST
                """,
                relativeTo: sourceURL
            )
            let media = try #require(result.media)
            let mapEncryption = try #require(
                media.resources.first?.encryption
            )

            #expect(mapEncryption.keyURL == keyURL)
            #expect(
                mapEncryption.initializationVector
                    == Data(repeating: 0, count: 15) + Data([1])
            )
            #expect(media.unsupportedEncryptionMethod == nil)
            try HLSMediaPlaylistValidator.validate(media)
        }
    }

    @Test("an unsupported initialization map is not masked")
    func preservesUnsupportedInitializationMapEncryption() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXT-X-MAP:URI="init.mp4"
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXTINF:1,
            segment.m4s
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )
        let media = try #require(result.media)

        #expect(media.resources.first?.encryption == nil)
        #expect(media.resources.last?.encryption != nil)
        #expect(media.unsupportedEncryptionMethod == "SAMPLE-AES")
        #expect(
            throws: HLSDownloadError.encryptedPlaylistUnsupported(
                method: "SAMPLE-AES"
            )
        ) {
            try HLSMediaPlaylistValidator.validate(media)
        }
    }

    @Test("METHOD NONE clears every parallel key format")
    func clearsParallelKeyFormats() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let result = try PlaylistResolver().resolve(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXT-X-KEY:METHOD=NONE
            #EXTINF:1,
            clear.ts
            #EXT-X-ENDLIST
            """,
            relativeTo: sourceURL
        )

        #expect(result.media?.encryptionMethod == nil)
        #expect(result.media?.resources.last?.encryption == nil)
    }

    @Test("AES-128 initialization maps require an explicit IV")
    func encryptedInitializationMapRequiresIV() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                """
                #EXTM3U
                #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:1,
                segment.m4s
                #EXT-X-ENDLIST
                """,
                relativeTo: sourceURL
            )
        }
    }

    @Test("AES-128 rejects malformed and duplicate key attributes")
    func rejectsInvalidAES128KeyAttributes() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let invalidPlaylists = [
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,METHOD=NONE,URI="key.bin"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-KEY:METHOD="AES-128",URI="key.bin"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI=key.bin
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV="0x1"
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=SAMPLE-AES
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-256-GCM,URI="key.bin",IV=0x1
            #EXTINF:1,
            segment.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXT-X-MAP:URI=init.mp4
            #EXTINF:1,
            segment.m4s
            #EXT-X-ENDLIST
            """,
        ]

        for playlist in invalidPlaylists {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    playlist,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("implicit byte-range offsets continue on the same resource")
    func resolvesImplicitByteRangeOffsets() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-BYTERANGE:4@2
            #EXTINF:1,
            media.ts
            #EXT-X-BYTERANGE:3
            #EXTINF:1,
            media.ts
            #EXT-X-ENDLIST
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(
            result.media?.resources.map(\.byteRange) == [
                HLSByteRange(offset: 2, length: 4),
                HLSByteRange(offset: 6, length: 3),
            ]
        )
    }

    @Test("initialization maps preserve their byte range")
    func resolvesInitializationByteRange() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-MAP:URI="media.mp4",BYTERANGE="8@0"
            #EXT-X-BYTERANGE:12@8
            #EXTINF:1,
            media.mp4
            #EXT-X-ENDLIST
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(
            result.media?.resources.map(\.byteRange) == [
                HLSByteRange(offset: 0, length: 8),
                HLSByteRange(offset: 8, length: 12),
            ]
        )
    }

    @Test("an implicit range requires a ranged previous segment at the same URL")
    func rejectsInvalidImplicitByteRange() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-BYTERANGE:4
            #EXTINF:1,
            media.ts
            #EXT-X-ENDLIST
            """

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                playlist,
                relativeTo: sourceURL
            )
        }
    }

    @Test("an implicit range cannot continue on a different resource")
    func rejectsImplicitByteRangeForDifferentResource() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-BYTERANGE:4@0
            #EXTINF:1,
            first.ts
            #EXT-X-BYTERANGE:4
            #EXTINF:1,
            second.ts
            #EXT-X-ENDLIST
            """

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                playlist,
                relativeTo: sourceURL
            )
        }
    }

    @Test("invalid and overflowing ranges are rejected")
    func rejectsInvalidByteRanges() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )

        for range in [
            "0@0",
            "-1@0",
            "1@-1",
            "1@9223372036854775807",
            "not-a-range",
        ] {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    """
                    #EXTM3U
                    #EXT-X-BYTERANGE:\(range)
                    #EXTINF:1,
                    media.ts
                    #EXT-X-ENDLIST
                    """,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("single-file unsafe media tags remain explicitly marked")
    func recognizesUnsafeSingleFileFeatures() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media/index.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-I-FRAMES-ONLY
            #EXT-X-MAP:URI="init-1.mp4"
            #EXTINF:1,
            segment-1.m4s
            #EXT-X-DISCONTINUITY
            #EXT-X-MAP:URI="init-2.mp4"
            #EXT-X-GAP
            #EXTINF:1,
            segment-2.m4s
            #EXT-X-ENDLIST
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(
            result.media?.unsupportedFeatures == [
                .iFramesOnly,
                .discontinuity,
                .multipleInitializationSections,
                .gap,
            ]
        )
    }

    @Test("invalid document is rejected")
    func rejectsInvalidDocument() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/not-hls.txt")
        )

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                "ordinary text",
                relativeTo: sourceURL
            )
        }
    }

    @Test("segment duration and segment-scoped flags require a valid URI")
    func rejectsInvalidOrDanglingSegmentMetadata() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media.m3u8")
        )
        let invalidPlaylists = [
            """
            #EXTM3U
            #EXTINF:0,
            segment.ts
            """,
            """
            #EXTM3U
            #EXTINF:nan,
            segment.ts
            """,
            """
            #EXTM3U
            #EXTINF:4,
            """,
            """
            #EXTM3U
            #EXT-X-DISCONTINUITY
            """,
            """
            #EXTM3U
            #EXT-X-GAP
            """,
        ]

        for playlist in invalidPlaylists {
            #expect(throws: HLSDownloadError.invalidPlaylist) {
                try PlaylistResolver().resolve(
                    playlist,
                    relativeTo: sourceURL
                )
            }
        }
    }

    @Test("non-positive resolutions are ignored")
    func ignoresNonPositiveResolutions() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=-1x720
            media.m3u8
            """

        let result = try PlaylistResolver().resolve(
            playlist,
            relativeTo: sourceURL
        )

        #expect(result.variants.first?.width == nil)
        #expect(result.variants.first?.height == nil)
    }

    @Test("master and media tags cannot be mixed")
    func rejectsMixedPlaylistKinds() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            media.m3u8
            #EXTINF:1,
            segment.ts
            """

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                playlist,
                relativeTo: sourceURL
            )
        }
    }

    @Test("master and single-file capability tags cannot be mixed")
    func rejectsCapabilityTagsInMultivariantPlaylist() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/master.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            media.m3u8
            #EXT-X-GAP
            """

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                playlist,
                relativeTo: sourceURL
            )
        }
    }

    @Test("fragmented MP4 segments require an initialization map")
    func rejectsFragmentedMP4WithoutMap() throws {
        let sourceURL = try #require(
            URL(string: "https://cdn.example/media.m3u8")
        )
        let playlist = """
            #EXTM3U
            #EXTINF:1,
            segment.m4s
            #EXT-X-ENDLIST
            """

        #expect(throws: HLSDownloadError.invalidPlaylist) {
            try PlaylistResolver().resolve(
                playlist,
                relativeTo: sourceURL
            )
        }
    }
}
