import Foundation

/// A typed HLS Media Characteristic Tag.
///
/// The raw value remains extensible so applications can retain custom or
/// future tags while using the standard constants known to this release.
public struct HLSMediaCharacteristic: RawRepresentable, Equatable, Hashable,
    Sendable
{
    /// The exact value carried by `EXT-X-MEDIA:CHARACTERISTICS`.
    public let rawValue: String

    /// Creates a characteristic from a standard or application-defined tag.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The rendition was authored or translated programmatically.
    public static let machineGenerated = HLSMediaCharacteristic(
        rawValue: "public.machine-generated"
    )

    /// The rendition is a translation.
    ///
    /// Apple-authored translated renditions also carry
    /// ``machineGenerated``.
    public static let translation = HLSMediaCharacteristic(
        rawValue: "public.translation"
    )
}

/// Controls one characteristic's role in subtitle selection.
public enum HLSMediaCharacteristicPreference: Equatable, Sendable {
    /// The characteristic neither raises priority nor excludes a rendition.
    case neutral

    /// Matching renditions win otherwise-equal subtitle selection.
    case preferred

    /// Matching renditions are ineligible for subtitle selection.
    case excluded
}

/// Composes machine-generated and translated subtitle selection behavior.
///
/// Exclusion is applied before every selection policy. Preference narrows
/// otherwise-equal language or name matches while retaining playlist order.
/// Automatic selection applies default and autoselect flags inside the
/// highest-priority provenance group.
public struct HLSSubtitleProvenancePolicy: Equatable, Sendable {
    let machineGenerated: HLSMediaCharacteristicPreference
    let translation: HLSMediaCharacteristicPreference

    /// Creates a subtitle provenance policy.
    public init(
        machineGenerated: HLSMediaCharacteristicPreference = .neutral,
        translation: HLSMediaCharacteristicPreference = .neutral
    ) {
        self.machineGenerated = machineGenerated
        self.translation = translation
    }
}

public extension HLSRendition {
    /// Typed media characteristics in playlist order.
    var mediaCharacteristics: [HLSMediaCharacteristic] {
        characteristics.map(HLSMediaCharacteristic.init(rawValue:))
    }

    /// Returns whether this rendition carries the exact characteristic.
    func hasCharacteristic(
        _ characteristic: HLSMediaCharacteristic
    ) -> Bool {
        characteristics.contains(characteristic.rawValue)
    }

    /// Whether this rendition was authored or translated programmatically.
    var isMachineGenerated: Bool {
        hasCharacteristic(.machineGenerated)
    }

    /// Whether this rendition is marked as a translation.
    var isTranslated: Bool {
        hasCharacteristic(.translation)
    }
}

public extension HLSOfflinePackageTrack {
    /// Typed media characteristics retained by the offline manifest.
    var mediaCharacteristics: [HLSMediaCharacteristic] {
        characteristics.map(HLSMediaCharacteristic.init(rawValue:))
    }

    /// Returns whether this track retains the exact characteristic.
    func hasCharacteristic(
        _ characteristic: HLSMediaCharacteristic
    ) -> Bool {
        characteristics.contains(characteristic.rawValue)
    }

    /// Whether this offline track was authored or translated programmatically.
    var isMachineGenerated: Bool {
        hasCharacteristic(.machineGenerated)
    }

    /// Whether this offline track is marked as a translation.
    var isTranslated: Bool {
        hasCharacteristic(.translation)
    }
}

struct HLSSubtitleProvenanceResolver: Sendable {
    private let policy: HLSSubtitleProvenancePolicy
    private let kind: HLSRenditionKind

    init(
        policy: HLSSubtitleProvenancePolicy,
        kind: HLSRenditionKind
    ) {
        self.policy = policy
        self.kind = kind
    }

    func eligible(
        _ renditions: [HLSRendition]
    ) -> [HLSRendition] {
        guard kind == .subtitles else {
            return renditions
        }
        return renditions.filter { rendition in
            !isExcluded(
                policy.machineGenerated,
                matches: rendition.isMachineGenerated
            )
                && !isExcluded(
                    policy.translation,
                    matches: rendition.isTranslated
                )
        }
    }

    func preferred(
        _ renditions: [HLSRendition]
    ) -> [HLSRendition] {
        guard kind == .subtitles,
            let highestScore = renditions.map(score).max(),
            highestScore > 0
        else {
            return renditions
        }
        return renditions.filter { score($0) == highestScore }
    }

    private func score(
        _ rendition: HLSRendition
    ) -> Int {
        var result = 0
        if policy.machineGenerated == .preferred,
            rendition.isMachineGenerated
        {
            result += 1
        }
        if policy.translation == .preferred,
            rendition.isTranslated
        {
            result += 1
        }
        return result
    }

    private func isExcluded(
        _ preference: HLSMediaCharacteristicPreference,
        matches: Bool
    ) -> Bool {
        preference == .excluded && matches
    }
}
