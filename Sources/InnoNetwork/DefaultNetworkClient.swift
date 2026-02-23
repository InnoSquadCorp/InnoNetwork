import Foundation
import SwiftProtobuf


public protocol NetworkClient: Sendable {
    func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse
    func protobufRequest<T: ProtobufAPIDefinition>(_ request: T) async throws -> T.APIResponse
}

private protocol SingleRequestExecutable: Sendable {
    associatedtype APIResponse: Sendable

    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }

    func asURLRequest(configuration: NetworkConfiguration) throws -> URLRequest
    func decode(data: Data, response: Response) throws -> APIResponse
}

private struct APISingleRequestExecutable<Base: APIDefinition>: SingleRequestExecutable {
    let base: Base

    var logger: NetworkLogger { base.logger }
    var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }

    func asURLRequest(configuration: NetworkConfiguration) throws -> URLRequest {
        try base.asURLRequest(configuration: configuration)
    }

    func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.decode(data: data, response: response)
    }
}

private struct MultipartSingleRequestExecutable<Base: MultipartAPIDefinition>: SingleRequestExecutable {
    let base: Base

    var logger: NetworkLogger { base.logger }
    var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }

    func asURLRequest(configuration: NetworkConfiguration) throws -> URLRequest {
        try base.asURLRequest(configuration: configuration)
    }

    func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.decode(data: data, response: response)
    }
}

private struct ProtobufSingleRequestExecutable<Base: ProtobufAPIDefinition>: SingleRequestExecutable {
    let base: Base

    var logger: NetworkLogger { base.logger }
    var requestInterceptors: [RequestInterceptor] { base.requestInterceptors }
    var responseInterceptors: [ResponseInterceptor] { base.responseInterceptors }

    func asURLRequest(configuration: NetworkConfiguration) throws -> URLRequest {
        try base.asURLRequest(configuration: configuration)
    }

    func decode(data: Data, response: Response) throws -> Base.APIResponse {
        try base.decode(data: data, response: response)
    }
}


public actor DefaultNetworkClient: NetworkClient {
    private let configuration: NetworkConfiguration
    private let session: URLSessionProtocol
    private let eventDispatcher = NetworkEventDispatcher()

    public init(
        configuration: APIConfigure,
        networkConfiguration: NetworkConfiguration? = nil,
        session: URLSessionProtocol = URLSession.shared
    ) throws {
        guard let baseURL = configuration.baseURL else {
            throw NetworkError.invalidBaseURL("\(configuration.host)/\(configuration.basePath)")
        }
        let metricsReporter = networkConfiguration?.metricsReporter
        self.configuration = NetworkConfiguration(
            baseURL: baseURL,
            timeout: networkConfiguration?.timeout ?? 30.0,
            cachePolicy: networkConfiguration?.cachePolicy ?? .useProtocolCachePolicy,
            retryPolicy: networkConfiguration?.retryPolicy,
            networkMonitor: networkConfiguration?.networkMonitor ?? NetworkMonitor.shared,
            metricsReporter: metricsReporter,
            trustPolicy: networkConfiguration?.trustPolicy ?? .systemDefault,
            eventObservers: networkConfiguration?.eventObservers ?? []
        )
        self.session = session
    }

    public func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performTypedRequest(APISingleRequestExecutable(base: request), configuration: configuration)
    }
    
    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performTypedRequest(MultipartSingleRequestExecutable(base: request), configuration: configuration)
    }

    public func protobufRequest<T: ProtobufAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performTypedRequest(ProtobufSingleRequestExecutable(base: request), configuration: configuration)
    }

    /// Generic retry wrapper that handles retry logic for any request type
    private func performRequestWithRetry<Response>(
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        requestID: UUID,
        eventObservers: [any NetworkEventObserving],
        operation: @Sendable (Int, UUID) async throws -> Response
    ) async throws -> Response {
        var retryIndex = 0
        var totalRetries = 0
        var snapshot = await networkMonitor?.currentSnapshot()

        while true {
            do {
                try Task.checkCancellation()
                return try await operation(retryIndex, requestID)
            } catch let error as NetworkError {
                guard let policy = retryPolicy, policy.shouldRetry(error: error, retryIndex: retryIndex) else {
                    throw error
                }
                guard totalRetries < policy.maxTotalRetries else {
                    throw error
                }
                let currentRetryIndex = retryIndex
                let delay = policy.retryDelay(for: currentRetryIndex)
                await notify(
                    .retryScheduled(
                        requestID: requestID,
                        retryIndex: currentRetryIndex,
                        delay: delay,
                        reason: error.localizedDescription
                    ),
                    observers: eventObservers
                )
                totalRetries += 1
                var nextRetryIndex = currentRetryIndex + 1
                if policy.waitsForNetworkChanges, let monitor = networkMonitor {
                    let newSnapshot = await monitor.waitForChange(
                        from: snapshot,
                        timeout: policy.networkChangeTimeout
                    )
                    if policy.shouldResetAttempts(afterNetworkChangeFrom: snapshot, to: newSnapshot) {
                        nextRetryIndex = 0
                    }
                    if let newSnapshot {
                        snapshot = newSnapshot
                    } else {
                        snapshot = await monitor.currentSnapshot() ?? snapshot
                    }
                }
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                retryIndex = nextRetryIndex
            } catch {
                throw toNetworkError(error)
            }
        }
    }

    private func performTypedRequest<D: SingleRequestExecutable>(
        _ apiDefinition: D,
        configuration: NetworkConfiguration
    ) async throws -> D.APIResponse {
        let requestID = UUID()
        return try await performRequestWithRetry(
            retryPolicy: configuration.retryPolicy,
            networkMonitor: configuration.networkMonitor,
            requestID: requestID,
            eventObservers: configuration.eventObservers
        ) { retryIndex, requestID in
            try await performSingleRequest(
                apiDefinition,
                configuration: configuration,
                retryIndex: retryIndex,
                requestID: requestID
            )
        }
    }

    private func performSingleRequest<D: SingleRequestExecutable>(
        _ apiDefinition: D,
        configuration: NetworkConfiguration,
        retryIndex: Int,
        requestID: UUID
    ) async throws -> D.APIResponse {
        try Task.checkCancellation()

        do {
            var urlRequest = try apiDefinition.asURLRequest(configuration: configuration)
            await notifyRequestStart(urlRequest, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            for interceptor in apiDefinition.requestInterceptors {
                urlRequest = try await interceptor.adapt(urlRequest)
            }
            await notifyRequestAdapted(urlRequest, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            apiDefinition.logger.log(request: urlRequest)

            let context = makeRequestContext(configuration: configuration, retryIndex: retryIndex, requestID: requestID)
            let (data, response) = try await session.data(
                for: urlRequest,
                context: context
            )

            try Task.checkCancellation()

            guard let httpURLResponse = response as? HTTPURLResponse else {
                throw NetworkError.nonHTTPResponse(response)
            }
            await notify(
                .responseReceived(
                    requestID: requestID,
                    statusCode: httpURLResponse.statusCode,
                    byteCount: data.count
                ),
                observers: configuration.eventObservers
            )

            var networkResponse = Response(
                statusCode: httpURLResponse.statusCode,
                data: data,
                request: urlRequest,
                response: httpURLResponse
            )

            for interceptor in apiDefinition.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: urlRequest)
            }

            guard (200..<300).contains(httpURLResponse.statusCode) else {
                throw NetworkError.statusCode(networkResponse)
            }

            apiDefinition.logger.log(response: networkResponse, isError: false)
            await notify(
                .requestFinished(
                    requestID: requestID,
                    statusCode: httpURLResponse.statusCode,
                    byteCount: data.count
                ),
                observers: configuration.eventObservers
            )

            return try apiDefinition.decode(data: data, response: networkResponse)
        } catch let error as NetworkError {
            apiDefinition.logger.log(error: error)
            await notifyNetworkFailure(error, requestID: requestID, configuration: configuration)
            throw error
        } catch where NetworkError.isCancellation(error) {
            apiDefinition.logger.log(error: NetworkError.cancelled)
            await notifyNetworkFailure(.cancelled, requestID: requestID, configuration: configuration)
            throw NetworkError.cancelled
        } catch {
            let networkError = toNetworkError(error)
            apiDefinition.logger.log(error: networkError)
            await notifyNetworkFailure(networkError, requestID: requestID, configuration: configuration)
            throw networkError
        }
    }

    private func makeRequestContext(
        configuration: NetworkConfiguration,
        retryIndex: Int,
        requestID: UUID
    ) -> NetworkRequestContext {
        NetworkRequestContext(
            requestID: requestID,
            retryIndex: retryIndex,
            metricsReporter: configuration.metricsReporter,
            trustPolicy: configuration.trustPolicy,
            eventObservers: configuration.eventObservers
        )
    }

    private func notify(_ event: NetworkEvent, observers: [any NetworkEventObserving]) async {
        await eventDispatcher.enqueue(event, observers: observers)
    }

    private func notifyRequestStart(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await notify(
            .requestStart(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            observers: configuration.eventObservers
        )
    }

    private func notifyRequestAdapted(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await notify(
            .requestAdapted(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            observers: configuration.eventObservers
        )
    }

    private func notifyNetworkFailure(
        _ networkError: NetworkError,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        let nsError = networkError as NSError
        await notify(
            .requestFailed(
                requestID: requestID,
                errorCode: nsError.code,
                message: networkError.localizedDescription
            ),
            observers: configuration.eventObservers
        )
    }

    private func toNetworkError(_ error: Error) -> NetworkError {
        if let trustEvaluationError = error as? TrustEvaluationError {
            switch trustEvaluationError {
            case .failed(let reason, _):
                return .trustEvaluationFailed(reason)
            }
        }
        if NetworkError.isCancellation(error) {
            return .cancelled
        }
        return .underlying(SendableUnderlyingError(error), nil)
    }
}


private actor NetworkEventDispatcher {
    private struct EnqueuedEvent: Sendable {
        let event: NetworkEvent
        let observers: [any NetworkEventObserving]
    }

    private var queue: [EnqueuedEvent] = []
    private var isProcessing = false

    func enqueue(_ event: NetworkEvent, observers: [any NetworkEventObserving]) {
        guard !observers.isEmpty else { return }
        queue.append(EnqueuedEvent(event: event, observers: observers))
        guard !isProcessing else { return }
        isProcessing = true

        Task {
            await drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let enqueued = queue.removeFirst()
            for observer in enqueued.observers {
                observer.handle(enqueued.event)
            }
        }
        isProcessing = false
    }
}


extension APIDefinition {
    func asURLRequest(configuration: NetworkConfiguration) throws -> URLRequest {
        var httpBody: Data?
        var targetURL = configuration.baseURL.appendingPathComponent(path)

        if case .get = method {
            let queryItems = parameters?.encodedQueryItems ?? []
            targetURL.append(queryItems: queryItems)
        } else {
            switch contentType {
            case .json:
                httpBody = parameters?.jsonData
            case .formUrlEncoded:
                httpBody = parameters?.formURLEncodedData
            default:
                httpBody = parameters?.jsonData
            }
        }

        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = method.rawValue
        urlRequest.allHTTPHeaderFields = headers.dictionary
        urlRequest.cachePolicy = configuration.cachePolicy
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = httpBody
        return urlRequest
    }

    func decode(data: Data, response: Response) throws -> Self.APIResponse {
        if Self.APIResponse.self == EmptyResponse.self && (data.isEmpty || response.statusCode == 204) {
            return EmptyResponse() as! Self.APIResponse
        }
        
        do {
            return try decoder.decode(Self.APIResponse.self, from: data)
        } catch {
            throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
        }
    }
}


extension MultipartAPIDefinition {
    func asURLRequest(configuration: NetworkConfiguration) throws -> URLRequest {
        let targetURL = configuration.baseURL.appendingPathComponent(path)

        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = method.rawValue
        urlRequest.allHTTPHeaderFields = headers.dictionary
        urlRequest.cachePolicy = configuration.cachePolicy
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = multipartFormData.encode()
        return urlRequest
    }

    func decode(data: Data, response: Response) throws -> Self.APIResponse {
        if Self.APIResponse.self == EmptyResponse.self && (data.isEmpty || response.statusCode == 204) {
            return EmptyResponse() as! Self.APIResponse
        }

        do {
            return try decoder.decode(Self.APIResponse.self, from: data)
        } catch {
            throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
        }
    }
}


extension ProtobufAPIDefinition {
    func asURLRequest(configuration: NetworkConfiguration) throws -> URLRequest {
        var httpBody: Data?
        let targetURL = configuration.baseURL.appendingPathComponent(path)

        if case .get = method {
            // GET requests with protobuf parameters are not supported
            // Protobuf binary data cannot be serialized to URL query parameters
            if parameters != nil {
                throw NetworkError.invalidRequestConfiguration(
                    "GET requests with protobuf parameters are not supported. " +
                    "Protobuf messages cannot be serialized to URL query parameters. " +
                    "Use POST/PUT methods for requests with protobuf body, or set parameters to nil for GET requests."
                )
            }
        } else {
            // Serialize protobuf message to binary data
            if let params = parameters {
                let bytes: [UInt8] = try params.serializedBytes()
                httpBody = Data(bytes)
            }
        }

        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = method.rawValue
        urlRequest.allHTTPHeaderFields = headers.dictionary
        urlRequest.cachePolicy = configuration.cachePolicy
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = httpBody
        return urlRequest
    }

    func decode(data: Data, response: Response) throws -> Self.APIResponse {
        if Self.APIResponse.self == ProtobufEmptyResponse.self && (data.isEmpty || response.statusCode == 204) {
            return ProtobufEmptyResponse() as! Self.APIResponse
        }

        do {
            return try Self.APIResponse(serializedBytes: data)
        } catch {
            throw NetworkError.objectMapping(SendableUnderlyingError(error), response)
        }
    }
}
