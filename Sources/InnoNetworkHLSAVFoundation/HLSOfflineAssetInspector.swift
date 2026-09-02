#if canImport(AVFoundation) && !os(tvOS) && !os(watchOS)
import AVFoundation
import Foundation

/// Inspects whether a system-managed HLS package is ready to play offline.
///
/// Inspection opens only the stored file URL and never starts playback, moves,
/// or removes the package. The returned values retain no AVFoundation objects.
/// FairPlay key validity remains application-owned and is not asserted by this
/// inspector.
public struct HLSOfflineAssetInspector: Sendable {
    /// Creates a stateless offline-package inspector.
    public init() {}

    /// Returns current package, rendition, and media-selection readiness.
    public func inspect(
        _ storedAsset: HLSStoredAsset
    ) async throws(CancellationError) -> HLSOfflineAssetReadinessSnapshot {
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        switch HLSAssetPackageInspector.state(
            at: storedAsset.location
        ) {
        case .missing:
            return Self.snapshot(state: .missing)
        case .invalid:
            return Self.snapshot(state: .invalidPackage)
        case .available:
            break
        }

        let asset = AVURLAsset(url: storedAsset.location)
        guard let cache = asset.assetCache else {
            return Self.snapshot(state: .unrecognizedPackage)
        }
        guard cache.isPlayableOffline else {
            return Self.snapshot(state: .incomplete)
        }

        let inspection = try await Self.mediaSelectionGroups(
            asset: asset,
            cache: cache
        )
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        return HLSOfflineAssetReadinessSnapshot(
            state: .ready,
            mediaSelectionGroups: inspection.groups,
            didCompleteMediaSelectionInspection: inspection.isComplete
        )
    }

    private static func snapshot(
        state: HLSOfflineAssetReadinessState
    ) -> HLSOfflineAssetReadinessSnapshot {
        HLSOfflineAssetReadinessSnapshot(
            state: state,
            mediaSelectionGroups: [],
            didCompleteMediaSelectionInspection: false
        )
    }

    private static func mediaSelectionGroups(
        asset: AVURLAsset,
        cache: AVAssetCache
    ) async throws(CancellationError) -> (
        groups: [HLSOfflineMediaSelectionGroupSnapshot],
        isComplete: Bool
    ) {
        var groups: [HLSOfflineMediaSelectionGroupSnapshot] = []
        var isComplete = true
        for descriptor in HLSOfflineMediaGroupDescriptor.all {
            do {
                guard
                    let group = try await asset.loadMediaSelectionGroup(
                        for: descriptor.characteristic
                    )
                else {
                    continue
                }
                groups.append(
                    HLSOfflineAssetMapper.group(
                        group,
                        cache: cache,
                        fallbackKind: descriptor.kind
                    )
                )
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                isComplete = false
            }
        }
        return (groups, isComplete)
    }
}

private struct HLSOfflineMediaGroupDescriptor {
    let characteristic: AVMediaCharacteristic
    let kind: HLSPlaybackMediaKind

    static let all: [HLSOfflineMediaGroupDescriptor] = [
        HLSOfflineMediaGroupDescriptor(
            characteristic: .audible,
            kind: .audio
        ),
        HLSOfflineMediaGroupDescriptor(
            characteristic: .visual,
            kind: .video
        ),
        HLSOfflineMediaGroupDescriptor(
            characteristic: .legible,
            kind: .subtitles
        ),
    ]
}

enum HLSOfflineAssetMapper {
    static let maximumOptionCount = 256
    static let maximumCustomLanguageCount = 256
    static let maximumLanguageUTF8ByteCount = 128
    static let maximumNativeLanguageInspectionCount = 1_024
    static let maximumCustomSelectorInspectionCount = 256
    static let maximumCustomSettingInspectionCount = 1_024

    static func group(
        _ group: AVMediaSelectionGroup,
        cache: AVAssetCache,
        fallbackKind: HLSPlaybackMediaKind
    ) -> HLSOfflineMediaSelectionGroupSnapshot {
        let nativeOptions = cache.mediaSelectionOptions(in: group)
        let options =
            nativeOptions
            .prefix(maximumOptionCount)
            .map {
                option(
                    $0,
                    group: group,
                    fallbackKind: fallbackKind
                )
            }
        let custom = customMediaSelection(
            group: group,
            cache: cache
        )
        return HLSOfflineMediaSelectionGroupSnapshot(
            kind: fallbackKind,
            options: options,
            didTruncateOptions:
                nativeOptions.count > maximumOptionCount,
            cachedCustomLanguageTags: custom.languages,
            didTruncateCustomLanguageTags:
                custom.didTruncateLanguages,
            customMediaSelectionCoverage: custom.coverage
        )
    }

    static func boundedLanguageTag(_ value: String?) -> String? {
        guard
            let value,
            value.utf8.count <= maximumLanguageUTF8ByteCount
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !trimmed.isEmpty,
            !trimmed.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return trimmed
    }

    static func boundedLanguageTags(
        _ values: [String]
    ) -> (values: [String], wasTruncated: Bool) {
        var seen: Set<String> = []
        var result: [String] = []
        var didOmitValue =
            values.count > maximumNativeLanguageInspectionCount
        for value in values.prefix(
            maximumNativeLanguageInspectionCount
        ) {
            guard let bounded = boundedLanguageTag(value) else {
                didOmitValue = true
                continue
            }
            let identity = bounded.lowercased()
            guard seen.insert(identity).inserted else {
                continue
            }
            guard result.count < maximumCustomLanguageCount else {
                didOmitValue = true
                continue
            }
            result.append(bounded)
        }
        return (result, didOmitValue)
    }

    static func boundedLanguageSet(
        _ values: [String]
    ) -> (values: Set<String>, didOmitValue: Bool) {
        var result: Set<String> = []
        var didOmitValue =
            values.count > maximumNativeLanguageInspectionCount
        for value in values.prefix(
            maximumNativeLanguageInspectionCount
        ) {
            guard let bounded = boundedLanguageTag(value) else {
                didOmitValue = true
                continue
            }
            result.insert(bounded.lowercased())
        }
        return (result, didOmitValue)
    }

    static func customCoverage(
        authoredLanguageCount: Int,
        cachedLanguageCount: Int,
        authoredSettingCount: Int,
        cachedSettingCount: Int,
        didTruncateInspection: Bool = false
    ) -> HLSOfflineCustomMediaSelectionCoverage {
        guard !didTruncateInspection else {
            return .indeterminate
        }
        let authoredLanguages = max(0, authoredLanguageCount)
        let cachedLanguages = min(
            authoredLanguages,
            max(0, cachedLanguageCount)
        )
        let authoredSettings = max(0, authoredSettingCount)
        let cachedSettings = min(
            authoredSettings,
            max(0, cachedSettingCount)
        )
        guard authoredLanguages > 0 || authoredSettings > 0 else {
            return .complete
        }
        guard cachedLanguages > 0 || cachedSettings > 0 else {
            return .none
        }
        return cachedLanguages == authoredLanguages
            && cachedSettings == authoredSettings
            ? .complete
            : .partial
    }

    private static func option(
        _ option: AVMediaSelectionOption,
        group: AVMediaSelectionGroup,
        fallbackKind: HLSPlaybackMediaKind
    ) -> HLSOfflineMediaSelectionOptionSnapshot {
        HLSOfflineMediaSelectionOptionSnapshot(
            kind: kind(option.mediaType, fallback: fallbackKind),
            languageTag: boundedLanguageTag(
                option.extendedLanguageTag
            ),
            isDefault: option == group.defaultOption
        )
    }

    private static func kind(
        _ mediaType: AVMediaType,
        fallback: HLSPlaybackMediaKind
    ) -> HLSPlaybackMediaKind {
        switch mediaType {
        case .audio:
            return .audio
        case .video:
            return .video
        case .closedCaption:
            return .closedCaptions
        case .subtitle, .text:
            return .subtitles
        default:
            return fallback
        }
    }

    private static func customMediaSelection(
        group: AVMediaSelectionGroup,
        cache: AVAssetCache
    ) -> (
        languages: [String],
        didTruncateLanguages: Bool,
        coverage: HLSOfflineCustomMediaSelectionCoverage
    ) {
        if #available(macOS 26, iOS 26, visionOS 26, *) {
            return modernCustomMediaSelection(
                group: group,
                cache: cache
            )
        }
        return ([], false, .unavailable)
    }
}

@available(macOS 26, iOS 26, visionOS 26, *)
private extension HLSOfflineAssetMapper {
    static func modernCustomMediaSelection(
        group: AVMediaSelectionGroup,
        cache: AVAssetCache
    ) -> (
        languages: [String],
        didTruncateLanguages: Bool,
        coverage: HLSOfflineCustomMediaSelectionCoverage
    ) {
        guard let scheme = group.customMediaSelectionScheme else {
            return ([], false, .notAuthored)
        }
        let nativeLanguages = cache.mediaPresentationLanguages(
            for: group
        )
        let languages = boundedLanguageTags(nativeLanguages)
        let nativeAuthoredLanguages =
            scheme.shouldOfferLanguageSelection
            ? scheme.availableLanguages
            : []
        let authoredLanguages = boundedLanguageSet(
            nativeAuthoredLanguages
        )
        let cachedLanguages = boundedLanguageSet(
            nativeLanguages
        )
        let cachedSettings = cache.mediaPresentationSettings(
            for: group
        )
        var authoredSettingCount = 0
        var cachedSettingCount = 0
        var didTruncateInspection =
            authoredLanguages.didOmitValue
            || (!authoredLanguages.values.isEmpty
                && cachedLanguages.didOmitValue)
            || scheme.selectors.count
                > maximumCustomSelectorInspectionCount
        var remainingSettingCount = maximumCustomSettingInspectionCount
        for (selectorIndex, selector) in scheme.selectors.prefix(
            maximumCustomSelectorInspectionCount
        ).enumerated() {
            let nativeSettings = selector.settings
            let retainedSettings = nativeSettings.prefix(
                remainingSettingCount
            )
            authoredSettingCount += retainedSettings.count
            if nativeSettings.count > retainedSettings.count {
                didTruncateInspection = true
            }
            let nativeAvailable = cachedSettings[selector] ?? []
            let available = nativeAvailable.prefix(
                maximumCustomSettingInspectionCount
            )
            var didMissBecauseOfCacheBound = false
            cachedSettingCount +=
                retainedSettings.filter { authored in
                    let matched = available.contains { cached in
                        cached.isEqual(authored)
                    }
                    if !matched,
                        nativeAvailable.count
                            > maximumCustomSettingInspectionCount
                    {
                        didMissBecauseOfCacheBound = true
                    }
                    return matched
                }.count
            didTruncateInspection =
                didTruncateInspection || didMissBecauseOfCacheBound
            remainingSettingCount -= retainedSettings.count
            if remainingSettingCount == 0 {
                if selectorIndex + 1 < scheme.selectors.count {
                    didTruncateInspection = true
                }
                break
            }
        }
        return (
            languages.values,
            languages.wasTruncated,
            customCoverage(
                authoredLanguageCount: authoredLanguages.values.count,
                cachedLanguageCount:
                    authoredLanguages.values.intersection(
                        cachedLanguages.values
                    ).count,
                authoredSettingCount: authoredSettingCount,
                cachedSettingCount: cachedSettingCount,
                didTruncateInspection: didTruncateInspection
            )
        )
    }

}

enum HLSAssetPackageState {
    case missing
    case invalid
    case available
}

enum HLSAssetPackageInspector {
    static func state(
        at location: URL,
        fileManager: FileManager = .default
    ) -> HLSAssetPackageState {
        guard fileManager.fileExists(atPath: location.path) else {
            return .missing
        }
        let values: URLResourceValues
        do {
            values = try location.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            return .invalid
        }
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            return .invalid
        }
        return .available
    }
}
#endif
