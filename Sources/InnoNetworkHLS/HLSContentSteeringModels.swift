import Foundation

/// A multivariant playlist's Content Steering declaration.
public struct HLSContentSteering: Equatable, Sendable {
    /// The resolved Steering Manifest URL.
    public let serverURL: URL

    /// The pathway to use until the first Steering Manifest is available.
    public let initialPathwayID: String?

    init(
        serverURL: URL,
        initialPathwayID: String?
    ) {
        self.serverURL = serverURL
        self.initialPathwayID = initialPathwayID
    }
}

/// The Content Steering operation represented by an observability event.
public enum HLSContentSteeringPhase: Hashable, Sendable {
    /// A pathway's media playlist is being resolved.
    case mediaPlaylist

    /// A media resource is being transferred.
    case mediaResource
}

/// Controls when a failing Content Steering pathway is temporarily excluded.
public struct HLSContentSteeringHealthPolicy: Equatable, Sendable {
    private static let maximumFailureThreshold = 16
    private static let maximumRecoveryCooldown: Duration = .seconds(3_600)

    let consecutiveFailureThreshold: Int
    let recoveryCooldown: Duration

    /// Creates a bounded pathway health policy.
    ///
    /// A pathway is penalized after `consecutiveFailureThreshold` failed
    /// operations without an intervening success. It becomes eligible again
    /// after `recoveryCooldown`. A zero cooldown keeps health statistics and
    /// typed events enabled without excluding a pathway.
    public init(
        consecutiveFailureThreshold: Int = 1,
        recoveryCooldown: Duration = .seconds(30)
    ) {
        self.consecutiveFailureThreshold = min(
            max(1, consecutiveFailureThreshold),
            Self.maximumFailureThreshold
        )
        self.recoveryCooldown = min(
            max(.zero, recoveryCooldown),
            Self.maximumRecoveryCooldown
        )
    }
}

/// The current eligibility of one Content Steering pathway.
public enum HLSContentSteeringPathwayAvailability: Equatable, Sendable {
    /// The pathway can be attempted.
    case available

    /// The pathway is excluded until its bounded cooldown expires.
    case penalized(retryAfter: Duration)
}

/// Session-scoped, value-redacted health for one Content Steering pathway.
public struct HLSContentSteeringPathwaySnapshot: Equatable, Sendable {
    /// The Content Steering pathway identifier.
    public let pathwayID: String

    /// The number of admitted pathway operations.
    public let attemptCount: Int

    /// The number of admitted operations that completed successfully.
    public let successCount: Int

    /// The number of admitted operations that failed.
    public let failureCount: Int

    /// Successful outcomes divided by all completed outcomes.
    public let successRate: Double

    /// Failures since the pathway's last success or cooldown recovery.
    public let consecutiveFailureCount: Int

    /// The pathway's current attempt eligibility.
    public let availability: HLSContentSteeringPathwayAvailability

    /// Selection counts grouped by typed transition reason.
    public let selectionCounts: [HLSContentSteeringSelectionReason: Int]

}

/// The typed reason that a Content Steering pathway was selected.
public enum HLSContentSteeringSelectionReason: Hashable, Sendable {
    /// The pathway was the first successful choice in this session.
    case initial

    /// Another pathway failed and this pathway was selected as recovery.
    case pathwayFailure(
        phase: HLSContentSteeringPhase,
        errorCode: HLSDownloadErrorCode
    )

    /// The pathway became eligible after its cooldown elapsed.
    case cooldownRecovery

}

/// A value-redacted Content Steering decision emitted by an HLS download.
///
/// Events intentionally expose pathway identifiers, stable error codes, and
/// resource indexes without exposing request URLs, headers, or query values.
public enum HLSContentSteeringEvent: Equatable, Sendable {
    /// A pathway operation is about to begin.
    case pathwayAttempt(
        pathwayID: String?,
        phase: HLSContentSteeringPhase,
        resourceIndex: Int?
    )

    /// A pathway operation ended with a terminal failure.
    case pathwayFailed(
        pathwayID: String?,
        phase: HLSContentSteeringPhase,
        resourceIndex: Int?,
        errorCode: HLSDownloadErrorCode
    )

    /// A pathway operation completed successfully.
    case pathwaySelected(
        pathwayID: String?,
        phase: HLSContentSteeringPhase,
        resourceIndex: Int?
    )

    /// Session health changed after an outcome, penalty, or recovery.
    case pathwayHealthChanged(
        HLSContentSteeringPathwaySnapshot
    )

    /// A pathway selection or transition was made for a typed reason.
    case pathwaySelectionChanged(
        fromPathwayID: String?,
        toPathwayID: String?,
        reason: HLSContentSteeringSelectionReason
    )
}

/// Receives value-redacted Content Steering decisions.
public protocol HLSContentSteeringEventObserving: Sendable {
    /// Handles one ordered Content Steering event.
    func contentSteeringDidEmit(
        _ event: HLSContentSteeringEvent
    ) async
}

/// Bounds optional Content Steering manifest resolution.
public struct HLSContentSteeringPack: Sendable {
    private let isEnabled: Bool
    private let maximumManifestBytes: Int
    private let allowsTransferFailover: Bool
    private let healthPolicy: HLSContentSteeringHealthPolicy
    private let eventObservers: [any HLSContentSteeringEventObserving]

    /// Enables Content Steering with bounded manifests and transfer recovery.
    public init(
        maximumManifestBytes: Int = 256 * 1_024,
        allowsTransferFailover: Bool = true,
        healthPolicy: HLSContentSteeringHealthPolicy =
            HLSContentSteeringHealthPolicy(),
        eventObservers: [any HLSContentSteeringEventObserving] = []
    ) {
        self.isEnabled = true
        self.maximumManifestBytes = maximumManifestBytes
        self.allowsTransferFailover = allowsTransferFailover
        self.healthPolicy = healthPolicy
        self.eventObservers = eventObservers
    }

    private init(
        isEnabled: Bool,
        maximumManifestBytes: Int,
        allowsTransferFailover: Bool,
        healthPolicy: HLSContentSteeringHealthPolicy,
        eventObservers: [any HLSContentSteeringEventObserving]
    ) {
        self.isEnabled = isEnabled
        self.maximumManifestBytes = maximumManifestBytes
        self.allowsTransferFailover = allowsTransferFailover
        self.healthPolicy = healthPolicy
        self.eventObservers = eventObservers
    }

    /// Ignores Steering Manifests while retaining the declared initial
    /// pathway as a deterministic fallback.
    public static var disabled: HLSContentSteeringPack {
        HLSContentSteeringPack(
            isEnabled: false,
            maximumManifestBytes: 1,
            allowsTransferFailover: false,
            healthPolicy: HLSContentSteeringHealthPolicy(
                recoveryCooldown: .zero
            ),
            eventObservers: []
        )
    }

    package var resolvedSettings: HLSContentSteeringSettings {
        HLSContentSteeringSettings(
            isEnabled: isEnabled,
            maximumManifestBytes: min(
                max(1, maximumManifestBytes),
                2 * 1_024 * 1_024
            ),
            allowsTransferFailover: allowsTransferFailover,
            healthPolicy: healthPolicy,
            eventObservers: eventObservers
        )
    }
}

package struct HLSContentSteeringSettings: Sendable {
    package let isEnabled: Bool
    package let maximumManifestBytes: Int
    package let allowsTransferFailover: Bool
    package let healthPolicy: HLSContentSteeringHealthPolicy
    package let eventObservers: [any HLSContentSteeringEventObserving]

    package func emit(
        _ event: HLSContentSteeringEvent
    ) async {
        for observer in eventObservers {
            await observer.contentSteeringDidEmit(event)
        }
    }
}

enum HLSPathwayID {
    static let implicit = "."

    static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isASCII
                    && ($0.isLetter
                        || $0.isNumber
                        || $0 == "."
                        || $0 == "-"
                        || $0 == "_")
            }
    }
}
