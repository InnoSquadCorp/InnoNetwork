# ``InnoNetworkHLSLive``

Resolve and reload live HLS presentations with blocking, delta-update, and
Content Steering support.

## Overview

`InnoNetworkHLSLive` is an optional companion product layered on
`InnoNetworkHLS`. It reuses the same parser, URL admission,
``InnoNetworkHLS/HLSRequestPolicy``, redirect handling, and bounded playlist
body limit. The live client accepts either a media-playlist URL or a
multivariant entry URL and resolves the latter with the configured selection
policy.

```swift
import InnoNetworkHLSLive

let client = HLSLivePlaylistClient(
    configuration: .advanced(
        variantSelectionPolicy: .compatible(deviceCapabilities)
    )
)
for try await snapshot in client.snapshots(from: masterOrMediaPlaylistURL) {
    print(snapshot.segments.map(\.sequenceNumber))
    print(snapshot.selectedVariant?.stableID as Any)
    if snapshot.isEnded {
        break
    }
}
```

A direct media URL still reloads without a selection step. A multivariant URL
selects one variant, exposes the selected pathway and its advertised
renditions on every snapshot, and keeps parent `EXT-X-DEFINE` imports
available to later reloads. Content Steering may recover a failed reload only
through a variant with the same nonempty stable ID and compatible encoding
shape. When the current playlist reports the destination rendition,
`EXT-X-RENDITION-REPORT` supplies `_HLS_msn` and `_HLS_part` for bounded
tune-in. Pathway events contain identifiers and stable error codes, never
request URLs or signed query values.

To preload upcoming encryption keys during the `snapshots(from:)` reload
stream, inject an
``HLSLiveEncryptionKeyPreloading`` implementation. The live client chooses a
random point in the projected `DATE-OF-FIRST-USE` window and calls the
application-owned handler once for the current hint:

```swift
let client = HLSLivePlaylistClient(
    keyPreloader: keyCache
)
```

The callback receives typed method, key-format, and URL metadata. This product
does not request, decrypt, persist, or log key bytes. Removing or replacing a
hint cancels its pending callback; ending the snapshot stream cancels all
remaining callbacks.

The first response is full. Later requests add `_HLS_msn` and `_HLS_part`
only when blocking reload is advertised, and `_HLS_skip` only when the server
advertises a skip window. Delta responses are reconstructed from the prior
window by media-sequence number. If the necessary base history is missing, the
client attempts one query-clean full reload.

Snapshots expose resolved media URLs and normal parsed playlist metadata; they
are application data, not an observability surface. Purpose-aware request
events remain value-redacted and classify subsequent requests as
``InnoNetworkHLS/HLSRequestPurpose/livePlaylistReload``.

Every snapshot also exposes the ``HLSLivePlaylistSnapshot/reloadMode`` that
produced it. A session-owned ``HLSLiveHealthAnalyzer`` can reduce those
snapshots into deterministic health without performing I/O or deciding a
recovery policy:

```swift
var healthAnalyzer = HLSLiveHealthAnalyzer(
    configuration: .advanced(
        thresholds: HLSLiveHealthThresholdPack(
            degradedStagnantSnapshotCount: 3,
            criticalStagnantSnapshotCount: 6
        )
    )
)

for try await snapshot in client.snapshots(from: mediaPlaylistURL) {
    let health = healthAnalyzer.ingest(
        snapshot,
        observedAt: .now
    )
    render(health.status, issues: health.issues)
}
```

When Program Date Time and server hold-back metadata are available, health
includes an estimated edge time, live latency, and recommended latency. Edge
regression, repeated equal edges, delta full-reload recovery, pathway changes,
and retained-window risk remain useful without that timing metadata. The
application owns the observation clock, analyzer lifetime, UI, alerting, and
any retry or pathway decision.

## Bounded live DVR

``HLSLiveDVRRecorder`` reuses a configured live client's session, request
policy, variant selection, and Content Steering behavior. The safe default
starts with the next completed segment instead of backfilling the current live
window:

```swift
let recorder = HLSLiveDVRRecorder(
    client: client,
    configuration: .advanced(
        limits: HLSLiveDVRLimitPack(
            maximumDuration: 15 * 60,
            maximumSegmentCount: 300,
            maximumTotalMediaBytes: 2 * 1_024 * 1_024 * 1_024
        ),
        startPosition: .nextCompletedSegment,
        renditions: HLSLiveDVRRenditionPack(
            audio: .preferredLanguages(["ko", "en"]),
            subtitles: .preferredLanguages(["ko", "en"]),
            subtitleProvenance: HLSSubtitleProvenancePolicy(
                machineGenerated: .neutral,
                translation: .preferred
            )
        ),
        parts: HLSLiveDVRPartPack(policy: .independent)
    )
)

for try await event in recorder.events(
    from: masterOrMediaPlaylistURL,
    to: packageDirectoryURL
) {
    switch event {
    case .progress(let progress):
        updateProgress(
            segments: progress.segmentCount,
            duration: progress.recordedDuration
        )
    case .completed(let receipt):
        play(receipt.entryPlaylistURL)
    }
}
```

Only complete segments are retained. Duration, segment count, per-resource
bytes, total media bytes, external renditions per kind, request timeout,
destination free capacity, and event buffering are bounded.
``HLSLiveDVRLimitPack/diskCapacityPolicy`` uses the same required,
best-effort, or disabled capacity contract as VOD storage. When the duration,
count, or total-byte boundary is reached, the recorder finishes at the last
complete segment. Exact `206` and `Content-Range` validation localizes
byte-range segments as complete files.

LL-HLS part capture is disabled by default. The `.independent` policy may
temporarily stage one incomplete parent sequence only when part zero is
independent. Count and byte limits apply before transfer, byte ranges receive
the same exact response validation as complete segments, and staged progress
is exposed through ``HLSLiveDVRProgress``. When the complete parent appears,
the recorder promotes only a contiguous part set whose summed duration matches
the parent; otherwise it removes the temporary parts and downloads the normal
complete segment. The committed package contains complete VOD segments only.
Identity-format AES-128 parts are not staged because part-level IV metadata is
not available; their complete parent follows the existing decryption path.

MPEG transport streams and fragmented MP4 with one stable initialization map
are written as a URL-free local VOD playlist. Identity-format AES-128 uses
explicit or media-sequence IVs, caches each 16-byte key only for the recording,
supports key rotation and encrypted fMP4 maps, and persists plaintext media
without `EXT-X-KEY` or source key URLs.

The default rendition pack retains one external audio rendition. Applications
can select external audio, alternate video, and subtitle playlists by default,
preferred language, exact name, or all referenced renditions. A URL-free local
master becomes ``HLSLiveDVRReceipt/entryPlaylistURL`` and
``HLSLiveDVRReceipt/tracks`` describes each retained local playlist. Content
Steering may move a rendition only when its stable rendition ID remains the
same; every selected rendition must cover the retained primary timeline or the
whole recording fails atomically.

Generated and translated subtitle selection uses the same
``InnoNetworkHLS/HLSSubtitleProvenancePolicy`` contract as offline packages.
Exclusion is applied before language or name matching, and preference only
breaks otherwise-equal matches while retaining source order. Audio and video
selection are unchanged. ``HLSLiveDVRTrack/characteristics``,
``HLSLiveDVRTrack/isMachineGenerated``, and
``HLSLiveDVRTrack/isTranslated`` preserve provenance in the committed receipt.

Program Date Time and self-contained, standard Date Range attributes are
preserved for the recorded interval. Source URLs, signed query values, key
bytes, redacted Date Range extension values, and request errors are never
persisted. Gaps, FairPlay or sample encryption, externally resolved timeline
resources, unrepresentable timeline metadata, incomplete external renditions,
and missing or changing initialization maps fail with ``HLSLiveDVRError``
rather than producing an incomplete presentation.

The package targets application-owned serving or resource loading. An
arbitrary `file://` HLS directory is not advertised as directly AVFoundation
playable; use `InnoNetworkHLSAVFoundation` for system-managed playback and
persistence.

The destination is reserved in-process and across cooperating processes.
Staging is a hidden sibling directory, and the complete package becomes
visible through one atomic directory move. Cancellation and failures remove
ephemeral staging data; recordings are not resumed after interruption.

## Topics

### Client

- ``HLSLivePlaylistClient``
- ``HLSLiveConfiguration``
- ``HLSLiveReloadPack``
- ``HLSLiveEncryptionKeyPreloading``

### Snapshots

- ``HLSLivePlaylistSnapshot``
- ``HLSLiveSegment``
- ``HLSLivePartialSegment``
- ``HLSLiveReloadMode``
- ``HLSLiveError``

### Live health

- ``HLSLiveHealthAnalyzer``
- ``HLSLiveHealthConfiguration``
- ``HLSLiveHealthThresholdPack``
- ``HLSLiveHealthSnapshot``
- ``HLSLiveHealthStatus``
- ``HLSLiveHealthIssue``
- ``HLSLiveEdgePosition``

### Bounded live DVR

- ``HLSLiveDVRRecorder``
- ``HLSLiveDVRConfiguration``
- ``HLSLiveDVRLimitPack``
- ``HLSLiveDVRRenditionPack``
- ``HLSLiveDVRRenditionSelectionPolicy``
- ``HLSLiveDVRPartPack``
- ``HLSLiveDVRPartCapturePolicy``
- ``HLSLiveDVRStartPosition``
- ``HLSLiveDVREvent``
- ``HLSLiveDVRProgress``
- ``HLSLiveDVRReceipt``
- ``HLSLiveDVRTrack``
- ``HLSLiveDVRTrackKind``
- ``HLSLiveDVRError``
- ``HLSLiveDVRUnsupportedFeature``
