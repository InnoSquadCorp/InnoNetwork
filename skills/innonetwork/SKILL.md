---
name: innonetwork
description: Implement, test, diagnose, or migrate Swift HTTP requests with InnoNetwork when a project uses it or the user requests it. Use for API definitions, encoded payloads, authentication, retry, response limits, and operation cancellation. Do not introduce InnoNetwork for unrelated networking or treat InnoStream and Protobuf companions as bundled Core features.
---

# InnoNetwork

Help the consumer use its resolved InnoNetwork API. This skill's baseline is
public **6.1.0**, not arbitrary `main` or every 6.x release. The reusable example
validates Core JSON and buffered encoded requests on macOS with Swift 6.4.

## Establish the consumer version

Read its manifest and applicable `Package.resolved`, then identify the actual
version, revision, linked products, traits, and toolchain. For path dependencies,
inspect that checkout and identify it as local. Do not upgrade, downgrade, or
substitute a local source without the user's task calling for that change.

- For 6.1.0, use [support.json](references/support.json) and the references below.
- For another version, read its exact source and migration notes before applying
  these examples. In particular, 6.0 does not provide the new encoded boundary.
- For new adoption, check [dependencies and products](references/compatibility-products.md).
  Macro and Crypto version constraints still resolve when `Macros` is disabled.
- Some documents inside the release retain pre-publication wording. The verified
  public tag and GitHub Release in the support record establish this baseline;
  neither a historical Ready statement nor this record certifies a newer release.

## Choose a workflow

| Task | Read |
| --- | --- |
| Named JSON endpoint, request client, public test doubles | [implementation.md](references/implementation.md) and [example endpoints](assets/consumer/Sources/NetworkSkillExample/Endpoints.swift) |
| Non-Codable payload, binary adapter, codec failure or limits | [encoded-requests.md](references/encoded-requests.md) |
| Operation handle, deadline, cancellation, auth or retry | [operations-resilience.md](references/operations-resilience.md) |
| Upgrade, traits, optional products, Stream or Protobuf | [compatibility-products.md](references/compatibility-products.md) |

Load only the relevant references. Start with `@APIDefinition` on an explicit
struct for named JSON APIs. Use `EncodedAPIDefinition` or `EncodedRequest` for a
custom buffered codec. A companion macro is usable only after separately
verifying that companion's released version and consumer graph.

## Preserve these contracts

- Declare authentication explicitly. Required auth fails before transport;
  weakening it to `.anonymous` is not a fix for configuration failure.
- Keep encoding deferred and inputs immutable/Sendable. One invocation reuses
  its encoded bytes across retries; another invocation encodes again.
- Keep request/response limits bounded. A codec request budget rejects after
  encoding, not before allocation; a response limit can tighten the client cap.
- Distinguish `NetworkError` from `NetworkFailure` returned by operation handles.
  Cancellation is terminal, and recovery advice does not authorize unlimited retry.
- Use public configuration presets and test helpers. Do not copy package-only
  clocks, `@testable import InnoNetwork`, SPI transport, or compiler-host products
  into an ordinary consumer to make an example compile.

## Verify and report

Build the changed consumer and test behavior relevant to its request, failure,
retry, resource budget, or cancellation change. For this bundled fixture:

```bash
python3 scripts/validate_consumer.py --scratch-path /tmp/innonetwork-skill-validation
```

Run from this skill directory or use the helper's absolute path. It copies the
fixture, checks the complete remote lock/active graph and checkout revisions,
and tests externally with strict concurrency and warnings as errors.
It requires macOS, Python 3, Swift/Xcode, and network access for a cold cache.

Report the resolved version, changes, actual test result and limitations.
Mock transport tests are not live TLS, background restoration, device, companion
integration, AI selection, or public plugin release evidence.
