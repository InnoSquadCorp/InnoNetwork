# Task persistence

Understand how InnoNetworkDownload persists task state across app launches and how to
operate it safely under crash, disk full, and concurrent-access conditions.

## Overview

Task persistence is durable enough to recover from process termination, app upgrades, and
unexpected restarts. The store uses an append-log + checkpoint hybrid that keeps writes
cheap on the hot path while bounding restoration cost.

The default implementation lives in `AppendLogDownloadTaskStore`. Applications tune it
through configuration-level choices such as the session identifier, fsync policy, and
compaction policy. The storage protocol is package-internal and not a public extension
point.

## On-disk layout

Each persisted session lives under `persistenceDirectory/<storage-component>/`:

```text
<storage-component>/
├── checkpoint.json   # most recent compact snapshot
├── .lock            # inter-process mutation lock
└── events.log        # JSON Lines append log of incremental changes
```

The component is the original value for a bounded lowercase ASCII identifier
using reverse-DNS-safe characters (`a-z`, `0-9`, `.`, `-`, `_`). Path-like,
uppercase, oversized, empty, or non-ASCII identifiers use a deterministic
SHA-256 component instead. Foundation still receives the original session
identifier; only library-owned filesystem paths use the mapped value. This
keeps sessions distinct on case-insensitive filesystems and prevents nested or
out-of-root storage.

Each line of `events.log` is a self-describing event:

```json
{"sequence":127,"timestamp":1714214830.123,"kind":"upsert","taskID":"…","url":"…","destinationURL":"…","resumeData":"…"}
{"sequence":128,"timestamp":1714214831.456,"kind":"remove","taskID":"…"}
```

Restoration reads `checkpoint.json` first, then replays any remaining `events.log`
suffix in sequence order.

## Storage protection

InnoNetworkDownload marks every library-owned persistence directory and metadata file as
excluded from backup on Darwin platforms. On iOS, tvOS, watchOS, and visionOS it also
requests complete-until-first-user-authentication file protection. These attributes are
applied through already-open file descriptors and reapplied when an existing store is
opened, including its checkpoint, event log, and lock file.

Protection is intentionally scoped to paths owned by the library. A caller-supplied
`persistenceBaseDirectoryURL` is only the parent of the `InnoNetworkDownload` directory;
the parent itself is not modified. Final download destinations are also caller-owned and
never receive the persistence or staging attributes.

The complete caller-provided base path is a trusted anchor and may itself contain symbolic
links (for example, a container path supplied by the OS). The library canonicalizes that
base once, then creates and opens its own `InnoNetworkDownload` and session components
relative to directory file descriptors with `O_NOFOLLOW`. Root, session, lock, checkpoint,
log, temporary, and quarantine symlinks, hard links, and non-regular entries are rejected
without blocking on FIFO endpoints. Every authoritative read, write,
rename, unlink, size check, and lock remains relative to the retained session descriptor,
so replacing the visible parent after initialization cannot redirect persistence I/O.

This containment assumes the documented single, cooperating owner for a session identifier.
App Group members that can mutate the same directory are inside that trust boundary and must
honor the persistence lock. The store does not attempt to defeat a concurrently malicious
process with the same container privileges; mutually untrusted components need separate
private containers or an IPC broker that exclusively owns persistence.

Checkpoints written before the optional `orderedRecordIDs` field cannot fully
recover the latest task id for repeated same-URL records. The loader keeps
restoration deterministic by applying `orderedRecordIDs` first when present,
then appending unseen records in sorted-ID order as a best-effort fallback.
Future compaction writes a fresh checkpoint with explicit order.

## Compaction

The store compacts the log into a fresh checkpoint when any of these triggers fire:

- Event count ≥ ``DownloadConfiguration/PersistenceCompactionPolicy/maxEvents`` since the
  last checkpoint (`1,000` by default).
- Log file size ≥ ``DownloadConfiguration/PersistenceCompactionPolicy/maxLogBytes`` (`1 MiB`
  by default).
- Tombstone ratio ≥ ``DownloadConfiguration/PersistenceCompactionPolicy/tombstoneRatio``
  (`25%` by default).

Compaction writes a temporary file and atomically renames it over `checkpoint.json`, then
truncates `events.log`. A crash mid-compaction is safe — the next launch detects the stale
log and replays from the older checkpoint.

Tune the thresholds when a long-running process accumulates a very large download queue:

```swift
let configuration = DownloadConfiguration.advanced(
    sessionIdentifier: "com.example.app.downloads",
    persistence: DownloadPersistencePack(
        compactionPolicy: .init(
            maxEvents: 500,
            maxLogBytes: 512 * 1024,
            tombstoneRatio: 0.2
        )
    )
)
```

## Corrupt file handling

Syntactically malformed or unsupported checkpoint data is quarantined so a valid append log
can still be replayed. When an append log has a malformed suffix, the store first commits and
fsyncs a checkpoint containing the valid prefix, then renames the source log to
`events.corrupted-<unique-id>.log` and creates a fresh active log. When quarantine succeeds,
the corrupt copy stays on disk until the operator removes it, allowing support to inspect it
after the fact.

File-access failures are different from malformed data. Data Protection before first unlock,
permission errors, lock failures, disk errors, and other transient I/O failures make
``DownloadManager/init(configuration:)`` throw without moving or deleting the checkpoint or
append log. Retry initialization after the storage boundary becomes available; the preserved
files remain authoritative for restoration.

## File locking

The store uses `flock(LOCK_EX)` around every write. Two `DownloadManager` instances with
the same `sessionIdentifier` would compete for the lock. Foundation already merges them
into a single backing session, so the second instance is the one that gets the lock-wait,
and the manager's session-identifier guard surfaces the conflict before it gets that far.

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
    sessionIdentifier: "com.example.app.downloads",
    persistence: DownloadPersistencePack(
        fsyncPolicy: .always   // or .onCheckpoint, or .never
    )
)
```

## Paused resume data durability

Paused tasks store `resumeData` in the same append-log record as their URL and destination.
After `pause(_:)` completes, a later process launch can restore the task in `.paused` state
and `resume(_:)` can create a system task from the stored resume payload. `resume(_:)`
clears the persisted payload before the new system task is allowed to start; if the
clearing write fails the in-flight system task is cancelled and the task is surfaced as
`.failed(.persistenceFailure)` rather than left running with stale resume bytes on disk.
The entire persistence row is removed on cancel or completion.

The durability boundary is still best-effort because `URLSession` resume data is owned by
the OS and server behavior. If the payload is rejected after an app upgrade, server range
policy change, or cache invalidation, the transfer may restart from byte 0.

## Public configuration points

The persistence store itself is package-internal. Applications customize its behavior
through public configuration:

- Use a stable, app-unique ``DownloadConfiguration/sessionIdentifier`` for each background
  session.
- Tune durability with ``DownloadConfiguration/persistenceFsyncPolicy``.
- Tune append-log growth with ``DownloadConfiguration/persistenceCompactionPolicy``.

The checkpoint and append-log file formats are internal implementation details. Do not parse
or mutate them from application code; use ``DownloadManager`` APIs to observe and control
download state.

## Related

- ``DownloadConfiguration``
- ``DownloadManager``
- <doc:BackgroundDownloads>
