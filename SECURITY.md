# Security Policy

## Reporting a Vulnerability

- Do not open public issues for security reports.
- Prefer GitHub private vulnerability reporting if it is enabled for this repository.
- If private reporting is not available, contact the maintainers directly before public disclosure.

Include:

- affected module and version
- reproduction steps
- expected impact
- proof-of-concept or logs if available

## Supported Versions

- `4.x` is the actively supported public release line.
- `3.x` receives security fixes on a best-effort basis when fixes can be
  backported without destabilizing the current release line.

## Disclosure

- We will validate the report, assess impact, and coordinate a fix before public disclosure.
- Release notes will identify security-relevant fixes when it is safe to do so.

## Verifying release artifacts

Tagged releases publish the benchmark snapshot (`benchmarks.json`) and a
CycloneDX SBOM (`sbom.cdx.json`) signed with sigstore cosign keyless
signatures. The signing workflow runs on
`InnoSquadCorp/InnoNetwork`'s release job and uses the GitHub OIDC issuer.
To verify a downloaded artifact:

```bash
# Pre-requisites:
brew install cosign

# Replace <version> with the release tag (e.g. 4.0.0).
version="<version>"
artifact="benchmarks.json"   # or sbom.cdx.json

curl -sLO "https://github.com/InnoSquadCorp/InnoNetwork/releases/download/${version}/${artifact}"
curl -sLO "https://github.com/InnoSquadCorp/InnoNetwork/releases/download/${version}/${artifact}.sig"
curl -sLO "https://github.com/InnoSquadCorp/InnoNetwork/releases/download/${version}/${artifact}.crt"

cosign verify-blob \
  --certificate "${artifact}.crt" \
  --signature "${artifact}.sig" \
  --certificate-identity-regexp 'https://github.com/InnoSquadCorp/InnoNetwork/.github/workflows/release.yml@refs/tags/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  "${artifact}"
```

A matching certificate identity confirms the artifact was signed by the
release workflow on the canonical repository at that tag, not a fork or a
re-uploaded copy.

## Supply-chain artifacts

- `sbom.cdx.json` — CycloneDX 1.5 software bill of materials. The package
  core runtime targets have no external library dependencies, while the
  optional `InnoNetworkCodegen` macro product uses SwiftPM's `swift-syntax`
  package at build time. The SBOM records the resolved package graph and build
  inputs for downstream auditors and procurement processes that require a
  structured manifest.
- `benchmarks.json` — frozen output of the release-time benchmark run
  ([Benchmarks/README.md](Benchmarks/README.md)).
