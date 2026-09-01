import Foundation

enum HLSPreferredLanguageResolver {
    static func resolve<Element>(
        _ elements: [Element],
        preferredLanguages: [String],
        language: (Element) -> String
    ) -> Element? {
        for preferredLanguage in preferredLanguages {
            let normalizedPreference = normalize(preferredLanguage)
            if let exact = elements.first(where: {
                normalize(language($0)) == normalizedPreference
            }) {
                return exact
            }
            if let compatible = elements.first(where: {
                languagesMatch(
                    normalize(language($0)),
                    normalizedPreference
                )
            }) {
                return compatible
            }
        }
        return nil
    }

    static func normalize(_ language: String) -> String {
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
