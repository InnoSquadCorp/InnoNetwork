import Foundation

/// A resolved Apple HLS JSON chapter document.
public struct HLSChapterCatalog: Equatable, Sendable {
    /// The Session Data identifier reserved for HLS chapter metadata.
    public static let sessionDataID = "com.apple.hls.chapters"

    /// Chapters in JSON source order.
    public let chapters: [HLSChapter]

    init(chapters: [HLSChapter]) {
        self.chapters = chapters
    }
}

/// One chapter entry from an Apple HLS JSON chapter document.
public struct HLSChapter: Equatable, Sendable {
    /// The optional author-supplied chapter number.
    public let chapterNumber: Double?

    /// The nonnegative start time in seconds.
    public let startTime: TimeInterval

    /// The positive duration in seconds.
    ///
    /// When the JSON omits duration, this is inferred from the next entry in
    /// source order. It is `nil` only for a final entry without a duration.
    public let duration: TimeInterval?

    /// Localized titles in JSON source order.
    public let titles: [HLSChapterTitle]

    /// Resolved image references in JSON source order.
    public let images: [HLSChapterImage]

    /// Application-defined metadata in JSON source order.
    public let metadata: [HLSChapterMetadata]

    init(
        chapterNumber: Double?,
        startTime: TimeInterval,
        duration: TimeInterval?,
        titles: [HLSChapterTitle],
        images: [HLSChapterImage],
        metadata: [HLSChapterMetadata]
    ) {
        self.chapterNumber = chapterNumber
        self.startTime = startTime
        self.duration = duration
        self.titles = titles
        self.images = images
        self.metadata = metadata
    }
}

/// One localized title attached to an HLS chapter.
public struct HLSChapterTitle: Equatable, Sendable {
    /// The BCP 47 language tag, or `und` for language-neutral text.
    public let language: String

    /// The chapter title.
    public let title: String

    init(language: String, title: String) {
        self.language = language
        self.title = title
    }
}

/// One image reference attached to an HLS chapter.
public struct HLSChapterImage: Equatable, Sendable {
    /// The author-defined category shared by comparable chapter images.
    public let category: String

    /// The positive image width in pixels.
    public let pixelWidth: Int

    /// The positive image height in pixels.
    public let pixelHeight: Int

    /// The admitted HTTP(S) image URL resolved against the final JSON response
    /// URL without permitting HTTPS downgrade or URL credentials.
    public let url: URL

    init(
        category: String,
        pixelWidth: Int,
        pixelHeight: Int,
        url: URL
    ) {
        self.category = category
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.url = url
    }
}

/// One application-defined metadata item attached to an HLS chapter.
public struct HLSChapterMetadata: Equatable, Sendable {
    /// The author-defined metadata key.
    public let key: String

    /// An optional BCP 47 language tag.
    public let language: String?

    /// The bounded JSON value.
    public let value: HLSChapterMetadataValue

    init(
        key: String,
        language: String?,
        value: HLSChapterMetadataValue
    ) {
        self.key = key
        self.language = language
        self.value = value
    }
}

/// A JSON value supplied as application-defined chapter metadata.
public indirect enum HLSChapterMetadataValue: Equatable, Sendable {
    /// A nested JSON null.
    ///
    /// Apple's schema excludes null as the metadata item's direct value but
    /// permits it inside an array or object.
    case null

    /// A JSON string.
    case string(String)

    /// A finite JSON number.
    case number(Double)

    /// A JSON Boolean.
    case boolean(Bool)

    /// An ordered JSON array.
    case array([HLSChapterMetadataValue])

    /// A JSON object whose keys retain their exact spelling.
    case object([String: HLSChapterMetadataValue])
}
