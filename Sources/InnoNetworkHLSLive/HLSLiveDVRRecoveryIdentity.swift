import Foundation
import InnoNetworkHLS

enum HLSLiveDVRRecoveryIdentity {
    static func sourceURLSHA256(
        _ sourceURL: URL
    ) -> String {
        var components = URLComponents(
            url: sourceURL,
            resolvingAgainstBaseURL: false
        )
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let value =
            components?.string
            ?? [
                sourceURL.scheme ?? "",
                sourceURL.host ?? "",
                sourceURL.path,
            ].joined(separator: "\u{1f}")
        return HLSContentFingerprint.sha256(value)
    }

    static func initializationSegmentIdentity(
        _ segment: HLSLiveInitializationSegment
    ) -> String {
        let rangeValue: String
        if let byteRange = segment.byteRange {
            rangeValue = "\(byteRange.offset):\(byteRange.length)"
        } else {
            rangeValue = ""
        }
        let encryptionValue: String
        if let encryption = segment.encryption {
            encryptionValue = [
                sourceURLSHA256(encryption.keyURL),
                HLSContentFingerprint.sha256(
                    encryption.initializationVector
                ),
            ].joined(separator: ":")
        } else {
            encryptionValue = ""
        }
        return HLSContentFingerprint.sha256(
            [
                sourceURLSHA256(segment.url),
                rangeValue,
                encryptionValue,
            ].joined(separator: "\u{1f}")
        )
    }
}

extension HLSVariant {
    var liveDVRCheckpointIdentity: String {
        let closedCaptionValue: String
        switch closedCaptions {
        case .explicitlyNone:
            closedCaptionValue = "none"
        case .group(let groupID):
            closedCaptionValue = "group:" + groupID
        case nil:
            closedCaptionValue = "unspecified"
        }
        var components: [String] = []
        components.append(
            stableID
                ?? HLSLiveDVRRecoveryIdentity.sourceURLSHA256(url)
        )
        components.append(bandwidth.map(String.init) ?? "")
        components.append(averageBandwidth.map(String.init) ?? "")
        components.append(width.map(String.init) ?? "")
        components.append(height.map(String.init) ?? "")
        components.append(audioGroupID ?? "")
        components.append(subtitleGroupID ?? "")
        components.append(videoGroupID ?? "")
        components.append(codecs.joined(separator: ","))
        components.append(supplementalCodecs.joined(separator: ","))
        components.append(frameRate.map { String($0) } ?? "")
        components.append(videoRange ?? "")
        components.append(closedCaptionValue)
        let value = components.joined(separator: "\u{1f}")
        return HLSContentFingerprint.sha256(value)
    }
}

extension HLSRendition {
    var liveDVRCheckpointIdentity: String {
        let kindValue: String
        switch kind {
        case .audio:
            kindValue = "audio"
        case .video:
            kindValue = "video"
        case .subtitles:
            kindValue = "subtitles"
        case .closedCaptions:
            kindValue = "closedCaptions"
        }
        let sourceIdentity =
            stableID
            ?? url.map(HLSLiveDVRRecoveryIdentity.sourceURLSHA256)
            ?? ""
        var components: [String] = []
        components.append(kindValue)
        components.append(sourceIdentity)
        components.append(groupID)
        components.append(name)
        components.append(language ?? "")
        components.append(associatedLanguage ?? "")
        components.append(instreamID ?? "")
        components.append(characteristics.joined(separator: ","))
        components.append(channels ?? "")
        components.append(audioBitDepth.map(String.init) ?? "")
        components.append(audioSampleRate.map(String.init) ?? "")
        components.append(isDefault ? "1" : "0")
        components.append(isAutoselect ? "1" : "0")
        components.append(isForced ? "1" : "0")
        let value = components.joined(separator: "\u{1f}")
        return HLSContentFingerprint.sha256(value)
    }
}
