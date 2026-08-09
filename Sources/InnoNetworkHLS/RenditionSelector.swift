import Foundation

/// Controls deterministic selection inside one rendition group.
public enum HLSRenditionSelectionPolicy: Equatable, Sendable {
    /// Selects the advertised default, then an autoselect rendition, then the
    /// first playlist entry.
    case defaultOrFirst

    /// Selects the earliest preferred language, falling back to
    /// ``defaultOrFirst`` when no language matches.
    case preferredLanguages([String])

    /// Selects the rendition whose name exactly matches this value.
    case named(String)

    /// Selects no rendition.
    case disabled
}

/// Selects alternate audio or subtitle metadata deterministically.
public struct RenditionSelector: Sendable {
    /// Creates a rendition selector.
    public init() {}

    /// Selects one rendition from a referenced group.
    public func select(
        in playlist: HLSPlaylist,
        groupID: String,
        kind: HLSRenditionKind,
        policy: HLSRenditionSelectionPolicy
    ) -> HLSRendition? {
        let renditions = playlist.renditions.filter {
            $0.groupID == groupID && $0.kind == kind
        }
        switch policy {
        case .disabled:
            return nil
        case .defaultOrFirst:
            return defaultOrFirst(in: renditions)
        case .preferredLanguages(let languages):
            for language in languages {
                let normalized = Self.normalizedLanguage(language)
                if let exactMatch = renditions.first(where: {
                    Self.normalizedLanguage($0.language) == normalized
                }) {
                    return exactMatch
                }
                if let fallbackMatch = renditions.first(where: {
                    Self.languagesMatch(
                        Self.normalizedLanguage($0.language),
                        normalized
                    )
                }) {
                    return fallbackMatch
                }
            }
            return defaultOrFirst(in: renditions)
        case .named(let name):
            return renditions.first { $0.name == name }
        }
    }

    private func defaultOrFirst(
        in renditions: [HLSRendition]
    ) -> HLSRendition? {
        renditions.first(where: \.isDefault)
            ?? renditions.first(where: \.isAutoselect)
            ?? renditions.first
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            ?? ""
    }

    private static func languagesMatch(
        _ renditionLanguage: String,
        _ preferredLanguage: String
    ) -> Bool {
        guard !renditionLanguage.isEmpty, !preferredLanguage.isEmpty else {
            return false
        }
        return renditionLanguage == preferredLanguage
            || renditionLanguage.hasPrefix(preferredLanguage + "-")
            || preferredLanguage.hasPrefix(renditionLanguage + "-")
    }
}
