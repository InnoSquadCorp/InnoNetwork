# Native package layout and release boundaries

## Compatibility decision

Keep the existing SwiftPM entry point at the repository root. Do not move or
duplicate its manifest, lockfile, `Sources`, `Tests`, resources, examples or
Swift smoke targets as part of Android/Web integration. Existing Swift clients
keep the same repository URL, product names and release line. This integration
does not change Swift source or the root package manifest from the merge base.

```text
InnoNetwork/
  Package.swift, Package.resolved, Sources/, Tests/  # existing Apple package
  Platforms/
    Android/                                      # Gradle root and four modules
    Web/                                          # npm package root
  SmokeTests/
    AndroidConsumer/                              # independent Maven/KSP/R8 client
    WebConsumer/, ReactConsumer/, WebTarballConsumer/, BrowserConsumer/
  Scripts/                                        # checks and local bundle tooling
```

Android and Web use independent 1.x version lines; the root Swift release line
remains 6.x. Do not force their version numbers to match or turn the repository
root into an npm workspace/package or a Gradle application.

## Distribution roots

| Distribution | Root / entry point | Contents and consumer gate |
| --- | --- | --- |
| SwiftPM | root `Package.swift` | Existing products/resources; `swift test`, consumer smoke and native CI |
| Maven | `Platforms/Android` | Four `com.innosquad.innonetwork` modules; AAR/JAR, sources, docs, POM, Gradle metadata and checksums; independent published-artifact consumer |
| npm | `Platforms/Web` | `@innosquad/innonetwork`; `dist`, source-map targets, README and license; installed tarball with DOM and Node-only consumers |

The npm `repository.directory` remains `Platforms/Web`; entry points resolve
within that package's `dist`. React is a consumer integration, not a mandatory
runtime dependency of the Web package. Consumers and generated build/cache
directories do not become part of another platform's published package.

`python3 Scripts/check_platform_layout.py` checks these canonical roots,
Android module membership, npm package boundaries/license and local consumer
paths without building or publishing. Its negative controls run in the portable
gate and each Cross-platform CI job. Artifact checks and real installed
consumers remain separate checks; a layout pass alone is not release readiness.

## Validate without publishing

From the repository root:

```bash
python3 Scripts/check_platform_layout.py
python3 Scripts/tests/test_check_platform_layout.py
Scripts/check_cross_platform.sh
bash Scripts/prepare_cross_platform_release.sh
```

The last command creates a new local Maven/npm bundle and records source and
artifact checksums. It does not publish remotely, sign artifacts, create a tag
or establish remote CI evidence. Do not overwrite older bundles or relabel
their recorded SHA as a later commit.

## Keep release channels separate

- Bare numeric Git tags belong to the existing Swift release process and its
  validation/ref policy. Android/Web `1.0.0` package versions do not authorize
  creating a repository-wide `1.0.0` tag or running the Swift publisher.
- A future Android/Web tag policy must use explicit platform namespaces, such
  as `android/1.0.0` and `web/1.0.0`, plus dedicated publishing workflows. These
  are reserved examples, not tags or publishers created by this integration.
- Main merge and Cross-platform CI validate source/artifacts; they do not
  publish Maven Central/npm or change the published Swift release.
- Public Android/Web release still requires registry ownership/credentials,
  signing or provenance, exact-commit release CI, an external registry-only
  consumer and release notes. Set up and authorize that publication separately.
- If package roots change later, update metadata, consumer paths, artifact
  checks, local bundle source manifests and CI triggers in the same change.
  Preserve a migration path and rerun installed-artifact consumption.

See [API stability](API_STABILITY.md), [release evidence](RELEASE_READINESS.md)
and the root [release policy](../docs/RELEASE_POLICY.md) for the independent
compatibility and publication gates.
