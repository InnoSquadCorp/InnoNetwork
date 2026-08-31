# ``InnoNetworkHLSAVFoundation``

Persist HLS streams with AVFoundation's system-managed background download
session and observe playback through value-redacted AVMetrics events.

## Overview

``HLSAssetDownloadSession`` is the system-backed companion to the raw
single-file assembler in `InnoNetworkHLS`. It owns one
`AVAssetDownloadURLSession`, reconnects by background-session identifier, and
keeps downloaded assets at the URLs managed by AVFoundation.

```swift
let session = try HLSAssetDownloadSession(
    configuration: HLSAssetDownloadSessionPack(
        identifier: "com.example.media.hls"
    )
)
let download = try await MainActor.run {
    try session.start(
        HLSAssetDownloadRequest(
            sourceURL: sourceURL,
            title: "Episode 1"
        )
    ) { configuration in
        configuration.primaryContentConfiguration.mediaSelections =
            preferredSelections
    }
}

for await event in session.events(for: download) {
    switch event {
    case .completed(let systemURL):
        let storedAsset = try download.storedAsset(at: systemURL)
        saveAssetReference(storedAsset)
    case .failed(let error):
        report(error)
    default:
        break
    }
}
```

The configuration closure stays synchronous and main-actor isolated so
AVFoundation's non-Sendable download configuration never crosses a concurrency
boundary.
Pass ``HLSAssetDownloadContentPack`` when the system should retain
interstitial assets for offline playback:

```swift
let download = try session.start(
    request,
    content: HLSAssetDownloadContentPack(
        includesInterstitialAssets: true
    )
)
```

The typed pack fails on operating-system versions that do not expose the
corresponding AVFoundation capability instead of silently omitting the
interstitial assets. Xcode 26 also imports this AVFoundation option as
unavailable on every platform, so the typed pack reports
``HLSAssetDownloadSessionError/interstitialAssetsUnavailable`` there; builds
made with Xcode 27 or newer enable it on supported operating-system versions.
The configuration closure remains available for advanced media-selection and
variant controls.

Downloaded assets must remain at the system-provided URL. Do not move them into
an application-selected destination. ``HLSAssetDownloadLibrary`` provides a
versioned, bounded, Codable collection of ``HLSStoredAsset`` references:

```swift
var library = try HLSAssetDownloadLibrary()
library = try library.registering(storedAsset)
save(try JSONEncoder().encode(library))

let inspection = try await storage.inspect(library)
library = try await library.pruningMissingAssets(using: storage)
```

The application owns persistence of the library value, including data
protection and cross-process coordination. The library keeps application
display order stable, replaces an existing identifier in place, rejects
duplicate package locations, and never moves or deletes asset bytes.

On macOS, iOS, and visionOS,
``HLSAssetDownloadStorage`` checks whether the package is still present,
configures the system's best-effort expiration/eviction policy, and removes
packages idempotently. Storage-policy APIs require an identified application
or extension host; command-line processes receive a typed
``HLSAssetDownloadStorageError/storagePolicyUnavailable`` failure instead of
an Objective-C exception. Do not remove an asset while it is being downloaded
or played.

Call
``HLSAssetDownloadSession/handleBackgroundSessionCompletion(_:completion:)``
from the matching application-delegate callback, and retain the session until
``HLSAssetDownloadSession/shutdown(cancelRunningTasks:)`` completes.
Set ``HLSAssetDownloadSessionPack/sharedContainerIdentifier`` when an app
extension owns the background session.

The companion accepts HTTPS assets only. AVFoundation owns media requests,
redirects, trust evaluation, and content-key loading; the request adapters and
custom trust policies from the raw `InnoNetworkHLS` downloader do not apply.
Preflight and lifecycle failures expose localized English and Korean
descriptions, actionable recovery suggestions, and
``HLSAssetDownloadSessionError/isRetriableHint`` for the narrow task-creation
failure that is normally worth retrying.

## Playback configuration

``HLSPlaybackConfigurator`` applies a value-typed command to a caller-owned
`AVPlayerItem` without taking over the player lifecycle:

```swift
let configuration = HLSPlaybackConfiguration.advanced(
    variant: HLSPlaybackVariantPack(
        maximumPeakBitRate: 4_000_000,
        maximumWidth: 1_920,
        maximumHeight: 1_080
    ),
    live: HLSPlaybackLivePack(timeOffsetFromLive: 3),
    mediaSelections: [
        .preferred(
            .audio,
            HLSPlaybackMediaPreference(
                preferredLanguage: "ko",
                selectedCharacteristicsBySelector: [
                    "broadcast": "public.accessibility.describes-video"
                ]
            )
        )
    ]
)

let result = try await HLSPlaybackConfigurator().apply(
    configuration,
    to: playerItem
)
```

Apply the configuration before enqueueing the item when it uses
`startsOnFirstEligibleVariant` or when Custom Media Selection UI should be
established as the item becomes ready. On version 26 and newer systems, keep
the associated `AVPlayer.appliesMediaSelectionCriteriaAutomatically` enabled
so the asset's native `AVCustomMediaSelectionScheme` can take effect. Existing
preferred schemes on the item are preserved and requested schemes are appended
once. Earlier systems choose a compatible `AVMediaSelectionOption` by BCP 47
language and authored media characteristics. The complete command first
resolves every requested group, so a validation failure does not partially
mutate the item. The result reports only media kind and application mechanism,
never option names, languages, or URLs.

### Custom legible media UI

Build custom subtitle and caption controls from a point-in-time value snapshot:

```swift
let configurator = HLSPlaybackConfigurator()
let catalog = try await configurator.legibleMediaCatalog(
    for: playerItem,
    displayLocale: Locale(identifier: "ko")
)

for option in catalog.options {
    renderSubtitle(
        name: option.displayName,
        language: option.languageTag,
        selected: option.isSelected
    )
}

if let korean = catalog.options.first(where: { $0.languageTag == "ko" }) {
    try await configurator.selectLegibleMedia(
        .option(korean.id),
        on: playerItem
    )
}
```

An asset without legible media returns an empty catalog. The catalog retains
no player item, asset, media group, or media option, so its `Sendable` values
can back application-owned UI state. Each option identifier is an opaque
fingerprint of AVFoundation's property-list identity; the property-list values
are never exposed. Use an identifier only with the same current asset, refresh
after asset or media-selection changes, and do not persist it as a content ID.
Exact selection resolves the current option before mutating the item, while
disabled selection respects the group's empty-selection policy.

Applications that prefer AVKit's system-owned menu can use
`AVLegibleMediaOptionsMenuController` directly instead of building custom UI.
InnoNetwork does not retain or own that controller.

## Interstitial playback

``HLSInterstitialPlaybackMonitor`` converts the caller-owned player's
AVFoundation interstitial lifecycle into a bounded stream of `Sendable`
values:

```swift
let interstitials = HLSInterstitialPlaybackMonitor(
    primaryPlayer: player,
    maximumBufferedEventCount: 64
)
let events = interstitials.events()

for await event in events {
    switch event {
    case .currentEventChanged(let current):
        updateInterstitialPresentation(current)
    case .assetListStatusChanged(_, let status, let hadError):
        recordAssetListState(status, failed: hadError)
    case .finished(_, let duration, let completed):
        recordInterstitialFinish(duration, completed: completed)
    default:
        break
    }
}
```

Create the monitor and each event stream on the main actor, while the returned
stream can be consumed from another task. Each stream first yields the current
schedule and current event. Its buffer is clamped to `2...1,024`; when a
consumer falls behind, newer lifecycle updates replace older buffered values.
Create one stream per consumer and cancel its consuming task when observation
ends.

The bridge is deliberately read-only. AVFoundation keeps ownership of
server-authored scheduling and system skip UI; the bridge does not replace the
schedule, cancel playback, or invoke skip controls. Snapshots exclude asset
URLs, asset-list bodies, user-defined attributes, and underlying errors.
Version 26 lifecycle events are emitted only where the operating system
provides them.

## Playback metrics

``HLSPlaybackMetrics`` converts `AVPlayerItem.allMetrics()` into typed events
that are safe to cross concurrency boundaries:

```swift
let metrics = HLSPlaybackMetrics(
    playerItem: playerItem,
    maximumBufferedEventCount: 64
)

for try await event in metrics.events() {
    switch event {
    case .mediaSegmentRequest(_, let mediaType, _, _, let transfer):
        recordSegment(
            mediaType: mediaType,
            duration: transfer?.requestDuration
        )
    case .variantSwitch(_, let phase):
        recordVariantSwitch(phase)
    case .playbackSummary(_, let summary):
        recordSummary(summary)
    default:
        break
    }
}
```

The bridge intentionally excludes resource URLs, server addresses, headers,
session identifiers, task metrics, and arbitrary error values. Observation
failure surfaces only as
``HLSPlaybackMetricsError/observationFailed``. Non-finite numeric values become
`nil`, while negative playback rates remain available for reverse playback.

Each call to ``HLSPlaybackMetrics/events()`` creates an independent,
cancellation-safe AVFoundation subscription. The bounded buffer retains the
newest events, so a slow consumer may miss older metrics. Create one stream per
consumer and drain it promptly when complete event retention matters.

## Playback health analysis

``HLSPlaybackHealthAnalyzer`` is a pure value reducer for one playback
session. It performs no AVFoundation observation or I/O, so applications can
test health policy independently and decide how snapshots affect their UI:

```swift
var analyzer = HLSPlaybackHealthAnalyzer(
    configuration: .advanced(
        thresholds: HLSPlaybackHealthThresholdPack(
            observationWindow: 60,
            slowStartupDuration: 5,
            slowMediaTransferDuration: 2,
            criticalStallCount: 3
        )
    )
)

for try await event in metrics.events() {
    let health = analyzer.ingest(event)
    updatePlaybackHealth(
        status: health.status,
        issues: health.issues
    )
}
```

Stalls, request outcomes, uncached transfer duration, and variant switches use
a bounded rolling window. Initial startup and terminal playback errors remain
session-level signals until ``HLSPlaybackHealthAnalyzer/reset()``. A playback
summary reconciles aggregate stall, recoverable-error, and variant-switch
counts when an upstream bounded stream dropped older events. Snapshots retain
only value-redacted counts and durations; they never introduce URLs, headers,
session identifiers, or underlying errors.

## FairPlay

``HLSFairPlaySession`` makes the AVContentKeySession integration order
explicit without owning a license service:

```swift
let fairPlay = try HLSFairPlaySession(
    delegate: keyDelegate,
    delegateQueue: keyQueue,
    storageDirectoryURL: expiredSessionReportDirectory
)
let protectedAsset = try fairPlay.makeAsset(sourceURL: sourceURL)
let download = try assetDownloadSession.start(
    asset: protectedAsset,
    title: "Protected Episode"
)
```

Keep the FairPlay session alive through download and playback. It strongly
retains the application delegate, attaches each `AVURLAsset` before media
loading begins, and accepts HTTPS sources through the same URL-admission rules
as unprotected downloads. Detach an asset only after both download and
playback finish, then call ``HLSFairPlaySession/expire()`` when the whole key
session is done.

The supplied delegate still owns certificate loading, SPC-to-CKC transport,
renewal, and secure persistable-content-key storage. The optional directory
passed to ``HLSFairPlaySession/init(delegate:delegateQueue:storageDirectoryURL:)``
is only AVFoundation's expired-session-report directory; it is not a key
store. Use `AVContentKeySession`, not the deprecated
`AVAssetResourceLoader` key-loading path.

### Persistent-key workflow

``HLSFairPlayPersistentKeyWorkflow`` coordinates the request-specific
restore-or-create sequence while keeping transport and durable storage
application-owned:

```swift
let persistentKeys = HLSFairPlayPersistentKeyWorkflow(
    transport: appLicenseTransport,
    storage: secureKeyStore
)

func contentKeySession(
    _ session: AVContentKeySession,
    didProvide keyRequest: AVContentKeyRequest
) {
    do {
        try persistentKeys.requestPersistence(for: keyRequest)
    } catch {
        keyRequest.processContentKeyResponseError(error as NSError)
    }
}

func contentKeySession(
    _ session: AVContentKeySession,
    didProvidePersistableContentKeyRequest request:
        AVPersistableContentKeyRequest
) {
    Task {
        try await persistentKeys.fulfill(
            request,
            keyID: appKeyID(for: request),
            acquisition: acquisitionInputs(for: request)
        )
    }
}
```

``HLSFairPlayPersistentKeyStoring`` is queried first. A valid stored key
fulfills playback without an application certificate or license request. When
storage misses, ``HLSFairPlayPersistentKeyAcquisition`` supplies bounded
certificate and content-identifier bytes; the workflow creates the SPC and
passes it to ``HLSFairPlayLicenseTransporting``. Apps can implement that
transport with an `@APIDefinition` endpoint and `DefaultNetworkClient` while
retaining authentication, retry, trust, and response-decoding policy.

Acquisition defaults to FairPlay protocol version `1`, matching AVFoundation's
compatibility behavior. Set `supportedProtocolVersions` to a list such as
`[3, 2, 1]` only after the application's KSM and credential set pass the
matching Apple FairPlay Streaming Server SDK test vectors. Empty, duplicate,
non-positive, or lists with more than 16 values fail before SPC creation.

The workflow validates every material boundary, converts CKC bytes into a
persistable key, requires the app store to commit it before fulfilling the
AVFoundation request, and reports only
``HLSFairPlayPersistentKeyError`` classifications. Forward
`contentKeySession(_:didUpdatePersistableContentKey:forContentKeyIdentifier:)`
through
``HLSFairPlayPersistentKeyWorkflow/storeUpdatedPersistableContentKey(_:for:)``
after mapping AVFoundation's identifier to the app's
``HLSFairPlayKeyID``.

The library does not provide a Keychain schema, write key files, retain
license credentials, or log key identifiers or material. The app remains
responsible for access control, data protection, atomic storage, entitlement
expiry, deletion, and server-side invalidation.

## Topics

### Session

- ``HLSAssetDownloadSession``
- ``HLSAssetDownloadSessionPack``
- ``HLSAssetDownloadSessionError``

### Downloads

- ``HLSAssetDownload``
- ``HLSAssetDownloadRequest``
- ``HLSAssetDownloadContentPack``
- ``HLSAssetDownloadEvent``

### Stored assets

- ``HLSStoredAsset``
- ``HLSStoredAssetAvailability``
- ``HLSAssetDownloadLibrary``
- ``HLSAssetDownloadLibraryItem``
- ``HLSAssetDownloadLibraryError``
- ``HLSAssetDownloadStorage``
- ``HLSAssetDownloadStoragePolicy``
- ``HLSAssetDownloadEvictionPriority``
- ``HLSAssetDownloadStorageError``

### FairPlay

- ``HLSFairPlaySession``
- ``HLSFairPlaySessionError``
- ``HLSFairPlayPersistentKeyWorkflow``
- ``HLSFairPlayPersistentKeyConfiguration``
- ``HLSFairPlayPersistentKeyLimitPack``
- ``HLSFairPlayPersistentKeyAcquisition``
- ``HLSFairPlayPersistentKeyDisposition``
- ``HLSFairPlayPersistentKeyError``
- ``HLSFairPlayKeyID``
- ``HLSFairPlayLicenseRequest``
- ``HLSFairPlayLicenseTransporting``
- ``HLSFairPlayPersistentKeyStoring``

### Interstitial playback

- ``HLSInterstitialPlaybackMonitor``
- ``HLSInterstitialRuntimeEvent``
- ``HLSInterstitialEventSnapshot``
- ``HLSInterstitialAssetListStatus``
- ``HLSInterstitialSkippableState``

### Playback metrics

- ``HLSPlaybackMetrics``
- ``HLSPlaybackMetricsError``
- ``HLSPlaybackMetricEvent``
- ``HLSPlaybackMetricContext``
- ``HLSPlaybackTransferMetric``
- ``HLSPlaybackMetricSummary``
- ``HLSPlaybackMetricMediaType``
- ``HLSPlaybackVariantSwitchPhase``
- ``HLSPlaybackMode``

### Playback health

- ``HLSPlaybackHealthAnalyzer``
- ``HLSPlaybackHealthConfiguration``
- ``HLSPlaybackHealthThresholdPack``
- ``HLSPlaybackHealthSnapshot``
- ``HLSPlaybackHealthStatus``
- ``HLSPlaybackHealthIssue``

### Playback configuration

- ``HLSPlaybackConfigurator``
- ``HLSPlaybackConfiguration``
- ``HLSPlaybackConfigurationResult``
- ``HLSPlaybackConfigurationError``
- ``HLSPlaybackVariantPack``
- ``HLSPlaybackLivePack``
- ``HLSPlaybackInterstitialPolicy``
- ``HLSPlaybackMediaSelection``
- ``HLSPlaybackMediaPreference``
- ``HLSPlaybackMediaKind``
- ``HLSPlaybackAppliedMediaSelection``
- ``HLSPlaybackMediaSelectionResolution``

### Legible media

- ``HLSLegibleMediaCatalog``
- ``HLSLegibleMediaOption``
- ``HLSLegibleMediaOptionID``
- ``HLSLegibleMediaSelection``
- ``HLSLegibleMediaKind``
- ``HLSLegibleMediaProvenance``
- ``HLSLegibleMediaFeature``
