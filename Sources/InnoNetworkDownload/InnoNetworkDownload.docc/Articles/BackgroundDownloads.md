# Background downloads

Configure ``DownloadManager`` so downloads continue (and resume) when the app is suspended
or terminated.

## Overview

Background downloads use an `URLSessionConfiguration.background(withIdentifier:)` session.
The system parks the connection in `nsurlsessiond`, schedules transfer based on radio and
power state, and wakes the app when the transfer makes progress or completes. The library
adds task persistence on top so a transfer that completes while the app was killed is
still observable on the next launch.

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
}
```

- **Session identifier.** Must be globally unique within the app process. Reusing an
  identifier across two `DownloadManager` instances causes Foundation to merge tasks into
  the first session — the second never receives delegate callbacks.
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

When the system finishes a background download while the app was suspended, it relaunches
the app and delivers a completion handler. Wire it through to the manager so the OS can
release the wake-lock promptly:

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
have been delivered.

## Restoration on launch

On app launch, the manager rehydrates known tasks from persistence and reconciles them
with the system's `allDownloadTasks()`:

- Tasks that exist in both stores are reattached and continue receiving events.
- Tasks that are persisted but missing from the system are marked failed and the
  persistence row is removed.
- Tasks that exist in the system but are not persisted are cancelled (they are foreign).
- Paused tasks with durable resume data can be restored from persistence even when
  `URLSession` no longer reports a live task.

Every public manager entry point waits for restoration internally before it
starts or mutates download work, so callers can issue new downloads immediately
after constructing the owning manager.

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

InnoNetwork 4.0.0 treats resume data as best-effort durable state. Process termination
after `pause(_:)` completes can resume from persisted `resumeData` on the next launch.
Server-side invalidation, OS resume-data incompatibility, or cache/range-policy changes
can still force a fresh download from byte 0.

If the resume data has been invalidated by the server (cache TTL, range support change),
the resumed task will fall back to a fresh download from byte 0. The transition is
transparent to observers.

## Cellular and roaming

The default `safeDefaults` configuration allows cellular access. For consumer apps that
should never burn cellular data on multi-megabyte downloads, override:

```swift
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.downloads"
) { builder in
    builder.allowsCellularAccess = false
}
```

## Related

- ``DownloadManager``
- ``DownloadConfiguration``
- <doc:Persistence>
