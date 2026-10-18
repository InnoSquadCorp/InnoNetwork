# Android and Web 1.0 API stability

Android and Web begin independent SemVer lines at `1.0.0`; they do not inherit
the root Swift package's 6.x version. The checked-in versions are release
candidates until registry publication and remote release evidence exist.

The following behavior is intended to be Stable for their 1.x lines:

- native request and response types remain available at the low-level boundary;
- HTTP 4xx and 5xx statuses remain response values until explicitly rejected;
- structured cancellation reaches the active native transport;
- buffered bodies use a conservative default ceiling with caller-owned
  streaming as the large-response path;
- error messages omit URL credentials, query strings, and response bodies;
- origin-scoped Web default headers fail automatic redirects closed;
- typed endpoint/client layers remain optional above the low-level session;
- serialization, KSP, and UI-framework integration remain optional modules or
  consumer-owned adapters;
- generated Android definitions produce native OkHttp requests and use the same
  `APIDefinition` / `NetworkClient` contracts as manual definitions;
- generated Android paths reject literal and expanded-placeholder dot segments
  that could escape the configured base URL path during OkHttp normalization;
- Web JSON decoders receive `unknown` and must validate domain data explicitly;
- Web ceilings measure decoded bytes and preserve bodyless HTTP semantics;
- buffered Android calls release their response before delivering a result;
- Web declarations work with DOM libraries or Node Fetch globals without DOM.

Patch releases may fix implementation bugs without changing these observable
contracts. Minor releases may add source-compatible declarations and optional
modules. Removing or incompatibly changing a Stable declaration or behavior
requires a new major version and migration notes.

## Compatibility gates

Every public change must update documentation and the changelog, then pass:

1. Android JVM-signature baselines for all release AAR/JAR modules;
2. Kotlin explicit API compilation, KSP ABI validation, unit tests, and lint;
3. local Maven publication consumed by an independent Android project;
4. KSP positive generation and deterministic negative-diagnostic fixtures;
5. Maven binary/source/Dokka/POM/checksum and embedded-license verification;
6. Web declaration baselines and unit tests on every supported Node line;
7. a complete npm tarball installed, compiled in DOM and Node-only projects,
   and executed outside the source package;
8. independent TypeScript, React StrictMode/lifecycle, native browser checks,
   and an R8-minified Android consumer;
9. strict Gradle dependency verification, verified Gradle wrapper integrity,
   lockfile-backed npm installs, and lifecycle scripts disabled in CI installs.

The API baselines are review gates, not an instruction to preserve a mistake.
An intentional breaking change must be designed as a major-version change
before its baseline is updated.

## Publication boundary

The repository builds and consumes complete `1.0.0` Maven and npm artifacts
locally. A public release additionally requires registry ownership, credentials,
artifact signing or provenance, remote consumer verification, remote CI and
CodeQL results, a tag, and release notes. Local green evidence does not establish
that Maven Central or npm publication has happened.
