# Migrating from Alamofire

Map Alamofire's `RequestAdapter` and `RequestRetrier` onto InnoNetwork's
``RequestInterceptor``, ``RetryPolicy``, and ``RefreshTokenPolicy``
without losing the single-flight refresh guarantee.

## Concept mapping

| Alamofire                                | InnoNetwork                                              |
|------------------------------------------|----------------------------------------------------------|
| `Session(configuration:interceptor:)`    | ``DefaultNetworkClient`` + ``NetworkConfiguration``      |
| `RequestInterceptor.adapt(_:for:_:completion:)` | ``RequestInterceptor/adapt(_:)``                  |
| `RequestInterceptor.retry(_:for:dueTo:completion:)` | ``RetryPolicy`` + ``RefreshTokenPolicy`` (split)  |
| `RequestModifier`                        | per-``APIDefinition`` ``RequestInterceptor``             |
| `EventMonitor`                           | ``NetworkObservability``                                 |
| `Authenticator` / `AuthenticationInterceptor` | ``RefreshTokenPolicy``                              |
| `ResponseSerializer`                     | ``ResponseInterceptor`` + decoder configuration          |
| `RetryResult.retryWithDelay(_:)`         | return value of ``RetryPolicy/shouldRetry(error:retryIndex:request:response:)`` |

The biggest conceptual difference: Alamofire collapses request
adaptation and retry decisions into one protocol (`RequestInterceptor`).
InnoNetwork splits them — adaptation is a pure function on the
request, retry decisions are a pure function on the error. That split
makes both sides easier to test and lets ``RefreshTokenPolicy`` own
the 401 → refresh → replay loop without sharing state with general
retry classification.

## Single-flight refresh: the operational difference

Alamofire's `AuthenticationInterceptor` serializes refresh through
its own internal locking: subsequent 401s queue behind an in-flight
refresh, and once the refresh completes, queued requests replay with
the new credential. The lock lives on the interceptor instance.

InnoNetwork's ``RefreshTokenPolicy`` uses an actor-based
``RefreshTokenCoordinator``: the in-flight refresh is observable as
actor state, and concurrent callers `await` the same task instead of
queueing through a lock. The behavioural contract is the same —
exactly one refresh runs for any burst of 401s — but the implementation
is async-native, which matters when the closures that perform the
refresh themselves do `await` work (Keychain I/O, attestation calls).

Practical consequence: `RefreshTokenPolicy` does not need a custom
serial queue or a wrapping `OperationQueue`. Instantiate it with the
two closures and pass it to ``NetworkConfiguration``:

```swift
let refresh = RefreshTokenPolicy(
    currentToken: { try await tokenStore.currentAccessToken() },
    refreshToken: { try await authService.refreshAccessToken() }
)

let configuration = NetworkConfiguration.advanced(baseURL: apiBaseURL) { builder in
    builder.refreshTokenPolicy = refresh
}
let client = DefaultNetworkClient(configuration: configuration)
```

## Side-by-side: 401 → refresh → retry

### Alamofire

```swift
final class TokenAuthenticator: Authenticator {
    func apply(_ credential: Credential, to urlRequest: inout URLRequest) {
        urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    }

    func refresh(_ credential: Credential, for session: Session,
                 completion: @escaping (Result<Credential, Error>) -> Void) {
        authService.refresh(credential.refreshToken) { result in completion(result) }
    }

    func didRequest(_ urlRequest: URLRequest, with response: HTTPURLResponse,
                    failDueToAuthenticationError error: Error) -> Bool {
        response.statusCode == 401
    }

    func isRequest(_ urlRequest: URLRequest, authenticatedWith credential: Credential) -> Bool {
        urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential.accessToken)"
    }
}

let interceptor = AuthenticationInterceptor(
    authenticator: TokenAuthenticator(),
    credential: initialCredential
)
let session = Session(interceptor: interceptor)
```

### InnoNetwork

```swift
let refresh = RefreshTokenPolicy(
    currentToken: { try await tokenStore.currentAccessToken() },
    refreshToken: { try await authService.refreshAccessToken() }
)

let client = DefaultNetworkClient(
    configuration: .advanced(baseURL: apiBaseURL) { builder in
        builder.refreshTokenPolicy = refresh
    }
)
```

The InnoNetwork version is shorter because the four-method
`Authenticator` API collapses into two closures. There is no
`isRequest(_:authenticatedWith:)` equivalent — the executor's
canonical authorization application path means there is exactly one
place the access token is written, and the refresh policy replaces
it directly on replay.

## Side-by-side: per-request adapter

### Alamofire

```swift
struct RequestIDAdapter: RequestAdapter {
    func adapt(_ urlRequest: URLRequest, for session: Session,
               completion: @escaping (Result<URLRequest, Error>) -> Void) {
        var request = urlRequest
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        completion(.success(request))
    }
}
```

### InnoNetwork

```swift
struct RequestIDInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }
}
```

Throw to abort; `async`/`throws` replaces Alamofire's completion-handler
result. Attach to a session via
``NetworkConfiguration/requestInterceptors`` or to a single endpoint
via ``APIDefinition/requestInterceptors`` — see <doc:Interceptors> for
the onion order.

## Retry classification: how it differs

Alamofire returns a `RetryResult` from a single `retry` callback that
sees both the error and the request. InnoNetwork's ``RetryPolicy``
sees the same surface but is shaped as a pure decision function:

```swift
public protocol RetryPolicy: Sendable {
    func shouldRetry(
        error: NetworkError,
        retryIndex: Int,
        request: URLRequest,
        response: HTTPURLResponse?
    ) async -> RetryDecision
}
```

`NetworkError`'s built-in classification (transport vs. status code vs.
decode failure vs. underlying URLError) lets policies pattern-match on
the failure category instead of inspecting the raw error type. See
<doc:RetryDecisions> for the canonical classification tree and
<doc:ErrorClassification> for the underlying error model.

## Migration order

A typical migration takes four passes:

1. Replace `Session` with ``DefaultNetworkClient`` and a
   ``NetworkConfiguration``.
2. Convert `RequestAdapter` adopters to ``RequestInterceptor``,
   moving session-wide ones onto the configuration and per-request
   ones onto the relevant ``APIDefinition``.
3. Replace `AuthenticationInterceptor` with ``RefreshTokenPolicy``,
   then delete the credential-storage and 401-detection scaffolding —
   the policy owns both.
4. Replace `RequestRetrier` adopters with a custom ``RetryPolicy``,
   or with ``ExponentialBackoffRetryPolicy`` if the existing logic
   collapses to "retry transient transport failures with backoff".

Convert one feature at a time. The two libraries can coexist in the
same process; use feature-scoped network clients so the migration
front advances feature-by-feature without a big-bang switch.
