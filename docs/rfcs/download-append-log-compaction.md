# RFC: Download Append-Log Snapshot and Compaction

Status: implemented defaults in 4.0.0, policy details subject to operational
feedback.

## Goals

Long-running apps can create thousands of download persistence events. The
append-log store must keep startup restore fast without losing enough history
to debug recovery failures.

4.0.0 introduces `DownloadConfiguration.PersistenceCompactionPolicy` with the
current defaults:

- `maxEvents = 1000`
- `maxLogBytes = 1_048_576`
- `tombstoneRatio = 0.25`

The defaults preserve existing behavior for typical apps while giving high
volume download clients a public configuration point.

## Snapshot Model

The store keeps two files:

- `checkpoint.json`: compact snapshot of live records.
- `events.log`: newline-delimited append log of events since the checkpoint.

On startup the store loads the checkpoint first, then replays any remaining
event-log suffix in order. If replay exceeds policy thresholds, the store
writes a new checkpoint and truncates the event log.

## Recovery Rules

- **Disk full while appending**: surface the write error to the caller and do
  not mutate in-memory persistence state for that event.
- **Disk full while compacting**: keep a recoverable checkpoint/log pair and
  retry compaction on a later write.
- **Malformed event suffix**: keep the events replayed before the corrupt
  suffix, durably write a fresh checkpoint, then quarantine the source log and
  create an empty active log. A checkpoint write failure leaves the source log
  untouched.
- **Malformed checkpoint**: start from an empty snapshot and replay the event
  log. If both are corrupt, restoration produces no persisted records but the
  manager remains usable.
- **File-access or lock failure**: fail initialization without quarantining or
  deleting either state file. Data Protection, permission, and transient I/O
  errors are not evidence of semantic corruption.
- **Unknown future checkpoint version**: ignore the checkpoint, replay the
  current-version event log when possible, and rewrite a current checkpoint on
  the next compaction.
- **App update**: checkpoint schema additions must be optional with defaults
  for at least one major line. `resumeData` and `orderedRecordIDs` follow this
  rule in 4.0.0: older rows decode as `resumeData == nil`. Checkpoints that
  include `orderedRecordIDs` restore same-URL task-id order from that field
  first, then append unseen records in sorted-ID order. Legacy checkpoints
  without `orderedRecordIDs` use only that sorted-ID append order as a
  deterministic best-effort fallback until the next checkpoint rewrite.

## Checksum Policy

4.0.0 does not add a checksum field because the current store is a local
best-effort recovery log rather than a tamper-evident audit log. If field
corruption appears in real app telemetry, add a checkpoint checksum first:

1. write `checkpoint.json.tmp`
2. fsync according to `PersistenceFsyncPolicy`
3. atomically replace `checkpoint.json`
4. store checksum metadata inside the checkpoint envelope

Event-log checksums are deferred until there is evidence that per-row
validation is worth the extra write overhead.

## Open Questions

- Whether high-volume apps need time-based compaction in addition to event and
  byte thresholds.
- Whether app-group storage should expose a stricter data-protection default.
- Whether tombstone ratio should count cancelled/completed rows separately from
  failed rows once product telemetry exists.

## Mutation fast path (7.0)

Until 7.0 every mutation took the directory lock and then replayed the
checkpoint and the whole event log before applying its change, so that a write
made by another store instance or another process sharing the session
directory was always observed. The replay costs time proportional to the
number of logged events, which made a run of N mutations quadratic: 1,000
upserts on one store took 26 seconds of CPU.

The store now keeps a fingerprint of the checkpoint and the log — device,
inode, file type, size, modification time and status-change time of each —
taken under the lock whenever it finishes reading or writing them. A mutation
compares the current fingerprint with the stored one while it holds the lock:

- **Unchanged**: nobody wrote since, so the in-memory state is exactly what a
  replay would produce and the replay is skipped.
- **Changed, or not inspectable**: the files are replayed as before.

Every cooperating writer changes the fingerprint: an append grows the log, a
compaction replaces the checkpoint with a new inode and truncates the log.
A failed mutation leaves the previous fingerprint in place, so a partially
applied write is replayed, not trusted.

One guarantee is narrower than before. Corruption that changes file contents
without changing size or timestamps is detected when the store is next opened
or after another writer changes the files, not at the very next mutation.
