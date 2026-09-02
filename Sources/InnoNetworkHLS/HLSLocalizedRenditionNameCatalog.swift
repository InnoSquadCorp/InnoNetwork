/// A resolved `_hls.localized-rendition-names` localization dictionary.
public struct HLSLocalizedRenditionNameCatalog: Equatable, Sendable {
    /// The Session Data identifier reserved for rendition-name localization.
    public static let sessionDataID =
        "_hls.localized-rendition-names"

    /// Localized names keyed first by the authored `EXT-X-MEDIA` name and
    /// then by primary language subtag.
    public let translations: [String: [String: String]]

    /// Unique primary language subtags in deterministic lexical order.
    public var availableLanguages: [String] {
        Set(
            translations.values.flatMap { names in
                names.keys.map(HLSPreferredLanguageResolver.normalize)
            }
        ).sorted()
    }

    /// Returns the localized base name for a rendition.
    ///
    /// Ordered locale preferences use exact or compatible BCP 47 tag-prefix
    /// matches. The authored rendition name is returned when the dictionary
    /// has no matching translation, as required by the HLS base-name
    /// selection procedure. Platform-specific name decoration remains with
    /// the application or AVKit.
    public func localizedName(
        for rendition: HLSRendition,
        preferredLanguages: [String]
    ) -> String {
        localizedName(
            for: rendition.name,
            preferredLanguages: preferredLanguages
        )
    }

    private func localizedName(
        for renditionName: String,
        preferredLanguages: [String]
    ) -> String {
        guard let localizedNames = translations[renditionName] else {
            return renditionName
        }
        return HLSPreferredLanguageResolver.resolve(
            localizedNames,
            preferredLanguages: preferredLanguages
        ) ?? renditionName
    }

    init(translations: [String: [String: String]]) {
        self.translations = translations
    }
}
