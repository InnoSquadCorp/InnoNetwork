import AVFoundation
import CoreFoundation
import CryptoKit
import Foundation

public extension HLSPlaybackConfigurator {
    /// Loads playable subtitle and caption options without retaining the item.
    ///
    /// The result contains no media option, asset, or player references and is
    /// safe to pass into custom UI state. Assets without a legible group return
    /// an empty catalog. Refresh after asset or media-selection changes.
    func legibleMediaCatalog(
        for playerItem: AVPlayerItem,
        displayLocale: Locale = .current
    ) async throws -> HLSLegibleMediaCatalog {
        let group: AVMediaSelectionGroup
        do {
            guard
                let loaded = try await playerItem.asset
                    .loadMediaSelectionGroup(for: .legible)
            else {
                return HLSLegibleMediaCatalog(
                    options: [],
                    allowsEmptySelection: true
                )
            }
            group = loaded
        } catch {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionGroupUnavailable(.subtitles)
        }

        let playable =
            AVMediaSelectionGroup
            .playableMediaSelectionOptions(from: group.options)
        let current = playerItem.currentMediaSelection
            .selectedMediaOption(in: group)
        let options = try playable.map { option in
            let id = try Self.legibleMediaOptionID(for: option)
            return HLSLegibleMediaOption(
                id: id,
                displayName: option.displayName(with: displayLocale),
                languageTag: option.extendedLanguageTag,
                kind: Self.legibleMediaKind(for: option),
                provenance: Self.legibleMediaProvenance(for: option),
                features: Self.legibleMediaFeatures(for: option),
                isSelected: option == current,
                isDefault: option == group.defaultOption
            )
        }
        try Self.validateUniqueLegibleMediaOptionIDs(
            options.map(\.id)
        )
        return HLSLegibleMediaCatalog(
            options: options,
            allowsEmptySelection: group.allowsEmptySelection
        )
    }

    /// Applies one exact legible media command to a caller-owned player item.
    ///
    /// Option identifiers are resolved against the item's current group before
    /// mutation. Refresh the catalog after selection if UI mirrors current
    /// player state.
    func selectLegibleMedia(
        _ selection: HLSLegibleMediaSelection,
        on playerItem: AVPlayerItem
    ) async throws {
        let group: AVMediaSelectionGroup
        do {
            guard
                let loaded = try await playerItem.asset
                    .loadMediaSelectionGroup(for: .legible)
            else {
                throw
                    HLSPlaybackConfigurationError
                    .mediaSelectionGroupUnavailable(.subtitles)
            }
            group = loaded
        } catch let error as HLSPlaybackConfigurationError {
            throw error
        } catch {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionGroupUnavailable(.subtitles)
        }

        switch selection {
        case .automatic:
            playerItem.selectMediaOptionAutomatically(in: group)
        case .disabled:
            guard group.allowsEmptySelection else {
                throw
                    HLSPlaybackConfigurationError
                    .emptyMediaSelectionUnavailable(.subtitles)
            }
            playerItem.select(nil, in: group)
        case .option(let requestedID):
            let playable =
                AVMediaSelectionGroup
                .playableMediaSelectionOptions(from: group.options)
            let identifiers = try playable.map {
                try Self.legibleMediaOptionID(for: $0)
            }
            let index = try Self.uniqueLegibleMediaOptionIndex(
                for: requestedID,
                in: identifiers
            )
            playerItem.select(playable[index], in: group)
        }
    }

    nonisolated internal static func validateUniqueLegibleMediaOptionIDs(
        _ identifiers: [HLSLegibleMediaOptionID]
    ) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(.subtitles)
        }
    }

    nonisolated internal static func uniqueLegibleMediaOptionIndex(
        for requestedID: HLSLegibleMediaOptionID,
        in identifiers: [HLSLegibleMediaOptionID]
    ) throws -> Int {
        let matches = identifiers.indices.filter {
            identifiers[$0] == requestedID
        }
        guard matches.count == 1, let index = matches.first else {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(.subtitles)
        }
        return index
    }

    nonisolated internal static func legibleMediaOptionID(
        forPropertyList propertyList: Any
    ) throws -> HLSLegibleMediaOptionID {
        guard
            PropertyListSerialization.propertyList(
                propertyList,
                isValidFor: .binary
            )
        else {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(.subtitles)
        }
        do {
            let data =
                try HLSLegibleMediaPropertyListFingerprint
                .canonicalData(for: propertyList)
            return HLSLegibleMediaOptionID(
                fingerprint: SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
            )
        } catch {
            throw
                HLSPlaybackConfigurationError
                .mediaSelectionUnavailable(.subtitles)
        }
    }

    private static func legibleMediaOptionID(
        for option: AVMediaSelectionOption
    ) throws -> HLSLegibleMediaOptionID {
        try legibleMediaOptionID(
            forPropertyList: option.propertyList()
        )
    }

    private static func legibleMediaKind(
        for option: AVMediaSelectionOption
    ) -> HLSLegibleMediaKind {
        if option.mediaType == .closedCaption {
            return .closedCaptions
        }
        if option.mediaType == .subtitle || option.mediaType == .text {
            return .subtitles
        }
        return .other
    }

    private static func legibleMediaProvenance(
        for option: AVMediaSelectionOption
    ) -> Set<HLSLegibleMediaProvenance> {
        var result: Set<HLSLegibleMediaProvenance> = []
        if option.hasMediaCharacteristic(
            AVMediaCharacteristic(rawValue: "public.machine-generated")
        ) {
            result.insert(.machineGenerated)
        }
        if option.hasMediaCharacteristic(
            AVMediaCharacteristic(rawValue: "public.translation")
        ) {
            result.insert(.translated)
        }
        return result
    }

    private static func legibleMediaFeatures(
        for option: AVMediaSelectionOption
    ) -> Set<HLSLegibleMediaFeature> {
        var result: Set<HLSLegibleMediaFeature> = []
        if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
            result.insert(.forcedNarrative)
        }
        if option.hasMediaCharacteristic(
            .transcribesSpokenDialogForAccessibility
        ) {
            result.insert(.transcribesSpokenDialogue)
        }
        if option.hasMediaCharacteristic(
            .describesMusicAndSoundForAccessibility
        ) {
            result.insert(.describesMusicAndSound)
        }
        if option.hasMediaCharacteristic(.easyToRead) {
            result.insert(.easyToRead)
        }
        return result
    }
}

private enum HLSLegibleMediaPropertyListFingerprint {
    static func canonicalData(for value: Any) throws -> Data {
        var data = Data()
        try append(value, to: &data)
        return data
    }

    private static func append(
        _ value: Any,
        to data: inout Data
    ) throws {
        if let dictionary = value as? [String: Any] {
            appendTag(0x01, to: &data)
            appendCount(dictionary.count, to: &data)
            for key in dictionary.keys.sorted() {
                try append(key, to: &data)
                guard let child = dictionary[key] else {
                    throw HLSLegibleMediaFingerprintError.invalidValue
                }
                try append(child, to: &data)
            }
            return
        }
        if let array = value as? [Any] {
            appendTag(0x02, to: &data)
            appendCount(array.count, to: &data)
            for child in array {
                try append(child, to: &data)
            }
            return
        }
        if let value = value as? String {
            appendTag(0x03, to: &data)
            appendBytes(Data(value.utf8), to: &data)
            return
        }
        if let value = value as? Data {
            appendTag(0x04, to: &data)
            appendBytes(value, to: &data)
            return
        }
        if let value = value as? Date {
            appendTag(0x05, to: &data)
            appendUInt64(
                value.timeIntervalSinceReferenceDate.bitPattern,
                to: &data
            )
            return
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                appendTag(value.boolValue ? 0x07 : 0x06, to: &data)
            } else {
                appendTag(0x08, to: &data)
                appendBytes(
                    Data(String(cString: value.objCType).utf8),
                    to: &data
                )
                appendBytes(Data(value.stringValue.utf8), to: &data)
            }
            return
        }
        throw HLSLegibleMediaFingerprintError.invalidValue
    }

    private static func appendTag(
        _ value: UInt8,
        to data: inout Data
    ) {
        data.append(value)
    }

    private static func appendBytes(
        _ value: Data,
        to data: inout Data
    ) {
        appendCount(value.count, to: &data)
        data.append(value)
    }

    private static func appendCount(
        _ value: Int,
        to data: inout Data
    ) {
        appendUInt64(UInt64(value), to: &data)
    }

    private static func appendUInt64(
        _ value: UInt64,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }
}

private enum HLSLegibleMediaFingerprintError: Error {
    case invalidValue
}
