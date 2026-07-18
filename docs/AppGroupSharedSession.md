# App Groups, Extensions, and Shared Sessions

iOS apps that ship with a Share Extension, Action Extension, Widget,
or App Intents target often want one of two related things:

1. **A download started in the host app must remain observable from
   an extension** (or vice versa). The classic case: the user kicks
   off a large download, the app is suspended or terminated by the
   system, and the OS-driven `nsurlsessiond` continues the transfer;
   later, an Action Extension needs to inspect the resulting file from
   inside its own bundle.
2. **A request issued from the extension should not pollute the host
   app's session state** (auth cookies, persistent caches). The
   extension should run with its own client and its own storage so
   the host app's session boundary stays clean.

This article documents the patterns InnoNetwork supports for shared
download sessions and for isolated extension HTTP clients.

## What InnoNetwork supports out of the box

- After `backgroundTransfersEnabled()` opt-in,
  `DownloadManager(configuration:)` builds a background `URLSession` whose
  identifier is whatever you pass through
  ``DownloadConfiguration/safeDefaults(sessionIdentifier:)`` or the advanced
  factory's `sessionIdentifier` argument. That identifier then scopes the
  OS-managed download queue, but it
  does not permit concurrent process ownership. A host app and extension may
  use the **same** identifier only for OS-driven reattachment after the previous
  owner process is no longer attached. Use **different** identifiers when both
  processes may run concurrently. Without the opt-in, both presets remain
  foreground sessions.
- `DownloadPersistencePack(sharedContainerIdentifier:)` maps directly to
  `URLSessionConfiguration.sharedContainerIdentifier`, so the system can place
  background-session state inside the App Group container when both targets
  participate in the same group.
- A per-process `URLSessionConfiguration` (built from
  `NetworkConfiguration.makeURLSessionConfiguration()`, see
  [Cookies.md](Cookies.md) and [HTTP3.md](HTTP3.md)) composes with the
  host-app/extension split: each binary builds its own session and
  passes it to `DefaultNetworkClient(configuration:session:)`, so
  cookies and caches stay on the right side of the boundary by
  default.

## Pattern A — Isolated extension client (recommended default)

When the extension simply needs to make HTTP requests on its own,
build a fully separate client from inside the extension target. Do
not reach for the host app's storage.

```swift
// inside the Share Extension target
let extensionConfig = NetworkConfiguration.safeDefaults(baseURL: baseURL)
let sessionConfig = extensionConfig.makeURLSessionConfiguration()
sessionConfig.httpShouldSetCookies = false
sessionConfig.httpCookieStorage = nil
let session = URLSession(configuration: sessionConfig)
let extensionClient = DefaultNetworkClient(configuration: extensionConfig, session: session)
```

This strict-isolation example disables automatic cookie persistence; use
request-scoped authorization or another extension-owned credential mechanism.
Do not use `sharedCookieStorage(forGroupContainerIdentifier:)` for isolation:
that store is intentionally visible to every app and extension entitled for
the App Group. Configure cache and credential storage with the same boundary
in mind.

## Pattern B — OS-driven single-owner reattachment

If the **same** download must be resumed by the host app or an extension at
different times, the later process may reattach only after the previous owner
process is gone and Foundation has released that session identifier. InnoNetwork
does not provide proactive live handoff: `DownloadManager.shutdown()` cancels
the owner's transfers and removes their logical persistence records. Both
binaries must:

1. Pass the same `sessionIdentifier` to
   `DownloadConfiguration.safeDefaults(sessionIdentifier:)`. The OS keys the
   background queue off this string, but only one process may attach at a time.
   Call `backgroundTransfersEnabled()` on the completed configuration so the
   identifier is used for an OS-managed background session.
2. Set the same `sharedContainerIdentifier` on the download
   configuration when the OS-managed session state itself must live in
   the App Group container.
3. Set the same `persistenceBaseDirectoryURL` to a writable directory inside
   that App Group. Foundation's shared-container state is not enough: the next
   owner also needs InnoNetwork's logical records to correlate restored tasks.
4. Be members of the same App Group (declared in `Info.plist`
   entitlements) so they can read the destination file from the
   shared container path.
5. Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
   in the host app target so the OS can deliver "transfer finished
   while you were dead" callbacks. Forward that callback through
   `DownloadManager.handleBackgroundSessionCompletion(_:completion:)`; see
   ``DownloadManager`` for the wiring.

If the app and extension may own downloads concurrently, give them distinct
session identifiers and destination paths instead of attempting a shared
attachment.

The destination URL must point inside the App Group container, not
the per-target sandbox:

```swift
let groupContainer = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.example.app.media"
)!
let destination = groupContainer.appending(path: "downloads/\(filename)")

await manager.download(url: source, to: destination)
```

Otherwise the extension cannot read the file even though the
download completed successfully.

## App Group session storage

Use both `sharedContainerIdentifier` and an App Group-backed
`persistenceBaseDirectoryURL` when a later process may need to restore the
background session:

```swift
let groupContainer = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.example.app.media"
)!

let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.downloads.shared",
    persistence: DownloadPersistencePack(
        sharedContainerIdentifier: "group.com.example.app.media",
        baseDirectoryURL: groupContainer.appending(
            path: "InnoNetworkPersistence",
            directoryHint: .isDirectory
        )
    )
).backgroundTransfersEnabled()

let manager = try DownloadManager(configuration: configuration)
```

`DownloadConfiguration.safeDefaults(...)` keeps both sharing settings `nil`;
call `backgroundTransfersEnabled()` for an app-private background session.
These settings do not replace the destination-file rule above: files the
extension must read still need to be written under
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.

Prefer Pattern A (isolated extension client) unless the OS-driven single-owner
reattachment in Pattern B is genuinely required. Most apps'
extensions only need to make a few opportunistic requests, and a fully
isolated client is simpler to reason about.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Host app sees the download but extension does not | The previous owner is still attached; `sessionIdentifier` differs; `persistenceBaseDirectoryURL` is not the same App Group-backed directory; or the destination is outside the App Group container. |
| Extension's download stops when the extension terminates | The manager is still in foreground mode, the extension background configuration lacks a valid `sharedContainerIdentifier`, or session ownership/configuration failed. A correctly configured background session is designed to continue out of process. |
| Transfer does not continue after the user force-quits the host app | This is expected platform behavior: a user-initiated force quit cancels background transfers and prevents automatic relaunch. Suspension or system termination is the supported continuation case. |
| `Set-Cookie` from extension shows up in host-app session | Both targets use an App Group cookie store. For strict isolation, set `httpShouldSetCookies = false` and `httpCookieStorage = nil`, or provide a genuinely extension-owned credential policy as in Pattern A. |
| Background completion handler never fires | Host app forgot to forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the manager's background completion store. |

## See also

- ``DownloadManager``
- [BackgroundDownloads.md (DocC article)](../Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/BackgroundDownloads.md)
- [Cookie Storage Isolation](Cookies.md)
- [HTTP/3 Opt-In](HTTP3.md)
