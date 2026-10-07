# Operation lifetime, auth and retry

Use `OperationNetworkClient(client:)` when the caller needs a handle before
completion, bounded lifecycle events, cancellation, or an end-to-end deadline.
`start(...)` supports both JSON and encoded endpoints in 6.1. Await
`operation.value()`, which throws the value-only `NetworkFailure`; direct
client `request(...)` instead throws `NetworkError`.

`OperationNetworkClient<Base>` now requires only `Base: Sendable`. JSON
forwarding extensions/functions must explicitly constrain `Base: NetworkClient`;
binary-only wrappers use `Base: EncodedRequestClient`. Do not impose Codable on
an encoded output just to satisfy an outdated generic wrapper.

- `operation.cancel()` cancels the operation. Cancelling a task currently
  awaiting `value()` forwards cancellation too. Merely dropping the handle is
  not the explicit lifecycle contract.
- `NetworkOperationDeadline(after:)` is one monotonic budget across preparation,
  auth, cache, admission, retries, transport and decoding. Nonpositive duration
  expires immediately. This differs from a per-attempt URLSession timeout.
- Use `NetworkFailure.kind`, `code`, `recovery`, and `deadlineStage`. Its recovery
  value is advice for bounded application policy, not permission for an endless
  retry loop or automatic reauthentication replay.
- `client.cancelAll(matching:)` scopes cancellation by tag. `shutdown()` ends
  that client permanently; later requests fail with cancellation. Injected real
  URLSessions remain caller-owned. Keep client/operation ownership explicit.

## Authentication and replay

Every endpoint declares `.anonymous`, `.optional`, or `.required`.
Required auth must be configured through the intended auth/refresh policy;
do not repair auth failures by weakening the endpoint or hardcoding tokens.
Use exact-version auth documentation when configuring realm and refresh scope.

The built-in retry policy defaults to GET/HEAD/OPTIONS/TRACE. Other methods
need the supported idempotency-key contract. Keep both attempt and total retry
budgets finite. A stable application-owned key across **manual operation
restarts** is distinct from a key generated for one operation; declaring
`.stableIdempotencyKey` only changes recovery advice and does not manufacture
that key or override the retry engine.

Do not log authorization/cookies, full URLs containing identifiers, bodies,
tokens, or arbitrary underlying errors. Use the released redacted event and
error surfaces. External auth, live TLS/pinning, streaming reconnection and
device background lifecycles need separate integration tests.

Sources:
[operation adapter](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetwork/V6/OperationNetworkClient.swift),
[operation handle](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetwork/V6/NetworkOperation.swift),
[failure/replay policy](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetwork/V6/NetworkFailure.swift),
[auth guide](https://github.com/InnoSquadCorp/InnoNetwork/blob/79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16/Sources/InnoNetwork/InnoNetwork.docc/Articles/AuthRefresh.md).
