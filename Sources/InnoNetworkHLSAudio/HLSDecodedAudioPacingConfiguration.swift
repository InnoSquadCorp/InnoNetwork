import Foundation

/// Controls demand-driven pacing for decoded HLS audio samples.
@available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *)
public struct HLSDecodedAudioPacingConfiguration: Equatable, Sendable {
    private static let defaultMaximumLeadTime: TimeInterval = 0.25
    private static let maximumAllowedLeadTime: TimeInterval = 10
    private static let defaultPollingInterval: TimeInterval = 0.01
    private static let minimumPollingInterval: TimeInterval = 0.001
    private static let maximumPollingInterval: TimeInterval = 0.25

    /// Maximum lead allowed before the sequence starts another sample read.
    ///
    /// Values are clamped to `0...10` seconds. Non-finite values use the
    /// 250-millisecond default.
    public let maximumLeadTime: TimeInterval

    /// Delay between playhead checks while the sequence is ahead.
    ///
    /// Values are clamped to `0.001...0.25` seconds. Non-finite values use
    /// the 10-millisecond default.
    public let pollingInterval: TimeInterval

    /// Creates a bounded decoded-audio pacing configuration.
    public init(
        maximumLeadTime: TimeInterval = 0.25,
        pollingInterval: TimeInterval = 0.01
    ) {
        self.maximumLeadTime = Self.normalized(
            maximumLeadTime,
            defaultValue: Self.defaultMaximumLeadTime,
            minimum: 0,
            maximum: Self.maximumAllowedLeadTime
        )
        self.pollingInterval = Self.normalized(
            pollingInterval,
            defaultValue: Self.defaultPollingInterval,
            minimum: Self.minimumPollingInterval,
            maximum: Self.maximumPollingInterval
        )
    }

    private static func normalized(
        _ value: TimeInterval,
        defaultValue: TimeInterval,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else {
            return defaultValue
        }
        return min(maximum, max(minimum, value))
    }
}
