# GeneratedClientRecipe

Compile-only sample package that shows two generator-friendly integration paths
onto `InnoNetwork`.

This sample includes future-candidate wrapper shapes. The `APIDefinition` path
matches the 4.0.0 stable public contract; the low-level execution path does
not.

## What it demonstrates

- generated REST-style contracts adapted onto `APIDefinition`
- generator-owned request contracts adapted onto future-candidate execution hooks
- `any NetworkClient` injection for stable request paths
- stored `HTTPMethod` properties inside `Sendable` generated models

## Why it exists

Generated SDKs do not always want to expose `APIDefinition` directly. Some fit
the default request model cleanly, while others need generator-specific payload
encoding or response decoding. This example keeps those boundaries explicit
without tying the repository to a particular OpenAPI tool.

The sample bootstrap still uses `safeDefaults` so the generated layer inherits
the same recommended configuration entry point as handwritten clients.

## How to use it

Build the package:

```bash
xcrun swift build
```

Then mirror the pattern that matches your generated surface:

1. Map simple generated operations onto `APIDefinition`.
2. Inject `any NetworkClient` into the wrapper layer instead of depending
   directly on `DefaultNetworkClient`.
3. Treat richer generator-owned execution hooks as roadmap material until they
   are explicitly promoted.
