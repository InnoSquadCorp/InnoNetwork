# DecodingInterceptor cookbook

Use ``DecodingInterceptor`` to inspect or rewrite the response payload at the
two boundaries the ``ResponseInterceptor`` chain cannot reach: just before the
decoder runs, and just after it produces a typed value.

## Overview

A ``ResponseInterceptor`` runs against a ``Response`` whose ``Response/data``
is the raw transport body. Once the executor reaches the decode boundary, the
``ResponseInterceptor`` chain has already settled. Anything you need to do
*around the decoder* belongs in a ``DecodingInterceptor``:

- ``DecodingInterceptor/willDecode(data:response:)`` — observe or rewrite the
  bytes the decoder will see.
- ``DecodingInterceptor/didDecode(_:response:)`` — observe or normalize the
  typed value the decoder produced.

Interceptors are applied in declaration order on
``NetworkConfiguration/decodingInterceptors``. The first interceptor in the
array runs first on `willDecode` and first on `didDecode`. Throwing from
either hook aborts the current attempt and routes the error through the
configured ``RetryPolicy`` exactly like a transport failure — pick a
``NetworkError`` category that reflects how the policy should classify the
failure.

## Recipe 1 — Unwrap a JSON envelope in `willDecode`

Some servers wrap every successful response in a `{"data": ...}` envelope.
Rather than declaring an envelope type for every endpoint, strip the wrapper
once at the decode boundary:

```swift
struct EnvelopeUnwrapper: DecodingInterceptor {
    func willDecode(data: Data, response: Response) async throws -> Data {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let inner = object["data"]
        else {
            return data
        }
        return try JSONSerialization.data(withJSONObject: inner)
    }
}

let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com")!
) { builder in
    builder.decodingInterceptors = [EnvelopeUnwrapper()]
}
```

The decoder downstream sees the inner payload and `APIDefinition` types stay
free of envelope plumbing. If the envelope is missing, the interceptor falls
through to the original bytes so non-enveloped error bodies still decode
through the normal error path.

## Recipe 2 — Validate domain invariants in `didDecode`

Some servers return HTTP 200 with a sentinel error code in the body. After the
decoder turns the bytes into a typed value, inspect that value and throw a
``NetworkError`` if it represents a domain failure:

```swift
struct DomainSentinelGuard: DecodingInterceptor {
    func didDecode<APIResponse>(
        _ value: APIResponse,
        response: Response
    ) async throws -> APIResponse where APIResponse: Sendable {
        if let sentinel = value as? DomainErrorCarrying, sentinel.errorCode != 0 {
            throw NetworkError.objectMapping(
                response.data,
                DomainSentinelError(code: sentinel.errorCode)
            )
        }
        return value
    }
}

protocol DomainErrorCarrying { var errorCode: Int { get } }
```

The hook signature requires the returned value to match the input type, so
this is an inspection-or-throw boundary, not a type-changing transform. Use
``NetworkError/objectMapping(_:_:)`` for non-retryable schema-level failures;
use ``NetworkError/statusCode(_:)`` if you want the failure to flow through
the same retry classification a server-side rejection would.

## Recipe 3 — Choosing between session and endpoint placement

``DecodingInterceptor`` only attaches at the session level
(``NetworkConfiguration/decodingInterceptors``). Unlike ``RequestInterceptor``
and ``ResponseInterceptor``, there is no per-``APIDefinition`` decoding slot:
envelope shapes and sentinel conventions are session-wide concerns by nature.

When an endpoint genuinely needs bespoke decode behavior, model it on the
``APIDefinition`` itself rather than reaching for a decoding interceptor —
either by giving the endpoint a different `APIResponse` type that already
expresses the wrapper, or by post-processing the value at the call site.
That keeps the session-level chain reserved for cross-cutting concerns: the
same envelope unwrapping, sentinel validation, or decode-metric recording
that every endpoint should benefit from.

For the request and response interceptor onion (where endpoint slots *do*
exist), see <doc:Interceptors>.
