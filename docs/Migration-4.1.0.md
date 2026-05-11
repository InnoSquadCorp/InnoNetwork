# Migration Guide: 4.1.0

This guide covers the three breaking changes introduced in the 4.1.0
minor release. The release is otherwise additive — every other surface
on the 4.x stable ledger continues to compile unchanged. Skim the
checklist below; if none of the three rows apply to your call sites,
no migration is needed.

---

## Immediate Migration Checklist

| Previous usage | 4.1.0 replacement / action |
| --- | --- |
| `MultipartUploadStrategy.inMemory` (zero-arg) | Pass an explicit `maxBytes:`, e.g. `.inMemory(maxBytes: 16 * 1024 * 1024)`. Or switch to `.platformDefault` / `.streamingThreshold(bytes: ...)`. |
| OpenAPI spec containing path templates (`/users/{id}`) | The generator now rejects the operation. Either pin the path on a hand-rolled `APIDefinition` struct or remove the placeholder upstream in the spec. |
| Private CA that identifies Ed25519 keys via the string `"ed25519"` | Switch the SPKI input to the RFC 8410 OID `1.3.101.112`. |

The rest of this document walks each row in detail.

---

## 1. `MultipartUploadStrategy.inMemory(maxBytes:)` is mandatory

### What changed

Previously `MultipartUploadStrategy.inMemory` could be written with no
arguments. The implementation silently defaulted to a `Int.max` ceiling
on the encoded body size, which meant a single oversized part could OOM
the process before the request even hit the wire. There was also a
small estimator-vs-read TOCTOU window in `MultipartFormData.encode`:
the pre-flight estimator checked size, but a file part whose size grew
between the estimator and the actual read would bypass the ceiling.

4.1.0 makes the ceiling explicit and closes the TOCTOU window:

- `MultipartUploadStrategy.inMemory(maxBytes: Int)` requires the
  argument at the call site — there is no default.
- `MultipartFormData.encode(maxInMemoryBytes:)` now records every
  written part against a running counter and throws
  `NetworkError.configuration(.invalidRequest(...))` the moment the
  accumulator exceeds the configured ceiling.
- `.platformDefault` and `.streamingThreshold(bytes:)` are unchanged.
  `.platformDefault` still wraps the canonical platform ceiling;
  prefer it if you do not have a project-specific cap to enforce.

### Before / After

```swift
// 4.0.x
struct UploadAvatar: MultipartAPIDefinition {
    var uploadStrategy: MultipartUploadStrategy { .inMemory }
    // ...
}

// 4.1.0 — explicit cap
struct UploadAvatar: MultipartAPIDefinition {
    var uploadStrategy: MultipartUploadStrategy {
        .inMemory(maxBytes: 16 * 1024 * 1024) // 16 MiB
    }
    // ...
}

// 4.1.0 — alternatively, use the platform default
struct UploadAvatar: MultipartAPIDefinition {
    var uploadStrategy: MultipartUploadStrategy { .platformDefault }
    // ...
}
```

### How to pick `maxBytes`

- For known-bounded payloads (avatars, profile photos, document
  thumbnails), pick the ceiling your product enforces upstream (e.g.
  10 MB for image uploads, 25 MB for documents). Aim slightly above
  the largest legitimate payload so the guard fires on misconfigured
  or malicious inputs, not on the happy path.
- For unbounded inputs (user-attached video, generic file picker),
  switch to `.streamingThreshold(bytes:)` so the encoder writes the
  body to disk past the configured threshold instead of buffering in
  memory.
- If you genuinely want to defer to the platform default, write
  `.platformDefault` rather than picking a number — the platform
  default is a `package`-owned constant and tracks future tuning.

### Compiler signal

The compiler surfaces the migration as:

```
error: missing argument for parameter 'maxBytes' in call
    .inMemory
    ^
        (maxBytes: <#Int#>)
```

so every call site is mechanically discoverable.

---

## 2. OpenAPI generator rejects path templates

### What changed

The `openapi-to-innonetwork` tool used to emit a generated
`APIDefinition` for operations whose path contained `{name}`
placeholders, embedding the placeholder literal into the generated
`path` property. This silently produced 404s at runtime when the
operation was invoked without substitution — the generator had no
mechanism to expose the placeholder names back to the caller.

4.1.0 fails generation early with
`GenerationError.unsupportedPath(<placeholder>)` whenever a path
matches `/\{[^/{}]+\}/`. The error description includes the offending
placeholder name so the operator can locate the spec entry.

### Migration paths

- **Remove the template from the spec.** If the path was templated by
  accident or the operation is no longer needed, drop the placeholder
  in the OpenAPI document and regenerate.
- **Hand-roll the `APIDefinition`.** For operations where the template
  was intentional, delete the generator-emitted file (the build now
  fails so it doesn't exist anyway) and check in a hand-written
  `APIDefinition` struct that constructs the path from its
  associated values:

  ```swift
  struct GetUser: APIDefinition {
      typealias Parameter = EmptyParameter
      typealias APIResponse = User

      let userID: String
      var method: HTTPMethod { .get }
      var path: String { "/users/\(userID)" }

      init(userID: String) { self.userID = userID }
  }
  ```

  The hand-written struct sits next to the generator output (the
  generator skips it because it never sees the operation); the rest
  of the typed `APIDefinition` surface is unchanged.

### When templating returns

A future minor on the 5.x line is expected to emit typed
`APIDefinition` structs with path-component associated values. Until
then, hand-rolled structs are the supported path for templated
operations.

---

## 3. Trust Ed25519 identification is OID-only

### What changed

`PublicKeyPinningEvaluator.spkiData(publicKeyData:keyType:keySizeInBits:)`
used to recognise Ed25519 keys via either of two paths:

1. The lowercased `keyType` string equals `"ed25519"`.
2. The `keyType` string equals the RFC 8410 OID `1.3.101.112`.

The string path was a private-CA pragma — Apple's
`Security.framework` does not currently expose an Ed25519
`kSecAttrKeyType` constant, and adopters who fed certificates through
a private CA toolchain often saw the lowercase keyword instead of the
OID. The match was loose enough to risk false positives against a
future framework constant that happens to embed the substring
`"ed25519"`, which would silently change pinning behavior.

4.1.0 narrows the recogniser to OID-only. The lowercase keyword no
longer matches; only `1.3.101.112` produces SPKI output.

### Migration

- **Trust pin fixtures that record `keyType = "ed25519"`.** Re-emit
  the fixture using the OID `"1.3.101.112"`. The SPKI output for the
  same public key is unchanged, so the hash that was pinned still
  matches at runtime.
- **Private CAs that fed `kSecAttrKeyType = "ed25519"` into a
  custom evaluator.** Update the CA wrapper to surface the OID
  instead. The OID is the long-term identifier — when
  `Security.framework` eventually exposes
  `kSecAttrKeyTypeEd25519`, the OID-only path will continue to
  function and the framework constant will be added alongside it.

### Compiler signal

This change has no compile-time surface; it manifests as a runtime
pinning behavior difference. Audit your pin fixtures and any private
CA `keyType` shim before upgrading. The
`spkiEncodingHelperRejectsEd25519Keywords` test in the trust target
locks the rejection so accidental keyword fallbacks regress noisily.

---

## Reference

- `CHANGELOG.md` — the `[Unreleased]` section enumerates every
  addition and breaking change in the release.
- `API_STABILITY.md` — provisionally stable / stable taxonomy for the
  surfaces touched by this release.
- `docs/rfcs/RFC9111-Compliance.md` — the new
  `ResponseCachePolicy.rfc9111Compliant(wrapping:)` adapter shipped in
  this release is additive and does not require migration; the doc
  enumerates the directive coverage.
