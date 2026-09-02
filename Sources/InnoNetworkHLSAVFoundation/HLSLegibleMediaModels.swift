import Foundation

/// The underlying form of one legible media option.
public enum HLSLegibleMediaKind: Equatable, Hashable, Sendable {
    /// Subtitle or timed-text media.
    case subtitles

    /// In-band or out-of-band closed captions.
    case closedCaptions

    /// A future AVFoundation legible media type.
    case other
}

/// Authored provenance advertised by a legible media option.
public enum HLSLegibleMediaProvenance: Equatable, Hashable, Sendable {
    /// The option was authored or translated programmatically.
    case machineGenerated

    /// The option is marked as a translation.
    case translated
}

/// A presentation feature advertised by a legible media option.
public enum HLSLegibleMediaFeature: Equatable, Hashable, Sendable {
    /// The option contains only forced narrative subtitles.
    case forcedNarrative

    /// The option transcribes spoken dialogue for accessibility.
    case transcribesSpokenDialogue

    /// The option describes music and sound for accessibility.
    case describesMusicAndSound

    /// The option is authored for easier reading.
    case easyToRead
}

/// An opaque identifier for one option in an asset's legible media group.
///
/// Identifiers contain only a fingerprint of AVFoundation's property-list
/// identity. Use them with the same player item and refresh the catalog when
/// its asset changes. Do not persist them as content identifiers.
public struct HLSLegibleMediaOptionID: Equatable, Hashable, Sendable {
    fileprivate let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }
}

/// A Sendable value for one selectable subtitle or caption option.
public struct HLSLegibleMediaOption: Equatable, Sendable {
    /// The opaque, asset-scoped selection identifier.
    public let id: HLSLegibleMediaOptionID

    /// A display name localized for the catalog request.
    public let displayName: String

    /// The option's IETF BCP 47 language tag, when authored.
    public let languageTag: String?

    /// Whether the option is subtitle, caption, or future legible media.
    public let kind: HLSLegibleMediaKind

    /// Machine-generated and translated provenance advertised by the option.
    ///
    /// An empty set means the asset did not advertise either characteristic;
    /// it does not prove human authorship.
    public let provenance: Set<HLSLegibleMediaProvenance>

    /// Accessibility and presentation features advertised by the option.
    public let features: Set<HLSLegibleMediaFeature>

    /// Whether the player item currently selects this option.
    public let isSelected: Bool

    /// Whether the asset designates this option as its default.
    public let isDefault: Bool

    init(
        id: HLSLegibleMediaOptionID,
        displayName: String,
        languageTag: String?,
        kind: HLSLegibleMediaKind,
        provenance: Set<HLSLegibleMediaProvenance>,
        features: Set<HLSLegibleMediaFeature>,
        isSelected: Bool,
        isDefault: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.languageTag = languageTag
        self.kind = kind
        self.provenance = provenance
        self.features = features
        self.isSelected = isSelected
        self.isDefault = isDefault
    }
}

/// A point-in-time, Sendable catalog for a player item's legible media group.
public struct HLSLegibleMediaCatalog: Equatable, Sendable {
    /// Playable options in AVFoundation order.
    public let options: [HLSLegibleMediaOption]

    /// Whether the player item can select no legible media.
    public let allowsEmptySelection: Bool

    init(
        options: [HLSLegibleMediaOption],
        allowsEmptySelection: Bool
    ) {
        self.options = options
        self.allowsEmptySelection = allowsEmptySelection
    }
}

/// One exact custom-player legible media command.
public enum HLSLegibleMediaSelection: Equatable, Sendable {
    /// Restores AVFoundation's automatic legible media selection.
    case automatic

    /// Deselects legible media when the asset permits it.
    case disabled

    /// Selects the matching option from a current catalog.
    case option(HLSLegibleMediaOptionID)
}
