# RFC: Persistent Response Cache (companion product)

**Status:** Implemented in 4.0.0 as `InnoNetworkPersistentCache`.
**Owner:** InnoNetwork core.
**Target:** Companion product to InnoNetwork 4.0.0 — an optional product that
stores ``ResponseCache`` entries on disk so cached responses survive process
restarts.

InnoNetwork's built-in ``InMemoryResponseCache`` covers the in-process
revalidation path that ``ResponseCachePolicy`` and the executor's 304
handling need. A persistent companion is a distinct concern: it owns
durability, eviction, and privacy decisions that have no single right
default and would balloon the core module's API surface if folded in.
The 4.0.0 implementation uses a conservative flat-file store:

- versioned `index.json` plus SHA-256-addressed body files
- max 50 MB total, max 1000 entries, max 5 MB per entry
- authenticated responses are not stored by default
- responses with `Set-Cookie` are not stored by default
- unknown index versions and corrupt entries are evicted and startup continues

## Why a separate product

- ``ResponseCache`` is already a protocol (``ResponseCache``) so a
  persistent backing can be plugged in without breaking the executor's
  contract.
- Disk persistence pulls in file-protection classes, app-group
  containers, schema versioning, and corruption recovery — concerns
  the core network library does not need to understand.
- Some apps must opt out of disk caching entirely (privacy posture,
  regulatory constraints). A separate product makes the opt-in
  explicit at the package-graph level.

## Six policies to decide

### 1. Cache key policy

The key set must be deterministic across processes and stable across
app updates. The minimum key today is `(method, URL, vary dimensions)`.
Open questions:

- Does the key include `Authorization` / `Cookie` headers? Including
  them gives per-user separation but inflates the keyspace and risks
  pinning per-token entries that will never be reused after refresh.
  Excluding them requires the persistent store to refuse to write
  entries whose response carries `Cache-Control: private` or an
  authenticated request — which mirrors RFC 9111 §3.5 shared-cache
  rules but is a meaningful behaviour change vs. the in-memory
  default.
- How are vary dimensions canonicalized? (header name lowercased,
  value trimmed, `*` short-circuits to "do not store"). The
  in-memory cache already normalizes; the persistent store must
  use the *same* canonicalization at write time and at read time.
- How is the key serialized on disk — fixed-length hash (SHA-256 of
  canonical tuple) vs. structured filename? A hash trades human
  inspectability for predictable filename length on case-insensitive
  filesystems.

### 2. Freshness policy

The companion must decide which freshness signal wins when several
are present:

- ``ResponseCachePolicy/freshnessWindow`` (caller-declared) vs.
  origin `Cache-Control: max-age` / `s-maxage`.
- `must-revalidate` and `no-cache` directives — does the persistent
  store honour them by forcing a 304 round-trip on every read, or
  refuse to store them at all?
- `Expires` (HTTP/1.0 absolute date) as a fallback when no
  `Cache-Control` is present.

Recommendation: the executor's existing precedence (caller-declared
window > origin `max-age` > store-defined fallback) should be the
default, with an override on the companion's configuration for callers
who want strict origin-driven freshness.

### 3. Eviction policy

A persistent cache without bounded eviction is a slow disk-fill bug.

- LRU vs. LRU-with-size-budget vs. TTI hybrid (touch-on-read +
  per-entry TTL).
- Per-entry size cap: a single 50 MB response should not consume the
  entire budget. Above the cap, fall through to "do not store" rather
  than evict everything else.
- Total budget: byte budget (e.g. 50 MB) and/or entry-count budget
  (e.g. 1000 entries), whichever fires first.
- Eviction trigger: synchronous on write (predictable, blocks the
  caller) vs. background (predictable footprint, requires a periodic
  task or actor heartbeat).

### 4. Privacy policy

Persistent storage of network responses is a privacy decision, not a
performance one.

- Does the store accept responses to authenticated requests at all?
  RFC 9111 `private` vs. `public` cache directives govern this for
  shared caches; for an on-device cache, the safer default is to
  accept `private` only when the caller has explicitly opted into
  storing authenticated responses.
- Does the store accept responses with `Set-Cookie` headers? The
  default should be no.
- Does the store redact `Authorization` from any persisted request
  metadata? (We persist enough request context to recompute vary
  dimensions; that context must not leak credentials.)

### 5. Data protection class

iOS file protection class governs whether the cache is readable when
the device is locked.

- ``.completeUnlessOpen`` is the safest default that still lets a
  background download or notification handler open the file.
- Apps that share the cache via an app group container need
  ``.completeUntilFirstUserAuthentication`` so the extension can read
  after first unlock.
- The companion's configuration must expose the protection class so
  apps can pick — and document the trade-off so callers don't pick
  ``.none`` for convenience.

### 6. Migration and versioning

The on-disk format will change. Plan for it from day one:

- A version byte (or short header) on every entry. Entries with an
  unknown version are silently dropped at read time, not surfaced as
  errors.
- A package-level format version stored once per cache directory; on
  mismatch, the store treats the entire directory as corrupted and
  rebuilds.
- Corruption handling: a single malformed entry must not poison the
  whole store. Read-side decoding errors evict the entry and continue.
- App-update behaviour: deleting the cache directory on schema
  upgrade is acceptable; partial migration is not (it bakes
  long-tail correctness bugs into the store).

## Implementation decisions (4.0.0)

The six policies above were resolved during the 4.0.0 implementation as
follows. The shipped behaviour is what callers should rely on; the
historical discussion above is preserved for context only.

| Policy | 4.0.0 decision |
|---|---|
| Cache key | `(canonical method, URL, vary dimensions)` hashed into a SHA-256 body filename. Vary dimensions reuse `InMemoryResponseCache`'s normalization (lowercased header name, trimmed value; `*` ⇒ do-not-store). |
| Freshness | Executor precedence preserved: caller-declared `freshnessWindow` > origin `max-age` > store fallback. `no-store` and `private` short-circuit to do-not-store. |
| Eviction | LRU with both 50 MB total byte budget and 1,000-entry budget, whichever fires first. Per-entry hard cap 5 MB. Eviction is synchronous on write. |
| Privacy | Authenticated requests are not stored unless the caller opts in via configuration. Responses with `Set-Cookie` are never stored. Persisted request metadata redacts `Authorization`. |
| Data protection | Configurable; default `.completeUnlessOpen`. App-group integrators may select `.completeUntilFirstUserAuthentication`. |
| Migration | Versioned `index.json`. Unknown index versions and decode failures evict only the index and bodies subtree, leaving the user-supplied directory root untouched, and the store starts fresh. |

## Out of scope (still deferred)

- A streaming-bodies persistence story. Streaming responses remain
  excluded; lifting that exclusion is a separate RFC.
- Alternate backends (SQLite, CoreData). The flat-file store covers the
  current product target; backend swaps are an internal change behind
  the existing protocol.
