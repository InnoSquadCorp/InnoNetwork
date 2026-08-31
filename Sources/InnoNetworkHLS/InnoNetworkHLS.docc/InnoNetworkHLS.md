# ``InnoNetworkHLS``

Resolve and download non-DRM HLS VOD streams with bounded transfers.

## Overview

`InnoNetworkHLS` is an optional companion product. It resolves multivariant
playlists, chooses a deterministic stream, and downloads media resources in
playlist order without launching a browser or external process.

Use ``PlaylistResolver`` and ``VariantSelector`` when an application wants a
deterministic variant URL and output container. Pass either a media playlist
or multivariant playlist to ``HLSDownloader`` for VOD assembly. Playlist
documents, each media resource, and the complete logical download are
transferred with explicit byte limits. The downloader checks destination-volume
capacity before the first request and reserves capacity again around every
staging and assembly write. It retries transient whole-resource attempts
through InnoNetwork's core retry policy, persists durable resource-boundary
checkpoints, and uses bounded parallel prefetch while preserving playlist
assembly order. Initial and adapter-rewritten URLs pass through the same secure
network-URL admission as core requests.

```swift
import Foundation
import InnoNetworkHLS

let sourceURL = URL(string: "https://media.example/master.m3u8")!
let destinationURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("video.ts")

let downloader = HLSDownloader()
for await event in downloader.download(
    sourceURL: sourceURL,
    destinationURL: destinationURL
) {
    switch event {
    case .progress(let progress):
        if let percent = progress.percentCompleted {
            print("\(progress.totalBytesWritten) bytes (\(percent)%)")
        } else {
            print("\(progress.totalBytesWritten) bytes")
        }
    case .completed(let fileURL):
        print(fileURL)
    case .failed(let error):
        print(error.localizedDescription)
    case .cancelled:
        break
    }
}
```

For authenticated media or custom transport policy, inject the same
`URLSession` and `NetworkRequestContext` used by the rest of the application.
``HLSRequestPolicy`` adds an HLS-specific purpose so authentication can vary
without guessing from URL suffixes:

```swift
import Foundation
import InnoNetwork
import InnoNetworkHLS

let session = URLSession(configuration: .ephemeral)
let requestContext = NetworkRequestContext()
let token = "<access token>"
let configuration = HLSDownloadConfiguration.advanced(
    storage: HLSStoragePack(
        maximumTotalDownloadBytes: 4 * 1_024 * 1_024 * 1_024,
        diskCapacityPolicy: .required(
            minimumAvailableCapacity: 1_024 * 1_024 * 1_024
        )
    ),
    variantSelectionPolicy: .maximumResolution(
        width: 1_920,
        height: 1_080
    ),
    transfer: HLSTransferPack(
        maximumConcurrentResourceTransfers: 2,
        retryPolicy: ExponentialBackoffRetryPolicy(maxRetries: 2)
    )
)
let downloader = HLSDownloader(
    session: session,
    configuration: configuration,
    requestContext: requestContext,
    requestPolicy: HLSRequestPolicy { request, context in
        var request = request
        switch context.purpose {
        case .entryPlaylist, .mediaPlaylist, .mediaResource:
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        case .encryptionKey, .contentSteeringManifest:
            break
        }
        return request
    }
)
```

``HLSRequestEventObserving`` receives purpose-aware start, response, and
pre-response failure events. The event model contains no URL, header, query
value, body, or arbitrary error string; use core
``InnoNetwork/NetworkEventObserving`` for full transport lifecycle and metrics.
The legacy single-argument request adapter initializer remains available for
source compatibility.

Use ``HLSDiskCapacityPolicy/required(minimumAvailableCapacity:)`` when capacity
must be known, ``HLSDiskCapacityPolicy/bestEffort(minimumAvailableCapacity:)``
when an unavailable capacity value may proceed, or
``HLSDiskCapacityPolicy/disabled`` when the application owns storage admission.
``HLSResumePolicy/automatic`` is the default and resumes only when the source
still resolves to the same media-playlist content identity, HTTP validators,
and ordered transfer plan. Use
``HLSResumePolicy/disabled`` when the application requires terminal cleanup
instead.
Resume metadata stores URL and validator fingerprints instead of their raw
values so signed query parameters are not copied into the checkpoint manifest.
Constrained variant policies fail with
``HLSDownloadError/noVariantMatchesSelectionPolicy(_:)`` rather than silently
selecting a stream that exceeds the requested limit.

Use ``HLSPlaybackCapabilities`` with
``HLSVariantSelectionPolicy/compatible(_:)`` to constrain resolution,
bandwidth, and advertised codec prefixes while preferring a video dynamic
range. ``HLSPlaylist/renditions`` exposes typed audio, video, subtitle, and
closed-caption metadata, while ``HLSPlaylist/iFrameVariants`` keeps trick-play
streams separate from regular playback variants;
``RenditionSelector`` selects within a referenced group by default, name, or
ordered BCP 47 language preference. The single-file downloader still chooses
only variants with in-band audio and never silently appends separately timed
tracks.

``HLSMediaCharacteristic`` gives standard and future `CHARACTERISTICS` values
one extensible type. ``HLSRendition/isMachineGenerated`` and
``HLSRendition/isTranslated`` are conveniences for Apple's generated and
translated rendition tags. Use ``HLSSubtitleProvenancePolicy`` to exclude or
prefer those subtitle sources without replacing the explicit language or name
policy:

```swift
let subtitle = RenditionSelector().select(
    in: playlist,
    groupID: "subtitles",
    kind: .subtitles,
    policy: .preferredLanguages(["ko", "en"]),
    subtitleProvenance: HLSSubtitleProvenancePolicy(
        machineGenerated: .excluded
    )
)
```

Exclusion runs first. An explicit language or name remains the primary
constraint, and provenance preference breaks ties inside that match. With
``HLSRenditionSelectionPolicy/defaultOrFirst``, provenance preference is
applied before the playlist's default and autoselect flags. The neutral
default preserves the existing playlist-order behavior.

Use ``HLSOfflinePackageDownloader`` when external audio, video, subtitles, or
I-frame trick-play streams must be retained without remuxing. It downloads
each selected playlist's resources,
rewrites byte-range and resource references to package-local paths, creates a
local multivariant `index.m3u8`, and commits the complete directory atomically.
The package manifest records only local paths and selection metadata; source
URLs and signed query values are not persisted.

```swift
let packageDownloader = HLSOfflinePackageDownloader(
    configuration: .advanced(
        storage: HLSOfflinePackageStoragePack(
            maximumTotalDownloadBytes: 4 * 1_024 * 1_024 * 1_024
        ),
        variantSelectionPolicy: .maximumResolution(
            width: 1_920,
            height: 1_080
        ),
        renditions: HLSOfflineRenditionPack(
            audio: .preferredLanguages(["ko", "en"]),
            video: .defaultOrFirst,
            subtitles: .preferredLanguages(["ko", "en"]),
            subtitleProvenance: HLSSubtitleProvenancePolicy(
                translation: .excluded
            ),
            includesIFrameTrickPlay: true
        )
    )
)
let package = try await packageDownloader.downloadPackage(
    sourceURL: sourceURL,
    destinationDirectoryURL:
        FileManager.default.temporaryDirectory
        .appendingPathComponent("episode.hlspkg")
)
print(package.entryPlaylistURL)
```

Reopen a committed directory through ``HLSOfflinePackageStore`` before using
its local entry point:

```swift
let reopened = try HLSOfflinePackageStore().open(
    at: package.directoryURL
)
print(reopened.entryPlaylistURL)
```

New packages use manifest schema 3. Reopening verifies the local playlist
closure, exact file membership, byte counts, and streaming SHA-256 records;
schema 1 and 2 remain readable with structural validation only. The digest is
an accidental-corruption check, not an authenticity signature. Validation is
synchronous and reads every package byte, so run it away from latency-sensitive
UI work for large packages. The reopened receipt's selected variant URL is the
local primary playlist URL.
Generated and translated characteristics are retained exactly in the package
manifest and remain available through
``HLSOfflinePackageTrack/mediaCharacteristics``,
``HLSOfflinePackageTrack/isMachineGenerated``, and
``HLSOfflinePackageTrack/isTranslated`` after reopening.

Package creation is all-or-nothing. Automatic resume retains implementation-
private, destination-scoped resource checkpoints after failure or cancellation,
but still exposes only the complete atomically committed directory. Each
retained resource is size- and checksum-validated; changed playlist identity,
HTTP validators, rendition metadata, ordered resources, or AES key fingerprints
discard the stale workspace. Set `resumePolicy: .disabled` on
``HLSOfflinePackageStoragePack`` for terminal cleanup. The completed receipt's
``HLSOfflinePackageReceipt/resumedResourceTransferCount`` reports reused
resources. Use ``HLSOfflinePackageDownloader/prepare(sourceURL:)`` to inspect
the selected local-track layout, selected trick-play variant, and resource
count before choosing a destination. The preparation and committed or reopened
receipt expose that stream through
``HLSOfflinePackagePreparation/selectedIFrameVariant`` and
``HLSOfflinePackageReceipt/selectedIFrameVariant``. URI-bearing media
extensions that the parser cannot model are
rejected rather than leaving a hidden remote dependency in the package.
Rendition selection defaults to at most eight external audio, video, or
subtitle playlists per kind and is always clamped to 32; exceeding the
configured bound fails before those rendition playlists are requested.
External video and I-frame retention are opt-in so existing storage behavior
does not change. I-frame selection first matches the selected regular variant's
resolution when possible, then applies the configured variant policy.
The entry playlist is a self-contained package index, not a promise that
AVFoundation will play an arbitrary local `file://` HLS tree. Use it from an
application-owned serving or resource-loader layer. For directly playable
system-managed offline assets, use the `InnoNetworkHLSAVFoundation` product.

Use ``HLSDownloader/prepare(sourceURL:)`` to resolve the current selection
without creating files or reserving a destination:

```swift
let preparation = try await downloader.prepare(sourceURL: sourceURL)
print(
    "\(preparation.segmentCount) segments as "
        + preparation.mediaContainer.fileExtension
)
```

Preparation is advisory. A later download resolves playlists again so changed
network metadata cannot be executed as a stale plan.

Inspect an already fetched playlist before presenting a download action:

```swift
let inspection = PlaylistResolver().inspect(
    playlistText,
    relativeTo: sourceURL
)

if inspection.canCreateOfflinePackage {
    showOfflineAction()
}
for diagnostic in inspection.diagnostics {
    record(
        code: diagnostic.code,
        severity: diagnostic.severity,
        scope: diagnostic.scope,
        lineNumber: diagnostic.lineNumber
    )
}
```

``HLSPlaylistInspection`` separates bounded document validity from raw
single-file and offline-package capability. Its ordered
``HLSPlaylistDiagnostic`` values contain only a classification, severity,
operation scope, optional one-based line number, and optional modeled media
feature. Diagnostic payloads never retain a source line, URL, attribute value,
or signed query value. The parsed
``HLSPlaylistInspection/playlist`` remains the normal playlist model and can
contain resolved URLs. Warnings are advisory; an error blocks only its declared
scope. Document inspection is deliberately local to the supplied text. For
authoring and CI that must validate the complete presentation relationship,
use bounded graph inspection:

```swift
let graph = try await resolver.inspectPresentation(
    from: sourceURL,
    using: .advanced(
        limits: HLSPresentationInspectionLimitPack(
            maximumPlaylistCount: 32,
            maximumConcurrentRequests: 4,
            maximumTotalPlaylistBytes: 16 * 1_024 * 1_024
        )
    )
)

for diagnostic in graph.diagnostics {
    record(
        code: diagnostic.code,
        playlistIndex: diagnostic.playlistIndex,
        relatedPlaylistIndex: diagnostic.relatedPlaylistIndex
    )
}
```

``PlaylistResolver/inspectPresentation(from:using:)`` fetches only bounded
playlist documents and never media segments. It coalesces duplicate references,
ignores unreferenced rendition groups, retains deterministic playlist indices,
and applies the explicitly reported
``HLSPresentationConformanceRevision/hlsSecondEditionDraft22`` contract. Graph
diagnostics expose only stable codes and indices; the returned playlist models
remain the opt-in surface for resolved URLs. Playlist-only evidence verifies
target duration, playlist type, segment-boundary alignment where VOD or
program-date-time provides an anchor, discontinuity sequences, program-date-time
mapping, corresponding Date Range attributes, and server control. It does not
replace media timestamp inspection, Apple Media Stream Validator, or playback
testing.

Authoring tools and CI can opt into Apple-oriented recommendations without
changing download capability:

```swift
let inspection = PlaylistResolver().inspect(
    playlistText,
    relativeTo: sourceURL,
    using: .appleAuthoring
)

for recommendation in inspection.appleAuthoringDiagnostics {
    print(recommendation.code, recommendation.lineNumber as Any)
}
```

The pack checks playlist-only evidence such as target duration, independent
segments, TLS, variant order, codec, average-bandwidth, resolution, frame-rate,
mixed dynamic-range and score declarations, caption language, Content Steering
identity, LL-HLS timeline/hold-back, and feature-compatible protocol versions.
These warnings are a fast authoring feedback layer, not a replacement for
Apple's media-level validation tools or playback testing.

Playlist inspection exposes selection-grade HLS 2nd Edition metadata without
leaking raw attribute dictionaries. ``HLSPlaylist/protocolVersion`` and
``HLSPlaylist/hasIndependentSegments`` describe document-wide compatibility;
``HLSVariant`` carries author score, supplemental codecs, stable identity,
pathway, and referenced media groups; ``HLSPlaylist/iFrameVariants`` represents
`EXT-X-I-FRAME-STREAM-INF` without mixing it into adaptive playback selection;
and ``HLSRendition`` carries associated
language, stable identity, in-stream identity, accessibility characteristics,
and audio format hints. Application-owned offline packages can opt into
external video and I-frame-only playlists while the single-file assembler
continues to reject I-frame-only media. Duplicate or malformed
attribute-list entries are rejected instead of being silently overwritten.

Draft-22 media metadata is available directly from ``HLSPlaylist``:
``HLSPlaylist/targetDuration``, ``HLSPlaylist/mediaSequence``,
``HLSPlaylist/discontinuitySequence``,
``HLSPlaylist/mediaPlaylistType``, and
``HLSPlaylist/segmentBitrates`` preserve the effective playlist and
per-segment values. ``HLSVariant/hdcpLevel``,
``HLSVariant/allowedContentProtectionConfigurations``, and
``HLSVariant/requiredVideoLayouts`` model playback constraints without
exposing a raw attribute dictionary. A variant with an unrecognized
`VIDEO-RANGE` or `REQ-VIDEO-LAYOUT` value is ineligible while other compatible
variants remain available.

Multivariant session metadata is available through
``HLSPlaylist/sessionData`` and ``HLSPlaylist/sessionKeys``.
``HLSSessionData`` keeps an inline value or a resolved `JSON`/`RAW` remote
resource together with its data identifier and language, while
``HLSSessionKey`` exposes
key-delivery metadata such as the method, resolved URL, format, versions, and
optional initialization vector. Playlist resolution never requests or stores
key bytes. These normal playlist models can contain source values and resolved
URLs; value-redaction applies to ``HLSPlaylistDiagnostic`` and Content
Steering events, not to the requested inspection result.

Remote Session Data, Custom Media Selection Schemes, Apple interstitial asset
lists, Date Range preload resources, and Date Range Schedules stay opt-in. Use
``HLSExternalResourceResolver`` to apply the same URL admission, redirect,
request-policy, and bounded-body pipeline:

```swift
let resources = HLSExternalResourceResolver(
    configuration: HLSExternalResourcePack(
        maximumSessionDataBytes: 256 * 1_024,
        maximumCustomMediaSelectionEntryCount: 256,
        maximumInterstitialAssetCount: 100,
        maximumDateRangeResourceBytes: 256 * 1_024,
        maximumScheduledDateRangeCount: 100
    )
)
let value = try await resources.resolveSessionData(sessionData)
let customScheme = try await resources.resolveCustomMediaSelection(
    in: playlist
)
let resolvedInterstitial = try await resources.resolveInterstitial(interstitial)
let preloaded = try await resources.preloadDateRangeResource(preloadRange)
let schedule = try await resources.resolveDateRangeSchedule(
    scheduleRange,
    preloadedResource: preloaded,
    occupiedDateRangeIDs: Set(playlist.dateRanges.map(\.id))
)
```

JSON Session Data is validated while preserving its original bytes. Apple
asset-list JSON requires the case-sensitive `ASSETS`, `URI`, and `DURATION`
members; entries remain in declaration order. ``HLSInterstitial`` also exposes
typed timeline occupancy/style, navigation restrictions, and skip-control
metadata for custom player UI. Missing or future timeline values use the HLS
defaults of point occupancy and highlighted style; unsupported restriction
tokens are ignored. A positive resume offset does not implicitly change point
occupancy because clients may apply that presentation policy differently.

``HLSInterstitialAssetResolution`` returns the ordered assets together with the
effective skip control after applying any asset-list `SKIP-CONTROL` fields over
their playlist-level counterparts. A missing skip offset does not make the
interstitial eligible to skip, and label IDs remain application localization
keys. Navigation enforcement, scheduling, localization, and UI remain with the
application or AVFoundation. Direct `X-ASSET-URI` sources return one asset
without a network request. The source-compatible
``HLSExternalResourceResolver/resolveInterstitialAssets(_:)`` operation remains
available when only the asset sequence is needed.

The reserved `_hls.media-presentation-settings` declaration resolves into
``HLSCustomMediaSelectionScheme``. Its presentation selectors remain in
author-defined priority order, localized names use deterministic BCP 47
fallbacks, and language decorations apply only to matching rendition
characteristics. ``CustomMediaSelector`` treats language as the highest
preference when offered, then honors settings in scheme order:

```swift
let selectedAudio = customScheme.flatMap {
    CustomMediaSelector().select(
        in: playlist,
        groupID: "audio",
        kind: .audio,
        scheme: $0,
        preferences: HLSCustomMediaSelectionPreferences(
            preferredLanguage: "ko",
            selectedCharacteristicsBySelector: [
                "Origin": "com.example.broadcast-source.home-team"
            ]
        )
    )
}
```

Media-playlist inspection also exposes typed timeline metadata.
``HLSPlaylist/preferredStartPosition`` represents `EXT-X-START`;
``HLSPlaylist/programDateTimes`` associates each
``HLSProgramDateTime/date`` with a zero-based segment index; and
``HLSPlaylist/dateRanges`` consolidates repeated `EXT-X-DATERANGE` tags by
identifier. Date Range extension values stay private: the public model exposes
only their names plus typed interstitial and external-resource URLs. External
interstitial, schedule, and preload resources block raw assembly and
application-owned offline packaging instead of leaving remote references in a
local playlist. Use the `InnoNetworkHLSAVFoundation` companion when the system
should retain interstitial assets.

``HLSDateRangePreload`` retains the target identity and join-duration
metadata, while ``HLSPreloadedDateRangeResource`` keeps bounded opaque bytes
until the target appears. A matching preload is reused only when target ID,
class, and resource URL agree. ``HLSDateRangeSchedule`` recursively resolves
the schedule's ordered `DATERANGES` members, enforces playlist-wide ID
uniqueness and parent bounds, honors `PRE`/`POST` cue rules, and limits both
entry count and nesting depth. Pass `_HLS_start_offset` through the
`startOffset` argument when joining within an active schedule.

`EXT-X-DEFINE` references are expanded only after their declaration. Local
`NAME`/`VALUE` definitions, explicit multivariant-to-media `IMPORT` values,
and percent-decoded `QUERYPARAM` values from the final redirected playlist URL
are supported. Variable expansion remains bounded by the playlist byte limit,
enforces HLS compatibility versions 8 and 11, and never recursively expands a
replacement value. Offline localization strips definitions and rejects any
unresolved reference so signed query values are not persisted.

Multivariant inspection exposes the resolved
``HLSPlaylist/contentSteering`` declaration. Download configuration enables
bounded Content Steering by default through ``HLSContentSteeringPack``. The
resolver honors VERSION 1 manifest priority, TTL and reload caching, initial-
pathway fallback, `data:` manifests, and pathway cloning with host, query,
stable-variant, and stable-rendition URI replacement. It attempts eligible
pathway media playlists in priority order before a transfer plan is committed.
Pathway cloning and stable-variant overrides apply to regular and I-frame
variants alike.
Set `contentSteering: .disabled` on an `advanced` configuration to skip the
manifest request while retaining deterministic declared-pathway failover.

After the configured retry policy is exhausted, a transient single-file media
resource failure can lazily activate the next pathway. Transfer-time failover
requires the same non-empty stable variant ID, media characteristics,
container, resource count, URL paths, byte ranges, encryption layout, and IVs;
otherwise the original terminal error is preserved. Disable this recovery with
`HLSContentSteeringPack(allowsTransferFailover: false)`.

Pass ``HLSContentSteeringEventObserving`` values to
``HLSContentSteeringPack/init(maximumManifestBytes:allowsTransferFailover:healthPolicy:eventObservers:)``
to observe ordered playlist and resource pathway attempts, failures, and
selections. Events expose only pathway IDs, resource indexes, and stable
``HLSDownloadErrorCode`` values; request URLs, headers, and query values remain
private. Observer handling participates in operation backpressure and should
stay bounded.

Use ``HLSContentSteeringHealthPolicy`` to choose a consecutive-failure
threshold and bounded recovery cooldown. Each prepare, download, offline-
package operation, one-shot live snapshot, or live snapshot stream owns an
independent health session. A penalized pathway is skipped while another
compatible pathway is available, becomes eligible after cooldown, and remains
the fallback when every alternative is also penalized, as required by Content
Steering evaluation. ``HLSContentSteeringEvent/pathwayHealthChanged(_:)``
provides per-pathway attempts, outcomes, success rate, consecutive failures,
availability, and selection-reason counts. The paired
``HLSContentSteeringEvent/pathwaySelectionChanged(fromPathwayID:toPathwayID:reason:)``
reports initial, failure-driven, and cooldown-recovery selection without
copying a media or Steering Manifest URL.

Offline planning requires stable variant and external-rendition identifiers
across every eligible pathway before any media resource is requested. When
trick-play retention is enabled, I-frame variant identity must also remain
stable and distinct across pathways.

Media-playlist inspection exposes Low-Latency HLS declarations through
``HLSPlaylist/lowLatency``. ``HLSLowLatencyMetadata`` groups typed server
control, partial-segment target and ranges, preload hints, rendition reports,
and delta-update history. The parser validates the version 9 requirement for
`EXT-X-SKIP`, version 10 when skipped Date Ranges are reported, hold-back
relationships, partial durations, adjacent implicit byte ranges, required URI
quoting, relative rendition-report references, and sequence indexes.
`TYPE=KEY` hints expose ``HLSEncryptionKeyPreload`` metadata and an optional
estimated first-use date without requesting or retaining key bytes.

This is an inspection surface, not an LL-HLS playback client. Server-control
metadata alone does not block a complete VOD download. Partial segments and
delta updates block both persistence paths because media history may be
incomplete. Preload hints and rendition reports can be ignored by complete
single-file assembly, but block application-owned offline packages because
their external references are not localized. Use AVFoundation or another
low-latency-aware playback stack for live workflows.
The `InnoNetworkHLSLive` companion can spread application-owned key-preload
callbacks across the estimated first-use window.

When progress is not needed, await a committed receipt and handle the same typed
terminal failures with ordinary error handling:

```swift
do {
    let receipt = try await downloader.downloadReceipt(
        sourceURL: sourceURL,
        destinationURL: destinationURL
    )
    print("\(receipt.byteCount) bytes at \(receipt.destinationURL)")
} catch let error as HLSDownloadError {
    print("HLS error \(error.code.rawValue): \(error.localizedDescription)")
    if error.isRetriableHint {
        showRetryAction()
    }
    if let suggestion = error.recoverySuggestion {
        print(suggestion)
    }
}
```

Use ``HLSDownloader/downloadFile(sourceURL:destinationURL:)`` when only the
committed file URL is needed.
``HLSDownloadError/isRetriableHint`` is a conservative UI hint and never
overrides the configured retry policy. ``HLSDownloadError/isUserVisible`` keeps
developer-configuration failures out of generic user alerts, while localized
English and Korean descriptions and recovery suggestions flow through both
`LocalizedError` and the `CustomNSError` bridge.

The initial contract assembles MPEG transport-stream segments (`.ts`) and
fragmented MP4 resources (`.mp4`) without transcoding. Valid byte-range
resources are fetched with exact `206` and `Content-Range` validation, and
contiguous ranges are coalesced without exceeding the per-resource byte limit.
Identity-format `METHOD=AES-128` resources are decrypted with AES-CBC and
PKCS#7 padding before assembly or offline-package persistence. Explicit IVs
and media-sequence-derived IVs are supported; encrypted initialization maps
must declare an IV. Key responses must be exactly 16 bytes and use the same
request adapter and transport policy as media. After adaptation, key requests
are forced to `Cache-Control: no-store` with local cache bypass, and key bytes
remain library-memory-only. Resume metadata stores only key, key-URL, and IV
fingerprints, so a rotated key invalidates stale completed boundaries without
persisting the secret.
SAMPLE-AES, FairPlay key formats, live playlists, and variants with separate
audio renditions are reported as typed failures. AES-CBC does not authenticate
ciphertext, so HTTPS and trusted playlist origins remain required.
Discontinuities, gaps, I-frame-only media, and multiple initialization sections
also fail before single-file media transfer because raw concatenation cannot
preserve those timelines safely. The offline package path can instead retain
validated `EXT-X-I-FRAMES-ONLY` playlists without concatenating them.
If a multivariant playlist contains both supported in-band audio and unsupported
separate-audio variants, the downloader chooses the best supported variant.
Concurrent downloads to the same destination fail before media transfer, both
within one process and across cooperating processes. The OS-backed advisory
lease is released automatically if a process exits. Its hashed, empty lock
files remain in a hidden `.innonetwork-hls-locks` directory beside the
destination and are marked for backup exclusion when the volume supports it;
don't delete that directory while downloads may be active. Non-file
destinations are rejected. The final file is committed only after the complete
stream succeeds.
``HLSDownloadProgress/totalBytesWritten`` reports
media bytes currently retained for assembly; it can decrease when a failed
resource attempt is discarded before retry or when AES-128 padding is removed.
Its expected-total value remains `nil` and
``HLSDownloadProgress/isIndeterminate`` remains `true` until every active
resource supplies a content length. The final progress event normalizes the
total to the completed plaintext byte count. Transfer failures preserve their
underlying `NSError` domain/code through ``SendableUnderlyingError``, while
``HLSDownloadError/code`` and the `CustomNSError` bridge provide stable HLS
classification for recovery and telemetry.
Media retry scheduling is delivered to the `NetworkEventObserving` values in
the injected `NetworkRequestContext`; response-status, pre-response transport,
and mid-body transfer failures all retry the complete resource when the policy
allows it. Every logical resource keeps one request ID while retry attempts
receive increasing retry indexes.
Applications that need DRM-protected offline playback should integrate
`AVAssetDownloadURLSession` at the app layer because Apple requires those
assets to remain at the system-managed URL.

## Quality gates

The repository pins embedded MPEG-TS and fragmented-MP4 fixtures by SHA-256
and validates their packet or top-level box structure. A deterministic parser
mutation corpus accepts only a valid invariant-preserving result or a typed
``HLSDownloadError``. Large-playlist tests guard against quadratic parser
growth, while separate race suites repeatedly exercise concurrent live
streams and AVFoundation terminal-event delivery.

Run this focused set without the rest of the package:

```sh
bash Scripts/run_hls_quality_gates.sh
```

CI runs the same entry point again after the complete coverage suite. The
bounded release-preflight shard inventory includes all three HLS test targets,
so adding an HLS target cannot silently leave it outside release validation.

## Topics

### Playlist metadata

- ``HLSPlaylist``
- ``HLSPreferredStartPosition``
- ``HLSProgramDateTime``
- ``HLSDateRange``
- ``HLSDateRangeCue``
- ``HLSDateRangePreload``
- ``HLSDateRangeResource``
- ``HLSDateRangeSchedule``
- ``HLSDateRangeScheduleEntry``
- ``HLSPreloadedDateRangeResource``
- ``HLSInterstitial``
- ``HLSInterstitialSource``
- ``HLSInterstitialTimelineOccupancy``
- ``HLSInterstitialTimelineStyle``
- ``HLSInterstitialNavigationRestriction``
- ``HLSInterstitialSkipControl``
- ``HLSInterstitialAssetResolution``
- ``HLSPlaylistInspection``
- ``HLSPlaylistDiagnostic``
- ``HLSPresentationGraphInspection``
- ``HLSPresentationPlaylistInspection``
- ``HLSPresentationDiagnostic``
- ``HLSPresentationInspectionPack``
- ``HLSPresentationInspectionLimitPack``
- ``HLSPresentationInspectionError``
- ``HLSPresentationConformanceRevision``
- ``HLSPresentationPlaylistRole``
- ``HLSContentSteering``
- ``HLSContentSteeringPack``
- ``HLSContentSteeringHealthPolicy``
- ``HLSContentSteeringPathwayAvailability``
- ``HLSContentSteeringPathwaySnapshot``
- ``HLSContentSteeringSelectionReason``
- ``HLSContentSteeringEvent``
- ``HLSContentSteeringEventObserving``
- ``HLSExternalResourceResolver``
- ``HLSExternalResourcePack``
- ``HLSExternalResourceError``
- ``HLSInterstitialAsset``
- ``HLSSessionData``
- ``HLSSessionDataContent``
- ``HLSSessionDataFormat``
- ``HLSSessionDataValue``
- ``HLSSessionKey``
- ``HLSCustomMediaSelectionScheme``
- ``HLSCustomMediaSelectionPreferences``
- ``HLSMediaPresentationType``
- ``HLSMediaPresentationSelector``
- ``HLSMediaPresentationSetting``
- ``HLSLanguageDecoration``
- ``CustomMediaSelector``
- ``HLSEncryptionKeyPreload``
- ``HLSLowLatencyMetadata``
- ``HLSPreloadHint``
- ``HLSPreloadHintType``
- ``HLSClosedCaptionReference``
- ``HLSMediaContainer``
- ``HLSPlaybackCapabilities``
- ``HLSMediaCharacteristic``
- ``HLSMediaCharacteristicPreference``
- ``HLSSubtitleProvenancePolicy``
- ``HLSRendition``
- ``HLSRenditionKind``
- ``HLSRenditionSelectionPolicy``
- ``HLSUnsupportedMediaFeature``
- ``HLSVariant``
- ``PlaylistResolver``
- ``VariantSelector``
- ``RenditionSelector``

### Download

- ``HLSDownloader``
- ``HLSDownloadConfiguration``
- ``HLSStoragePack``
- ``HLSTransferPack``
- ``HLSDiskCapacityPolicy``
- ``HLSResumePolicy``
- ``HLSDownloadPreparation``
- ``HLSDownloadProgress``
- ``HLSDownloadReceipt``
- ``HLSDownloadEvent``
- ``HLSDownloadError``
- ``HLSDownloadErrorCode``
- ``HLSVariantSelectionPolicy``

### Offline packages

- ``HLSOfflinePackageDownloader``
- ``HLSOfflinePackageStore``
- ``HLSOfflinePackageConfiguration``
- ``HLSOfflinePackageStoragePack``
- ``HLSOfflineRenditionPack``
- ``HLSOfflineRenditionSelectionPolicy``
- ``HLSOfflinePackagePreparation``
- ``HLSOfflinePackageReceipt``
- ``HLSOfflinePackageEvent``
- ``HLSOfflinePackageTrack``
- ``HLSOfflinePackageTrackKind``
