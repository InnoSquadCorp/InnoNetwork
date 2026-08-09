import AVFoundation
import CoreGraphics
import Foundation

/// Applies typed HLS preferences to a caller-owned `AVPlayerItem`.
///
/// The configurator does not create, retain, enqueue, or play the item.
@MainActor
public struct HLSPlaybackConfigurator {
    /// Creates a stateless playback configurator.
    public init() {}

    /// Validates and applies one complete playback command.
    ///
    /// Media groups are resolved before the item is mutated. On version 26
    /// and newer operating systems, authored Custom Media Selection Schemes
    /// are preferred. Earlier systems select a matching media option directly.
    /// Apply the command before enqueueing the item when it configures
    /// `startsOnFirstEligibleVariant` or a Custom Media Selection Scheme.
    /// The associated player must keep automatic media-selection criteria
    /// enabled for native scheme selections to take effect.
    public func apply(
        _ configuration: HLSPlaybackConfiguration,
        to playerItem: AVPlayerItem
    ) async throws -> HLSPlaybackConfigurationResult {
        try Self.validate(configuration.mediaSelections)

        if #available(macOS 26,
        iOS 26,
        tvOS 26,
        watchOS 26,
        visionOS 26,
        *) {
            let selections = try await resolveModernSelections(
                configuration.mediaSelections,
                asset: playerItem.asset
            )
            applyScalarConfiguration(configuration, to: playerItem)
            applyModernSelections(selections, to: playerItem)
            return HLSPlaybackConfigurationResult(
                mediaSelections: selections.map(\.result)
            )
        }

        let selections = try await resolveLegacySelections(
            configuration.mediaSelections,
            asset: playerItem.asset
        )
        applyScalarConfiguration(configuration, to: playerItem)
        applyLegacySelections(selections, to: playerItem)
        return HLSPlaybackConfigurationResult(
            mediaSelections: selections.map(\.result)
        )
    }

    nonisolated static func validate(
        _ selections: [HLSPlaybackMediaSelection]
    ) throws {
        for selection in selections {
            if case .preferred(let kind, let preference) = selection,
                preference.isEmpty
            {
                throw
                    HLSPlaybackConfigurationError
                    .emptyMediaPreference(kind)
            }
        }

        for (index, selection) in selections.enumerated() {
            guard
                let conflict = selections.dropFirst(index + 1).first(where: {
                    mediaCharacteristic(for: $0.kind)
                        == mediaCharacteristic(for: selection.kind)
                })
            else {
                continue
            }
            throw
                HLSPlaybackConfigurationError
                .conflictingMediaSelections(
                    selection.kind,
                    conflict.kind
                )
        }
    }

    private func applyScalarConfiguration(
        _ configuration: HLSPlaybackConfiguration,
        to playerItem: AVPlayerItem
    ) {
        let variant = configuration.variant
        playerItem.preferredPeakBitRate =
            Double(variant.maximumPeakBitRate ?? 0)
        playerItem.preferredPeakBitRateForExpensiveNetworks =
            Double(
                variant.maximumPeakBitRateForExpensiveNetworks ?? 0
            )
        #if !os(watchOS)
        playerItem.preferredMaximumResolution = size(
            width: variant.maximumWidth,
            height: variant.maximumHeight
        )
        playerItem.preferredMaximumResolutionForExpensiveNetworks =
            size(
                width: variant.maximumWidthForExpensiveNetworks,
                height:
                    variant.maximumHeightForExpensiveNetworks
            )
        #endif
        playerItem.startsOnFirstEligibleVariant =
            variant.startsOnFirstEligibleVariant
        playerItem.variantPreferences =
            variant.permitsLosslessAudio
            ? [.scalabilityToLosslessAudio]
            : []
        playerItem.configuredTimeOffsetFromLive =
            configuration.live.timeOffsetFromLive.map {
                CMTime(seconds: $0, preferredTimescale: 600)
            }
            ?? .invalid
        playerItem.automaticallyHandlesInterstitialEvents =
            configuration.interstitialPolicy == .systemManaged
    }

    #if !os(watchOS)
    private func size(width: Int?, height: Int?) -> CGSize {
        guard let width, let height else {
            return .zero
        }
        return CGSize(width: width, height: height)
    }
    #endif

    private func resolveLegacySelections(
        _ selections: [HLSPlaybackMediaSelection],
        asset: AVAsset
    ) async throws -> [HLSResolvedLegacyPlaybackSelection] {
        var resolved: [HLSResolvedLegacyPlaybackSelection] = []
        resolved.reserveCapacity(selections.count)
        for selection in selections {
            let group = try await loadGroup(
                for: selection.kind,
                asset: asset
            )
            resolved.append(
                try resolveLegacySelection(selection, group: group)
            )
        }
        return resolved
    }

    private func loadGroup(
        for kind: HLSPlaybackMediaKind,
        asset: AVAsset
    ) async throws -> AVMediaSelectionGroup {
        do {
            guard
                let group = try await asset.loadMediaSelectionGroup(
                    for: Self.mediaCharacteristic(for: kind)
                )
            else {
                throw
                    HLSPlaybackConfigurationError
                    .mediaSelectionGroupUnavailable(kind)
            }
            return group
        } catch let error as HLSPlaybackConfigurationError {
            throw error
        } catch {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionGroupUnavailable(kind)
        }
    }

    private func resolveLegacySelection(
        _ selection: HLSPlaybackMediaSelection,
        group: AVMediaSelectionGroup
    ) throws -> HLSResolvedLegacyPlaybackSelection {
        switch selection {
        case .automatic(let kind):
            return HLSResolvedLegacyPlaybackSelection(
                kind: kind,
                group: group,
                action: .automatic
            )
        case .disabled(let kind):
            guard group.allowsEmptySelection else {
                throw
                    HLSPlaybackConfigurationError
                    .emptyMediaSelectionUnavailable(kind)
            }
            return HLSResolvedLegacyPlaybackSelection(
                kind: kind,
                group: group,
                action: .disabled
            )
        case .preferred(let kind, let preference):
            guard
                let option = Self.preferredOption(
                    in: group.options,
                    preference: preference
                )
            else {
                throw
                    HLSPlaybackConfigurationError
                    .mediaSelectionUnavailable(kind)
            }
            return HLSResolvedLegacyPlaybackSelection(
                kind: kind,
                group: group,
                action: .option(option)
            )
        }
    }

    private func applyLegacySelections(
        _ selections: [HLSResolvedLegacyPlaybackSelection],
        to playerItem: AVPlayerItem
    ) {
        for selection in selections {
            switch selection.action {
            case .automatic:
                playerItem.selectMediaOptionAutomatically(
                    in: selection.group
                )
            case .disabled:
                playerItem.select(nil, in: selection.group)
            case .option(let option):
                playerItem.select(option, in: selection.group)
            }
        }
    }

    private static func preferredOption(
        in options: [AVMediaSelectionOption],
        preference: HLSPlaybackMediaPreference
    ) -> AVMediaSelectionOption? {
        let characteristics = preference
            .selectedCharacteristicsBySelector
            .values
            .sorted()
        let candidates = options.enumerated().filter { _, option in
            let hasCharacteristics = characteristics.allSatisfy {
                option.hasMediaCharacteristic(
                    AVMediaCharacteristic(rawValue: $0)
                )
            }
            guard hasCharacteristics else {
                return false
            }
            guard preference.preferredLanguage != nil else {
                return true
            }
            return languageScore(
                option.extendedLanguageTag,
                preferred: preference.preferredLanguage
            ) > 0
        }
        return candidates.max { lhs, rhs in
            let lhsScore = languageScore(
                lhs.element.extendedLanguageTag,
                preferred: preference.preferredLanguage
            )
            let rhsScore = languageScore(
                rhs.element.extendedLanguageTag,
                preferred: preference.preferredLanguage
            )
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return lhs.offset > rhs.offset
        }?.element
    }

    nonisolated private static func languageScore(
        _ available: String?,
        preferred: String?
    ) -> Int {
        guard let preferred else {
            return 0
        }
        let available = normalizedLanguage(available)
        let normalizedPreferred = normalizedLanguage(preferred)
        guard !available.isEmpty, !normalizedPreferred.isEmpty else {
            return 0
        }
        if available == normalizedPreferred {
            return 2
        }
        if available.hasPrefix(normalizedPreferred + "-")
            || normalizedPreferred.hasPrefix(available + "-")
        {
            return 1
        }
        return -1
    }

    nonisolated private static func normalizedLanguage(
        _ language: String?
    ) -> String {
        language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            ?? ""
    }

    nonisolated private static func mediaCharacteristic(
        for kind: HLSPlaybackMediaKind
    ) -> AVMediaCharacteristic {
        switch kind {
        case .audio:
            return .audible
        case .video:
            return .visual
        case .subtitles, .closedCaptions:
            return .legible
        }
    }

    nonisolated static func preferredLanguage(
        _ preferred: String,
        available: [String]
    ) -> String? {
        let normalizedPreferred = normalizedLanguage(preferred)
        if let exact = available.first(where: {
            normalizedLanguage($0) == normalizedPreferred
        }) {
            return exact
        }
        return available.first(where: {
            let normalized = normalizedLanguage($0)
            return normalized.hasPrefix(normalizedPreferred + "-")
                || normalizedPreferred.hasPrefix(normalized + "-")
        })
    }
}

private enum HLSLegacyPlaybackSelectionAction {
    case automatic
    case disabled
    case option(AVMediaSelectionOption)
}

private struct HLSResolvedLegacyPlaybackSelection {
    let kind: HLSPlaybackMediaKind
    let group: AVMediaSelectionGroup
    let action: HLSLegacyPlaybackSelectionAction

    var result: HLSPlaybackAppliedMediaSelection {
        let resolution: HLSPlaybackMediaSelectionResolution
        switch action {
        case .automatic:
            resolution = .automatic
        case .disabled:
            resolution = .disabled
        case .option:
            resolution = .mediaOption
        }
        return HLSPlaybackAppliedMediaSelection(
            kind: kind,
            resolution: resolution
        )
    }
}

@available(
    macOS 26,
    iOS 26,
    tvOS 26,
    watchOS 26,
    visionOS 26,
    *
)
private extension HLSPlaybackConfigurator {
    func resolveModernSelections(
        _ selections: [HLSPlaybackMediaSelection],
        asset: AVAsset
    ) async throws -> [HLSResolvedModernPlaybackSelection] {
        var resolved: [HLSResolvedModernPlaybackSelection] = []
        resolved.reserveCapacity(selections.count)
        for selection in selections {
            let group = try await loadGroup(
                for: selection.kind,
                asset: asset
            )
            switch selection {
            case .preferred(let kind, let preference):
                if let scheme = group.customMediaSelectionScheme {
                    resolved.append(
                        try resolveCustomSelection(
                            kind: kind,
                            preference: preference,
                            group: group,
                            scheme: scheme
                        )
                    )
                } else {
                    resolved.append(
                        .legacy(
                            try resolveLegacySelection(
                                selection,
                                group: group
                            )
                        )
                    )
                }
            case .automatic, .disabled:
                resolved.append(
                    .legacy(
                        try resolveLegacySelection(
                            selection,
                            group: group
                        )
                    )
                )
            }
        }
        return resolved
    }

    func resolveCustomSelection(
        kind: HLSPlaybackMediaKind,
        preference: HLSPlaybackMediaPreference,
        group: AVMediaSelectionGroup,
        scheme: AVCustomMediaSelectionScheme
    ) throws -> HLSResolvedModernPlaybackSelection {
        let language: String?
        if scheme.shouldOfferLanguageSelection,
            let preferredLanguage = preference.preferredLanguage
        {
            guard
                let matched = Self.preferredLanguage(
                    preferredLanguage,
                    available: scheme.availableLanguages
                )
            else {
                throw
                    HLSPlaybackConfigurationError
                    .mediaSelectionUnavailable(kind)
            }
            language = matched
        } else {
            language = nil
        }

        let requested =
            preference.selectedCharacteristicsBySelector
        if !scheme.shouldOfferLanguageSelection,
            preference.preferredLanguage != nil,
            requested.isEmpty
        {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(kind)
        }
        let selectorIDs = Set(scheme.selectors.map(\.identifier))
        guard Set(requested.keys).isSubset(of: selectorIDs) else {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(kind)
        }

        var selections: [HLSNativeMediaPresentationSelection] = []
        for selector in scheme.selectors {
            guard let characteristic = requested[selector.identifier] else {
                continue
            }
            guard
                let setting = selector.settings.first(where: {
                    $0.mediaCharacteristic.rawValue == characteristic
                })
            else {
                throw
                    HLSPlaybackConfigurationError
                    .mediaSelectionUnavailable(kind)
            }
            selections.append(
                HLSNativeMediaPresentationSelection(
                    selector: selector,
                    setting: setting
                )
            )
        }

        for selection in selections {
            let complementary = selections.compactMap {
                $0.selector === selection.selector ? nil : $0.setting
            }
            let available = scheme.mediaPresentationSettings(
                for: selection.selector,
                complementaryToLanguage: language,
                settings: complementary
            )
            guard
                available.contains(where: {
                    $0.isEqual(selection.setting)
                })
            else {
                throw
                    HLSPlaybackConfigurationError
                    .mediaSelectionUnavailable(kind)
            }
        }

        return .custom(
            HLSResolvedCustomPlaybackSelection(
                kind: kind,
                group: group,
                scheme: scheme,
                language: language,
                settings: selections
            )
        )
    }

    func applyModernSelections(
        _ selections: [HLSResolvedModernPlaybackSelection],
        to playerItem: AVPlayerItem
    ) {
        let schemes = selections.compactMap { selection in
            if case .custom(let custom) = selection {
                return custom.scheme
            }
            return nil
        }
        if !schemes.isEmpty {
            var identifiers: Set<ObjectIdentifier> = []
            let merged =
                playerItem.preferredCustomMediaSelectionSchemes
                + schemes
            playerItem.preferredCustomMediaSelectionSchemes =
                merged.filter {
                    identifiers.insert(ObjectIdentifier($0)).inserted
                }
        }

        for selection in selections {
            switch selection {
            case .legacy(let legacy):
                applyLegacySelections([legacy], to: playerItem)
            case .custom(let custom):
                if let language = custom.language {
                    playerItem.selectMediaPresentationLanguage(
                        language,
                        for: custom.group
                    )
                }
                for setting in custom.settings {
                    playerItem.select(
                        setting.setting,
                        for: custom.group
                    )
                }
            }
        }
    }
}

@available(
    macOS 26,
    iOS 26,
    tvOS 26,
    watchOS 26,
    visionOS 26,
    *
)
private struct HLSNativeMediaPresentationSelection {
    let selector: AVMediaPresentationSelector
    let setting: AVMediaPresentationSetting
}

@available(
    macOS 26,
    iOS 26,
    tvOS 26,
    watchOS 26,
    visionOS 26,
    *
)
private struct HLSResolvedCustomPlaybackSelection {
    let kind: HLSPlaybackMediaKind
    let group: AVMediaSelectionGroup
    let scheme: AVCustomMediaSelectionScheme
    let language: String?
    let settings: [HLSNativeMediaPresentationSelection]

    var result: HLSPlaybackAppliedMediaSelection {
        HLSPlaybackAppliedMediaSelection(
            kind: kind,
            resolution: .customScheme
        )
    }
}

@available(
    macOS 26,
    iOS 26,
    tvOS 26,
    watchOS 26,
    visionOS 26,
    *
)
private enum HLSResolvedModernPlaybackSelection {
    case legacy(HLSResolvedLegacyPlaybackSelection)
    case custom(HLSResolvedCustomPlaybackSelection)

    var result: HLSPlaybackAppliedMediaSelection {
        switch self {
        case .legacy(let legacy):
            return legacy.result
        case .custom(let custom):
            return custom.result
        }
    }
}
