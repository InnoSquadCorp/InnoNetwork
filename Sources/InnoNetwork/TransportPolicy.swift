import Foundation

/// Describes how an endpoint encodes its request and decodes its response.
///
/// `TransportPolicy` is the single transport-shape entry point on
/// ``APIDefinition`` and ``MultipartAPIDefinition``. Most endpoints stick to
/// one of the public factories — ``json(encoder:decoder:)``,
/// ``query(encoder:rootKey:decoder:)``, ``formURLEncoded(encoder:rootKey:decoder:)``,
/// ``multipart(decoder:)``, or ``custom(encoding:decode:)`` — and never touch
/// the underlying ``RequestEncodingPolicy`` / ``ResponseDecodingStrategy``
/// values directly.
///
/// When `Output` conforms to ``HTTPEmptyResponseDecodable`` the standard
/// factories automatically choose the empty-tolerant decoder, so endpoints
/// declared as `TransportPolicy<EmptyResponse>` (or any other empty-decodable
/// response) handle HTTP 204 / zero-byte bodies without extra plumbing.
public struct TransportPolicy<Output: Sendable>: Sendable {
    public let requestEncoding: RequestEncodingPolicy
    public let responseDecoding: ResponseDecodingStrategy<Output>
    public let responseDecoder: AnyResponseDecoder<Output>

    public init(
        requestEncoding: RequestEncodingPolicy,
        responseDecoding: ResponseDecodingStrategy<Output>,
        responseDecoder: AnyResponseDecoder<Output>
    ) {
        self.requestEncoding = requestEncoding
        self.responseDecoding = responseDecoding
        self.responseDecoder = responseDecoder
    }
}

// MARK: - Standard JSON-decoded factories

public extension TransportPolicy where Output: Decodable {
    /// JSON request body, JSON response body. The default for body-bearing
    /// endpoints (`POST`, `PUT`, `PATCH`).
    static func json(
        encoder: JSONEncoder = defaultRequestEncoder,
        decoder: JSONDecoder = defaultResponseDecoder
    ) -> Self {
        let strategy = emptyAwareStrategy(decoder)
        return Self(
            requestEncoding: .json(encoder),
            responseDecoding: strategy,
            responseDecoder: AnyResponseDecoder(strategy: strategy)
        )
    }

    /// Query-string request encoding, JSON response body. The default for
    /// `GET` endpoints.
    static func query(
        encoder: URLQueryEncoder = URLQueryEncoder(),
        rootKey: String? = nil,
        decoder: JSONDecoder = defaultResponseDecoder
    ) -> Self {
        let strategy = emptyAwareStrategy(decoder)
        return Self(
            requestEncoding: .query(encoder, rootKey: rootKey),
            responseDecoding: strategy,
            responseDecoder: AnyResponseDecoder(strategy: strategy)
        )
    }

    /// `application/x-www-form-urlencoded` request body, JSON response body.
    static func formURLEncoded(
        encoder: URLQueryEncoder = URLQueryEncoder(),
        rootKey: String? = nil,
        decoder: JSONDecoder = defaultResponseDecoder
    ) -> Self {
        let strategy = emptyAwareStrategy(decoder)
        return Self(
            requestEncoding: .formURLEncoded(encoder, rootKey: rootKey),
            responseDecoding: strategy,
            responseDecoder: AnyResponseDecoder(strategy: strategy)
        )
    }

    /// Used by ``MultipartAPIDefinition`` endpoints. The multipart body is
    /// encoded by the multipart pipeline; this factory only configures the
    /// JSON response decoder.
    static func multipart(
        decoder: JSONDecoder = defaultResponseDecoder
    ) -> Self {
        let strategy = emptyAwareStrategy(decoder)
        return Self(
            requestEncoding: .none,
            responseDecoding: strategy,
            responseDecoder: AnyResponseDecoder(strategy: strategy)
        )
    }

    /// Fully custom transport: caller supplies the request encoding policy
    /// and a decode closure that receives the raw response data and the
    /// wrapping ``Response`` for header/status inspection.
    static func custom(
        encoding: RequestEncodingPolicy,
        decode: @Sendable @escaping (Data, Response) throws -> Output
    ) -> Self {
        Self(
            requestEncoding: encoding,
            responseDecoding: .custom(decode),
            responseDecoder: AnyResponseDecoder(decode)
        )
    }

    /// Picks the empty-tolerant decoding strategy automatically when `Output`
    /// conforms to ``HTTPEmptyResponseDecodable``; otherwise falls back to a
    /// plain JSON strategy.
    private static func emptyAwareStrategy(_ decoder: JSONDecoder) -> ResponseDecodingStrategy<Output> {
        if Output.self is any HTTPEmptyResponseDecodable.Type {
            return .jsonAllowingEmpty(decoder)
        }
        return .json(decoder)
    }
}

// MARK: - Empty-response intent alias

public extension TransportPolicy where Output: Decodable & HTTPEmptyResponseDecodable {
    /// Explicit alias of ``json(encoder:decoder:)`` for callers who want the
    /// empty-tolerant intent to appear at the call site. Behaves identically
    /// because the standard `.json` factory already chooses the empty-tolerant
    /// decoder when `Output` conforms to ``HTTPEmptyResponseDecodable``.
    static func jsonAllowingEmpty(
        encoder: JSONEncoder = defaultRequestEncoder,
        decoder: JSONDecoder = defaultResponseDecoder
    ) -> Self {
        .json(encoder: encoder, decoder: decoder)
    }
}
