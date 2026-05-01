# Migrating off `DownloadManager.shared`

Move from a single global download manager to per-feature instances so each
feature can pick its own ``DownloadConfiguration`` and lifetime.

## Why migrate

``DownloadManager/shared`` is `@available(*, deprecated, ...)` for the 4.x
line. It is convenient, but it forces a single global ``DownloadConfiguration``:
one cellular policy, one retry policy, one persistence directory, one session
identifier. Apps that grow beyond a single download domain — for example,
"media downloads on Wi-Fi only" alongside "document downloads on cellular" —
cannot express both behaviours through a single shared instance.

The shared instance also carries an implicit fallback path: if the default
session identifier is already claimed by another `DownloadManager` in the
same process, `shared` quietly falls back to a UUID-suffixed identifier and
logs an OSLog `.fault`. That is recoverable in most cases, but it makes
multi-domain setups brittle and obscures which manager owns which session.

The migration target is dependency injection: each feature module owns
exactly one ``DownloadManager`` instance, constructed at the feature's entry
point with an explicit configuration and stored on the feature's owning
component.

## Step 1 — Pick an owning component

Choose where the manager will live. The owning component should outlive any
in-progress downloads:

- An app-wide `DownloadCoordinator` actor or service for cross-feature
  background downloads.
- A feature-scoped `MediaDownloadService` for per-feature lifetimes.
- A `@Observable` view-model only when the downloads are scoped to a single
  screen and acceptable to lose on dismissal.

`DownloadManager` is `public actor`, so the owning component should hold it
behind an actor-safe handle (`let manager: DownloadManager`).

## Step 2 — Build a configuration

Use ``DownloadConfiguration/safeDefaults(sessionIdentifier:)`` (or the
designated initializer) to build a configuration with an explicit session
identifier. The session identifier must be unique per
``DownloadManager`` in the same process — the constructor throws
``DownloadManagerError/duplicateSessionIdentifier(_:)`` if it is already
claimed:

```swift
let mediaConfiguration = DownloadConfiguration.safeDefaults(
    sessionIdentifier: "com.example.media.downloads"
)
```

Use distinct identifiers per feature — `com.example.media.downloads`,
`com.example.documents.downloads`, etc. — to keep persistence directories,
runtime registries, and background completion handlers separated.

## Step 3 — Construct via `make(configuration:)`

Prefer ``DownloadManager/make(configuration:)`` over the throwing initializer
so the call site reads as a factory and matches the convention used elsewhere
in the package:

```swift
let mediaDownloads = try DownloadManager.make(configuration: mediaConfiguration)
```

For previews and tests, inject the manager exactly the same way: pass the
constructed instance into the consuming component instead of reaching for
`DownloadManager.shared`.

## Step 4 — Wire background completion (when needed)

For background-eligible configurations, route
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the
manager that owns that session identifier:

```swift
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    if identifier == "com.example.media.downloads" {
        mediaDownloads.handleBackgroundSessionCompletion(identifier, completion: completionHandler)
    } else if identifier == "com.example.documents.downloads" {
        documentDownloads.handleBackgroundSessionCompletion(identifier, completion: completionHandler)
    }
}
```

`handleBackgroundSessionCompletion(_:completion:)` is `nonisolated`, so the
synchronous app-delegate entry point can call it without `await`.

## Step 5 — Decommission the singleton call sites

Refactor every `DownloadManager.shared.…` call site to take a manager
parameter (or read one from the owning component). The compiler emits a
deprecation warning on each remaining `shared` reference, which makes the
migration self-tracking.

A typical conversion:

```swift
// Before
final class MediaListViewModel {
    func startDownload(url: URL, to destination: URL) async {
        _ = await DownloadManager.shared.download(url: url, to: destination)
    }
}

// After
final class MediaListViewModel {
    private let downloads: DownloadManager
    init(downloads: DownloadManager) { self.downloads = downloads }

    func startDownload(url: URL, to destination: URL) async {
        _ = await downloads.download(url: url, to: destination)
    }
}
```

## Lifetime checklist

- [ ] One ``DownloadManager`` per feature with a unique session identifier.
- [ ] Construction via ``DownloadManager/make(configuration:)``.
- [ ] Background completion handler routed to the manager that owns the
      session identifier in the app delegate.
- [ ] No `DownloadManager.shared` references remain at compile-time
      (deprecation warnings cleared).
- [ ] Tests and previews receive the manager via the same dependency
      surface as production code.
