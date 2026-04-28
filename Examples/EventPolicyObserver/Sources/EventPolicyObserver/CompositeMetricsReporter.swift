import Foundation
import InnoNetwork

/// Forwards every metric to each wrapped reporter in order. Useful for
/// wiring both `LoggerMetricsReporter` (for log aggregation) and
/// `SignPostMetricsReporter` (for Instruments) without swapping
/// configuration.
public struct CompositeMetricsReporter: EventPipelineMetricsReporting {

    private let reporters: [any EventPipelineMetricsReporting]

    public init(_ reporters: [any EventPipelineMetricsReporting]) {
        self.reporters = reporters
    }

    public func report(_ metric: EventPipelineMetric) {
        for reporter in reporters {
            reporter.report(metric)
        }
    }
}
