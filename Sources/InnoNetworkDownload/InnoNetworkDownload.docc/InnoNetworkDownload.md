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

Download task events flow through the shared event hub. Tune buffering, overflow behavior, and metrics integration via ``DownloadConfiguration/eventDeliveryPolicy`` — see the [event delivery guide](https://innosquadcorp.github.io/InnoNetwork/InnoNetwork/documentation/innonetwork/eventdeliveryguide) in the core module.

## Topics

### Essentials

- ``DownloadManager``
- ``DownloadConfiguration``
- ``DownloadTask``
- ``DownloadState``

### Lifecycle and Recovery

- <doc:BackgroundDownloads>
- <doc:Persistence>
- ``DownloadManager``
- ``DownloadConfiguration``
- ``DownloadTask``
