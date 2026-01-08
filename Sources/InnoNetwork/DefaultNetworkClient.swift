import Foundation
import SwiftProtobuf


public protocol NetworkClient: Sendable {
    func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse
    func protobufRequest<T: ProtobufAPIDefinition>(_ request: T) async throws -> T.APIResponse
}


public actor DefaultNetworkClient: NetworkClient {
    private let configuration: NetworkConfiguration
    private let session: URLSessionProtocol

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
            metricsReporter: metricsReporter
        )
        if let metricsReporter, let urlSession = session as? URLSession {
            self.session = MetricsURLSession(
                configuration: urlSession.configuration,
                reporter: metricsReporter
            )
        } else {
            self.session = session
        }
    }

    public func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performRequest(request, configuration: configuration)
    }
    
    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performMultipartRequest(request, configuration: configuration)
    }

    public func protobufRequest<T: ProtobufAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performProtobufRequest(request, configuration: configuration)
    }

    /// Generic retry wrapper that handles retry logic for any request type
    private func performRequestWithRetry<Response>(
        retryPolicy: RetryPolicy?,
        networkMonitor: (any NetworkMonitoring)?,
        operation: @Sendable (Int) async throws -> Response
    ) async throws -> Response {
        var attempt = 0
        var snapshot = await networkMonitor?.currentSnapshot()

        while true {
            do {
                try Task.checkCancellation()
                return try await operation(attempt)
            } catch let error as NetworkError {
                guard let policy = retryPolicy, policy.shouldRetry(error: error, attempt: attempt) else {
                    throw error
                }
                var nextAttempt = attempt + 1
                if policy.waitsForNetworkChanges, let monitor = networkMonitor {
                    let newSnapshot = await monitor.waitForChange(
                        from: snapshot,
                        timeout: policy.networkChangeTimeout
                    )
                    if policy.shouldResetAttempts(afterNetworkChangeFrom: snapshot, to: newSnapshot) {
                        nextAttempt = 0
                    }
                    snapshot = newSnapshot ?? snapshot
                }
                attempt = nextAttempt
                let delay = policy.retryDelay(for: attempt)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                throw error
            }
        }
    }

    private func performRequest<T: APIDefinition>(_ apiDefinition: T, configuration: NetworkConfiguration) async throws -> T.APIResponse {
        try await performRequestWithRetry(
            retryPolicy: configuration.retryPolicy,
            networkMonitor: configuration.networkMonitor
        ) { attempt in
            try await performSingleRequest(apiDefinition, configuration: configuration, attempt: attempt)
        }
    }

    private func performMultipartRequest<T: MultipartAPIDefinition>(_ apiDefinition: T, configuration: NetworkConfiguration) async throws -> T.APIResponse {
        try await performRequestWithRetry(
            retryPolicy: configuration.retryPolicy,
            networkMonitor: configuration.networkMonitor
        ) { attempt in
            try await performSingleRequest(apiDefinition, configuration: configuration, attempt: attempt)
        }
    }

    private func performProtobufRequest<T: ProtobufAPIDefinition>(_ apiDefinition: T, configuration: NetworkConfiguration) async throws -> T.APIResponse {
        try await performRequestWithRetry(
            retryPolicy: configuration.retryPolicy,
            networkMonitor: configuration.networkMonitor
        ) { attempt in
            try await performSingleRequest(apiDefinition, configuration: configuration, attempt: attempt)
        }
    }

    private func performSingleRequest<T: APIDefinition>(_ apiDefinition: T, configuration: NetworkConfiguration, attempt: Int) async throws -> T.APIResponse {
        try Task.checkCancellation()

        do {
            var urlRequest = try apiDefinition.asURLRequest(configuration: configuration)

            for interceptor in apiDefinition.requestInterceptors {
                urlRequest = try await interceptor.adapt(urlRequest)
            }

            apiDefinition.logger.log(request: urlRequest)

            let (data, response) = try await session.data(for: urlRequest)

            try Task.checkCancellation()

            guard let httpURLResponse = response as? HTTPURLResponse else {
                throw NetworkError.nonHTTPResponse(response)
            }

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

            return try apiDefinition.decode(data: data, response: networkResponse)
        } catch let error as NetworkError {
            apiDefinition.logger.log(error: error)
            throw error
        } catch where NetworkError.isCancellation(error) {
            apiDefinition.logger.log(error: NetworkError.cancelled)
            throw NetworkError.cancelled
        } catch {
            apiDefinition.logger.log(error: NetworkError.underlying(error, nil))
            throw NetworkError.underlying(error, nil)
        }
    }
    
    private func performSingleRequest<T: MultipartAPIDefinition>(_ apiDefinition: T, configuration: NetworkConfiguration, attempt: Int) async throws -> T.APIResponse {
        try Task.checkCancellation()

        do {
            var urlRequest = try apiDefinition.asURLRequest(configuration: configuration)

            for interceptor in apiDefinition.requestInterceptors {
                urlRequest = try await interceptor.adapt(urlRequest)
            }

            apiDefinition.logger.log(request: urlRequest)

            let (data, response) = try await session.data(for: urlRequest)

            try Task.checkCancellation()

            guard let httpURLResponse = response as? HTTPURLResponse else {
                throw NetworkError.nonHTTPResponse(response)
            }

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

            return try apiDefinition.decode(data: data, response: networkResponse)
        } catch let error as NetworkError {
            apiDefinition.logger.log(error: error)
            throw error
        } catch where NetworkError.isCancellation(error) {
            apiDefinition.logger.log(error: NetworkError.cancelled)
            throw NetworkError.cancelled
        } catch {
            apiDefinition.logger.log(error: NetworkError.underlying(error, nil))
            throw NetworkError.underlying(error, nil)
        }
    }

    private func performSingleRequest<T: ProtobufAPIDefinition>(_ apiDefinition: T, configuration: NetworkConfiguration, attempt: Int) async throws -> T.APIResponse {
        try Task.checkCancellation()

        do {
            var urlRequest = try apiDefinition.asURLRequest(configuration: configuration)

            for interceptor in apiDefinition.requestInterceptors {
                urlRequest = try await interceptor.adapt(urlRequest)
            }

            apiDefinition.logger.log(request: urlRequest)

            let (data, response) = try await session.data(for: urlRequest)

            try Task.checkCancellation()

            guard let httpURLResponse = response as? HTTPURLResponse else {
                throw NetworkError.nonHTTPResponse(response)
            }

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

            return try apiDefinition.decode(data: data, response: networkResponse)
        } catch let error as NetworkError {
            apiDefinition.logger.log(error: error)
            throw error
        } catch where NetworkError.isCancellation(error) {
            apiDefinition.logger.log(error: NetworkError.cancelled)
            throw NetworkError.cancelled
        } catch {
            apiDefinition.logger.log(error: NetworkError.underlying(error, nil))
            throw NetworkError.underlying(error, nil)
        }
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
            throw NetworkError.objectMapping(error, response)
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
            throw NetworkError.objectMapping(error, response)
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
                httpBody = try params.serializedData()
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
            return try Self.APIResponse(serializedData: data)
        } catch {
            throw NetworkError.objectMapping(error, response)
        }
    }
}
