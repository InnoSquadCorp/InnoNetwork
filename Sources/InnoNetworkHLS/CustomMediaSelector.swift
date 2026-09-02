import Foundation

/// Selects a rendition using a Custom Media Selection Scheme.
public struct CustomMediaSelector: Sendable {
    /// Creates a custom media selector.
    public init() {}

    /// Selects one rendition from a referenced group.
    ///
    /// Language has the highest priority when the scheme offers it. Requested
    /// settings are then honored in the selector order declared by the
    /// scheme. Playlist default and autoselect flags break equal-score ties.
    public func select(
        in playlist: HLSPlaylist,
        groupID: String,
        kind: HLSRenditionKind,
        scheme: HLSCustomMediaSelectionScheme,
        preferences: HLSCustomMediaSelectionPreferences
    ) -> HLSRendition? {
        let renditions = playlist.renditions.filter {
            $0.groupID == groupID && $0.kind == kind
        }
        guard
            !renditions.isEmpty,
            let presentation = scheme.presentation(for: kind)
        else {
            return nil
        }

        return renditions.enumerated().max { lhs, rhs in
            compare(
                lhs,
                rhs,
                presentation: presentation,
                preferences: preferences
            )
        }?.element
    }

    private func compare(
        _ lhs: EnumeratedSequence<[HLSRendition]>.Element,
        _ rhs: EnumeratedSequence<[HLSRendition]>.Element,
        presentation: HLSMediaPresentationType,
        preferences: HLSCustomMediaSelectionPreferences
    ) -> Bool {
        let lhsScore = score(
            lhs.element,
            presentation: presentation,
            preferences: preferences
        )
        let rhsScore = score(
            rhs.element,
            presentation: presentation,
            preferences: preferences
        )
        if lhsScore != rhsScore {
            return lhsScore.lexicographicallyPrecedes(rhsScore)
        }
        let lhsFallback = fallbackScore(lhs.element)
        let rhsFallback = fallbackScore(rhs.element)
        if lhsFallback != rhsFallback {
            return lhsFallback < rhsFallback
        }
        return lhs.offset > rhs.offset
    }

    private func score(
        _ rendition: HLSRendition,
        presentation: HLSMediaPresentationType,
        preferences: HLSCustomMediaSelectionPreferences
    ) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(presentation.selectors.count + 1)
        result.append(
            languageScore(
                rendition.language,
                presentation: presentation,
                preferredLanguage: preferences.preferredLanguage
            )
        )
        for selector in presentation.selectors {
            guard
                let characteristic =
                    preferences.selectedCharacteristicsBySelector[
                        selector.identifier
                    ],
                selector.settings.contains(where: {
                    $0.characteristic == characteristic
                })
            else {
                result.append(0)
                continue
            }
            result.append(
                rendition.characteristics.contains(characteristic)
                    ? 1
                    : 0
            )
        }
        return result
    }

    private func languageScore(
        _ renditionLanguage: String?,
        presentation: HLSMediaPresentationType,
        preferredLanguage: String?
    ) -> Int {
        guard
            presentation.offersLanguageSelection,
            let preferredLanguage
        else {
            return 0
        }
        let rendition = Self.normalize(renditionLanguage)
        let preferred = Self.normalize(preferredLanguage)
        guard !rendition.isEmpty, !preferred.isEmpty else {
            return 0
        }
        if rendition == preferred {
            return 2
        }
        if rendition.hasPrefix(preferred + "-")
            || preferred.hasPrefix(rendition + "-")
        {
            return 1
        }
        return 0
    }

    private func fallbackScore(_ rendition: HLSRendition) -> Int {
        if rendition.isDefault {
            return 2
        }
        if rendition.isAutoselect {
            return 1
        }
        return 0
    }

    private static func normalize(_ language: String?) -> String {
        language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            ?? ""
    }
}
