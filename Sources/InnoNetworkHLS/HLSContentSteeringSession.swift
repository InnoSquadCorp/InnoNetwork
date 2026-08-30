import Foundation
import InnoNetwork

package actor HLSContentSteeringSession {
    package enum AttemptAdmission: Equatable, Sendable {
        case admitted
        case recovered
        case penalized
    }

    package struct Selection: Sendable {
        package let fromPathwayID: String?
        package let reason: HLSContentSteeringSelectionReason

        package init(
            fromPathwayID: String?,
            reason: HLSContentSteeringSelectionReason
        ) {
            self.fromPathwayID = fromPathwayID
            self.reason = reason
        }
    }

    private struct PathwayState: Sendable {
        var attemptCount = 0
        var successCount = 0
        var failureCount = 0
        var consecutiveFailureCount = 0
        var penalizedAt: Date?
        var penalizedUntil: Date?
        var selectionCounts: [HLSContentSteeringSelectionReason: Int] = [:]
    }

    private let settings: HLSContentSteeringSettings
    private let now: @Sendable () -> Date
    private var states: [String: PathwayState] = [:]

    package init(
        settings: HLSContentSteeringSettings,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.now = now
    }

    package func beginAttempt(
        pathwayID: String?,
        phase: HLSContentSteeringPhase,
        resourceIndex: Int?
    ) async -> AttemptAdmission {
        let admission = await admit(pathwayID: pathwayID)
        guard admission != .penalized else {
            return admission
        }
        if let pathwayID {
            states[pathwayID, default: PathwayState()].attemptCount += 1
        }
        await settings.emit(
            .pathwayAttempt(
                pathwayID: pathwayID,
                phase: phase,
                resourceIndex: resourceIndex
            )
        )
        return admission
    }

    package func recordSuccess(
        pathwayID: String?,
        phase: HLSContentSteeringPhase,
        resourceIndex: Int?,
        selection: Selection? = nil
    ) async {
        if let pathwayID {
            var state = states[pathwayID, default: PathwayState()]
            state.successCount += 1
            state.consecutiveFailureCount = 0
            state.penalizedAt = nil
            state.penalizedUntil = nil
            if let selection {
                state.selectionCounts[selection.reason, default: 0] += 1
            }
            states[pathwayID] = state
        }
        await settings.emit(
            .pathwaySelected(
                pathwayID: pathwayID,
                phase: phase,
                resourceIndex: resourceIndex
            )
        )
        if let selection {
            await settings.emit(
                .pathwaySelectionChanged(
                    fromPathwayID: selection.fromPathwayID,
                    toPathwayID: pathwayID,
                    reason: selection.reason
                )
            )
        }
        await emitHealth(for: pathwayID)
    }

    package func beginPenalizedFallbackAttempt(
        pathwayID: String?,
        phase: HLSContentSteeringPhase,
        resourceIndex: Int?
    ) async {
        if let pathwayID {
            states[pathwayID, default: PathwayState()].attemptCount += 1
        }
        await settings.emit(
            .pathwayAttempt(
                pathwayID: pathwayID,
                phase: phase,
                resourceIndex: resourceIndex
            )
        )
    }

    package func recordFailure(
        pathwayID: String?,
        phase: HLSContentSteeringPhase,
        resourceIndex: Int?,
        errorCode: HLSDownloadErrorCode
    ) async {
        if let pathwayID {
            var state = states[pathwayID, default: PathwayState()]
            state.failureCount += 1
            state.consecutiveFailureCount += 1
            if state.consecutiveFailureCount
                >= settings.healthPolicy.consecutiveFailureThreshold,
                settings.healthPolicy.recoveryCooldown > .zero
            {
                let observationTime = now()
                state.penalizedAt = observationTime
                state.penalizedUntil = observationTime.addingTimeInterval(
                    settings.healthPolicy.recoveryCooldown.timeInterval
                )
            }
            states[pathwayID] = state
        }
        await settings.emit(
            .pathwayFailed(
                pathwayID: pathwayID,
                phase: phase,
                resourceIndex: resourceIndex,
                errorCode: errorCode
            )
        )
        await emitHealth(for: pathwayID)
    }

    private func admit(
        pathwayID: String?
    ) async -> AttemptAdmission {
        guard let pathwayID,
            var state = states[pathwayID],
            let penalizedUntil = state.penalizedUntil
        else {
            return .admitted
        }
        let observationTime = now()
        let clockRegressed =
            state.penalizedAt.map {
                observationTime < $0
            } ?? false
        guard observationTime >= penalizedUntil || clockRegressed else {
            return .penalized
        }
        state.consecutiveFailureCount = 0
        state.penalizedAt = nil
        state.penalizedUntil = nil
        states[pathwayID] = state
        await emitHealth(for: pathwayID)
        return .recovered
    }

    private func emitHealth(
        for pathwayID: String?
    ) async {
        guard let pathwayID,
            let state = states[pathwayID]
        else {
            return
        }
        let completedCount = state.successCount + state.failureCount
        let successRate =
            completedCount > 0
            ? Double(state.successCount) / Double(completedCount)
            : 0
        let availability: HLSContentSteeringPathwayAvailability
        if let penalizedUntil = state.penalizedUntil {
            let observationTime = now()
            let clockRegressed =
                state.penalizedAt.map {
                    observationTime < $0
                } ?? false
            if observationTime < penalizedUntil, !clockRegressed {
                let remaining = min(
                    settings.healthPolicy.recoveryCooldown.timeInterval,
                    penalizedUntil.timeIntervalSince(observationTime)
                )
                availability = .penalized(
                    retryAfter: .milliseconds(
                        Int64((remaining * 1_000).rounded(.up))
                    )
                )
            } else {
                availability = .available
            }
        } else {
            availability = .available
        }
        await settings.emit(
            .pathwayHealthChanged(
                HLSContentSteeringPathwaySnapshot(
                    pathwayID: pathwayID,
                    attemptCount: state.attemptCount,
                    successCount: state.successCount,
                    failureCount: state.failureCount,
                    successRate: successRate,
                    consecutiveFailureCount:
                        state.consecutiveFailureCount,
                    availability: availability,
                    selectionCounts: state.selectionCounts
                )
            )
        )
    }
}
