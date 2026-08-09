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
public enum HLSContentSteeringPhase: Equatable, Sendable {
    /// A pathway's media playlist is being resolved.
    case mediaPlaylist

    /// A media resource is being transferred.
    case mediaResource
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
    private let eventObservers: [any HLSContentSteeringEventObserving]

    /// Enables Content Steering with bounded manifests and transfer recovery.
    public init(
        maximumManifestBytes: Int = 256 * 1_024,
        allowsTransferFailover: Bool = true,
        eventObservers: [any HLSContentSteeringEventObserving] = []
    ) {
        self.isEnabled = true
        self.maximumManifestBytes = maximumManifestBytes
        self.allowsTransferFailover = allowsTransferFailover
        self.eventObservers = eventObservers
    }

    private init(
        isEnabled: Bool,
        maximumManifestBytes: Int,
        allowsTransferFailover: Bool,
        eventObservers: [any HLSContentSteeringEventObserving]
    ) {
        self.isEnabled = isEnabled
        self.maximumManifestBytes = maximumManifestBytes
        self.allowsTransferFailover = allowsTransferFailover
        self.eventObservers = eventObservers
    }

    /// Ignores Steering Manifests while retaining the declared initial
    /// pathway as a deterministic fallback.
    public static var disabled: HLSContentSteeringPack {
        HLSContentSteeringPack(
            isEnabled: false,
            maximumManifestBytes: 1,
            allowsTransferFailover: false,
            eventObservers: []
        )
    }

    var resolvedSettings: HLSContentSteeringSettings {
        HLSContentSteeringSettings(
            isEnabled: isEnabled,
            maximumManifestBytes: min(
                max(1, maximumManifestBytes),
                2 * 1_024 * 1_024
            ),
            allowsTransferFailover: allowsTransferFailover,
            eventObservers: eventObservers
        )
    }
}

struct HLSContentSteeringSettings: Sendable {
    let isEnabled: Bool
    let maximumManifestBytes: Int
    let allowsTransferFailover: Bool
    let eventObservers: [any HLSContentSteeringEventObserving]

    func emit(
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
