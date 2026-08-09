import Foundation

struct HLSOfflinePackageManifest: Codable, Sendable {
    static let currentSchemaVersion = 3

    struct Track: Codable, Equatable, Sendable {
        let kind: String
        let name: String?
        let language: String?
        let associatedLanguage: String?
        let stableID: String?
        let instreamID: String?
        let characteristics: [String]
        let channels: String?
        let audioBitDepth: Int?
        let audioSampleRate: Int?
        let isDefault: Bool
        let isAutoselect: Bool
        let isForced: Bool
        let playlistPath: String

        init(_ track: HLSOfflinePackageTrack) {
            self.kind = track.kind.manifestValue
            self.name = track.name
            self.language = track.language
            self.associatedLanguage = track.associatedLanguage
            self.stableID = track.stableID
            self.instreamID = track.instreamID
            self.characteristics = track.characteristics
            self.channels = track.channels
            self.audioBitDepth = track.audioBitDepth
            self.audioSampleRate = track.audioSampleRate
            self.isDefault = track.isDefault
            self.isAutoselect = track.isAutoselect
            self.isForced = track.isForced
            self.playlistPath = track.relativePlaylistPath
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(
                keyedBy: CodingKeys.self
            )
            self.kind = try container.decode(String.self, forKey: .kind)
            self.name = try container.decodeIfPresent(
                String.self,
                forKey: .name
            )
            self.language = try container.decodeIfPresent(
                String.self,
                forKey: .language
            )
            self.associatedLanguage = try container.decodeIfPresent(
                String.self,
                forKey: .associatedLanguage
            )
            self.stableID = try container.decodeIfPresent(
                String.self,
                forKey: .stableID
            )
            self.instreamID = try container.decodeIfPresent(
                String.self,
                forKey: .instreamID
            )
            self.characteristics =
                try container.decodeIfPresent(
                    [String].self,
                    forKey: .characteristics
                ) ?? []
            self.channels = try container.decodeIfPresent(
                String.self,
                forKey: .channels
            )
            self.audioBitDepth = try container.decodeIfPresent(
                Int.self,
                forKey: .audioBitDepth
            )
            self.audioSampleRate = try container.decodeIfPresent(
                Int.self,
                forKey: .audioSampleRate
            )
            self.isDefault =
                try container.decodeIfPresent(
                    Bool.self,
                    forKey: .isDefault
                ) ?? false
            self.isAutoselect =
                try container.decodeIfPresent(
                    Bool.self,
                    forKey: .isAutoselect
                ) ?? false
            self.isForced =
                try container.decodeIfPresent(
                    Bool.self,
                    forKey: .isForced
                ) ?? false
            self.playlistPath = try container.decode(
                String.self,
                forKey: .playlistPath
            )
        }

        func descriptor() throws -> HLSOfflinePackageTrack {
            guard
                let kind = HLSOfflinePackageTrackKind(
                    manifestValue: kind
                )
            else {
                throw HLSDownloadError.invalidOfflinePackage
            }
            return HLSOfflinePackageTrack(
                kind: kind,
                name: name,
                language: language,
                associatedLanguage: associatedLanguage,
                stableID: stableID,
                instreamID: instreamID,
                characteristics: characteristics,
                channels: channels,
                audioBitDepth: audioBitDepth,
                audioSampleRate: audioSampleRate,
                isDefault: isDefault,
                isAutoselect: isAutoselect,
                isForced: isForced,
                relativePlaylistPath: playlistPath
            )
        }
    }

    struct AllowedContentProtectionConfiguration:
        Codable,
        Equatable,
        Sendable
    {
        let keyFormat: String
        let labels: [String]

        init(_ configuration: HLSAllowedContentProtectionConfiguration) {
            self.keyFormat = configuration.keyFormat
            self.labels = configuration.labels
        }

        var playlistValue: String {
            keyFormat + ":" + labels.joined(separator: "/")
        }
    }

    struct RequiredVideoLayout: Codable, Equatable, Sendable {
        let channelLayout: String?
        let projection: String?

        init(_ layout: HLSRequiredVideoLayout) {
            self.channelLayout = layout.channelLayout?.rawValue
            self.projection = layout.projection?.rawValue
        }

        var playlistValue: String {
            [channelLayout, projection]
                .compactMap { $0 }
                .joined(separator: "/")
        }
    }

    struct Variant: Codable, Equatable, Sendable {
        let bandwidth: Int?
        let averageBandwidth: Int?
        let score: Double?
        let width: Int?
        let height: Int?
        let codecs: [String]
        let supplementalCodecs: [String]
        let frameRate: Double?
        let videoRange: String?
        let hdcpLevel: String?
        let allowedContentProtectionConfigurations: [AllowedContentProtectionConfiguration]
        let requiredVideoLayouts: [RequiredVideoLayout]
        let stableID: String?

        init(_ variant: HLSVariant) {
            self.bandwidth = variant.bandwidth
            self.averageBandwidth = variant.averageBandwidth
            self.score = variant.score
            self.width = variant.width
            self.height = variant.height
            self.codecs = variant.codecs
            self.supplementalCodecs = variant.supplementalCodecs
            self.frameRate = variant.frameRate
            self.videoRange = variant.videoRange
            self.hdcpLevel = variant.hdcpLevel?.rawValue
            self.allowedContentProtectionConfigurations =
                variant.allowedContentProtectionConfigurations.map(
                    AllowedContentProtectionConfiguration.init
                )
            self.requiredVideoLayouts = variant.requiredVideoLayouts.map(
                RequiredVideoLayout.init
            )
            self.stableID = variant.stableID
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(
                keyedBy: CodingKeys.self
            )
            self.bandwidth = try container.decodeIfPresent(
                Int.self,
                forKey: .bandwidth
            )
            self.averageBandwidth = try container.decodeIfPresent(
                Int.self,
                forKey: .averageBandwidth
            )
            self.score = try container.decodeIfPresent(
                Double.self,
                forKey: .score
            )
            self.width = try container.decodeIfPresent(
                Int.self,
                forKey: .width
            )
            self.height = try container.decodeIfPresent(
                Int.self,
                forKey: .height
            )
            self.codecs =
                try container.decodeIfPresent(
                    [String].self,
                    forKey: .codecs
                ) ?? []
            self.supplementalCodecs =
                try container.decodeIfPresent(
                    [String].self,
                    forKey: .supplementalCodecs
                ) ?? []
            self.frameRate = try container.decodeIfPresent(
                Double.self,
                forKey: .frameRate
            )
            self.videoRange = try container.decodeIfPresent(
                String.self,
                forKey: .videoRange
            )
            self.hdcpLevel = try container.decodeIfPresent(
                String.self,
                forKey: .hdcpLevel
            )
            self.allowedContentProtectionConfigurations =
                try container.decodeIfPresent(
                    [AllowedContentProtectionConfiguration].self,
                    forKey: .allowedContentProtectionConfigurations
                ) ?? []
            self.requiredVideoLayouts =
                try container.decodeIfPresent(
                    [RequiredVideoLayout].self,
                    forKey: .requiredVideoLayouts
                ) ?? []
            self.stableID = try container.decodeIfPresent(
                String.self,
                forKey: .stableID
            )
        }

        func localVariant(
            at url: URL,
            entryVariant: HLSVariant
        ) throws -> HLSVariant {
            let hdcpLevel: HLSHDCPLevel?
            if let value = self.hdcpLevel {
                guard let parsed = HLSHDCPLevel(rawValue: value) else {
                    throw HLSDownloadError.invalidOfflinePackage
                }
                hdcpLevel = parsed
            } else {
                hdcpLevel = nil
            }
            let allowedConfigurations: [HLSAllowedContentProtectionConfiguration]
            do {
                allowedConfigurations =
                    try HLSPlaylistAttributeDecoder
                    .parseAllowedContentProtectionConfigurations(
                        allowedContentProtectionConfigurations.isEmpty
                            ? nil
                            : allowedContentProtectionConfigurations
                                .map(\.playlistValue)
                                .joined(separator: ",")
                    )
            } catch {
                throw HLSDownloadError.invalidOfflinePackage
            }
            let requiredLayouts: [HLSRequiredVideoLayout]
            do {
                switch try HLSPlaylistAttributeDecoder
                    .parseRequiredVideoLayouts(
                        requiredVideoLayouts.isEmpty
                            ? nil
                            : requiredVideoLayouts
                                .map(\.playlistValue)
                                .joined(separator: ",")
                    )
                {
                case .supported(let parsed):
                    requiredLayouts = parsed
                case .unsupported:
                    throw HLSDownloadError.invalidOfflinePackage
                }
            } catch {
                throw HLSDownloadError.invalidOfflinePackage
            }
            return HLSVariant(
                url: url,
                bandwidth: bandwidth,
                averageBandwidth: averageBandwidth,
                score: score,
                width: width,
                height: height,
                audioGroupID: entryVariant.audioGroupID,
                subtitleGroupID: entryVariant.subtitleGroupID,
                videoGroupID: entryVariant.videoGroupID,
                closedCaptions: entryVariant.closedCaptions,
                codecs: codecs,
                supplementalCodecs: supplementalCodecs,
                frameRate: frameRate,
                videoRange: videoRange,
                hdcpLevel: hdcpLevel,
                allowedContentProtectionConfigurations:
                    allowedConfigurations,
                requiredVideoLayouts: requiredLayouts,
                stableID: stableID,
                pathwayID: nil
            )
        }
    }

    struct FileRecord: Codable, Equatable, Sendable {
        let path: String
        let byteCount: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let entryPlaylistPath: String
    let tracks: [Track]
    let selectedVariant: Variant?
    let selectedIFrameVariant: Variant?
    let resumedResourceTransferCount: Int
    let files: [FileRecord]?

    init(
        entryPlaylistPath: String,
        tracks: [HLSOfflinePackageTrack],
        selectedVariant: HLSVariant?,
        selectedIFrameVariant: HLSVariant? = nil,
        resumedResourceTransferCount: Int = 0,
        files: [FileRecord]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.entryPlaylistPath = entryPlaylistPath
        self.tracks = tracks.map(Track.init)
        self.selectedVariant = selectedVariant.map(Variant.init)
        self.selectedIFrameVariant = selectedIFrameVariant.map(Variant.init)
        self.resumedResourceTransferCount = resumedResourceTransferCount
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entryPlaylistPath
        case tracks
        case selectedVariant
        case selectedIFrameVariant
        case resumedResourceTransferCount
        case files
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        self.entryPlaylistPath = try container.decode(
            String.self,
            forKey: .entryPlaylistPath
        )
        self.tracks = try container.decode(
            [Track].self,
            forKey: .tracks
        )
        self.selectedVariant = try container.decodeIfPresent(
            Variant.self,
            forKey: .selectedVariant
        )
        self.selectedIFrameVariant = try container.decodeIfPresent(
            Variant.self,
            forKey: .selectedIFrameVariant
        )
        self.resumedResourceTransferCount =
            try container.decodeIfPresent(
                Int.self,
                forKey: .resumedResourceTransferCount
            ) ?? 0
        self.files = try container.decodeIfPresent(
            [FileRecord].self,
            forKey: .files
        )
    }
}

extension HLSOfflinePackageTrackKind {
    var manifestValue: String {
        switch self {
        case .primary:
            return "primary"
        case .audio:
            return "audio"
        case .subtitles:
            return "subtitles"
        case .video:
            return "video"
        case .iFrames:
            return "i-frames"
        case .iFrameVideo:
            return "i-frame-video"
        }
    }

    init?(manifestValue: String) {
        switch manifestValue {
        case "primary":
            self = .primary
        case "audio":
            self = .audio
        case "subtitles":
            self = .subtitles
        case "video":
            self = .video
        case "i-frames":
            self = .iFrames
        case "i-frame-video":
            self = .iFrameVideo
        default:
            return nil
        }
    }
}
