# Task persistence

Understand how InnoNetworkDownload persists task state across app launches and how to
operate it safely under crash, disk full, and concurrent-access conditions.

## Overview

Task persistence is durable enough to recover from process termination, app upgrades, and
unexpected restarts. The store uses an append-log + checkpoint hybrid that keeps writes
cheap on the hot path while bounding restoration cost.

The default implementation lives in `AppendLogDownloadTaskStore`. Applications tune it
through configuration-level choices such as the persistence directory, session identifier,
and fsync policy. The storage protocol is package-internal and not a public extension point.

## On-disk layout

Each persisted session lives under `persistenceDirectory/<sessionIdentifier>/`:

```text
<sessionIdentifier>/
├── checkpoint.json   # most recent compact snapshot
└── events.log        # JSON Lines append log of incremental changes
```

Each line of `events.log` is a self-describing event:

```json
{"sequence":127,"timestamp":1714214830.123,"kind":"upsert","taskID":"…","url":"…","destinationURL":"…"}
{"sequence":128,"timestamp":1714214831.456,"kind":"remove","taskID":"…"}
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
`events.corrupted-<timestamp>.log` and continues with whatever is recoverable, then writes a
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
`Darwin.fsync(_:)` on the events log and on checkpoint writes. The default is
``DownloadConfiguration/PersistenceFsyncPolicy/onCheckpoint``.

| Policy | Event append | Checkpoint write | Loss on crash |
|--------|-------------|------------------|---------------|
| ``DownloadConfiguration/PersistenceFsyncPolicy/always`` | fsync after every mutation batch | fsync before atomic rename | ~0 events in the batch |
| ``DownloadConfiguration/PersistenceFsyncPolicy/onCheckpoint`` (default) | no fsync | fsync before atomic rename | events since the last checkpoint |
| ``DownloadConfiguration/PersistenceFsyncPolicy/never`` | no fsync | no fsync | up to a few minutes of OS-cached writes |

`fsync(_:)` is expensive on busy or low-power volumes — it forces the host's IO scheduler
to flush dirty pages to stable storage before returning. `.always` is the right choice for
paid content, legal documents, or anywhere a missed event would be a user-visible support
ticket. `.onCheckpoint` is the right default for consumer apps: typical writes are cheap
and the recovery on crash falls back to the last durable checkpoint plus the partial log
suffix replayed on startup.

Switching policy is a configuration knob — the on-disk format is identical and you can
upgrade or downgrade between runs without migration:

```swift
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.downloads"
) { builder in
    builder.persistenceFsyncPolicy = .always   // or .onCheckpoint, or .never
}
```

## Public configuration points

The persistence store itself is package-internal. Applications customize its behavior
through public configuration:

- Use a stable, app-unique ``DownloadConfiguration/sessionIdentifier`` for each background
  session.
- Choose ``DownloadConfiguration/persistenceDirectory`` when the default Application Support
  location is not appropriate.
- Tune durability with ``DownloadConfiguration/persistenceFsyncPolicy``.

The checkpoint and append-log file formats are internal implementation details. Do not parse
or mutate them from application code; use ``DownloadManager`` APIs to observe and control
download state.

## Related

- ``DownloadConfiguration``
- ``DownloadManager``
- <doc:BackgroundDownloads>
