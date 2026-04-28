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
    builder.discretionary = false
    builder.isWaitingForConnectivity = true
    builder.persistenceDirectory = .documents
}
```

- **Session identifier.** Must be globally unique within the app process. Reusing an
  identifier across two `DownloadManager` instances causes Foundation to merge tasks into
  the first session — the second never receives delegate callbacks.
- **`discretionary`.** When `true`, the OS may delay the transfer to favour battery and
  data plan efficiency. Set `false` only when the user explicitly initiated the download.
- **`isWaitingForConnectivity`.** When `true`, the task waits for connectivity rather than
  failing immediately on radio loss. Recommended for user-driven downloads.

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
// In your AppDelegate / scene entry point:
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    Task {
        await DownloadManager.shared.attachBackgroundCompletion(
            identifier: identifier,
            completion: completionHandler
        )
    }
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

You can wait for restoration explicitly before issuing new downloads:

```swift
await DownloadManager.shared.waitForRestoration()
```

## Pause and resume

`pause(_:)` calls `cancelByProducingResumeData()` on the underlying URL task, captures the
resume data on the actor, and transitions the task to `.paused`. `resume(_:)` rehydrates
the task with the saved resume data.

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
    builder.allowsExpensiveNetworkAccess = false  // hotspot, etc.
    builder.allowsConstrainedNetworkAccess = false  // Low Data Mode
}
```

## Related

- ``DownloadManager``
- ``DownloadConfiguration``
- <doc:Persistence>
