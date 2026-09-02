# ``InnoNetworkHLSAVFoundation``

Persist HLS streams with AVFoundation's system-managed background download
session and observe playback through value-redacted metrics and timed metadata
events.

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
    case .variantSelection(let selection):
        updateSelectedQuality(selection)
    case .downloadSummary(let summary):
        recordDownloadSummary(summary)
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

After AVFoundation completes environment-dependent variant selection,
``HLSAssetDownloadEvent/variantSelection(_:)`` arrives before normal transfer
progress on macOS 14, iOS 16, watchOS 10, visionOS 1, and newer systems.
``HLSAssetDownloadVariantSelection`` retains the total selected count and at
most 64 ``HLSAssetDownloadVariantSummary`` values. It is deduplicated and
replayed to late observers, including after a terminal event, so a background
session can reconnect after the delegate callback. Variant objects and their
media-playlist URLs never cross the public boundary. The selection describes
what AVFoundation chose for the environment when the download started; it is
an observation, not a promise that application preference controls were fully
satisfied.

On version 26 and newer systems, AVFoundation emits one
``HLSAssetDownloadEvent/downloadSummary(_:)`` near the end of a system-managed
download. ``HLSAssetDownloadSummary`` retains non-negative request, byte, and
error counts, a finite duration, and at most 64 URL-free selected-variant
summaries. It does not retain task metrics, URLs, native objects, or underlying
errors. Compare recoverable-error counts only within the same OS version,
because AVFoundation's reporting can change between system updates. Older
systems continue to emit the existing progress, location, and terminal events
without a download summary.

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

Directory presence does not prove that AVFoundation retained a complete
offline rendition. Inspect the stored reference again after relaunch and
before presenting an offline playback action:

```swift
let readiness = try await HLSOfflineAssetInspector().inspect(storedAsset)

switch readiness.state {
case .ready:
    presentOfflinePlayback(
        choices: readiness.mediaSelectionGroups
    )
case .incomplete:
    offerDownloadRepair()
case .missing, .invalidPackage, .unrecognizedPackage:
    removeStaleReference()
@unknown default:
    removeStaleReference()
}
```

``HLSOfflineAssetInspector`` opens only the stored file URL and uses
`AVAssetCache.isPlayableOffline` to distinguish a complete offline rendition
from an existing but incomplete package. Its value-only snapshot contains the
standard audio, video, subtitle, and caption choices that AVFoundation reports
as available offline. Each group retains at most 256 native choices. Language
tags containing control characters or exceeding 128 UTF-8 bytes are omitted;
Custom Media Selection languages are unique, ordered, and capped at 256.

On version 26 and newer systems, the snapshot compares cached Custom Media
Selection languages and selector settings with the authored scheme. Coverage
is reported as none, partial, complete, or indeterminate when bounded
inspection cannot prove completeness. Older systems report the coverage API
as unavailable, and groups without a scheme report it as not authored.
Cancellation is preserved as `CancellationError`; unrelated AVFoundation
media-group load failures produce a partial group list with
`didCompleteMediaSelectionInspection == false` instead of exposing an
underlying error.

`isPlayableOffline` does not promise that every authored media choice is
cached, which is why choices and Custom Media Selection coverage are reported
separately. It also does not validate an application-managed FairPlay
persistent content key. Attach and validate protected-content policy through
the application's ``HLSFairPlaySession`` workflow before playback.

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

## Application-owned local packages

Raw offline and live-DVR receipts from `InnoNetworkHLS` expose an
`HLSLocalPlaybackSource`. Open it through ``HLSLocalPlaybackAsset`` before
creating the player item:

```swift
let localAsset = try await HLSLocalPlaybackAsset(
    source: receipt.playbackSource
)
let playerItem = AVPlayerItem(asset: localAsset.urlAsset)
let player = AVPlayer(playerItem: playerItem)

// Retain localAsset for the complete player-item lifetime.
player.play()

// After playback and all asset loading finish:
localAsset.close()
```

The main-actor owner binds a random path on IPv4 loopback only. Before the
listener starts, it validates bounded reachable playlists, rejects remote or
package-escaping references and symbolic links, then freezes playlist bytes so
later file mutation cannot introduce an external request. Media files are
admitted as regular package-contained files for each GET, HEAD, or single-byte
range request. There is no directory listing and no non-loopback listener.

Keep the owner alive for as long as AVFoundation may load or seek within the
asset; ``HLSLocalPlaybackAsset/close()`` is idempotent and makes later resource
loads fail. The bridge does not run as a background download service, grant
background execution time, validate FairPlay keys, or convert arbitrary local
HLS trees. Use ``HLSAssetDownloadSession`` for system-managed persistence and
the application's ``HLSFairPlaySession`` policy for protected playback.

## Playback configuration

Configure CMCD before creating a player item or otherwise loading the asset:

```swift
let asset = AVURLAsset(url: sourceURL)
let cmcdStatus = HLSPlaybackAssetConfigurator().apply(
    .enabled,
    to: asset
)
let playerItem = AVPlayerItem(asset: asset)
```

AVFoundation owns every generated CMCD header name and value. The typed result
reports when the operating system cannot enable the feature, and the caller
continues to own the asset and player lifecycle. watchOS reports
``HLSCommonMediaClientDataStatus/unavailable`` because it does not expose the
asset resource loader needed to configure this behavior.

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

## Timed metadata

``HLSTimedMetadataMonitor`` observes ID3 and other allowlisted metadata through
`AVPlayerItemMetadataOutput`. It never uses the deprecated
`AVPlayerItem.timedMetadata` property and never passes `nil` identifiers to the
native output:

```swift
let metadataConfiguration = HLSTimedMetadataConfiguration.advanced(
    fields: [
        .text(.id3Title, maximumUTF8ByteCount: 1_024),
        .text(.id3LeadPerformer, maximumUTF8ByteCount: 1_024),
        .redacted(.id3Private),
    ],
    advanceInterval: 0.25,
    maximumBufferedEventCount: 64
)
let metadata = try HLSTimedMetadataMonitor(
    playerItem: playerItem,
    configuration: metadataConfiguration
)

for await event in metadata.events() {
    switch event {
    case .metadata(let group):
        consume(group.items)
    case .sequenceFlushed:
        discardQueuedMetadata()
    case .eventsDropped(let count):
        recordMetadataLoss(count)
    }
}
```

Start with ``HLSTimedMetadataConfiguration/safeDefaults(identifiers:)`` when
only identifier and timing should cross the boundary. Text, number, and date
access are per-identifier opt-ins. Text is UTF-8 bounded, numbers must be
finite, language tags are bounded and control-character free, and failed or
type-mismatched loads become ``HLSTimedMetadataValue/unavailable`` without an
underlying value or error. Raw data and URL objects have no public value case.

The monitor is main-actor lifecycle state around a caller-owned player item.
Each ``HLSTimedMetadataMonitor/events()`` call creates an independent bounded
subscriber that retains the newest events. ``HLSTimedMetadataEvent/eventsDropped(count:)``
reports native callbacks discarded before asynchronous value mapping; a slow
subscriber may still replace its own older buffered values by design. Seeking
and playback-direction changes produce
``HLSTimedMetadataEvent/sequenceFlushed``. Call
``HLSTimedMetadataMonitor/detach()`` when observation should end early.

This initial contract does not decode arbitrary ID3 payloads or fragmented-MP4
`emsg` boxes. Add a typed representation only after a checked-in playback
fixture proves the native AVFoundation value shape.

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

## Integrated playback timeline

On macOS 15, iOS and tvOS 18, watchOS 11, and visionOS 2 or newer,
``HLSIntegratedTimelineMonitor`` turns
`AVPlayerItem.integratedTimeline` into value-only snapshots suitable for
custom player UI:

```swift
let timeline = HLSIntegratedTimelineMonitor(
    playerItem: playerItem,
    updateInterval: 0.5,
    maximumBufferedUpdateCount: 64
)

for await update in timeline.updates() {
    let currentSegment = update.snapshot.currentSegmentIndex.map {
        update.snapshot.segments[$0]
    }
    renderTimeline(
        duration: update.snapshot.duration,
        playhead: update.snapshot.currentTime,
        currentKind: currentSegment?.kind,
        reason: update.reason
    )
}
```

The monitor combines sampled playhead changes with AVFoundation's native
segment, current-segment, and loaded-range invalidations. It enqueues an
initial state before observation begins. Each call to
``HLSIntegratedTimelineMonitor/updates()`` creates an independent newest-value
buffer; prolonged unconsumed streams can replace older updates, including the
initial one. Cancel the consuming task when observation ends.

Each ``HLSIntegratedTimelineSnapshot`` retains at most 1,024 chronological
segments, and each segment retains at most 256 native loaded ranges. Truncation
flags distinguish a complete value from a bounded prefix. Interstitial
identifiers are limited to 1,024 UTF-8 bytes with an explicit truncation flag.
Invalid, indefinite, negative-duration, and non-finite native times become
`nil`; a point interstitial remains an empty integrated range rather than
being discarded.

Snapshots exclude player items, assets, template items, URLs, custom
attributes, asset-list responses, and underlying errors. The monitor retains
the caller-owned primary item only for observation lifetime and remains
read-only: the application and AVFoundation continue to own playback, seeking,
interstitial scheduling, skip controls, and navigation restrictions.

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
let protectedAssetID = HLSFairPlayAssetID()
let protectedAsset = try fairPlay.makeAsset(
    sourceURL: sourceURL,
    assetID: protectedAssetID
)
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

On version 26 and newer, classify each delegate request against the same
caller-known identity without retaining a URL or native recipient:

```swift
let origin = fairPlay.requestOriginResolver.origin(of: request)
switch origin {
case .attachedAsset(let assetID) where assetID == protectedAssetID:
    recordPrimaryAssetKeyRequest()
case .noRecipient:
    recordPreloadedKeyRequest()
case .unrecognizedRecipient:
    recordUnregisteredRecipient()
case .unavailable:
    break
case .attachedAsset:
    recordOtherAttachedAssetKeyRequest()
}
```

``HLSFairPlayContentKeyRequestOrigin/unavailable`` preserves the package's
lower deployment targets. ``HLSFairPlayContentKeyRequestOrigin/noRecipient``
means AVFoundation reported no originating recipient, which includes direct
application requests, while
``HLSFairPlayContentKeyRequestOrigin/unrecognizedRecipient`` means the native
recipient was not created through this wrapper. Asset identifiers are opaque
UUIDs and must be unique among currently attached assets; detaching an asset
releases its identifier for reuse. The resolver is thread-safe and independent
of the main actor, so a content-key delegate can retain only
``HLSFairPlayContentKeyRequestOriginResolver`` and classify the request
immediately on its delegate queue without creating a retain cycle back to the
session.

The supplied delegate still owns certificate loading, SPC-to-CKC transport,
renewal, and secure persistable-content-key storage. The optional directory
passed to ``HLSFairPlaySession/init(delegate:delegateQueue:storageDirectoryURL:)``
is only AVFoundation's expired-session-report directory; it is not a key
store. Use `AVContentKeySession`, not the deprecated
`AVAssetResourceLoader` key-loading path.

### Streaming-key workflow

``HLSFairPlayStreamingKeyWorkflow`` uses the same application-owned
``HLSFairPlayLicenseTransporting`` boundary for both initial and renewing
streaming keys:

```swift
let streamingKeys = HLSFairPlayStreamingKeyWorkflow(
    transport: appLicenseTransport
)

func contentKeySession(
    _ session: AVContentKeySession,
    didProvide request: AVContentKeyRequest
) {
    Task {
        try await streamingKeys.fulfill(
            request,
            keyID: appKeyID(for: request),
            acquisition: acquisitionInputs(for: request),
            purpose: .initial
        )
    }
}

func contentKeySession(
    _ session: AVContentKeySession,
    didProvideRenewingContentKeyRequest request: AVContentKeyRequest
) {
    Task {
        try await streamingKeys.fulfill(
            request,
            keyID: appKeyID(for: request),
            acquisition: acquisitionInputs(for: request),
            purpose: .renewal
        )
    }
}
```

A successful return emits
``HLSFairPlayContentKeyEvent/responseSubmitted(_:)`` because AVFoundation has
received, but not necessarily accepted, the CKC. Emit
``HLSFairPlayContentKeyEvent/responseAccepted(_:)`` only from
`contentKeySession(_:contentKeyRequestDidSucceed:)`. Map retry and terminal
delegate callbacks through ``HLSFairPlayContentKeyRetryReason`` and
``HLSFairPlayContentKeyFailureReason`` so diagnostics do not retain response
data, identifiers, or underlying error payloads.

The workflow defaults to protocol version `1`. Protocol version `3` requires
an SDK 26 application certificate and a matching KSM that has passed Apple's
test vectors. The opt-in physical-device gate is documented in
`Tests/FairPlayAcceptance/README.md` and runs through
`Scripts/run_fairplay_acceptance.sh`. Its HTTPS KSM adapter receives raw SPC
bytes and must return raw CKC bytes; this operational bridge is intentionally
not a library transport policy.

On version 26 or newer, an acquisition can opt into randomizing the anonymized
device identifier embedded in its SPC:

```swift
let acquisition = HLSFairPlayStreamingKeyAcquisition(
    applicationCertificate: certificate,
    contentIdentifier: contentID,
    deviceIdentifierPolicy: .randomized
)
```

``HLSFairPlayDeviceIdentifierPolicy/systemDefault`` preserves AVFoundation's
existing behavior on every supported deployment target. Randomized policies
fail with a typed error before SPC generation on earlier systems. Coordinate
the policy with the application's KSM, entitlement rules, privacy disclosures,
and tracking-consent obligations before enabling it. If the application needs
``HLSFairPlayDeviceIdentifierPolicy/randomizedWithSeed(_:)``, generate the
exactly 16-byte seed with a cryptographically secure random source and never
log it; the library validates and forwards the seed but does not create,
persist, or rotate it.

The application and KSM must not retain or use FairPlay's anonymized device
identifier for purposes other than enforcing playback business-rule limits.
Use App Tracking Transparency when the application or its key service collects
end-user data and shares it with another company for cross-app or cross-site
tracking.

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
Persistent acquisition uses the same
``HLSFairPlayDeviceIdentifierPolicy`` contract as streaming acquisition, and
applies it only after a stored-key miss requires a new SPC.

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

For offline playback, create a validated ``HLSStoredAsset`` from the
AVFoundation-delivered package URL, recreate the application delegate and
secure key store, then attach the package with
``HLSFairPlaySession/makeAsset(storedAsset:)`` before creating the player item.
Use ``HLSOfflineAssetInspector`` first when the UI needs a readiness decision.
The stored-asset convenience is unavailable on watchOS, where this companion
does not ship its package storage and readiness types.

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
- ``HLSAssetDownloadSummary``
- ``HLSAssetDownloadVariantSelection``
- ``HLSAssetDownloadVariantSummary``

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

### Application-owned local playback

- ``HLSLocalPlaybackAsset``
- ``HLSLocalPlaybackAssetError``

### FairPlay

- ``HLSFairPlayAssetID``
- ``HLSFairPlayContentKeyRequestOrigin``
- ``HLSFairPlayContentKeyRequestOriginResolver``
- ``HLSFairPlaySession``
- ``HLSFairPlaySessionError``
- ``HLSFairPlayDeviceIdentifierPolicy``
- ``HLSFairPlayStreamingKeyWorkflow``
- ``HLSFairPlayStreamingKeyConfiguration``
- ``HLSFairPlayStreamingKeyLimitPack``
- ``HLSFairPlayStreamingKeyAcquisition``
- ``HLSFairPlayStreamingKeyError``
- ``HLSFairPlayLicenseRequestPurpose``
- ``HLSFairPlayContentKeyEvent``
- ``HLSFairPlayContentKeyRetryReason``
- ``HLSFairPlayContentKeyFailureReason``
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

### Timed metadata

- ``HLSTimedMetadataMonitor``
- ``HLSTimedMetadataConfiguration``
- ``HLSTimedMetadataField``
- ``HLSTimedMetadataIdentifier``
- ``HLSTimedMetadataValueExposure``
- ``HLSTimedMetadataEvent``
- ``HLSTimedMetadataGroup``
- ``HLSTimedMetadataItem``
- ``HLSTimedMetadataValue``
- ``HLSTimedMetadataSource``
- ``HLSTimedMetadataError``

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

- ``HLSPlaybackAssetConfigurator``
- ``HLSCommonMediaClientDataPolicy``
- ``HLSCommonMediaClientDataStatus``
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
