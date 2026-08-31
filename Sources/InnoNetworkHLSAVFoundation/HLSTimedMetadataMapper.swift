import AVFoundation
import Foundation

enum HLSTimedMetadataMapper {
    static func map(
        _ groups: [AVTimedMetadataGroup],
        source: HLSTimedMetadataSource,
        configuration: HLSTimedMetadataConfiguration
    ) async -> [HLSTimedMetadataEvent] {
        var events: [HLSTimedMetadataEvent] = []
        events.reserveCapacity(groups.count)
        for group in groups {
            events.append(
                .metadata(
                    await map(
                        group,
                        source: source,
                        configuration: configuration
                    )
                )
            )
        }
        return events
    }

    private static func map(
        _ group: AVTimedMetadataGroup,
        source: HLSTimedMetadataSource,
        configuration: HLSTimedMetadataConfiguration
    ) async -> HLSTimedMetadataGroup {
        var items: [HLSTimedMetadataItem] = []
        items.reserveCapacity(
            min(
                group.items.count,
                configuration.maximumItemCountPerGroup
            )
        )
        var allowlistedItemCount = 0

        for item in group.items {
            guard
                let rawIdentifier = item.identifier?.rawValue,
                let identifier = HLSTimedMetadataIdentifier(
                    rawIdentifier
                ),
                let field =
                    configuration
                    .fieldsByIdentifier[identifier]
            else {
                continue
            }
            allowlistedItemCount += 1
            guard
                items.count < configuration.maximumItemCountPerGroup
            else {
                continue
            }
            items.append(
                await map(item, field: field)
            )
        }

        return HLSTimedMetadataGroup(
            source: source,
            startTime: finite(group.timeRange.start),
            duration: finiteNonnegative(group.timeRange.duration),
            items: items,
            didTruncateItems:
                allowlistedItemCount > items.count
        )
    }

    private static func map(
        _ item: AVMetadataItem,
        field: HLSTimedMetadataField
    ) async -> HLSTimedMetadataItem {
        HLSTimedMetadataItem(
            identifier: field.identifier,
            value: await value(item, exposure: field.valueExposure),
            languageTag: languageTag(
                for: item,
                exposure: field.valueExposure
            ),
            startTime: finite(item.time),
            duration: finiteNonnegative(item.duration)
        )
    }

    private static func languageTag(
        for item: AVMetadataItem,
        exposure: HLSTimedMetadataValueExposure
    ) -> String? {
        guard exposure != .redacted else {
            return nil
        }
        return boundedLanguageTag(item.extendedLanguageTag)
    }

    private static func value(
        _ item: AVMetadataItem,
        exposure: HLSTimedMetadataValueExposure
    ) async -> HLSTimedMetadataValue {
        do {
            switch exposure {
            case .redacted:
                return .redacted
            case .text(let maximumUTF8ByteCount):
                guard let value = try await item.load(.stringValue) else {
                    return .unavailable
                }
                let bounded = boundedText(
                    value,
                    maximumUTF8ByteCount: maximumUTF8ByteCount
                )
                return .text(
                    bounded.value,
                    wasTruncated: bounded.wasTruncated
                )
            case .number:
                guard
                    let value = try await item.load(.numberValue)?
                        .doubleValue,
                    value.isFinite
                else {
                    return .unavailable
                }
                return .number(value)
            case .date:
                guard let value = try await item.load(.dateValue) else {
                    return .unavailable
                }
                return .date(value)
            }
        } catch {
            return .unavailable
        }
    }

    static func boundedText(
        _ value: String,
        maximumUTF8ByteCount: Int
    ) -> (value: String, wasTruncated: Bool) {
        guard value.utf8.count > maximumUTF8ByteCount else {
            return (value, false)
        }
        var result = ""
        result.reserveCapacity(
            min(value.count, maximumUTF8ByteCount)
        )
        var byteCount = 0
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard
                byteCount + characterByteCount
                    <= maximumUTF8ByteCount
            else {
                break
            }
            result.append(character)
            byteCount += characterByteCount
        }
        return (result, true)
    }

    static func boundedLanguageTag(_ value: String?) -> String? {
        guard
            let value,
            !value.isEmpty,
            value.utf8.count <= 128,
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return value
    }

    static func finite(_ time: CMTime) -> TimeInterval? {
        guard time.isNumeric, time.seconds.isFinite else {
            return nil
        }
        return time.seconds
    }

    static func finiteNonnegative(
        _ time: CMTime
    ) -> TimeInterval? {
        guard let value = finite(time), value >= 0 else {
            return nil
        }
        return value
    }
}
