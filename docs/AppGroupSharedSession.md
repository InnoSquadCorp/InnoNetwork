# App Groups, Extensions, and Shared Sessions

iOS apps that ship with a Share Extension, Action Extension, Widget,
or App Intents target often want one of two related things:

1. **A download started in the host app must remain observable from
   an extension** (or vice versa). The classic case: the user kicks
   off a large download, swipes the app away, and the OS-driven
   `nsurlsessiond` continues the transfer; later, an Action Extension
   needs to inspect the resulting file from inside its own bundle.
2. **A request issued from the extension should not pollute the host
   app's session state** (auth cookies, persistent caches). The
   extension should run with its own client and its own storage so
   the host app's session boundary stays clean.

This article documents the patterns InnoNetwork supports for shared
download sessions and for isolated extension HTTP clients.

## What InnoNetwork supports out of the box

- `DownloadManager.make(configuration:)` builds a background
  `URLSession` whose `sessionIdentifier` is whatever you pass in
  through ``DownloadConfiguration/safeDefaults(sessionIdentifier:)``
  or the advanced builder. This identifier scopes the OS-managed
  download queue. Host app and extension that pass the **same**
  identifier will share that queue (the OS reattaches both to the
  same transfer); processes that pass **different** identifiers stay
  fully isolated.
- ``DownloadConfiguration/sharedContainerIdentifier`` maps directly to
  `URLSessionConfiguration.sharedContainerIdentifier`, so the system can
  place background-session state inside the App Group container when both
  targets participate in the same group.
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
sessionConfig.httpCookieStorage = .sharedCookieStorage(
    forGroupContainerIdentifier: "group.com.example.app.share-extension"
)
let session = URLSession(configuration: sessionConfig)
let extensionClient = DefaultNetworkClient(configuration: extensionConfig, session: session)
```

Cookies, caches, and credentials all stay inside the extension
container — the host app never sees them, and an authentication
state introduced in the extension does not leak into the host app's
session.

## Pattern B — Resumable background download accessible from both targets

If the **same** download must be observable from both the host app
and an extension that wakes up later, both binaries must:

1. Pass the same `sessionIdentifier` to
   `DownloadConfiguration.safeDefaults(sessionIdentifier:)`. The OS
   keys the background queue off this string.
2. Set the same `sharedContainerIdentifier` on the download
   configuration when the OS-managed session state itself must live in
   the App Group container.
3. Be members of the same App Group (declared in `Info.plist`
   entitlements) so they can read the destination file from the
   shared container path.
4. Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
   in the host app target so the OS can deliver "transfer finished
   while you were dead" callbacks. `DownloadManager` exposes a
   `BackgroundCompletionStore` for stashing the completion handler;
   see ``DownloadManager`` for the wiring.

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

Use `sharedContainerIdentifier` when the background session itself must
persist in-flight transfer state in the App Group container:

```swift
let configuration = DownloadConfiguration.advanced { builder in
    builder.sessionIdentifier = "com.example.app.downloads.shared"
    builder.sharedContainerIdentifier = "group.com.example.app.media"
}

let manager = try DownloadManager.make(configuration: configuration)
```

`DownloadConfiguration.safeDefaults(...)` keeps
`sharedContainerIdentifier == nil`, so existing app-private background
sessions remain unchanged. Setting the value does not replace the
destination-file rule above: files the extension must read still need to
be written under `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.

Prefer Pattern A (isolated extension client) unless the OS-resumable
shared-queue contract in Pattern B is genuinely required. Most apps'
extensions only need to make a few opportunistic requests, and a fully
isolated client is simpler to reason about.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Host app sees the download but extension does not | Different `sessionIdentifier` between binaries, or destination URL outside the App Group container. |
| Extension's downloads are silently cancelled when it terminates | Extension lifetimes are short. Use a host-app `DownloadManager` for long transfers and let the extension only schedule them. |
| `Set-Cookie` from extension shows up in host-app session | Both targets share `HTTPCookieStorage.shared`. Inject per-container `HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier:)` per Pattern A. |
| Background completion handler never fires | Host app forgot to forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the manager's background completion store. |

## See also

- ``DownloadManager``
- [BackgroundDownloads.md (DocC article)](../Sources/InnoNetworkDownload/InnoNetworkDownload.docc/Articles/BackgroundDownloads.md)
- [Cookie Storage Isolation](Cookies.md)
- [HTTP/3 Opt-In](HTTP3.md)
