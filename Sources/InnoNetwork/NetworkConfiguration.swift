import Foundation


public struct NetworkConfiguration: Sendable {
    /// The default range of HTTP status codes treated as successful responses.
    /// `2xx` per RFC 9110 §15.3.
    public static let defaultAcceptableStatusCodes: Set<Int> = Set(200..<300)

    package enum Presets {
        static func safeDefaults(baseURL: URL) -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: 30.0,
                cachePolicy: .useProtocolCachePolicy,
                retryPolicy: nil,
                networkMonitor: NetworkMonitor.shared,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: [],
                eventDeliveryPolicy: .default,
                eventMetricsReporter: nil,
                acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes
            )
        }

        static func advancedTuning(baseURL: URL) -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: 60.0,
                cachePolicy: .reloadIgnoringLocalCacheData,
                retryPolicy: nil,
                networkMonitor: NetworkMonitor.shared,
                metricsReporter: nil,
                trustPolicy: .systemDefault,
                eventObservers: [],
                eventDeliveryPolicy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: 512,
                    maxBufferedEventsPerConsumer: 512,
                    overflowPolicy: .dropOldest
                ),
                eventMetricsReporter: nil,
                acceptableStatusCodes: NetworkConfiguration.defaultAcceptableStatusCodes
            )
        }
    }

    public let baseURL: URL
    public let timeout: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
    public let retryPolicy: RetryPolicy?
    public let networkMonitor: (any NetworkMonitoring)?
    public let metricsReporter: (any NetworkMetricsReporting)?
    public let trustPolicy: TrustPolicy
    public let eventObservers: [any NetworkEventObserving]
    public let eventDeliveryPolicy: EventDeliveryPolicy
    public let eventMetricsReporter: (any EventPipelineMetricsReporting)?
    /// HTTP status codes that the request executor treats as successful.
    /// Responses with a status code outside this set throw
    /// ``NetworkError/statusCode(_:)``. Defaults to ``defaultAcceptableStatusCodes``
    /// (`200..<300`); override to allow values like `304` or `205` to flow
    /// through to consumer code without error mapping.
    public let acceptableStatusCodes: Set<Int>

    public struct AdvancedBuilder: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval
        public var cachePolicy: URLRequest.CachePolicy
        public var retryPolicy: RetryPolicy?
        public var networkMonitor: (any NetworkMonitoring)?
        public var metricsReporter: (any NetworkMetricsReporting)?
        public var trustPolicy: TrustPolicy
        public var eventObservers: [any NetworkEventObserving]
        public var eventDeliveryPolicy: EventDeliveryPolicy
        public var eventMetricsReporter: (any EventPipelineMetricsReporting)?
        public var acceptableStatusCodes: Set<Int>

        fileprivate init(preset: NetworkConfiguration) {
            self.baseURL = preset.baseURL
            self.timeout = preset.timeout
            self.cachePolicy = preset.cachePolicy
            self.retryPolicy = preset.retryPolicy
            self.networkMonitor = preset.networkMonitor
            self.metricsReporter = preset.metricsReporter
            self.trustPolicy = preset.trustPolicy
            self.eventObservers = preset.eventObservers
            self.eventDeliveryPolicy = preset.eventDeliveryPolicy
            self.eventMetricsReporter = preset.eventMetricsReporter
            self.acceptableStatusCodes = preset.acceptableStatusCodes
        }

        fileprivate func build() -> NetworkConfiguration {
            NetworkConfiguration(
                baseURL: baseURL,
                timeout: timeout,
                cachePolicy: cachePolicy,
                retryPolicy: retryPolicy,
                networkMonitor: networkMonitor,
                metricsReporter: metricsReporter,
                trustPolicy: trustPolicy,
                eventObservers: eventObservers,
                eventDeliveryPolicy: eventDeliveryPolicy,
                eventMetricsReporter: eventMetricsReporter,
                acceptableStatusCodes: acceptableStatusCodes
            )
        }
    }

    public static func safeDefaults(baseURL: URL) -> NetworkConfiguration {
        Presets.safeDefaults(baseURL: baseURL)
    }

    public static func advanced(
        baseURL: URL,
        _ configure: (inout AdvancedBuilder) -> Void
    ) -> NetworkConfiguration {
        var builder = AdvancedBuilder(preset: Presets.advancedTuning(baseURL: baseURL))
        configure(&builder)
        return builder.build()
    }

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30.0,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        retryPolicy: RetryPolicy? = nil,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        metricsReporter: (any NetworkMetricsReporting)? = nil,
        trustPolicy: TrustPolicy = .systemDefault,
        eventObservers: [any NetworkEventObserving] = [],
        eventDeliveryPolicy: EventDeliveryPolicy = .default,
        eventMetricsReporter: (any EventPipelineMetricsReporting)? = nil,
        acceptableStatusCodes: Set<Int> = NetworkConfiguration.defaultAcceptableStatusCodes
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.retryPolicy = retryPolicy
        self.networkMonitor = networkMonitor
        self.metricsReporter = metricsReporter
        self.trustPolicy = trustPolicy
        self.eventObservers = eventObservers
        self.eventDeliveryPolicy = eventDeliveryPolicy
        self.eventMetricsReporter = eventMetricsReporter
        self.acceptableStatusCodes = acceptableStatusCodes
    }
}
