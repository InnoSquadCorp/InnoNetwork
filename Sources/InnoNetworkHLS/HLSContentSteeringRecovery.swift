import Foundation
import InnoNetwork

struct HLSPathwayResource: Sendable {
    let pathwayID: String?
    let transfer: HLSResourceTransfer
    let aes128KeySet: HLSAES128KeySet
}

actor HLSContentSteeringRecovery {
    private let playlistResolver: PlaylistResolver
    private let keyResolver: HLSAES128KeyResolver
    private let maximumTransferBytes: Int
    private let primaryVariant: HLSVariant
    private let primaryContainer: HLSMediaContainer
    private let primaryTransfers: [HLSResourceTransfer]
    private let contentSteering: HLSContentSteeringSettings
    private var remainingCandidates: [HLSMediaPlaylistCandidate]
    private var activePlan: ActivePlan?
    private var activation: Activation?

    init(
        client: HLSHTTPClient,
        clock: any InnoNetworkClock,
        retryPolicy: (any RetryPolicy)?,
        maximumTransferBytes: Int,
        primaryVariant: HLSVariant,
        primaryContainer: HLSMediaContainer,
        primaryTransfers: [HLSResourceTransfer],
        fallbackCandidates: [HLSMediaPlaylistCandidate],
        contentSteering: HLSContentSteeringSettings
    ) {
        self.playlistResolver = PlaylistResolver(client: client)
        self.keyResolver = HLSAES128KeyResolver(
            client: client,
            retryPolicy: retryPolicy,
            clock: clock
        )
        self.maximumTransferBytes = maximumTransferBytes
        self.primaryVariant = primaryVariant
        self.primaryContainer = primaryContainer
        self.primaryTransfers = primaryTransfers
        self.remainingCandidates = fallbackCandidates
        self.contentSteering = contentSteering
    }

    func resource(
        at index: Int,
        afterFailureOf pathwayID: String?
    ) async throws -> HLSPathwayResource? {
        if let activePlan, activePlan.pathwayID != pathwayID {
            return activePlan.resource(at: index)
        }
        if activePlan?.pathwayID == pathwayID {
            activePlan = nil
        }

        let currentActivation: Activation
        if let activation {
            currentActivation = activation
        } else {
            currentActivation = Activation(
                id: UUID(),
                task: Task {
                    try await self.activateNextPlan()
                }
            )
            activation = currentActivation
        }
        do {
            let plan = try await currentActivation.task.value
            if activation?.id == currentActivation.id {
                activation = nil
                activePlan = plan
                try Task.checkCancellation()
                return plan?.resource(at: index)
            }
            if let activePlan {
                try Task.checkCancellation()
                return activePlan.resource(at: index)
            }
            if activation != nil {
                return try await resource(
                    at: index,
                    afterFailureOf: pathwayID
                )
            }
            try Task.checkCancellation()
            return plan?.resource(at: index)
        } catch {
            if activation?.id == currentActivation.id {
                activation = nil
            }
            throw error
        }
    }

    private func activateNextPlan() async throws -> ActivePlan? {
        while !remainingCandidates.isEmpty {
            let candidate = remainingCandidates.removeFirst()
            guard isVariantCompatible(candidate.variant) else {
                continue
            }
            await contentSteering.emit(
                .pathwayAttempt(
                    pathwayID: candidate.pathwayID,
                    phase: .mediaPlaylist,
                    resourceIndex: nil
                )
            )
            do {
                let document = try await playlistResolver.resolveDocument(
                    from: candidate.variant.url,
                    multivariantVariables:
                        candidate.multivariantVariables,
                    purpose: .mediaPlaylist
                )
                guard
                    let media = document.playlist.media,
                    let container = document.playlist.mediaContainer
                else {
                    await emitPlaylistFailure(
                        for: candidate.pathwayID,
                        code: .invalidPlaylist
                    )
                    continue
                }
                try HLSMediaPlaylistValidator.validate(media)
                let transfers = HLSResourcePlan(
                    resources: media.resources,
                    maximumTransferBytes: maximumTransferBytes
                ).transfers
                guard
                    container == primaryContainer,
                    Self.isCompatible(
                        primaryTransfers,
                        transfers
                    )
                else {
                    await emitPlaylistFailure(
                        for: candidate.pathwayID,
                        code: .invalidPlaylist
                    )
                    continue
                }
                let keySet = try await keyResolver.resolve(
                    resources: transfers
                )
                let plan = ActivePlan(
                    pathwayID: candidate.pathwayID,
                    transfers: transfers,
                    aes128KeySet: keySet
                )
                await contentSteering.emit(
                    .pathwaySelected(
                        pathwayID: candidate.pathwayID,
                        phase: .mediaPlaylist,
                        resourceIndex: nil
                    )
                )
                return plan
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await emitPlaylistFailure(
                    for: candidate.pathwayID,
                    code: (error as? HLSDownloadError)?.code
                        ?? .transferFailed
                )
                continue
            }
        }
        return nil
    }

    private func emitPlaylistFailure(
        for pathwayID: String?,
        code: HLSDownloadErrorCode
    ) async {
        await contentSteering.emit(
            .pathwayFailed(
                pathwayID: pathwayID,
                phase: .mediaPlaylist,
                resourceIndex: nil,
                errorCode: code
            )
        )
    }

    private func isVariantCompatible(
        _ candidate: HLSVariant
    ) -> Bool {
        guard
            let stableID = primaryVariant.stableID,
            stableID == candidate.stableID
        else {
            return false
        }
        return primaryVariant.codecs == candidate.codecs
            && primaryVariant.supplementalCodecs
                == candidate.supplementalCodecs
            && primaryVariant.width == candidate.width
            && primaryVariant.height == candidate.height
            && primaryVariant.videoRange == candidate.videoRange
    }

    private static func isCompatible(
        _ primary: [HLSResourceTransfer],
        _ fallback: [HLSResourceTransfer]
    ) -> Bool {
        guard primary.count == fallback.count else {
            return false
        }
        return zip(primary, fallback).allSatisfy { first, second in
            first.url.path == second.url.path
                && first.byteRange == second.byteRange
                && encryptionIsCompatible(
                    first.encryption,
                    second.encryption
                )
        }
    }

    private static func encryptionIsCompatible(
        _ first: HLSAES128Encryption?,
        _ second: HLSAES128Encryption?
    ) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case (.some(let first), .some(let second)):
            return first.initializationVector
                == second.initializationVector
        case (.none, .some), (.some, .none):
            return false
        }
    }

    private struct ActivePlan: Sendable {
        let pathwayID: String?
        let transfers: [HLSResourceTransfer]
        let aes128KeySet: HLSAES128KeySet

        func resource(
            at index: Int
        ) -> HLSPathwayResource? {
            guard transfers.indices.contains(index) else {
                return nil
            }
            return HLSPathwayResource(
                pathwayID: pathwayID,
                transfer: transfers[index],
                aes128KeySet: aes128KeySet
            )
        }
    }

    private struct Activation: Sendable {
        let id: UUID
        let task: Task<ActivePlan?, Error>
    }
}
