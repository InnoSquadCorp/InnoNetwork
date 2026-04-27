# Task persistence

Understand how InnoNetworkDownload persists task state across app launches and how to
operate it safely under crash, disk full, and concurrent-access conditions.

## Overview

Task persistence is durable enough to recover from process termination, app upgrades, and
unexpected restarts. The store uses an append-log + checkpoint hybrid that keeps writes
cheap on the hot path while bounding restoration cost.

The default implementation lives in `AppendLogDownloadTaskStore`. You can replace it with
a custom `DownloadTaskStore` if your application has a different persistence model.

## On-disk layout

Each persisted session lives under `persistenceDirectory/<sessionIdentifier>/`:

```
<sessionIdentifier>/
├── checkpoint.json   # most recent compact snapshot
└── events.log        # JSON Lines append log of incremental changes
```

Each line of `events.log` is a self-describing event:

```json
{"sequence":127,"timestamp":1714214830.123,"kind":"upsert","taskID":"…","url":"…","destinationURL":"…"}
{"sequence":128,"timestamp":1714214831.456,"kind":"tombstone","taskID":"…"}
```

Restoration reads `checkpoint.json` first, then replays events with sequence numbers
greater than the checkpoint's high-water mark.

## Compaction

The store compacts the log into a fresh checkpoint when any of these triggers fire:

- Event count ≥ 1000 since the last checkpoint.
- Log file size ≥ 1 MiB.
- Tombstone ratio ≥ 25 % (most events are deletions of completed/cancelled tasks).

Compaction writes a temporary file and atomically renames it over `checkpoint.json`, then
truncates `events.log`. A crash mid-compaction is safe — the next launch detects the stale
log and replays from the older checkpoint.

## Corrupt file handling

A read failure during restoration (truncated JSON, wrong sequence ordering, file system
fault) does not block startup. The store renames the corrupt file to
`events.log.corrupt-<timestamp>` and continues with whatever is recoverable, then writes a
fresh checkpoint. The corrupt copy stays on disk until the operator removes it, so support
can inspect it after the fact.

## File locking

The store uses `flock(LOCK_EX)` around every write. Two `DownloadManager` instances with
the same `sessionIdentifier` would compete for the lock. Foundation already merges them
into a single backing session, so the second instance is the one that gets the lock-wait,
and the manager's session-identifier guard surfaces the conflict before it gets that far.

## Persistence directory choice

| Choice | Survives `NSFileProtectionComplete`? | Cleared by user "Clear Storage"? |
|--------|--------------------------------------|----------------------------------|
| Documents | Yes | Yes (Settings → Storage → App) |
| Application Support | Yes | Yes |
| Caches | Yes (until system pressure) | Yes |
| `tmp/` | No (system can delete at any time) | Yes |

The default is Application Support. Use Caches only if you are willing to lose persisted
task state when the OS reclaims space. `tmp/` is never appropriate.

## Tuning fsync semantics

`DownloadConfiguration.persistenceFsyncPolicy` controls how aggressively the store calls
`fsync(_:)`. Tradeoffs:

- ``DownloadConfiguration/PersistenceFsyncPolicy/always`` — fsync every event. Maximum
  durability, highest IO cost. Recommended only for high-value transfers (paid content,
  legal documents).
- ``DownloadConfiguration/PersistenceFsyncPolicy/onCheckpoint`` — fsync at compaction.
  Safe default. The most we lose on crash is the events written since the last checkpoint
  (typically seconds of progress).
- ``DownloadConfiguration/PersistenceFsyncPolicy/never`` — rely on the OS to flush. Crash
  may lose a few minutes of progress. Use for transient transfers where re-download is
  cheap.

## Replacing the store

Implement `DownloadTaskStore` and pass it through ``DownloadConfiguration``:

```swift
struct CoreDataDownloadTaskStore: DownloadTaskStore {
    func upsert(id: UUID, url: URL, destinationURL: URL) async throws { /* ... */ }
    func tombstone(id: UUID) async throws { /* ... */ }
    func loadAll() async throws -> [PersistedDownloadTask] { /* ... */ }
}
```

The library uses the protocol's narrow surface. The default implementation's checkpoint
file format is internal; do not depend on it from a custom store.

## Related

- ``DownloadConfiguration``
- ``DownloadManager``
- <doc:BackgroundDownloads>
