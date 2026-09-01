import Foundation

enum HLSChapterDecoder {
    private static let maximumMetadataDepth = 16

    static func decode(
        _ data: Data,
        relativeTo documentURL: URL,
        maximumChapterCount: Int,
        maximumEntryCount: Int
    ) throws -> HLSChapterCatalog {
        do {
            let rawChapters = try JSONDecoder().decode(
                [RawChapter].self,
                from: data
            )
            guard rawChapters.count <= maximumChapterCount else {
                throw HLSExternalResourceError.tooManyChapters(
                    limit: maximumChapterCount
                )
            }
            return try validate(
                rawChapters,
                relativeTo: documentURL,
                maximumEntryCount: maximumEntryCount
            )
        } catch let error as HLSExternalResourceError {
            throw error
        } catch {
            throw HLSExternalResourceError.invalidChapterData
        }
    }

    private static func validate(
        _ rawChapters: [RawChapter],
        relativeTo documentURL: URL,
        maximumEntryCount: Int
    ) throws -> HLSChapterCatalog {
        var entryCount = 0
        var chapters: [HLSChapter] = []
        chapters.reserveCapacity(rawChapters.count)

        for (index, rawChapter) in rawChapters.enumerated() {
            try addEntry(
                to: &entryCount,
                maximumEntryCount: maximumEntryCount
            )
            guard
                isNonnegativeFinite(rawChapter.startTime),
                rawChapter.chapterNumber.map(isPositiveFinite) ?? true,
                rawChapter.duration.map(isPositiveFinite) ?? true
            else {
                throw HLSExternalResourceError.invalidChapterData
            }

            var titleLanguages: Set<String> = []
            let titles = try rawChapter.titles.map { rawTitle in
                try addEntry(
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                guard
                    isSafeText(rawTitle.language),
                    isSafeText(rawTitle.title),
                    titleLanguages.insert(
                        normalizeLanguage(rawTitle.language)
                    ).inserted
                else {
                    throw HLSExternalResourceError.invalidChapterData
                }
                return HLSChapterTitle(
                    language: rawTitle.language,
                    title: rawTitle.title
                )
            }

            let images = try rawChapter.images.map { rawImage in
                try addEntry(
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                guard
                    isSafeText(rawImage.category),
                    rawImage.pixelWidth > 0,
                    rawImage.pixelHeight > 0,
                    isSafeText(rawImage.url),
                    let url = URL(
                        string: rawImage.url,
                        relativeTo: documentURL
                    )?.absoluteURL,
                    isAdmittedImageURL(
                        url,
                        documentURL: documentURL
                    )
                else {
                    throw HLSExternalResourceError.invalidChapterData
                }
                return HLSChapterImage(
                    category: rawImage.category,
                    pixelWidth: rawImage.pixelWidth,
                    pixelHeight: rawImage.pixelHeight,
                    url: url
                )
            }

            var metadataIdentities: Set<MetadataIdentity> = []
            let metadata = try rawChapter.metadata.map { rawMetadata in
                try addEntry(
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                guard
                    isSafeText(rawMetadata.key),
                    rawMetadata.language.map(isSafeText) ?? true,
                    metadataIdentities.insert(
                        MetadataIdentity(
                            key: rawMetadata.key,
                            language: rawMetadata.language.map(
                                normalizeLanguage
                            )
                        )
                    ).inserted
                else {
                    throw HLSExternalResourceError.invalidChapterData
                }
                return HLSChapterMetadata(
                    key: rawMetadata.key,
                    language: rawMetadata.language,
                    value: try convertRootMetadataValue(
                        rawMetadata.value,
                        entryCount: &entryCount,
                        maximumEntryCount: maximumEntryCount
                    )
                )
            }

            let duration: TimeInterval?
            if let declaredDuration = rawChapter.duration {
                duration = declaredDuration
            } else if index < rawChapters.index(before: rawChapters.endIndex) {
                let inferred =
                    rawChapters[index + 1].startTime
                    - rawChapter.startTime
                guard isPositiveFinite(inferred) else {
                    throw HLSExternalResourceError.invalidChapterData
                }
                duration = inferred
            } else {
                duration = nil
            }

            chapters.append(
                HLSChapter(
                    chapterNumber: rawChapter.chapterNumber,
                    startTime: rawChapter.startTime,
                    duration: duration,
                    titles: titles,
                    images: images,
                    metadata: metadata
                )
            )
        }
        return HLSChapterCatalog(chapters: chapters)
    }

    private static func convert(
        _ value: RawJSONValue,
        depth: Int,
        entryCount: inout Int,
        maximumEntryCount: Int
    ) throws -> HLSChapterMetadataValue {
        guard depth <= maximumMetadataDepth else {
            throw HLSExternalResourceError.chapterMetadataDepthExceeded(
                limit: maximumMetadataDepth
            )
        }
        switch value {
        case .null:
            return .null
        case .string(let value):
            return .string(value)
        case .number(let value):
            guard value.isFinite else {
                throw HLSExternalResourceError.invalidChapterData
            }
            return .number(value)
        case .boolean(let value):
            return .boolean(value)
        case .array(let values):
            var result: [HLSChapterMetadataValue] = []
            result.reserveCapacity(values.count)
            for value in values {
                try addEntry(
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                result.append(
                    try convert(
                        value,
                        depth: depth + 1,
                        entryCount: &entryCount,
                        maximumEntryCount: maximumEntryCount
                    )
                )
            }
            return .array(result)
        case .object(let object):
            var result: [String: HLSChapterMetadataValue] = [:]
            result.reserveCapacity(object.count)
            for (key, value) in object {
                try addEntry(
                    to: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
                guard isSafeText(key) else {
                    throw HLSExternalResourceError.invalidChapterData
                }
                result[key] = try convert(
                    value,
                    depth: depth + 1,
                    entryCount: &entryCount,
                    maximumEntryCount: maximumEntryCount
                )
            }
            return .object(result)
        }
    }

    private static func convertRootMetadataValue(
        _ value: RawJSONValue,
        entryCount: inout Int,
        maximumEntryCount: Int
    ) throws -> HLSChapterMetadataValue {
        if case .null = value {
            throw HLSExternalResourceError.invalidChapterData
        }
        return try convert(
            value,
            depth: 0,
            entryCount: &entryCount,
            maximumEntryCount: maximumEntryCount
        )
    }

    private static func addEntry(
        to entryCount: inout Int,
        maximumEntryCount: Int
    ) throws {
        guard entryCount < maximumEntryCount else {
            throw HLSExternalResourceError.tooManyChapterEntries(
                limit: maximumEntryCount
            )
        }
        entryCount += 1
    }

    private static func isSafeText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func normalizeLanguage(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func isAdmittedImageURL(
        _ url: URL,
        documentURL: URL
    ) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            return false
        }
        return documentURL.scheme?.lowercased() != "https"
            || scheme == "https"
    }

    private static func isNonnegativeFinite(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private static func isPositiveFinite(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }
}

private struct RawChapter: Decodable {
    let chapterNumber: Double?
    let startTime: Double
    let duration: Double?
    let titles: [RawChapterTitle]
    let images: [RawChapterImage]
    let metadata: [RawChapterMetadata]

    enum CodingKeys: String, CodingKey {
        case chapterNumber = "chapter"
        case startTime = "start-time"
        case duration
        case titles
        case images
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterNumber = try container.decodeIfPresent(
            Double.self,
            forKey: .chapterNumber
        )
        startTime = try container.decode(Double.self, forKey: .startTime)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        titles =
            try container.decodeIfPresent(
                [RawChapterTitle].self,
                forKey: .titles
            ) ?? []
        images =
            try container.decodeIfPresent(
                [RawChapterImage].self,
                forKey: .images
            ) ?? []
        metadata =
            try container.decodeIfPresent(
                [RawChapterMetadata].self,
                forKey: .metadata
            ) ?? []
    }
}

private struct RawChapterTitle: Decodable {
    let language: String
    let title: String
}

private struct RawChapterImage: Decodable {
    let category: String
    let pixelWidth: Int
    let pixelHeight: Int
    let url: String

    enum CodingKeys: String, CodingKey {
        case category = "image-category"
        case pixelWidth = "pixel-width"
        case pixelHeight = "pixel-height"
        case url
    }
}

private struct RawChapterMetadata: Decodable {
    let key: String
    let value: RawJSONValue
    let language: String?
}

private indirect enum RawJSONValue: Decodable {
    case null
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([RawJSONValue])
    case object([String: RawJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([RawJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(
                try container.decode([String: RawJSONValue].self)
            )
        }
    }
}

private struct MetadataIdentity: Hashable {
    let key: String
    let language: String?
}
