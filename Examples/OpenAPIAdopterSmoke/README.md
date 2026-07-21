# OpenAPI Adopter Smoke

This independent Swift package verifies that an application can consume the
public `InnoNetwork`, `InnoNetworkOpenAPI`, and `InnoNetworkTestSupport`
products without package-only access.

The executable adapts an `OpenAPIRestOperation` through `OpenAPIRequest`, runs
it through `DefaultNetworkClient`, and validates query encoding and response
decoding at the public consumer boundary.

Run it from the repository root:

```bash
xcrun swift run --package-path Examples/OpenAPIAdopterSmoke
```
