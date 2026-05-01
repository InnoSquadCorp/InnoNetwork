# Auth: RefreshTokenPolicy + Keychain

Demonstrates how to wire `RefreshTokenPolicy` to a Keychain-backed
token store. Mirrors the pattern most production iOS / macOS apps use:

1. Keychain stores the access token across launches.
2. An `AuthService` actor exposes the closures `RefreshTokenPolicy`
   needs — one to read the current token, one to refresh and persist
   a new one.
3. `RefreshTokenPolicy` owns the single-flight refresh and the
   one-time replay after configured auth status codes (default `401`).
4. `NetworkConfiguration.advanced(baseURL:)` registers the policy on
   the client.

## Why the library does not ship a Keychain layer

InnoNetwork keeps its dependency footprint at zero on purpose. Storage
choices vary across products (Keychain, encrypted files, SwiftData,
custom HSM bridges, server-pinned session tokens), so the library
exposes the orchestration primitive (`RefreshTokenPolicy`) and lets
the application decide where bytes live. This example is a reference
implementation only — production apps should layer access groups,
biometric protection, multi-account scoping, and migration handling
on top of the simple `SecItem` wrapper shown here.

## Files

- `AuthExample.swift` — single-file example with a `KeychainTokenStore`
  actor, an `AuthService` actor, the `RefreshTokenPolicy` wire-up, and
  a `GetProfile` request that exercises the configured client.

## Running

This is documentation-quality code. The hosted endpoint
`https://api.example.com/v1/auth/refresh` is fictional; replace the
base URL and refresh path with your backend before running. The
example compiles against `import InnoNetwork` and `import Security`.
