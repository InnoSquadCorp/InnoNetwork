# ``InnoNetworkDownload``

Durable download lifecycle management with retry handling, restoration, append-log persistence, and async event delivery.

## Overview

`InnoNetworkDownload` is the download-focused module of the package. It is designed for clients that need more than a single `URLSessionDownloadTask` wrapper.

Use this module when you need:

- pause, resume, retry, and restoration support
- durable task persistence across app launches
- secure foreground downloads by default, with explicit background continuation
- listener or `AsyncStream` delivery for download state transitions

Construct one ``DownloadManager`` per download domain with an explicit
``DownloadConfiguration`` and a unique session identifier. The safe and
advanced presets use a foreground session so each redirect can be admitted
before transport. Call
``DownloadConfiguration/backgroundTransfersEnabled()`` only when continuation
outside the app process is worth Foundation automatically following redirects
without per-hop library preflight; see <doc:BackgroundDownloads>.

Download task events flow through the shared event hub. Tune buffering,
overflow behavior, and metrics integration through
``DownloadObservabilityPack`` — see the [event delivery guide](https://innosquadcorp.github.io/InnoNetwork/InnoNetwork/documentation/innonetwork/eventdeliveryguide)
in the core module.

## Failures and retry

A `URLSession` download task does not fail on `4xx` or `5xx`, so the manager
validates the HTTP status itself before the file is staged. An error body is
never saved to the destination.

- `DownloadTransferPack(acceptableStatusCodes:)` names the statuses that count
  as a finished transfer. The default is `200..<300`, which includes the `206`
  a resumed transfer returns.
- `408`, `416`, `429`, and `5xx` are retried under ``DownloadRetryPack``. When
  the budget runs out the task fails with
  ``DownloadError/maxRetriesExceeded(lastError:)``; `lastError` is the failure
  of the final attempt.
- A resumed transfer whose range the server rejects with `416`, or whose
  redirect target refuses it, restarts from the source URL at once without
  spending the retry budget.
- Any other unacceptable status fails immediately with
  ``DownloadError/unacceptableStatusCode(_:)`` — for example `403` for an
  expired signed URL or `404` for a missing object — without spending the
  retry budget.

``DownloadError/httpStatusCode`` returns the status for
`.unacceptableStatusCode` and for a `.maxRetriesExceeded` whose final attempt
ended on a status.

```swift
for await event in await manager.events(for: task) {
    guard case .failed(let error) = event else { continue }
    switch error {
    case .unacceptableStatusCode(let statusCode):
        showUnavailable(statusCode: statusCode)
    case .maxRetriesExceeded(let lastError):
        showRetryLater(reason: lastError.message, statusCode: error.httpStatusCode)
    default:
        show(error)
    }
}
```

If a server answers a download with a status outside `2xx` on purpose, widen
the set:

```swift
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.media",
    transfer: DownloadTransferPack(acceptableStatusCodes: Set(200..<300).union([304]))
)
```

An automatic retry continues from the resume data of the failed attempt
instead of restarting from byte 0, and falls back to a fresh request when the
server rejects the range. `DownloadRetryPack(waitsForNetworkChanges:)`
(default `true`) defers a retry until the network path changes only after a
connectivity failure; a retryable status or a timeout on a working network
goes straight to backoff.

Downloads read the core module's connectivity table, so a download and a
request agree on what counts as offline. The connectivity failures are the
`URLError` codes that `InnoNetwork` reports as `NetworkError.reachability`:
`notConnectedToInternet`, `dnsLookupFailed`, `cannotFindHost`,
`networkConnectionLost`, and the cellular codes `dataNotAllowed`,
`internationalRoamingOff`, and `callIsActive`. `cannotConnectToHost` is a
connection timeout, not a connectivity failure, so a retry after it goes
straight to backoff.

## Topics

### Essentials

- ``DownloadManager``
- ``DownloadConfiguration``
- ``DownloadTask``
- ``DownloadState``
- ``DownloadEvent``
- ``DownloadError``

### Configuration Packs

- ``DownloadTransferPack``
- ``DownloadRetryPack``
- ``DownloadObservabilityPack``
- ``DownloadPersistencePack``

### Lifecycle and Recovery

- <doc:BackgroundDownloads>
- <doc:Persistence>
- ``DownloadManager``
- ``DownloadConfiguration``
- ``DownloadTask``
