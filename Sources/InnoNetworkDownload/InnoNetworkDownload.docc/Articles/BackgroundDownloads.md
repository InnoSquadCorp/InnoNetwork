# Background downloads

Opt ``DownloadManager`` into process-independent transfers when downloads must
continue after the app is suspended or terminated by the system. A user-initiated
force quit cancels background transfers and prevents automatic relaunch.

## Overview

``DownloadConfiguration/safeDefaults(sessionIdentifier:)`` and
``DownloadConfiguration/advanced(sessionIdentifier:_:)`` use the secure
foreground session mode by default. Foreground mode lets InnoNetwork inspect
each redirect before Foundation follows it.

Call ``DownloadConfiguration/backgroundTransfersEnabled()`` explicitly when
the transfer must continue outside the app process. Background mode uses
`URLSessionConfiguration.background(withIdentifier:)`; the system parks the
connection in `nsurlsessiond`, schedules transfer based on radio and power
state, and wakes the app when the transfer completes. The library adds task
persistence so a completion delivered while the app was absent remains
observable after launch.

> Important: Background continuation has a redirect-security trade-off.
> Foundation automatically follows redirects for background sessions without
> calling the redirect delegate, so InnoNetwork cannot enforce
> `DefaultRedirectPolicy` or URL-admission preflight on every hop. The initial
> source and final URL are still validated where Foundation exposes them, but
> final validation cannot prevent contact with an intermediate redirect
> target. Keep the default foreground mode when per-hop admission is required.

## Configuration

```swift
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.downloads"
) { builder in
    builder.allowsCellularAccess = true
    builder.maxConnectionsPerHost = 4
    builder.persistenceCompactionPolicy = .init(
        maxEvents: 1_000,
        maxLogBytes: 1_048_576,
        tombstoneRatio: 0.25
    )
}.backgroundTransfersEnabled()
```

- **Background transfer opt-in.** `backgroundTransfersEnabled()` is the only
  public switch for process-independent continuation. Omit it to retain the
  secure foreground default and per-hop redirect admission.
- **Session identifier.** Must be globally unique within the app process and
  also scopes the persistence log. In background mode it is additionally the
  Foundation background-session identifier. Reusing it across managers is
  rejected by ``DownloadManager``.
- **Shared container.** `sharedContainerIdentifier` is applied only to a
  background session. Set it when an App Group owns the transfer state. It does
  not authorize simultaneous managers in the app and extension: exactly one
  process may own a given session identifier at a time. Proactive live handoff
  is not supported; a later process may use OS-driven reattachment only after
  the previous process is gone.
- **Destination ownership.** Give each active logical task an exclusive final
  destination path. A shared container does not serialize different session
  identifiers or different processes that write the same caller-owned file.
- **Cellular access.** Set `allowsCellularAccess` per feature when downloads may be large
  or expensive for the user.
- **Persistence compaction.** Long-running apps can tune the append-log snapshot budget
  without replacing the persistence store.

## Info.plist

`URLSession` background downloads do not require `UIBackgroundModes` by themselves. Declare
background modes only for the wake-up mechanism your app owns outside the transfer:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

Add `remote-notification` only when a push notification is expected to trigger the download.

## Wiring the system completion handler

When the system finishes a background download while the app was suspended,
it relaunches the app and delivers a completion handler. Wire it through to the
manager that owns the matching session identifier so the OS can release the
wake-lock promptly. Foreground managers do not receive this callback:

```swift
// In your AppDelegate / scene entry point. Route the completion to the
// DownloadManager that owns this session identifier — construct it with
// `make(configuration:)` and store the manager on the owning feature module.
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    mediaDownloads.handleBackgroundSessionCompletion(
        identifier,
        completion: completionHandler
    )
}
```

The manager invokes the completion handler once the session emits
`urlSessionDidFinishEvents(forBackgroundURLSession:)`, signalling that all queued events
have been delivered. App-facing callbacks are dispatched on a separate
per-task ordered lane, so a slow progress, completed, or failed callback does
not delay this system completion. ``DownloadManager/shutdown()`` still drains
callbacks accepted before its final boundary.

The public entry point registers the UIKit handler synchronously. A
`urlSessionDidFinishEvents` observed while no handler is registered is not
carried into a later background batch; that later handler waits for its own
finish event.

## Restoration on launch

On app launch, the manager rehydrates known tasks from persistence and reconciles them
with the system's `allDownloadTasks()`:

- Tasks that exist in both stores are reattached and continue receiving events.
- In foreground mode, tasks that are persisted but missing from the system are
  marked failed after the in-process delegate snapshot drains.
- In background mode, a missing-system failure remains provisional until
  `urlSessionDidFinishEvents(forBackgroundURLSession:)` confirms that Foundation
  delivered every message queued before session reattachment. A valid download
  completion arriving after the task inventory snapshot can therefore still win.
- Tasks that exist in the system but are not persisted are cancelled (they are foreign).
- Paused tasks with durable resume data can be restored from persistence even when
  `URLSession` no longer reports a live task.

Every public manager entry point waits for restoration internally before it
starts or mutates download work, so callers can issue new downloads immediately
after constructing the owning manager.

Successful background completions move Foundation's temporary file into a
deterministic journal before the delegate returns. A durable commit records the
source URL, final URL, destination, byte count, and payload SHA-256. On restart,
the manager validates the installed destination before deleting journal evidence.
Both live and recovered finished receipts remain durable until the terminal
event and any snapshotted app callbacks are accepted. Only an exact
metadata-and-outcome acknowledgment can then remove the receipt, so an old
completion cannot erase a newer generation. If destination integrity validation
fails, the task reports `DownloadError.fileSystemError` and preserves the
receipt and staged recovery evidence instead of silently reinstalling over a
caller-owned file.

```swift
// Optional: explicitly await restoration (every public entry point already
// awaits it internally, so this is only needed when callers want to gate
// UI on restore completion).
let didRestore = await mediaDownloads.waitForRestoration()

let task = await mediaDownloads.download(url: remoteURL, to: destinationURL)
```

## Pause and resume

`pause(_:)` calls `cancelByProducingResumeData()` on the underlying URL task, captures the
resume data in persistence, and transitions the task to `.paused`. `resume(_:)` rehydrates
the task with the saved resume data and clears the stored resume payload once the new
system task is created.

The InnoNetwork 5.0 preview treats resume data as best-effort durable state. Process termination
after `pause(_:)` completes can resume from persisted `resumeData` on the next launch.
Server-side invalidation, OS resume-data incompatibility, or cache/range-policy changes
can still force a fresh download from byte 0.

If the resume data has been invalidated by the server (cache TTL, range support change),
the resumed task will fall back to a fresh download from byte 0. The transition is
transparent to observers.

## Cellular and roaming

The default `safeDefaults` configuration disables cellular access. For apps that
explicitly allow background downloads over cellular, opt in:

```swift
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.downloads"
) { builder in
    builder.allowsCellularAccess = true
}.backgroundTransfersEnabled()
```

## Related

- ``DownloadManager``
- ``DownloadConfiguration``
- <doc:Persistence>
