# Macro Adopter Smoke

This independent Swift package exercises the macro-first path through the
same public products available to an application and its test target. It does
not use `@testable import`, package access, or implementation-only hooks.

The executable declares explicit endpoint structs with `@APIDefinition`, then
sends them through `DefaultNetworkClient` backed by the public
`InnoNetworkTestSupport` session. Its runtime assertions cover:

- path placeholder and GET query encoding;
- POST JSON body inference and response decoding;
- explicit anonymous and required authentication policies;
- protocol-composed endpoint metadata matching production catalog usage;
- bearer-token application before the required-auth transport attempt;
- 6.0-compatible conditional helpers and actual configuration-specific headers;
- an unconditional manual payload pair forwarding a conditional body;
- unchanged legacy conditional-payload omission, now explicitly warned (a
  compatibility fixture, not recommended endpoint design);
- the generic operation-client migration using `where Base: NetworkClient`.

Run it from the repository root:

```bash
xcrun swift run --package-path Examples/MacroAdopterSmoke
xcrun swift run -c release --package-path Examples/MacroAdopterSmoke
```

CI, release validation, and local preflight execute the Debug command in addition
to compiling every independent example package. The Release command additionally
checks the non-DEBUG conditional branch during compatibility validation.
