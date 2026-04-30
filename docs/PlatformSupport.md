# Platform Support

## Supported platforms

InnoNetwork ships against the current Apple platforms only:

- iOS 18.0+
- macOS 15.0+
- tvOS 18.0+
- watchOS 11.0+
- visionOS 2.0+

The package targets these versions intentionally so the codebase can rely on
modern Swift Concurrency semantics, strict Sendable checking, and the latest
URLSession surface without compatibility shims. There is no Linux toolchain
support and no plan to add one in 4.x.

## Why no Linux

The library leans on `URLSession`, `OSAllocatedUnfairLock`, `OSLog`,
`Network.framework`, and `UniformTypeIdentifiers`. Each of those is either
Apple-only at the framework level or available on Linux only through partial
shims (`Foundation` on Linux ships a different `URLSession` implementation
that does not match Apple's behaviour, and `OSLog`/`os.unfair_lock` have no
counterpart). Plugging swift-corelibs-foundation or rewriting the storage
primitives would compromise the package's existing isolation contract for an
audience that is better served by `swift-server` ecosystem libraries.

## Sharing models with Linux server code

If you need to share request/response models between an Apple client and a
Linux server (for example, a Vapor backend), keep the model types in a
separate package that depends on neither InnoNetwork nor server-side
frameworks. InnoNetwork itself should stay an Apple-only consumer of those
shared model types.

```text
ProductKit (Linux + Apple)         ← shared Decodable/Encodable models
  ├── InnoNetwork (Apple-only)     ← API definitions, transport policy
  └── VaporServer  (Linux-only)    ← server handlers
```

## CI matrix

The `.github/workflows/ci.yml` job runs on `macos-15` only. Adding a Linux
build leg is intentionally out of scope; it would not catch any regression
because the package does not compile on Linux.

## Supply-chain provenance

Tagged releases produce two artifacts that consumers can verify:

- `sbom.cdx.json` — CycloneDX 1.5 software bill of materials describing the
  resolved package graph and build inputs. Core runtime targets have no
  external library dependencies; the optional codegen/macro product records
  SwiftPM's `swift-syntax` package when the full package graph is resolved.
- `benchmarks.json` — frozen benchmark output from the release validation
  job.

Both artifacts are signed with sigstore cosign keyless signatures. See
[SECURITY.md](../SECURITY.md) for the exact `cosign verify-blob` invocation.
