# ``InnoNetworkDownload``

Durable download lifecycle management with retry handling, restoration, append-log persistence, and async event delivery.

## Overview

`InnoNetworkDownload` is the download-focused module of the package. It is designed for clients that need more than a single `URLSessionDownloadTask` wrapper.

Use this module when you need:

- pause, resume, retry, and restoration support
- durable task persistence across app launches
- foreground and background session handling
- listener or `AsyncStream` delivery for download state transitions

The shared manager is intentionally easy to start with, but custom managers remain available when you need an explicit ``DownloadConfiguration``.

Download task events flow through the shared event hub. Tune buffering, overflow behavior, and metrics integration via ``DownloadConfiguration/eventDeliveryPolicy`` — see <doc:EventDeliveryPolicy> in the core module for a full guide.

## Topics

### Essentials

- ``DownloadManager``
- ``DownloadConfiguration``
- ``DownloadTask``
- ``DownloadState``

### Lifecycle and Recovery

- ``DownloadManager``
- ``DownloadConfiguration``
- ``DownloadTask``
