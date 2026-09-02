import Foundation

/// The AVFoundation media-selection group controlled by a playback request.
public enum HLSPlaybackMediaKind: Equatable, Sendable {
    /// Alternate or supplemental audio.
    case audio

    /// Alternate video, such as another camera angle.
    case video

    /// Subtitle or other legible media.
    case subtitles

    /// Closed-caption media exposed through the legible group.
    case closedCaptions
}

/// Custom Media Selection preferences expressed in HLS-authored identifiers.
public struct HLSPlaybackMediaPreference: Equatable, Sendable {
    /// Preferred BCP 47 language, when the media scheme offers languages.
    public let preferredLanguage: String?

    /// Selected Media Characteristic Tags keyed by authored selector ID.
    public let selectedCharacteristicsBySelector: [String: String]

    /// Creates a custom media preference.
    public init(
        preferredLanguage: String? = nil,
        selectedCharacteristicsBySelector: [String: String] = [:]
    ) {
        let language = preferredLanguage?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.preferredLanguage =
            language?.isEmpty == false ? language : nil
        self.selectedCharacteristicsBySelector =
            selectedCharacteristicsBySelector
    }

    var isEmpty: Bool {
        preferredLanguage == nil
            && selectedCharacteristicsBySelector.isEmpty
    }
}

/// One explicit media-selection command.
public enum HLSPlaybackMediaSelection: Equatable, Sendable {
    /// Restores AVFoundation's automatic selection for the group.
    case automatic(HLSPlaybackMediaKind)

    /// Deselects the group when its author permits an empty selection.
    case disabled(HLSPlaybackMediaKind)

    /// Applies an authored language and Custom Media Selection preference.
    case preferred(
        HLSPlaybackMediaKind,
        HLSPlaybackMediaPreference
    )

    /// The media kind controlled by this command.
    public var kind: HLSPlaybackMediaKind {
        switch self {
        case .automatic(let kind),
            .disabled(let kind),
            .preferred(let kind, _):
            return kind
        }
    }
}

/// Groups HLS variant limits applied to an `AVPlayerItem`.
public struct HLSPlaybackVariantPack: Equatable, Sendable {
    /// Maximum peak bit rate in bits per second, or `nil` for no limit.
    public let maximumPeakBitRate: Int?

    /// Maximum peak bit rate on expensive networks, or `nil` for no limit.
    public let maximumPeakBitRateForExpensiveNetworks: Int?

    /// Maximum video width, or `nil` for no limit.
    ///
    /// Width and height are retained only when both are positive.
    public let maximumWidth: Int?

    /// Maximum video height, or `nil` for no limit.
    ///
    /// Width and height are retained only when both are positive.
    public let maximumHeight: Int?

    /// Maximum width on expensive networks, or `nil` for no limit.
    ///
    /// Width and height are retained only when both are positive.
    public let maximumWidthForExpensiveNetworks: Int?

    /// Maximum height on expensive networks, or `nil` for no limit.
    ///
    /// Width and height are retained only when both are positive.
    public let maximumHeightForExpensiveNetworks: Int?

    /// Whether variants with lossless audio may participate in adaptation.
    public let permitsLosslessAudio: Bool

    /// Whether startup should use the first eligible declared variant.
    public let startsOnFirstEligibleVariant: Bool

    /// Creates bounded variant preferences.
    ///
    /// Nonpositive limits become `nil`, which restores AVFoundation's
    /// automatic behavior for that field.
    public init(
        maximumPeakBitRate: Int? = nil,
        maximumPeakBitRateForExpensiveNetworks: Int? = nil,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil,
        maximumWidthForExpensiveNetworks: Int? = nil,
        maximumHeightForExpensiveNetworks: Int? = nil,
        permitsLosslessAudio: Bool = false,
        startsOnFirstEligibleVariant: Bool = false
    ) {
        let peakBitRate = Self.positive(maximumPeakBitRate)
        self.maximumPeakBitRate = peakBitRate
        self.maximumPeakBitRateForExpensiveNetworks = Self.tighterLimit(
            Self.positive(maximumPeakBitRateForExpensiveNetworks),
            than: peakBitRate
        )
        let maximumResolution = Self.resolution(
            width: maximumWidth,
            height: maximumHeight
        )
        self.maximumWidth = maximumResolution.width
        self.maximumHeight = maximumResolution.height
        let expensiveResolution = Self.resolution(
            width: maximumWidthForExpensiveNetworks,
            height: maximumHeightForExpensiveNetworks
        )
        self.maximumWidthForExpensiveNetworks = Self.tighterLimit(
            expensiveResolution.width,
            than: maximumResolution.width
        )
        self.maximumHeightForExpensiveNetworks = Self.tighterLimit(
            expensiveResolution.height,
            than: maximumResolution.height
        )
        self.permitsLosslessAudio = permitsLosslessAudio
        self.startsOnFirstEligibleVariant =
            startsOnFirstEligibleVariant
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
    }

    private static func resolution(
        width: Int?,
        height: Int?
    ) -> (width: Int?, height: Int?) {
        guard
            let width = positive(width),
            let height = positive(height)
        else {
            return (nil, nil)
        }
        return (width, height)
    }

    private static func tighterLimit(
        _ value: Int?,
        than unconditional: Int?
    ) -> Int? {
        guard let unconditional else {
            return value
        }
        return value.map { min($0, unconditional) }
    }
}

/// Groups live-edge behavior applied to an `AVPlayerItem`.
public struct HLSPlaybackLivePack: Equatable, Sendable {
    /// Desired distance from the live edge, or `nil` for system behavior.
    public let timeOffsetFromLive: TimeInterval?

    /// Creates live-edge preferences.
    ///
    /// Negative and non-finite offsets become `nil`.
    public init(timeOffsetFromLive: TimeInterval? = nil) {
        guard
            let timeOffsetFromLive,
            timeOffsetFromLive.isFinite,
            timeOffsetFromLive >= 0
        else {
            self.timeOffsetFromLive = nil
            return
        }
        self.timeOffsetFromLive = timeOffsetFromLive
    }
}

/// Controls playback of server-authored HLS interstitial events.
public enum HLSPlaybackInterstitialPolicy: Equatable, Sendable {
    /// Allows AVFoundation to schedule server-authored interstitials.
    case systemManaged

    /// Prevents automatic scheduling of future server-authored interstitials.
    case disabled
}

/// An immutable command for configuring one caller-owned `AVPlayerItem`.
public struct HLSPlaybackConfiguration: Equatable, Sendable {
    /// Variant and network-cost limits.
    public let variant: HLSPlaybackVariantPack

    /// Live-edge preferences.
    public let live: HLSPlaybackLivePack

    /// Server-authored interstitial behavior.
    public let interstitialPolicy: HLSPlaybackInterstitialPolicy

    /// Explicit media-selection commands.
    public let mediaSelections: [HLSPlaybackMediaSelection]

    private init(
        variant: HLSPlaybackVariantPack,
        live: HLSPlaybackLivePack,
        interstitialPolicy: HLSPlaybackInterstitialPolicy,
        mediaSelections: [HLSPlaybackMediaSelection]
    ) {
        self.variant = variant
        self.live = live
        self.interstitialPolicy = interstitialPolicy
        self.mediaSelections = mediaSelections
    }

    /// Returns system-managed playback behavior.
    public static func safeDefaults() -> HLSPlaybackConfiguration {
        advanced()
    }

    /// Returns an explicitly tuned playback command.
    public static func advanced(
        variant: HLSPlaybackVariantPack = HLSPlaybackVariantPack(),
        live: HLSPlaybackLivePack = HLSPlaybackLivePack(),
        interstitialPolicy: HLSPlaybackInterstitialPolicy =
            .systemManaged,
        mediaSelections: [HLSPlaybackMediaSelection] = []
    ) -> HLSPlaybackConfiguration {
        HLSPlaybackConfiguration(
            variant: variant,
            live: live,
            interstitialPolicy: interstitialPolicy,
            mediaSelections: mediaSelections
        )
    }
}

/// How one media-selection command was applied.
public enum HLSPlaybackMediaSelectionResolution: Equatable, Sendable {
    /// AVFoundation automatic selection was restored.
    case automatic

    /// The group was deselected.
    case disabled

    /// The operating system's Custom Media Selection Scheme was used.
    case customScheme

    /// A compatible media option was selected directly.
    case mediaOption
}

/// Redacted result for one applied media-selection command.
public struct HLSPlaybackAppliedMediaSelection: Equatable, Sendable {
    /// The configured media group.
    public let kind: HLSPlaybackMediaKind

    /// The mechanism used to apply the command.
    public let resolution: HLSPlaybackMediaSelectionResolution
}

/// Redacted result of applying a playback configuration.
public struct HLSPlaybackConfigurationResult: Equatable, Sendable {
    /// Media-selection commands in caller order.
    public let mediaSelections: [HLSPlaybackAppliedMediaSelection]
}

/// Typed configuration failures that do not retain asset or media URLs.
public enum HLSPlaybackConfigurationError: Error, Equatable, Sendable {
    /// More than one command targeted the same AVFoundation media group.
    case conflictingMediaSelections(
        HLSPlaybackMediaKind,
        HLSPlaybackMediaKind
    )

    /// A preferred command did not specify a language or characteristic.
    case emptyMediaPreference(HLSPlaybackMediaKind)

    /// The asset did not expose the requested media group.
    case mediaSelectionGroupUnavailable(HLSPlaybackMediaKind)

    /// The group does not permit an empty selection.
    case emptyMediaSelectionUnavailable(HLSPlaybackMediaKind)

    /// No compatible language, selector, setting, or option was available.
    case mediaSelectionUnavailable(HLSPlaybackMediaKind)
}

extension HLSPlaybackConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .conflictingMediaSelections:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.conflictingMediaSelections"
            )
        case .emptyMediaPreference:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.emptyMediaPreference"
            )
        case .mediaSelectionGroupUnavailable:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.mediaSelectionGroupUnavailable"
            )
        case .emptyMediaSelectionUnavailable:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.emptyMediaSelectionUnavailable"
            )
        case .mediaSelectionUnavailable:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.mediaSelectionUnavailable"
            )
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .conflictingMediaSelections:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.recovery.removeConflict"
            )
        case .emptyMediaPreference:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.recovery.addPreference"
            )
        case .mediaSelectionGroupUnavailable,
            .emptyMediaSelectionUnavailable,
            .mediaSelectionUnavailable:
            playbackConfigurationLocalized(
                "HLSPlaybackConfigurationError.recovery.refreshAsset"
            )
        }
    }
}

@inline(__always)
private func playbackConfigurationLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: .module,
        comment: "AVFoundation HLS playback configuration diagnostic"
    )
}
