import Foundation

struct HLSMediaPlaylistMetadata: Equatable, Sendable {
    let targetDuration: Int?
    let mediaSequence: Int64
    let discontinuitySequence: Int64
    let playlistType: HLSMediaPlaylistType?
    let hasEndList: Bool
}

enum HLSMediaPlaylistMetadataParser {
    static func parse(
        _ lines: [String]
    ) throws -> HLSMediaPlaylistMetadata {
        var targetDuration: Int?
        var mediaSequence: Int64?
        var discontinuitySequence: Int64?
        var playlistType: HLSMediaPlaylistType?
        var hasPlaylistType = false
        var hasEndList = false
        var hasSegmentURI = false
        var expectsSegmentURI = false
        var hasDiscontinuity = false

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                guard targetDuration == nil,
                    let value = Int(
                        line.dropFirst(
                            "#EXT-X-TARGETDURATION:".count
                        )
                    ),
                    value > 0
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                targetDuration = value
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard mediaSequence == nil, !hasSegmentURI,
                    let value = Int64(
                        line.dropFirst(
                            "#EXT-X-MEDIA-SEQUENCE:".count
                        )
                    ),
                    value >= 0
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                mediaSequence = value
            } else if line.hasPrefix(
                "#EXT-X-DISCONTINUITY-SEQUENCE:"
            ) {
                guard discontinuitySequence == nil,
                    !hasSegmentURI,
                    !hasDiscontinuity,
                    let value = Int64(
                        line.dropFirst(
                            "#EXT-X-DISCONTINUITY-SEQUENCE:".count
                        )
                    ),
                    value >= 0
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                discontinuitySequence = value
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                guard !hasPlaylistType else {
                    throw HLSDownloadError.invalidPlaylist
                }
                hasPlaylistType = true
                guard
                    let value = HLSMediaPlaylistType(
                        rawValue: String(
                            line.dropFirst(
                                "#EXT-X-PLAYLIST-TYPE:".count
                            )
                        )
                    )
                else {
                    throw HLSDownloadError.invalidPlaylist
                }
                playlistType = value
            } else if line == "#EXT-X-ENDLIST" {
                guard !hasEndList else {
                    throw HLSDownloadError.invalidPlaylist
                }
                hasEndList = true
            } else if line == "#EXT-X-DISCONTINUITY" {
                hasDiscontinuity = true
            } else if line.hasPrefix("#EXTINF:") {
                expectsSegmentURI = true
            } else if !line.isEmpty, !line.hasPrefix("#"),
                expectsSegmentURI
            {
                hasSegmentURI = true
                expectsSegmentURI = false
            }
        }

        return HLSMediaPlaylistMetadata(
            targetDuration: targetDuration,
            mediaSequence: mediaSequence ?? 0,
            discontinuitySequence: discontinuitySequence ?? 0,
            playlistType: playlistType,
            hasEndList: hasEndList
        )
    }
}
