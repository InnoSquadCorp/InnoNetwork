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
        startPosition: .nextCompletedSegment
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
        play(receipt.playlistURL)
    }
}
```

Only complete segments are retained. Duration, segment count, per-resource
bytes, total media bytes, request timeout, and event buffering are bounded.
When the duration, count, or total-byte boundary is reached, the recorder
finishes at the last complete segment. Exact `206` and `Content-Range`
validation localizes byte-range segments as complete files.

MPEG transport streams and fragmented MP4 with one stable initialization map
are written as a URL-free local VOD playlist. Source URLs, signed query values,
Date Range metadata, and request errors are not persisted. Gaps, encrypted
media, external rendition playlists, external timeline resources, and missing
or changing initialization maps fail with ``HLSLiveDVRError`` rather than
producing an incomplete presentation.

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
- ``HLSLiveError``

### Bounded live DVR

- ``HLSLiveDVRRecorder``
- ``HLSLiveDVRConfiguration``
- ``HLSLiveDVRLimitPack``
- ``HLSLiveDVRStartPosition``
- ``HLSLiveDVREvent``
- ``HLSLiveDVRProgress``
- ``HLSLiveDVRReceipt``
- ``HLSLiveDVRError``
- ``HLSLiveDVRUnsupportedFeature``
