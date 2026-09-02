import Foundation

enum HLSLocalizedRenditionNameDecoder {
    static func decode(
        _ data: Data,
        maximumEntryCount: Int
    ) throws -> HLSLocalizedRenditionNameCatalog {
        do {
            let translations = try JSONDecoder().decode(
                [String: [String: String]].self,
                from: data
            )
            return try validate(
                translations,
                maximumEntryCount: maximumEntryCount
            )
        } catch let error as HLSExternalResourceError {
            throw error
        } catch {
            throw HLSExternalResourceError
                .invalidLocalizedRenditionNames
        }
    }

    private static func validate(
        _ translations: [String: [String: String]],
        maximumEntryCount: Int
    ) throws -> HLSLocalizedRenditionNameCatalog {
        guard !translations.isEmpty else {
            throw HLSExternalResourceError
                .invalidLocalizedRenditionNames
        }
        var entryCount = 0
        for (sourceName, localizedNames) in translations {
            try addEntry(
                to: &entryCount,
                maximumEntryCount: maximumEntryCount
            )
            guard isSafeText(sourceName), !localizedNames.isEmpty else {
                throw HLSExternalResourceError
                    .invalidLocalizedRenditionNames
            }
            var languageIdentities: Set<String> = []
            for (language, localizedName) in localizedNames {
                try addEntry(
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                let identity = HLSPreferredLanguageResolver.normalize(
                    language
                )
                guard
                    isPrimaryLanguageSubtag(language),
                    languageIdentities.insert(identity).inserted,
                    isSafeText(localizedName)
                else {
                    throw HLSExternalResourceError
                        .invalidLocalizedRenditionNames
                }
            }
        }
        return HLSLocalizedRenditionNameCatalog(
            translations: translations
        )
    }

    private static func addEntry(
        to entryCount: inout Int,
        maximumEntryCount: Int
    ) throws {
        guard entryCount < maximumEntryCount else {
            throw
                HLSExternalResourceError
                .tooManyLocalizedRenditionNameEntries(
                    limit: maximumEntryCount
                )
        }
        entryCount += 1
    }

    private static func isPrimaryLanguageSubtag(
        _ value: String
    ) -> Bool {
        let bytes = Array(value.utf8)
        return (2...8).contains(bytes.count)
            && bytes.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
            }
    }

    private static func isSafeText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}
