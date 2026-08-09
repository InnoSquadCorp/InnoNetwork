import Foundation

/// A resolved `_hls.media-presentation-settings` Session Data resource.
public struct HLSCustomMediaSelectionScheme: Equatable, Sendable {
    /// The Session Data identifier reserved for this scheme.
    public static let sessionDataID =
        "_hls.media-presentation-settings"

    /// Media-type declarations in source order.
    public let mediaPresentationTypes: [HLSMediaPresentationType]

    /// Returns the declaration for one HLS rendition kind.
    public func presentation(
        for kind: HLSRenditionKind
    ) -> HLSMediaPresentationType? {
        mediaPresentationTypes.first { $0.kind == kind }
    }
}

/// Custom selection metadata for one `EXT-X-MEDIA` type.
public struct HLSMediaPresentationType: Equatable, Sendable {
    /// The rendition kind controlled by this declaration.
    public let kind: HLSRenditionKind

    /// Whether an application should offer language as a separate preference.
    public let offersLanguageSelection: Bool

    /// Mutually exclusive selector collections, from highest to lowest
    /// priority.
    public let selectors: [HLSMediaPresentationSelector]

    /// Ordered rules that can decorate a displayed language name.
    public let languageDecorations: [HLSLanguageDecoration]

    /// Applies the first matching language-decoration rule.
    ///
    /// The supplied `languageName` remains unchanged when the rendition does
    /// not match a declared decoration or the declaration has no localized
    /// display name.
    public func decoratedLanguageName(
        _ languageName: String,
        for rendition: HLSRendition,
        preferredDisplayLanguages: [String]
    ) -> String {
        guard
            rendition.kind == kind,
            let decoration = languageDecorations.first(where: {
                rendition.characteristics.contains($0.characteristic)
            }),
            let template = decoration.localizedName(
                preferredLanguages: preferredDisplayLanguages
            )
        else {
            return languageName
        }
        if template.contains("${language}") {
            return template.replacingOccurrences(
                of: "${language}",
                with: languageName
            )
        }
        return template
    }
}

/// One prioritized collection of mutually exclusive presentation settings.
public struct HLSMediaPresentationSelector: Equatable, Sendable {
    /// The short identifier referenced by application preferences.
    public let identifier: String

    /// Localized selector names keyed by BCP 47 language tag.
    public let displayNames: [String: String]

    /// Settings offered by this selector in source order.
    public let settings: [HLSMediaPresentationSetting]

    /// Selects a deterministic localized display name.
    public func localizedName(
        preferredLanguages: [String]
    ) -> String? {
        HLSLocalizedDisplayNameResolver.resolve(
            displayNames,
            preferredLanguages: preferredLanguages
        )
    }
}

/// One selectable media characteristic in a presentation selector.
public struct HLSMediaPresentationSetting: Equatable, Sendable {
    /// The exact Media Characteristic Tag matched against `EXT-X-MEDIA`.
    public let characteristic: String

    /// Localized setting names keyed by BCP 47 language tag.
    public let displayNames: [String: String]

    /// Selects a deterministic localized display name.
    public func localizedName(
        preferredLanguages: [String]
    ) -> String? {
        HLSLocalizedDisplayNameResolver.resolve(
            displayNames,
            preferredLanguages: preferredLanguages
        )
    }
}

/// One characteristic-driven language decoration.
public struct HLSLanguageDecoration: Equatable, Sendable {
    /// The exact Media Characteristic Tag that activates this decoration.
    public let characteristic: String

    /// Optional localized templates keyed by BCP 47 language tag.
    public let displayNames: [String: String]?

    /// Selects a deterministic localized display template.
    public func localizedName(
        preferredLanguages: [String]
    ) -> String? {
        guard let displayNames else {
            return nil
        }
        return HLSLocalizedDisplayNameResolver.resolve(
            displayNames,
            preferredLanguages: preferredLanguages
        )
    }
}

/// User preferences applied to a Custom Media Selection Scheme.
public struct HLSCustomMediaSelectionPreferences: Equatable, Sendable {
    /// The preferred BCP 47 language, when language selection is offered.
    public let preferredLanguage: String?

    /// Selected Media Characteristic Tags keyed by selector identifier.
    public let selectedCharacteristicsBySelector: [String: String]

    /// Creates custom media preferences.
    public init(
        preferredLanguage: String? = nil,
        selectedCharacteristicsBySelector: [String: String] = [:]
    ) {
        self.preferredLanguage = preferredLanguage
        self.selectedCharacteristicsBySelector =
            selectedCharacteristicsBySelector
    }
}

private enum HLSLocalizedDisplayNameResolver {
    static func resolve(
        _ displayNames: [String: String],
        preferredLanguages: [String]
    ) -> String? {
        let entries = displayNames.sorted { $0.key < $1.key }
        for preferredLanguage in preferredLanguages {
            let normalized = normalize(preferredLanguage)
            if let exact = entries.first(where: {
                normalize($0.key) == normalized
            }) {
                return exact.value
            }
            if let compatible = entries.first(where: {
                languagesMatch(normalize($0.key), normalized)
            }) {
                return compatible.value
            }
        }
        return entries.first?.value
    }

    private static func normalize(_ language: String) -> String {
        language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func languagesMatch(
        _ available: String,
        _ preferred: String
    ) -> Bool {
        guard !available.isEmpty, !preferred.isEmpty else {
            return false
        }
        return available.hasPrefix(preferred + "-")
            || preferred.hasPrefix(available + "-")
    }
}
