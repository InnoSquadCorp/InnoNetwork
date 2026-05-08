import Foundation

// MARK: - Event publication helpers
//
// Event publication shims that the executor pipeline calls into at
// stage boundaries (request-start, post-adaptation, terminal failure).
// Lives in its own file so the central RequestExecutor stays focused
// on dispatch and resilience logic; the helpers are package-internal
// so they remain reachable from RequestExecutor.swift through extension
// composition.

extension RequestExecutor {
    func notifyRequestStart(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await eventHub.publish(
            .requestStart(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    func notifyRequestAdapted(
        _ request: URLRequest,
        retryIndex: Int,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        await eventHub.publish(
            .requestAdapted(
                requestID: requestID,
                method: request.httpMethod ?? "UNKNOWN",
                url: request.url?.absoluteString ?? "",
                retryIndex: retryIndex
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }

    func notifyFailure(
        _ networkError: NetworkError,
        requestID: UUID,
        configuration: NetworkConfiguration
    ) async {
        let nsError = networkError as NSError
        await eventHub.publish(
            .requestFailed(
                requestID: requestID,
                errorCode: nsError.code,
                message: networkError.localizedDescription
            ),
            requestID: requestID,
            observers: configuration.eventObservers
        )
    }
}
