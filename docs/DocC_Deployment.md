# DocC Deployment Guide

## Overview

DocC documentation is built and deployed to GitHub Pages via:

- `.github/workflows/ci.yml`: read-only validation and exact-run Pages artifact
- `.github/workflows/docs-publish.yml`: trusted API-only publication followed by read-only route smoke
- `.github/workflows/docc-pages.yml`: standalone manual preview

The CI and publication workflows build and publish DocC archives for ten public
products: nine runtime products and one compiler-host-only support product.

1. `InnoNetwork`
2. `InnoNetworkAuthAWS`
3. `InnoNetworkDownload`
4. `InnoNetworkUpload`
5. `InnoNetworkWebSocket`
6. `InnoNetworkPersistentCache`
7. `InnoNetworkOpenAPI`
8. `InnoNetworkTrust`
9. `InnoNetworkTestSupport`
10. `InnoNetworkMacroSupport` (compiler-host-only; not an application runtime import)

The build uses the repository's required Xcode toolchain matrix.

Each public product owns a same-named DocC catalog. This keeps the generated
module landing page and curated topic groups from depending on DocC's
symbol-only fallback behavior.

## Triggers

- Successful current-main push CI, after all selected validation succeeds
- Successful authenticated Dependabot current-main recovery CI
- `DocC Pages` manual dispatch produces preview artifacts only

PRs, stale main runs and ordinary unverified manual CI dispatches cannot publish.
See [CI automation](CIAutomation.md) for origin checks and activation boundaries.

## Deployment Output

The workflow deploys a static site to GitHub Pages with module-specific entry points:

- `/<repo>/InnoNetwork/documentation/innonetwork`
- `/<repo>/InnoNetworkAuthAWS/documentation/innonetworkauthaws`
- `/<repo>/InnoNetworkDownload/documentation/innonetworkdownload`
- `/<repo>/InnoNetworkUpload/documentation/innonetworkupload`
- `/<repo>/InnoNetworkWebSocket/documentation/innonetworkwebsocket`
- `/<repo>/InnoNetworkPersistentCache/documentation/innonetworkpersistentcache`
- `/<repo>/InnoNetworkOpenAPI/documentation/innonetworkopenapi`
- `/<repo>/InnoNetworkTrust/documentation/innonetworktrust`
- `/<repo>/InnoNetworkTestSupport/documentation/innonetworktestsupport`
- `/<repo>/InnoNetworkMacroSupport/documentation/innonetworkmacrosupport`

It also publishes a root index page linking to every module. Before upload, the
workflow requires each module's transformed landing HTML and render-node JSON
to exist and requires the root index to link to all ten routes. After Pages
deployment, it requests the root and every module URL with bounded retries so a
bad hosting base path or missing route fails the deployment job.

## Publication verification

A GitHub Release does not by itself establish that Pages has deployed matching
documentation. Check the [publisher workflow](https://github.com/InnoSquadCorp/InnoNetwork/actions/workflows/docs-publish.yml)
for a successful current-main deployment and its subsequent root and all ten
product-route smoke checks.

The publisher identifies the source by the canonical
`.github/workflows/ci.yml` definition and its API-verified ID, path, name and
active state. A dynamic execution title such as
`CI validation / push / refs/heads/main` is not the workflow definition name.
For verified main pushes and authenticated Dependabot recovery, the exact
`Verify prior validation for metadata` step may be skipped, while
`Require every planned CI result` must succeed. Other unexpected skips still
fail; source, current-main, exact-attempt, check and artifact verification remain
required before the Pages API is called.

Publisher changes require exact-head CI, independent review and normal
integration. Local regression fixtures and an uploaded DocC artifact do not
prove live deployment or route availability. The publishing flow does not
change Pages or repository settings.

## Local Reproduction

From repo root:

```bash
xcodebuild docbuild \
  -scheme InnoNetwork-Package \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/DocC

bash Scripts/check_docc_archives.sh .build/DocC

mkdir -p .build/docc-site

while IFS= read -r module; do
  archive="$(find .build/DocC/Build/Products -type d \
    -path "*/${module}.doccarchive" -print -quit)"
  xcrun docc process-archive transform-for-static-hosting "$archive" \
    --output-path ".build/docc-site/$module" \
    --hosting-base-path "InnoNetwork/$module"

  slug="$(printf '%s' "$module" | tr '[:upper:]' '[:lower:]')"
  test -s ".build/docc-site/$module/documentation/$slug/index.html"
  test -s ".build/docc-site/$module/data/documentation/$slug.json"
done < docs/public-docc-products.txt
```

Replace the first `InnoNetwork` in each `--hosting-base-path` with the actual
repository name when reproducing a fork's Pages layout.

For local CPU stability, run DocC archive transforms sequentially. Avoid running
symbol graph generation for other Swift packages at the same time; DocC and
SwiftPM symbol extraction are CPU-heavy and can saturate local developer
machines.

## Operational Notes

- Ensure GitHub Pages is enabled in repository settings.
- CI uses `actions/upload-pages-artifact`; the trusted publisher uses the Pages
  deployment API after exact-origin/attempt/job/step/artifact verification.
- Post-deployment route smoke retains bounded retries in a separate read-only job.
- A library product addition or rename must update its DocC catalog,
  `docs/public-docc-products.txt`, this route list, and `docs/site/index.html`
  together. The archive contract rejects drift from `Package.swift`.
