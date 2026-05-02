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
- **Disk full while compacting**: keep the old checkpoint/log pair and retry
  compaction on a later write.
- **Malformed event suffix**: keep the events replayed before the corrupt
  suffix, quarantine the log, write a fresh checkpoint, and truncate the active
  log.
- **Malformed checkpoint**: start from an empty snapshot and replay the event
  log. If both are corrupt, restoration produces no persisted records but the
  manager remains usable.
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
