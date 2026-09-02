import Foundation
import InnoNetworkHLS

struct HLSLiveCDNTuneInResult: Sendable {
    let document: HLSLiveResolvedDocument
    let reloadMode: HLSLiveReloadMode
}

enum HLSLiveCDNTuneInCoordinator {
    static func resolve(
        initialDocument: HLSLiveResolvedDocument,
        settings: HLSLiveCDNTuneInSettings,
        now: @Sendable () -> Date,
        load: @Sendable (URL) async throws -> HLSLiveResolvedDocument
    ) async throws -> HLSLiveCDNTuneInResult {
        let initialMode = HLSLiveReloadMode.initial
        guard settings.isEnabled else {
            return HLSLiveCDNTuneInResult(
                document: initialDocument,
                reloadMode: initialMode
            )
        }
        let firstMeasuredAt = now()
        let firstSnapshot = try HLSLivePlaylistMerger.makeSnapshot(
            from: initialDocument,
            previous: nil,
            generation: 0,
            reloadMode: initialMode,
            measuredAt: firstMeasuredAt
        )
        guard let plan = HLSLiveCDNTuneInPlan(first: firstSnapshot) else {
            return HLSLiveCDNTuneInResult(
                document: initialDocument,
                reloadMode: initialMode
            )
        }

        var document = initialDocument
        var snapshot = firstSnapshot
        var reloadMode = initialMode
        for _ in 0..<settings.maximumAdditionalRequestCount {
            let measuredAt = now()
            let request: HLSLiveReloadRequest
            do {
                guard
                    let nextRequest = try plan.nextRequest(
                        after: snapshot,
                        measuredAt: measuredAt
                    )
                else {
                    break
                }
                request = nextRequest
                let loadedDocument = try await load(request.url)
                let loadedSnapshot = try HLSLivePlaylistMerger.makeSnapshot(
                    from: loadedDocument,
                    previous: nil,
                    generation: 0,
                    reloadMode: request.mode,
                    measuredAt: now()
                )
                document = loadedDocument
                snapshot = loadedSnapshot
                reloadMode = request.mode
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                break
            }
        }
        return HLSLiveCDNTuneInResult(
            document: document,
            reloadMode: reloadMode
        )
    }
}
