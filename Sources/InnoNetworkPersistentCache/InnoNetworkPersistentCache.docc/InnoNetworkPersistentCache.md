# ``InnoNetworkPersistentCache``

Persist HTTP response cache entries to disk with conservative privacy defaults.

## Overview

`InnoNetworkPersistentCache` provides ``PersistentResponseCache``, an on-disk
``InnoNetwork/ResponseCache`` implementation for apps that want cached
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

Sensitive request-header values that participate in disk cache keys are stored
as managed HMAC-SHA256 values instead of raw text or unsalted fingerprints.
Entries that cannot satisfy the active privacy policy or storage budget are
treated as misses and scrubbed from the cache's own files. Corrupt or
unknown-version on-disk indexes are recovered automatically by resetting the
cache's own subtree (never the user-supplied directory root).

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
