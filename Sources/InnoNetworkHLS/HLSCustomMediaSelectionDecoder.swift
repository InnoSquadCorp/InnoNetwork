import Foundation

enum HLSCustomMediaSelectionDecoder {
    static func decode(
        _ data: Data,
        maximumEntryCount: Int
    ) throws -> HLSCustomMediaSelectionScheme {
        do {
            let declarations = try JSONDecoder().decode(
                [RawMediaPresentationType].self,
                from: data
            )
            return try validate(
                declarations,
                maximumEntryCount: maximumEntryCount
            )
        } catch let error as HLSExternalResourceError {
            throw error
        } catch {
            throw HLSExternalResourceError
                .invalidCustomMediaSelectionScheme
        }
    }

    private static func validate(
        _ declarations: [RawMediaPresentationType],
        maximumEntryCount: Int
    ) throws -> HLSCustomMediaSelectionScheme {
        var entryCount = 0
        var kinds: Set<HLSRenditionKind> = []
        var presentations: [HLSMediaPresentationType] = []
        presentations.reserveCapacity(declarations.count)

        for declaration in declarations {
            try addEntries(
                1,
                to: &entryCount,
                maximumEntryCount: maximumEntryCount
            )
            let kind = try parseKind(declaration.type)
            guard kinds.insert(kind).inserted else {
                throw HLSExternalResourceError
                    .invalidCustomMediaSelectionScheme
            }
            let offersLanguageSelection: Bool
            if let languageDisplay = declaration.languageDisplay {
                guard isNonempty(languageDisplay) else {
                    throw HLSExternalResourceError
                        .invalidCustomMediaSelectionScheme
                }
                offersLanguageSelection = languageDisplay != "NONE"
            } else {
                offersLanguageSelection = true
            }

            var selectorIdentifiers: Set<String> = []
            var selectors: [HLSMediaPresentationSelector] = []
            selectors.reserveCapacity(
                declaration.mediaPresentationSettings.count
            )
            for rawSelector in declaration.mediaPresentationSettings {
                try addEntries(
                    1,
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                guard
                    isNonempty(rawSelector.selector),
                    selectorIdentifiers.insert(
                        rawSelector.selector
                    ).inserted,
                    validDisplayNames(rawSelector.displayNames)
                else {
                    throw HLSExternalResourceError
                        .invalidCustomMediaSelectionScheme
                }

                var characteristics: Set<String> = []
                var settings: [HLSMediaPresentationSetting] = []
                settings.reserveCapacity(rawSelector.settings.count)
                for rawSetting in rawSelector.settings {
                    try addEntries(
                        1,
                        to: &entryCount,
                        maximumEntryCount: maximumEntryCount
                    )
                    guard
                        isNonempty(rawSetting.characteristic),
                        characteristics.insert(
                            rawSetting.characteristic
                        ).inserted,
                        let displayNames =
                            rawSetting.displayNames,
                        validDisplayNames(displayNames)
                    else {
                        throw HLSExternalResourceError
                            .invalidCustomMediaSelectionScheme
                    }
                    settings.append(
                        HLSMediaPresentationSetting(
                            characteristic:
                                rawSetting.characteristic,
                            displayNames:
                                displayNames
                        )
                    )
                }
                selectors.append(
                    HLSMediaPresentationSelector(
                        identifier: rawSelector.selector,
                        displayNames: rawSelector.displayNames,
                        settings: settings
                    )
                )
            }

            var decorations: [HLSLanguageDecoration] = []
            decorations.reserveCapacity(
                declaration.languageDecoration?.count ?? 0
            )
            for rawDecoration in declaration.languageDecoration ?? [] {
                try addEntries(
                    1,
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                guard
                    isNonempty(rawDecoration.characteristic),
                    rawDecoration.displayNames.map(
                        validDisplayNames
                    ) ?? true
                else {
                    throw HLSExternalResourceError
                        .invalidCustomMediaSelectionScheme
                }
                decorations.append(
                    HLSLanguageDecoration(
                        characteristic:
                            rawDecoration.characteristic,
                        displayNames:
                            rawDecoration.displayNames
                    )
                )
            }
            presentations.append(
                HLSMediaPresentationType(
                    kind: kind,
                    offersLanguageSelection:
                        offersLanguageSelection,
                    selectors: selectors,
                    languageDecorations: decorations
                )
            )
        }
        return HLSCustomMediaSelectionScheme(
            mediaPresentationTypes: presentations
        )
    }

    private static func parseKind(
        _ value: String
    ) throws -> HLSRenditionKind {
        switch value {
        case "AUDIO":
            return .audio
        case "VIDEO":
            return .video
        case "SUBTITLES":
            return .subtitles
        case "CLOSED-CAPTIONS":
            return .closedCaptions
        default:
            throw HLSExternalResourceError
                .invalidCustomMediaSelectionScheme
        }
    }

    private static func validDisplayNames(
        _ displayNames: [String: String]
    ) -> Bool {
        !displayNames.isEmpty
            && displayNames.allSatisfy {
                isNonempty($0.key) && isNonempty($0.value)
            }
    }

    private static func isNonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    private static func addEntries(
        _ count: Int,
        to entryCount: inout Int,
        maximumEntryCount: Int
    ) throws {
        guard count <= maximumEntryCount - entryCount else {
            throw
                HLSExternalResourceError
                .tooManyCustomMediaSelectionEntries(
                    limit: maximumEntryCount
                )
        }
        entryCount += count
    }
}

private struct RawMediaPresentationType: Decodable {
    let type: String
    let languageDisplay: String?
    let mediaPresentationSettings: [RawPresentationSelector]
    let languageDecoration: [RawPresentationSetting]?

    enum CodingKeys: String, CodingKey {
        case type = "TYPE"
        case languageDisplay = "LANGUAGE-DISPLAY"
        case mediaPresentationSettings =
            "MEDIA-PRESENTATION-SETTINGS"
        case languageDecoration = "LANGUAGE-DECORATION"
    }
}

private struct RawPresentationSelector: Decodable {
    let selector: String
    let displayNames: [String: String]
    let settings: [RawPresentationSetting]

    enum CodingKeys: String, CodingKey {
        case selector = "SELECTOR"
        case displayNames = "DISPLAY-NAMES"
        case settings = "SETTINGS"
    }
}

private struct RawPresentationSetting: Decodable {
    let characteristic: String
    let displayNames: [String: String]?

    enum CodingKeys: String, CodingKey {
        case characteristic = "CHARACTERISTIC"
        case displayNames = "DISPLAY-NAMES"
    }
}
