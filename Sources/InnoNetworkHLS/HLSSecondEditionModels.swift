import Foundation

/// The output copy-protection requirement advertised by `HDCP-LEVEL`.
public enum HLSHDCPLevel: Equatable, Hashable, Sendable {
    /// The variant does not require output copy protection.
    case none

    /// The variant requires HDCP Type 0 or equivalent protection.
    case type0

    /// The variant requires HDCP Type 1 or equivalent protection.
    case type1
}

/// One content-protection robustness declaration from `ALLOWED-CPC`.
public struct HLSAllowedContentProtectionConfiguration:
    Equatable,
    Hashable,
    Sendable
{
    /// The key format that defines the configuration labels.
    public let keyFormat: String

    /// Configuration labels accepted for the key format, in author order.
    public let labels: [String]

    init(keyFormat: String, labels: [String]) {
        self.keyFormat = keyFormat
        self.labels = labels
    }
}

/// The video-channel arrangement required for specialized rendering.
public enum HLSVideoChannelLayout: Equatable, Hashable, Sendable {
    /// A single image is present.
    case monoscopic

    /// Left-eye and right-eye images are present.
    case stereoscopic
}

/// The video projection required for specialized rendering.
public enum HLSVideoProjection: Equatable, Hashable, Sendable {
    /// No projection is required.
    case rectilinear

    /// A 360-degree equirectangular projection is required.
    case equirectangular

    /// A 180-degree half-equirectangular projection is required.
    case halfEquirectangular

    /// A parametric immersive projection is required.
    case parametricImmersive
}

/// One view-presentation entry from `REQ-VIDEO-LAYOUT`.
public struct HLSRequiredVideoLayout: Equatable, Hashable, Sendable {
    /// The explicitly declared video-channel arrangement.
    public let channelLayout: HLSVideoChannelLayout?

    /// The explicitly declared projection.
    ///
    /// Absence has the same protocol meaning as ``HLSVideoProjection/rectilinear``.
    public let projection: HLSVideoProjection?

    init(
        channelLayout: HLSVideoChannelLayout? = nil,
        projection: HLSVideoProjection? = nil
    ) {
        self.channelLayout = channelLayout
        self.projection = projection
    }
}

/// The mutability contract declared by `EXT-X-PLAYLIST-TYPE`.
public enum HLSMediaPlaylistType: Equatable, Hashable, Sendable {
    /// Segments may only be appended to the media playlist.
    case event

    /// The media playlist cannot change.
    case videoOnDemand
}

/// An `EXT-X-BITRATE` value applied to one complete media segment.
public struct HLSSegmentBitrate: Equatable, Hashable, Sendable {
    /// The zero-based complete-segment index in the playlist.
    public let segmentIndex: Int

    /// The approximate segment bitrate in kilobits per second.
    public let kilobitsPerSecond: Int

    init(segmentIndex: Int, kilobitsPerSecond: Int) {
        self.segmentIndex = segmentIndex
        self.kilobitsPerSecond = kilobitsPerSecond
    }
}

extension HLSAllowedContentProtectionConfiguration {
    var playlistValue: String {
        keyFormat + ":" + labels.joined(separator: "/")
    }
}

extension HLSHDCPLevel {
    init?(rawValue: String) {
        switch rawValue {
        case "NONE":
            self = .none
        case "TYPE-0":
            self = .type0
        case "TYPE-1":
            self = .type1
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .none:
            "NONE"
        case .type0:
            "TYPE-0"
        case .type1:
            "TYPE-1"
        }
    }
}

extension HLSMediaPlaylistType {
    init?(rawValue: String) {
        switch rawValue {
        case "EVENT":
            self = .event
        case "VOD":
            self = .videoOnDemand
        default:
            return nil
        }
    }
}

extension HLSVideoChannelLayout {
    init?(rawValue: String) {
        switch rawValue {
        case "CH-MONO":
            self = .monoscopic
        case "CH-STEREO":
            self = .stereoscopic
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .monoscopic:
            "CH-MONO"
        case .stereoscopic:
            "CH-STEREO"
        }
    }
}

extension HLSVideoProjection {
    init?(rawValue: String) {
        switch rawValue {
        case "PROJ-RECT":
            self = .rectilinear
        case "PROJ-EQUI":
            self = .equirectangular
        case "PROJ-HEQU":
            self = .halfEquirectangular
        case "PROJ-PRIM":
            self = .parametricImmersive
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .rectilinear:
            "PROJ-RECT"
        case .equirectangular:
            "PROJ-EQUI"
        case .halfEquirectangular:
            "PROJ-HEQU"
        case .parametricImmersive:
            "PROJ-PRIM"
        }
    }
}

extension HLSRequiredVideoLayout {
    var playlistValue: String {
        [channelLayout?.rawValue, projection?.rawValue]
            .compactMap { $0 }
            .joined(separator: "/")
    }
}
