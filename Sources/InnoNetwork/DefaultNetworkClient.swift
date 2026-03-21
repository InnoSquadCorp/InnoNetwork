import Foundation


public protocol NetworkClient: Sendable {
    func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse
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
        try await performTypedRequest(APISingleRequestExecutable(base: request))
    }
    
    public func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse {
        try await performTypedRequest(MultipartSingleRequestExecutable(base: request))
    }

    /// Generic retry wrapper that handles retry logic for any request type
    package func performTypedRequest<D: SingleRequestExecutable>(_ apiDefinition: D) async throws -> D.APIResponse {
        let requestID = UUID()
        let retryCoordinator = RetryCoordinator(eventHub: eventHub)
        return try await retryCoordinator.execute(
            retryPolicy: configuration.retryPolicy,
            networkMonitor: configuration.networkMonitor,
            requestID: requestID,
            eventObservers: configuration.eventObservers
        ) { retryIndex, requestID in
            try await RequestExecutor(session: session, eventHub: eventHub).execute(
                apiDefinition,
                configuration: configuration,
                requestBuilder: requestBuilder,
                retryIndex: retryIndex,
                requestID: requestID
            )
        }
    }
}
