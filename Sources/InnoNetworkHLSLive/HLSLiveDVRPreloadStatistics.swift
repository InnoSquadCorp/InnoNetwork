/// Non-sensitive counters for one kind of LL-HLS DVR preload resource.
///
/// Counts describe one recording session. They do not include resource URLs,
/// request headers, or response bodies. Counts and byte totals saturate at
/// their numeric maximum instead of overflowing.
public struct HLSLiveDVRPreloadResourceStatistics: Equatable, Sendable {
    /// Preload transfers started from eligible hints.
    public let requestCount: Int

    /// Preload transfers that successfully completed.
    public let completedCount: Int

    /// Hints later confirmed by an exact playlist resource match.
    public let confirmedCount: Int

    /// Confirmed preloads moved into the DVR package.
    public let reuseCount: Int

    /// Ordinary DVR loads used because no exact preload was reusable.
    public let missCount: Int

    /// Preload transfers that failed for a reason other than cancellation.
    public let failureCount: Int

    /// Preload transfers cancelled before producing a reusable resource.
    public let cancellationCount: Int

    /// Preload entries removed without being reused.
    public let discardCount: Int

    /// Bytes successfully transferred by preload requests.
    public let transferredByteCount: Int64

    /// Preloaded bytes moved into the DVR package.
    public let reusedByteCount: Int64

    /// Successfully preloaded bytes removed without reuse.
    public let discardedByteCount: Int64

    init(
        requestCount: Int = 0,
        completedCount: Int = 0,
        confirmedCount: Int = 0,
        reuseCount: Int = 0,
        missCount: Int = 0,
        failureCount: Int = 0,
        cancellationCount: Int = 0,
        discardCount: Int = 0,
        transferredByteCount: Int64 = 0,
        reusedByteCount: Int64 = 0,
        discardedByteCount: Int64 = 0
    ) {
        self.requestCount = requestCount
        self.completedCount = completedCount
        self.confirmedCount = confirmedCount
        self.reuseCount = reuseCount
        self.missCount = missCount
        self.failureCount = failureCount
        self.cancellationCount = cancellationCount
        self.discardCount = discardCount
        self.transferredByteCount = transferredByteCount
        self.reusedByteCount = reusedByteCount
        self.discardedByteCount = discardedByteCount
    }
}

/// Value-redacted LL-HLS preload statistics for one DVR recording session.
public struct HLSLiveDVRPreloadStatistics: Equatable, Sendable {
    /// Partial-segment preload counters.
    public let partialSegments: HLSLiveDVRPreloadResourceStatistics

    /// Initialization-map preload counters.
    public let initializationMaps: HLSLiveDVRPreloadResourceStatistics

    init(
        partialSegments: HLSLiveDVRPreloadResourceStatistics =
            HLSLiveDVRPreloadResourceStatistics(),
        initializationMaps: HLSLiveDVRPreloadResourceStatistics =
            HLSLiveDVRPreloadResourceStatistics()
    ) {
        self.partialSegments = partialSegments
        self.initializationMaps = initializationMaps
    }
}
