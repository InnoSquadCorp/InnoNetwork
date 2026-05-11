import Foundation

// MARK: - Pipeline stage
//
// Outer pipeline that the entrypoint `RequestExecutor.execute(...)` delegates
// to: auth-scope validation, the cache/transport pump, the custom-policy
// chain, and the refresh-lane gate. Event publication helpers that the
// pipeline calls at stage boundaries (request-start, post-adaptation,
// terminal failure) also live here so the surface stays adjacent to its
// callers.

extension RequestExecutor {
    func validateAuthScope<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration
    ) throws {
        guard executable.requiresRefreshTokenPolicy, configuration.refreshTokenPolicy == nil else {
            return
        }
        throw NetworkError.configuration(
            reason: .invalidRequest("Auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."))
    }

    func executeWithPolicies(
        request adaptedRequest: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Response {
        var request = adaptedRequest
        var replayedAfterRefresh = false

        while true {
            let cacheKey = ResponseCacheKey(request: request)
            if let cachedResponse = try await cachedResponseIfAvailable(
                cacheKey: cacheKey,
                request: request,
                configuration: configuration,
                context: context,
                bodySource: bodySource,
                runtime: runtime,
                originalRequestID: requestID
            ) {
                return cachedResponse
            }

            let revalidation = try await prepareConditionalCacheHeaders(
                request: &request,
                cacheKey: cacheKey,
                configuration: configuration
            )

            let networkResponse = try await performTransport(
                request: request,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                requestID: requestID
            )

            if let substitution = try await convertNotModifiedIfNeeded(
                networkResponse,
                cacheKey: cacheKey,
                request: request,
                configuration: configuration,
                revalidation: revalidation
            ) {
                if notModifiedRevisesVary(
                    cached: substitution.cached,
                    notModifiedHeaders: networkResponse.response?.allHeaderFields
                ) {
                    try enforceResponseBodyLimit(substitution.preservedResponse, configuration: configuration)
                    // The 304 advertises a different Vary dimension than the
                    // stored entry was keyed on. Rewriting with the new
                    // snapshot would silently move the entry to a different
                    // dimension; refresh `storedAt` instead so the freshness
                    // window reflects the successful revalidation while the
                    // stored representation remains addressable through its
                    // original Vary signature.
                    await refreshCachedFreshness(
                        cached: substitution.cached,
                        cacheKey: cacheKey,
                        configuration: configuration
                    )
                    return substitution.preservedResponse
                } else {
                    try enforceResponseBodyLimit(substitution.mergedResponse, configuration: configuration)
                    await storeCacheIfNeeded(
                        substitution.mergedResponse,
                        cacheKey: cacheKey,
                        request: request,
                        configuration: configuration
                    )
                    return substitution.mergedResponse
                }
            }

            if let refreshCoordinator = runtime.refreshCoordinator,
                await refreshCoordinator.shouldRefresh(statusCode: networkResponse.statusCode, request: request),
                !replayedAfterRefresh
            {
                // Replay from the fully adapted request so session and
                // endpoint interceptors keep their headers/signatures while
                // the auth policy replaces only the Authorization value.
                request = try await refreshCoordinator.refreshAndApply(to: adaptedRequest)
                replayedAfterRefresh = true
                continue
            }

            // Enforced before the response cache is written so an oversize
            // body cannot poison subsequent GETs that would replay it from
            // cache. The check is controlled by responseBodyBufferingPolicy;
            // nil keeps collection unbounded while still using the selected
            // streaming or buffered transport path.
            try enforceResponseBodyLimit(networkResponse, configuration: configuration)
            await storeCacheIfNeeded(
                networkResponse, cacheKey: cacheKey, request: request, configuration: configuration)
            return networkResponse
        }
    }

    func executeCustomPolicies(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Response {
        let eventHub = self.eventHub
        let baseNext = RequestExecutionNext { nextRequest in
            let result = try await performTransportResult(
                request: nextRequest,
                bodySource: bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime
            )
            await eventHub.publish(
                .responseReceived(
                    requestID: requestID,
                    statusCode: result.response.statusCode,
                    byteCount: result.data.count
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )
            return Response(
                statusCode: result.response.statusCode,
                data: result.data,
                request: nextRequest,
                response: result.response
            )
        }

        let policyContext = RequestExecutionContext(
            requestID: requestID,
            retryIndex: context.retryIndex,
            metricsReporter: context.metricsReporter,
            trustPolicy: context.trustPolicy,
            eventObservers: context.eventObservers
        )

        let chain = configuration.customExecutionPolicies.reversed().reduce(baseNext) { next, policy in
            RequestExecutionNext { nextRequest in
                try await policy.execute(
                    input: RequestExecutionInput(
                        request: nextRequest,
                        requestID: requestID,
                        retryIndex: context.retryIndex
                    ),
                    context: policyContext,
                    next: next
                )
            }
        }

        return try await chain.execute(request)
    }

    func refreshLaneIfInProgress(
        coordinator: RefreshTokenCoordinator?
    ) async -> UUID? {
        guard let coordinator else { return nil }
        return await coordinator.isRefreshInProgress ? UUID() : nil
    }
}

// MARK: - Event publication helpers
//
// Event publication shims that the executor pipeline calls into at
// stage boundaries (request-start, post-adaptation, terminal failure).

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
