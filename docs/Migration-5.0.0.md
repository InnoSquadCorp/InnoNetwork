# InnoNetwork 5.0 Migration Notes

The endpoint vocabulary and `NetworkError` ledger originally planned for 5.0
landed in `4.0.0` as a breaking API reset. This guide now tracks the remaining
5.0 work and the 4.0 migration steps consumers must complete before adopting
future minors.

## Already Required in 4.0.0

| Previous usage | Current API |
| --- | --- |
| `EndpointShape` | `Endpoint` |
| `EndpointAuthScope` | `AuthScope` |
| `ScopedEndpoint<Response, Scope>` | `EndpointBuilder<Response, Scope>` |
| `Endpoint<Response>` | `EndpointBuilder<Response, PublicAuthScope>` |
| `AuthenticatedEndpoint<Response>` | `EndpointBuilder<Response, AuthRequiredScope>` |
| `NetworkError.invalidBaseURL(_:)` | `NetworkError.configuration(reason: .invalidBaseURL(...))` |
| `NetworkError.invalidRequestConfiguration(_:)` | `NetworkError.configuration(reason: .invalidRequest(...))` |

There is no 4.x compatibility alias for the removed names above. Code that
still references them must be updated before it can compile against `4.0.0`.

## Still Planned for 5.0

- `NetworkConfiguration` pack-shaped entry points may become first-class
  convenience parameters. The existing `AdvancedBuilder` path remains the
  source-compatible baseline.
- Code generation may add richer auth mapping and schema coverage, building on
  the current `Tools/openapi-to-innonetwork` preview.
- New `NetworkError` cases may appear for additional failure modes. Keep
  `@unknown default` in exhaustive switches because `NetworkError` is not
  `@frozen`.

## Pre-flight Checklist

- [ ] Replace old endpoint names with `Endpoint`, `AuthScope`, and
  `EndpointBuilder`.
- [ ] Replace top-level configuration error cases with
  `NetworkError.configuration(reason:)`.
- [ ] For auth-required fluent calls, use
  `EndpointBuilder<EmptyResponse, AuthRequiredScope>` and configure
  `NetworkConfiguration.refreshTokenPolicy`.
- [ ] Build stable examples or app integration targets against `4.0.0` before
  taking later minors.

## See Also

- [API_STABILITY.md](../API_STABILITY.md) for the symbol-level 4.x contract.
- [Migration-4.0.0.md](Migration-4.0.0.md) for the full 4.0 breaking-change
  checklist.
- [MIGRATION_POLICY.md](MIGRATION_POLICY.md) for the project's general
  migration philosophy.
