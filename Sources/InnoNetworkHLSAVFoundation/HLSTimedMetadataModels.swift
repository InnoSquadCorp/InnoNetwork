import AVFoundation
import Foundation

/// A validated AVFoundation timed-metadata identifier.
///
/// Identifiers are schema names rather than metadata values. The public
/// initializer rejects empty, control-character, and oversized values so a
/// configuration remains safe to retain and log.
public struct HLSTimedMetadataIdentifier: Equatable, Hashable, Sendable {
    /// The AVFoundation metadata identifier.
    public let rawValue: String

    /// Creates a custom metadata identifier.
    ///
    /// The value must contain `1...512` UTF-8 bytes and no control
    /// characters.
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    private init(knownValue: String) {
        self.rawValue = knownValue
    }

    /// ID3 `TIT2`, the title or content description.
    public static let id3Title = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataTitleDescription.rawValue
    )

    /// ID3 `TPE1`, the lead performer or artist.
    public static let id3LeadPerformer = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataLeadPerformer.rawValue
    )

    /// ID3 `TALB`, the album, movie, or show title.
    public static let id3AlbumTitle = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataAlbumTitle.rawValue
    )

    /// ID3 `TCON`, the authored content type.
    public static let id3ContentType = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataContentType.rawValue
    )

    /// ID3 `TLAN`, the authored language list.
    public static let id3Language = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataLanguage.rawValue
    )

    /// ID3 `TRSN`, the internet-radio station name.
    public static let id3InternetRadioStationName = Self(
        knownValue:
            AVMetadataIdentifier
            .id3MetadataInternetRadioStationName.rawValue
    )

    /// ID3 `PRIV`, an application-defined private frame.
    ///
    /// Use the default redacted policy unless the application separately owns
    /// and validates the frame format. This companion never exports raw data.
    public static let id3Private = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataPrivate.rawValue
    )

    /// ID3 `TXXX`, application-defined text.
    public static let id3UserText = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataUserText.rawValue
    )

    /// ID3 `WXXX`, an application-defined URL.
    ///
    /// URL objects are never exported. Text exposure is available only when
    /// the caller explicitly opts in for this identifier.
    public static let id3UserURL = Self(
        knownValue:
            AVMetadataIdentifier.id3MetadataUserURL.rawValue
    )

    private static func isValid(_ value: String) -> Bool {
        let count = value.utf8.count
        guard (1...512).contains(count) else {
            return false
        }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// How one allowlisted metadata value may cross the AVFoundation boundary.
public enum HLSTimedMetadataValueExposure: Equatable, Hashable, Sendable {
    /// Exposes only the identifier and timing.
    case redacted

    /// Exposes a bounded string representation.
    ///
    /// The UTF-8 byte limit is normalized to `1...16,384` when a field is
    /// created. Choosing this case is an explicit content and privacy opt-in.
    case text(maximumUTF8ByteCount: Int)

    /// Exposes a finite numeric representation.
    case number

    /// Exposes a date representation.
    case date
}

/// One identifier allowlist entry and its value-exposure policy.
public struct HLSTimedMetadataField: Equatable, Hashable, Sendable {
    /// The only identifier this field accepts.
    public let identifier: HLSTimedMetadataIdentifier

    /// The value representation permitted for this identifier.
    public let valueExposure: HLSTimedMetadataValueExposure

    private init(
        identifier: HLSTimedMetadataIdentifier,
        valueExposure: HLSTimedMetadataValueExposure
    ) {
        self.identifier = identifier
        self.valueExposure = valueExposure
    }

    /// Creates an identifier-only field that never loads its value.
    public static func redacted(
        _ identifier: HLSTimedMetadataIdentifier
    ) -> HLSTimedMetadataField {
        HLSTimedMetadataField(
            identifier: identifier,
            valueExposure: .redacted
        )
    }

    /// Creates an explicitly text-exposing field.
    public static func text(
        _ identifier: HLSTimedMetadataIdentifier,
        maximumUTF8ByteCount: Int = 1_024
    ) -> HLSTimedMetadataField {
        HLSTimedMetadataField(
            identifier: identifier,
            valueExposure: .text(
                maximumUTF8ByteCount: min(
                    16_384,
                    max(1, maximumUTF8ByteCount)
                )
            )
        )
    }

    /// Creates an explicitly number-exposing field.
    public static func number(
        _ identifier: HLSTimedMetadataIdentifier
    ) -> HLSTimedMetadataField {
        HLSTimedMetadataField(
            identifier: identifier,
            valueExposure: .number
        )
    }

    /// Creates an explicitly date-exposing field.
    public static func date(
        _ identifier: HLSTimedMetadataIdentifier
    ) -> HLSTimedMetadataField {
        HLSTimedMetadataField(
            identifier: identifier,
            valueExposure: .date
        )
    }
}

/// Configures one timed-metadata observation bridge.
public struct HLSTimedMetadataConfiguration: Equatable, Sendable {
    /// Allowlisted identifiers in deterministic caller order.
    public let fields: [HLSTimedMetadataField]

    /// Seconds before presentation when AVFoundation may deliver metadata.
    public let advanceInterval: TimeInterval

    /// Maximum native callbacks retained before mapping and events retained
    /// for each subscriber.
    public let maximumBufferedEventCount: Int

    /// Maximum metadata items emitted from one timed group.
    public let maximumItemCountPerGroup: Int

    package let fieldsByIdentifier: [HLSTimedMetadataIdentifier: HLSTimedMetadataField]

    private init(
        fields: [HLSTimedMetadataField],
        advanceInterval: TimeInterval,
        maximumBufferedEventCount: Int,
        maximumItemCountPerGroup: Int
    ) {
        var identifiers: Set<HLSTimedMetadataIdentifier> = []
        var normalizedFields: [HLSTimedMetadataField] = []
        normalizedFields.reserveCapacity(min(256, fields.count))
        for field in fields {
            guard normalizedFields.count < 256 else {
                break
            }
            guard identifiers.insert(field.identifier).inserted else {
                continue
            }
            normalizedFields.append(field)
        }
        self.fields = normalizedFields
        self.fieldsByIdentifier = Dictionary(
            uniqueKeysWithValues: self.fields.map {
                ($0.identifier, $0)
            }
        )
        self.advanceInterval = Self.normalizedAdvanceInterval(
            advanceInterval
        )
        self.maximumBufferedEventCount = min(
            1_024,
            max(1, maximumBufferedEventCount)
        )
        self.maximumItemCountPerGroup = min(
            1_024,
            max(1, maximumItemCountPerGroup)
        )
    }

    /// Returns identifier-only observation with no metadata values exposed.
    ///
    /// ``HLSTimedMetadataMonitor`` rejects an empty allowlist before calling
    /// AVFoundation; it never interprets an empty list as "receive all".
    public static func safeDefaults(
        identifiers: [HLSTimedMetadataIdentifier]
    ) -> HLSTimedMetadataConfiguration {
        advanced(fields: identifiers.map(HLSTimedMetadataField.redacted))
    }

    /// Returns explicitly tuned timed-metadata observation behavior.
    ///
    /// The first field for a duplicate identifier wins. The field count is
    /// limited to 256, the event and item limits are clamped to `1...1,024`,
    /// and the finite advance interval is clamped to `0...60` seconds.
    public static func advanced(
        fields: [HLSTimedMetadataField],
        advanceInterval: TimeInterval = 0,
        maximumBufferedEventCount: Int = 64,
        maximumItemCountPerGroup: Int = 64
    ) -> HLSTimedMetadataConfiguration {
        HLSTimedMetadataConfiguration(
            fields: fields,
            advanceInterval: advanceInterval,
            maximumBufferedEventCount: maximumBufferedEventCount,
            maximumItemCountPerGroup: maximumItemCountPerGroup
        )
    }

    private static func normalizedAdvanceInterval(
        _ value: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else {
            return 0
        }
        return min(60, max(0, value))
    }
}

/// A value-redacted timed-metadata setup failure.
public enum HLSTimedMetadataError: Error, Equatable, Sendable {
    /// Observation requires at least one explicitly allowlisted identifier.
    case emptyIdentifierAllowlist
}

extension HLSTimedMetadataError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyIdentifierAllowlist:
            "Timed metadata requires at least one allowlisted identifier."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyIdentifierAllowlist:
            "Create a configuration with an explicit metadata identifier."
        }
    }
}

/// A value-safe representation of one timed metadata item.
public enum HLSTimedMetadataValue: Equatable, Sendable {
    /// The value was intentionally not loaded.
    case redacted

    /// A bounded text value and whether it was truncated.
    case text(String, wasTruncated: Bool)

    /// A finite numeric value.
    case number(Double)

    /// A date value.
    case date(Date)

    /// The requested representation was absent, invalid, or failed to load.
    ///
    /// Underlying values and errors are intentionally not retained.
    case unavailable
}

/// Whether timed metadata describes the asset or a specific player-item track.
public enum HLSTimedMetadataSource: Equatable, Sendable {
    /// Asset-level metadata with no associated player-item track.
    case asset

    /// Metadata delivered by one player-item track.
    case track
}

/// One value-safe metadata item.
public struct HLSTimedMetadataItem: Equatable, Sendable {
    /// The allowlisted metadata identifier.
    public let identifier: HLSTimedMetadataIdentifier

    /// The permitted value representation.
    public let value: HLSTimedMetadataValue

    /// The authored IETF BCP 47 language tag, when available and the field's
    /// value exposure is not redacted.
    public let languageTag: String?

    /// Item start time in seconds, when numeric and finite.
    public let startTime: TimeInterval?

    /// Item duration in seconds, when numeric, finite, and nonnegative.
    public let duration: TimeInterval?
}

/// One timed group delivered by AVFoundation.
public struct HLSTimedMetadataGroup: Equatable, Sendable {
    /// Whether metadata describes the asset or a specific track.
    public let source: HLSTimedMetadataSource

    /// Group start time in seconds, when numeric and finite.
    public let startTime: TimeInterval?

    /// Group duration in seconds, when numeric, finite, and nonnegative.
    ///
    /// HLS metadata commonly has an indefinite duration until the next group.
    public let duration: TimeInterval?

    /// Allowlisted items in AVFoundation order.
    public let items: [HLSTimedMetadataItem]

    /// Whether the configured per-group item limit removed later items.
    public let didTruncateItems: Bool
}

/// A bounded timed-metadata lifecycle event.
public enum HLSTimedMetadataEvent: Equatable, Sendable {
    /// AVFoundation delivered one metadata group.
    case metadata(HLSTimedMetadataGroup)

    /// Seeking or playback-direction changes started a new output sequence.
    case sequenceFlushed

    /// Native callback events were discarded before value mapping.
    ///
    /// This can occur when asynchronous value loading falls behind the
    /// configured bounded callback buffer. Subscriber-local buffering remains
    /// governed separately by the stream's newest-event policy.
    case eventsDropped(count: Int)
}
