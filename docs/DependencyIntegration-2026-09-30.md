# Dependency PR integration into #133

The user requested integration of all other open InnoNetwork PRs into #133,
explicitly excluding #132. The source set was re-read on 2026-09-30; `main`
remained `9d8053d5f921ebf5c38cc2f816efe90c7db4a450`, and #133's prior head was
`c2e8b2562565bdeb07fe2c1967ae8f5bf4c9c189`. None of the source PRs are closed
or merged by this integration. #132 and its companion remain untouched.

## Exact source PRs

| PR | Verified source head | Integrated change |
| --- | --- | --- |
| [#116](https://github.com/InnoSquadCorp/InnoNetwork/pull/116) | `97dba15681330ed9f5556328eaf404b9853a6d19` | Swift Crypto 4.5.0 → 4.5.1, revision `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6` |
| [#75](https://github.com/InnoSquadCorp/InnoNetwork/pull/75) | `2550326d2c1d74eb352d39da474e1cf74c3c97b7` | actions/cache 6.1.0 at `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` |
| [#74](https://github.com/InnoSquadCorp/InnoNetwork/pull/74) | `cb49288bebc2e0110e259f164d093e63fbfef89e` | softprops/action-gh-release 3.0.2 at `3d0d9888cb7fd7b750713d6e236d1fcb99157228` |
| [#73](https://github.com/InnoSquadCorp/InnoNetwork/pull/73) | `f4f359fe3b963b9d99e9cc76447dbc8314ffac53` | actions/checkout 7.0.1 at `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| [#71](https://github.com/InnoSquadCorp/InnoNetwork/pull/71) | `aaae19925589b317e5359aa26899f6e469c6b3a1` | codecov/codecov-action 7.0.0 at `fb8b3582c8e4def4969c97caa2f19720cb33a72f` |
| [#70](https://github.com/InnoSquadCorp/InnoNetwork/pull/70) | `a22e8572e4d2d5c08fb8bda2e17e61e1d427a0df` | github/codeql-action 4.36.2 at `8aad20d150bbac5944a9f9d289da16a4b0d87c1e` |

The source PR bases predate the automation restructuring. Their intended updates
were mapped onto the current files rather than merging stale workflow bodies.
The same action SHA now applies across CI, release candidate, trusted publishers,
scheduled workflows and the consumer-cache composite. An offline gate rejects
mutable action refs, mixed versions of the same action repository and an unsafe
checkout opt-in. The consumer-cache contract still requires the canonical
`actions/cache` source and immutable SHA, without freezing one version forever.
Its lane/toolchain/dependency isolation and mandatory test execution are unchanged.

The official pinned action metadata was inspected: checkout/cache/release/CodeQL
use Node 24; Codecov remains a composite action and retains the existing `binary`,
`use_oidc`, `files`, `flags`, `disable_search` and `fail_ci_if_error` inputs. No
new token, permission or unsafe PR checkout opt-in was added.

## Dependency and API boundaries

Swift Crypto is the only runtime dependency change. Network implementation and
API files, Package.swift, all platform floors, the default Macros trait,
SwiftSyntax 603.0.2, the codecov CLI integrity pin and the 20% performance guard
remain unchanged. Swift Crypto 4.5.1's checked-out manifest declares tools 6.1;
Network still declares tools 6.2, so no minimum is raised for this integration.

Using Swift 6.3.3 in the Linux VM, normal resolution and a second
`--force-resolved-versions` resolution both succeeded. The complete #116 lockfile,
including its origin hash, stayed byte-identical during the frozen resolve:
SHA-256 `514d6b18a4fa285cec5187e878bf42330f4ab45454ec8ce3db1e799f75b43235`.
Only Swift Crypto's version/revision and the resolver origin hash differ from the
previous lock. All other pins remain unchanged. Manifest evaluation confirms the
same nine library products, Macros default trait and five Apple deployment floors.
The existing trusted dependency-transition verifier also accepts this transition.

## Validation boundary

- Python automation/negative-control tests: 65 passed
- Ruby consumer CI tests: 10 tests / 41 assertions passed
- Immutable and coherent action pins: passed
- Existing required-check, platform and release workflow contracts: retained
- actionlint: passed except the existing custom `xcode-27` label catalog warning
- Runtime source, public API and Package.swift diff: empty

Linux resolution and policy tests are not Apple runtime validation. The old #133
run for `c2e8b256...` is superseded once this integrated head is uploaded; its
successful Xcode 27.0 and DocC jobs do not establish this updated head's result.
All 32 concrete CI jobs, including major action and runtime dependency behavior,
need fresh exact-head hosted evidence. Tag/release publication, repository
activation and closing source PRs remain separate actions.
