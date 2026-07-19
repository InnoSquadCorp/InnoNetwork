import InnoNetwork

public extension DefaultNetworkClient {
    /// Creates a production client around an in-memory scripted test session.
    /// Keep this initializer in test targets by depending on
    /// `InnoNetworkTestSupport` only from those targets.
    convenience init(
        configuration: NetworkConfiguration,
        session: MockURLSession
    ) {
        self.init(
            configuration: configuration,
            session: session as any URLSessionProtocol
        )
    }

    /// Creates a production client around a deterministic VCR record/replay
    /// session. Keep this initializer in test targets by depending on
    /// `InnoNetworkTestSupport` only from those targets.
    convenience init(
        configuration: NetworkConfiguration,
        session: VCRURLSession
    ) {
        self.init(
            configuration: configuration,
            session: session as any URLSessionProtocol
        )
    }
}
