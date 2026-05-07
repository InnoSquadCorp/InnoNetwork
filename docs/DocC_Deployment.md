# DocC Deployment Guide

## Overview

DocC documentation is built and deployed to GitHub Pages via:

- `.github/workflows/docc-pages.yml`

The workflow builds DocC archives for all public library products:

1. `InnoNetwork`
2. `InnoNetworkDownload`
3. `InnoNetworkPersistentCache`
4. `InnoNetworkWebSocket`

## Triggers

- `push` to `main`
- `workflow_dispatch` (manual run)

## Deployment Output

The workflow deploys a static site to GitHub Pages with module-specific entry points:

- `/<repo>/InnoNetwork/documentation/innonetwork`
- `/<repo>/InnoNetworkDownload/documentation/innonetworkdownload`
- `/<repo>/InnoNetworkPersistentCache/documentation/innonetworkpersistentcache`
- `/<repo>/InnoNetworkWebSocket/documentation/innonetworkwebsocket`

It also publishes a root index page linking to those module docs.

## Local Reproduction

From repo root:

```bash
xcodebuild docbuild \
  -scheme InnoNetwork-Package \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/DocC

mkdir -p .build/docc-site

xcrun docc process-archive transform-for-static-hosting \
  .build/DocC/Build/Products/Debug/InnoNetwork.doccarchive \
  --output-path .build/docc-site/InnoNetwork \
  --hosting-base-path InnoNetwork/InnoNetwork
```

Repeat the `process-archive` step for `InnoNetworkDownload`,
`InnoNetworkPersistentCache`, and `InnoNetworkWebSocket` if needed.

For local CPU stability, run DocC archive transforms sequentially. Avoid running
symbol graph generation for other Swift packages at the same time; DocC and
SwiftPM symbol extraction are CPU-heavy and can saturate local developer
machines.

## Operational Notes

- Ensure GitHub Pages is enabled in repository settings.
- The workflow uses `actions/upload-pages-artifact` and `actions/deploy-pages`.
- If module naming changes, update the root index links in `docc-pages.yml`.
