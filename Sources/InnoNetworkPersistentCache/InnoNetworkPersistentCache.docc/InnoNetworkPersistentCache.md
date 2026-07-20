# ``InnoNetworkPersistentCache``

Persist HTTP response cache entries to disk with conservative privacy defaults.

## Overview

`InnoNetworkPersistentCache` provides ``PersistentResponseCache``, an on-disk
`InnoNetwork.ResponseCache` implementation for apps that want cached
responses to survive process restarts.

By default the cache rejects responses tied to credential-like request headers,
`Set-Cookie`, and `Cache-Control: private`. It also applies
``PersistentResponseCacheConfiguration/DataProtectionClass/completeUntilFirstUserAuthentication``
file protection on iOS, tvOS, watchOS, and visionOS, keeping background reads
available after the first device unlock while protecting data across restarts.

Reproducible cache-owned artifacts are excluded from backup on Darwin: the
`bodies/` directory, `index.json`, file-backed HMAC key, and individual body
files. The caller-supplied directory root is not marked as excluded because it
may also contain app-owned files. Protection and backup-exclusion metadata are
reapplied after atomic replacement and when an existing cache is reopened.

The complete raw query and sensitive request-header values that participate in
disk cache keys are stored as managed HMAC-SHA256 values instead of raw text or
unsalted fingerprints. Query order, duplicate keys, empty items, and raw
percent-encoding remain distinct through the HMAC input without appearing in
the index.
Entries that cannot satisfy the active privacy policy or storage budget are
treated as misses and scrubbed from the cache's own files. Corrupt or
unknown-version on-disk indexes are recovered automatically by resetting the
cache's own subtree (never the user-supplied directory root).

A missing index opens as an empty cache. A directory, symbolic link, FIFO, or
other non-regular entry at the index path is deterministic structural corruption
and cold-resets only cache-owned state. Index reads are capped at 16 MiB before
JSON decoding; an oversized index follows the same cache-owned cold-reset path.
Protected-data, permission, and transient storage errors while reading an
existing index or inspecting body files instead fail initialization without
deleting cache state; FIFO body entries are rejected without waiting for a
peer. If an existing
cache instance encounters the same kind of transient body-read error,
``PersistentResponseCache/get(_:)`` returns a miss but preserves the entry for
a later retry. Only verified missing, invalid, symbolic-link, non-regular, or
oversized body state is scrubbed.

Use ``PersistentResponseCache/statistics()`` for storage-pressure snapshots and
``PersistentResponseCache/telemetrySnapshot()`` or
``PersistentResponseCache/drainTelemetryEvents()`` to inspect scrub and
eviction events during rollout.

## Topics

### Cache

- ``PersistentResponseCache``
- ``PersistentResponseCacheConfiguration``
- ``PersistentResponseCacheEvictionReason``
- ``PersistentResponseCacheStatistics``
- ``PersistentResponseCacheTelemetryEvent``
