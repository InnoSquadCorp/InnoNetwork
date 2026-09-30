import Foundation
import os

/// Payload-free, machine-readable failures from a custom binary codec.
public enum EncodedPayloadFailure: Int, Error, Sendable, CustomNSError {
    /// The request encoder rejected its input.
    case encoding = 1
    /// Encoded request bytes exceeded the caller's transmission budget.
    case requestBodyLimit = 2
    /// A byte or nesting limit is invalid.
    case invalidLimit = 3
    /// Response media type or its parameters do not match the codec.
    case mediaType = 4
    /// A no-content response contained data or used an unexpected status.
    case unexpectedContent = 5
    /// The response codec rejected the binary representation.
    case decoding = 6
    /// A collected response exceeded the codec's byte budget.
    case responseBodyLimit = 7

    public static var errorDomain: String { "InnoNetwork.EncodedPayload" }
    public var errorCode: Int { rawValue }
    public var errorUserInfo: [String: Any] { [:] }
}

/// Payload-free measurements from a codec invocation, not a physical HTTP attempt.
public struct EncodedCodecMeasurement: Sendable {
    public enum Stage: Sendable {
        case encoding
        case decoding
    }
    public let stage: Stage
    /// Nil if encoding failed before producing bytes.
    public let byteCount: Int?
    public let duration: Duration
    public let succeeded: Bool
}

/// Value-semantic HTTP policy inputs. An EncodedRequest stores an immutable snapshot.
public struct EncodedRequestOptions: Sendable {
    public var headers: HTTPHeaders
    public var queryItems: [URLQueryItem]
    public let logger: any NetworkLogger
    public let requestInterceptors: [any RequestInterceptor]
    public let requestSigners: [any RequestSigner]
    public let responseInterceptors: [any ResponseInterceptor]
    public let acceptableStatusCodes: Set<Int>?
    public let timeout: TimeInterval?
    public let cachePolicy: URLRequest.CachePolicy?
    public let priority: RequestPriority?
    public let allowsCellularAccess: Bool?
    public let allowsExpensiveNetworkAccess: Bool?
    public let allowsConstrainedNetworkAccess: Bool?
    /// Tightens, never raises, the client response limit. Collection is streaming when set.
    public var maximumResponseBytes: Int64?
    /// Synchronous, payload-free callback; keep it short. No callback on replayed encoding.
    public let codecObserver: (@Sendable (EncodedCodecMeasurement) -> Void)?

    public init(
        headers: HTTPHeaders = .default,
        queryItems: [URLQueryItem] = [],
        logger: any NetworkLogger = DefaultNetworkLogger(),
        requestInterceptors: [any RequestInterceptor] = [],
        requestSigners: [any RequestSigner] = [],
        responseInterceptors: [any ResponseInterceptor] = [],
        acceptableStatusCodes: Set<Int>? = nil,
        timeout: TimeInterval? = nil,
        cachePolicy: URLRequest.CachePolicy? = nil,
        priority: RequestPriority? = nil,
        allowsCellularAccess: Bool? = nil,
        allowsExpensiveNetworkAccess: Bool? = nil,
        allowsConstrainedNetworkAccess: Bool? = nil,
        maximumResponseBytes: Int64? = nil,
        codecObserver: (@Sendable (EncodedCodecMeasurement) -> Void)? = nil
    ) {
        self.headers = headers
        self.queryItems = queryItems
        self.logger = logger
        self.requestInterceptors = requestInterceptors
        self.requestSigners = requestSigners
        self.responseInterceptors = responseInterceptors
        self.acceptableStatusCodes = acceptableStatusCodes
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.priority = priority
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.maximumResponseBytes = maximumResponseBytes
        self.codecObserver = codecObserver
    }
}

/// A deferred, buffered HTTP body. Capture immutable Sendable input in the encoder.
/// Encoding occurs once per client invocation, after URL/auth preflight. Retries reuse
/// those bytes. The byte budget rejects before transport, not before allocation.
public struct EncodedRequestBody: Sendable {
    public let contentType: String
    public let maximumBytes: Int?
    let encode: @Sendable () throws -> Data

    public init(
        contentType: String,
        maximumBytes: Int? = nil,
        encode: @escaping @Sendable () throws -> Data
    ) {
        self.contentType = contentType
        self.maximumBytes = maximumBytes
        self.encode = encode
    }
}

/// Stable buffered-codec boundary; unlike APIDefinition, Output need not be Decodable.
/// A nil body and a body that encodes to zero bytes have distinct HTTP semantics.
public struct EncodedRequest<Output: Sendable>: Sendable {
    public let method: HTTPMethod
    public let path: String
    public let sessionAuthentication: SessionAuthentication
    public let body: EncodedRequestBody?
    public let options: EncodedRequestOptions
    public let responseDecoder: AnyResponseDecoder<Output>

    public init(
        method: HTTPMethod,
        path: String,
        auth: SessionAuthentication,
        body: EncodedRequestBody? = nil,
        options: EncodedRequestOptions = .init(),
        responseDecoder: AnyResponseDecoder<Output>
    ) {
        self.method = method
        self.path = path
        self.sessionAuthentication = auth
        self.body = body
        self.options = options
        self.responseDecoder = responseDecoder
    }
}

/// Binary-only clients and test doubles need not implement the Codable client API.
public protocol EncodedRequestClient: Sendable {
    func request<Output: Sendable>(
        _ request: EncodedRequest<Output>, tag: CancellationTag?
    ) async throws(NetworkError) -> Output
}

public extension EncodedRequestClient {
    func request<Output: Sendable>(_ request: EncodedRequest<Output>) async throws(NetworkError) -> Output {
        try await self.request(request, tag: nil)
    }
}

public extension AnyResponseDecoder where Output == EmptyResponse {
    /// No-content is an HTTP contract, not a serialization format's empty message.
    static func noContent(statusCodes: Set<Int> = [204, 205]) -> Self {
        Self { data, response in
            guard statusCodes.contains(response.statusCode), data.isEmpty else {
                throw NetworkError.decoding(
                    stage: .responseBody,
                    underlying: SendableUnderlyingError(EncodedPayloadFailure.unexpectedContent),
                    response: response
                )
            }
            return EmptyResponse()
        }
    }
}

protocol EncodedExecutableMetadata {
    var queryItems: [URLQueryItem] { get }
    var maximumResponseBytes: Int64? { get }
}

struct EncodedRequestExecutable<Output: Sendable>: SingleRequestExecutable, EncodedExecutableMetadata {
    let base: EncodedRequest<Output>
    // Created per invocation, never shared by separate calls using the same request value.
    private let payload = OSAllocatedUnfairLock<Result<Data, any Error>?>(initialState: nil)
    init(_ base: EncodedRequest<Output>) { self.base = base }
    var method: HTTPMethod { base.method }
    var path: String { base.path }
    var sessionAuthentication: SessionAuthentication { base.sessionAuthentication }
    var bodyContentType: String? { base.body?.contentType }
    var headers: HTTPHeaders { base.options.headers }
    var queryItems: [URLQueryItem] { base.options.queryItems }
    var maximumResponseBytes: Int64? { base.options.maximumResponseBytes }
    var logger: any NetworkLogger { base.options.logger }
    var requestInterceptors: [any RequestInterceptor] { base.options.requestInterceptors }
    var requestSigners: [any RequestSigner] { base.options.requestSigners }
    var responseInterceptors: [any ResponseInterceptor] { base.options.responseInterceptors }
    var acceptableStatusCodes: Set<Int>? { base.options.acceptableStatusCodes }
    var timeoutOverride: TimeInterval? { base.options.timeout }
    var cachePolicyOverride: URLRequest.CachePolicy? { base.options.cachePolicy }
    var priorityOverride: RequestPriority? { base.options.priority }
    var allowsCellularAccessOverride: Bool? { base.options.allowsCellularAccess }
    var allowsExpensiveNetworkAccessOverride: Bool? { base.options.allowsExpensiveNetworkAccess }
    var allowsConstrainedNetworkAccessOverride: Bool? { base.options.allowsConstrainedNetworkAccess }

    func makePayload() throws -> RequestPayload {
        try Task.checkCancellation()
        if let limit = maximumResponseBytes, limit < 0 {
            throw NetworkError.configuration(reason: .invalidPayload(.invalidLimit))
        }
        guard let body = base.body else { return .none }
        guard !method.forbidsRequestBody else {
            throw NetworkError.configuration(reason: .invalidRequest("This HTTP method forbids a body."))
        }
        if let limit = body.maximumBytes, limit < 0 {
            throw NetworkError.configuration(reason: .invalidPayload(.invalidLimit))
        }
        let (result, measurement) = payload.withLock { cached -> (Result<Data, any Error>, EncodedCodecMeasurement?) in
            if let cached { return (cached, nil) }
            let started = ContinuousClock.now
            var byteCount: Int?
            var succeeded = false
            let result = Result<Data, any Error> {
                let data: Data
                do {
                    data = try body.encode()
                    byteCount = data.count
                } catch is CancellationError {
                    throw NetworkError.cancelled
                } catch let failure as EncodedPayloadFailure {
                    throw NetworkError.configuration(reason: .invalidPayload(failure))
                } catch {
                    // Never retry arbitrary encoder errors as transport failures or disclose input.
                    throw NetworkError.configuration(reason: .invalidPayload(.encoding))
                }
                try Task.checkCancellation()
                if let limit = body.maximumBytes, data.count > limit {
                    throw NetworkError.configuration(reason: .invalidPayload(.requestBodyLimit))
                }
                succeeded = true
                return data
            }
            // Even a custom retry policy cannot re-run a failed encoder in
            // this invocation. The memoized result contains sanitized errors.
            cached = result
            return (
                result,
                .init(
                    stage: .encoding, byteCount: byteCount,
                    duration: started.duration(to: .now), succeeded: succeeded)
            )
        }
        // User callbacks run outside the memoization lock, including on failure.
        if let measurement { base.options.codecObserver?(measurement) }
        return .data(try result.get())
    }

    func decode(data: Data, response: Response) throws -> Output {
        let started = ContinuousClock.now
        var succeeded = false
        defer {
            base.options.codecObserver?(
                .init(
                    stage: .decoding, byteCount: data.count,
                    duration: started.duration(to: .now), succeeded: succeeded))
        }
        do {
            let result = try base.responseDecoder.decode(data: data, response: response)
            try Task.checkCancellation()
            succeeded = true
            return result
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.decoding(
                stage: .responseBody, underlying: SendableUnderlyingError(error), response: response)
        }
    }
}
