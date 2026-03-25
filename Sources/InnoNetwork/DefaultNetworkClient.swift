import Foundation


public protocol NetworkClient: Sendable {
    /// Executes a standard typed request modeled with ``APIDefinition``.
    ///
    /// Prefer this entry point for normal request/response APIs.
    ///
    /// - Parameter request: The typed request definition to execute.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    /// Executes a multipart request modeled with ``MultipartAPIDefinition``.
    ///
    /// Prefer this entry point for upload-style integrations.
    ///
    /// - Parameter request: The multipart request definition to execute.
    /// - Returns: The decoded `APIResponse` produced by the multipart request.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the multipart request.
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse
    /// Executes a standard typed request through the low-level execution pipeline.
    ///
    /// `perform(_:)` is primarily intended for framework authors and policy layers
    /// that need to adapt richer request contracts into `InnoNetwork` without using
    /// SPI imports. Application integrations should normally prefer ``request(_:)``.
    ///
    /// - Parameter request: The typed request definition to execute through the
    ///   low-level pipeline.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    func perform<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    /// Executes a custom request executable through the low-level execution pipeline.
    ///
    /// This overload exists for higher-level networking layers that want to control
    /// request serialization and decoding while still delegating execution, retry,
    /// and observability to `InnoNetwork`.
    ///
    /// - Parameter executable: The custom executable that owns request metadata,
    ///   payload creation, and response decoding.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    func perform<D: SingleRequestExecutable>(executable: D) async throws -> D.APIResponse
}


public actor DefaultNetworkClient: NetworkClient {
    private let configuration: NetworkConfiguration
    private let session: URLSessionProtocol
    private let requestBuilder = RequestBuilder()
    private let eventHub: NetworkEventHub

    public init(
        configuration: NetworkConfiguration,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.configuration = configuration
        self.session = session
        self.eventHub = NetworkEventHub(
            policy: configuration.eventDeliveryPolicy,
            metricsReporter: configuration.eventMetricsReporter,
            hubKind: .networkRequest
        )
    }

    public func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(request)
    }
    
    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(executable: MultipartSingleRequestExecutable(base: request))
    }

    /// Low-level typed execution entry point for standard ``APIDefinition`` requests.
    ///
    /// Use this when you need to make the execution pipeline itself the dependency
    /// boundary. Most app integrations should still prefer ``request(_:)``.
    ///
    /// - Parameter request: The typed request definition to execute through the
    ///   low-level pipeline.
    /// - Returns: The decoded `APIResponse` produced by the request definition.
    /// - Throws: A ``NetworkError`` or another execution error produced while encoding,
    ///   sending, validating, or decoding the request.
    public func perform<T: APIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await perform(executable: APISingleRequestExecutable(base: request))
    }

    /// Low-level typed execution entry point for custom ``SingleRequestExecutable`` values.
    ///
    /// This API is intended for upper networking layers that need full control over
    /// serialization and decoding but still want `InnoNetwork` to own request
    /// building, retry coordination, trust handling, and observability.
    ///
    /// - Parameter executable: The custom executable that owns request metadata,
    ///   payload creation, and response decoding.
    /// - Returns: The decoded `APIResponse` produced by the executable.
    /// - Throws: A ``NetworkError`` or another execution error produced while building,
    ///   sending, validating, or decoding the executable request.
    public func perform<D: SingleRequestExecutable>(executable: D) async throws -> D.APIResponse {
        let requestID = UUID()
        let retryCoordinator = RetryCoordinator(eventHub: eventHub)
        return try await retryCoordinator.execute(
            retryPolicy: configuration.retryPolicy,
            networkMonitor: configuration.networkMonitor,
            requestID: requestID,
            eventObservers: configuration.eventObservers
        ) { retryIndex, requestID in
            try await RequestExecutor(session: session, eventHub: eventHub).execute(
                executable,
                configuration: configuration,
                requestBuilder: requestBuilder,
                retryIndex: retryIndex,
                requestID: requestID
            )
        }
    }
}
