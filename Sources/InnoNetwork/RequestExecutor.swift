import Foundation
import OSLog


package struct RequestExecutor {
    let session: URLSessionProtocol
    let eventHub: NetworkEventHub

    package init(session: URLSessionProtocol, eventHub: NetworkEventHub) {
        self.session = session
        self.eventHub = eventHub
    }

    package func execute<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration,
        requestBuilder: RequestBuilder,
        runtime: RequestExecutionRuntime,
        retryIndex: Int,
        requestID: UUID
    ) async throws -> D.APIResponse {
        try Task.checkCancellation()

        var retryRequest: URLRequest?
        var attemptStartedAt: Date?
        do {
            try validateAuthScope(executable, configuration: configuration)
            let built = try requestBuilder.build(executable, configuration: configuration)
            var request = built.request
            let cleanupFileURL: URL?
            if case .file(let fileURL, cleanupAfterUse: true) = built.bodySource {
                cleanupFileURL = fileURL
            } else {
                cleanupFileURL = nil
            }
            defer {
                if let cleanupFileURL {
                    try? FileManager.default.removeItem(at: cleanupFileURL)
                }
            }
            configuration.idempotencyKeyPolicy.apply(to: &request, requestID: requestID)
            await notifyRequestStart(
                request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            // Onion model: session-level interceptors run first (outer), then
            // per-request interceptors (inner). Cross-cutting concerns
            // declared on NetworkConfiguration apply to every endpoint;
            // per-APIDefinition interceptors layer on top.
            for interceptor in configuration.requestInterceptors {
                request = try await interceptor.adapt(request)
            }
            for interceptor in executable.requestInterceptors {
                request = try await interceptor.adapt(request)
            }
            if let refreshCoordinator = runtime.refreshCoordinator {
                request = try await refreshCoordinator.applyCurrentToken(to: request)
            }
            retryRequest = request
            await notifyRequestAdapted(
                request, retryIndex: retryIndex, requestID: requestID, configuration: configuration)

            executable.logger.log(request: request)

            let context = NetworkRequestContext(
                requestID: requestID,
                retryIndex: retryIndex,
                metricsReporter: configuration.metricsReporter,
                trustPolicy: configuration.trustPolicy,
                eventObservers: configuration.eventObservers,
                redirectPolicy: configuration.redirectPolicy
            )

            attemptStartedAt = Date()
            var networkResponse = try await executeWithPolicies(
                request: request,
                bodySource: built.bodySource,
                configuration: configuration,
                context: context,
                runtime: runtime,
                requestID: requestID
            )

            // Onion unwinds inner→outer: per-request interceptors first,
            // session-level interceptors last. A session-level response
            // interceptor sees the same response a session-only setup would
            // produce because per-endpoint adapters have already finished.
            for interceptor in executable.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: request)
            }
            for interceptor in configuration.responseInterceptors {
                networkResponse = try await interceptor.adapt(networkResponse, request: request)
            }
            // After response interceptors settle, give cancellation a chance
            // to short-circuit before we spend cycles on body-limit checks,
            // decode, and didDecode chains.
            try Task.checkCancellation()
            try enforceResponseBodyLimit(networkResponse, configuration: configuration)

            // Per-endpoint override wins over the session-wide configuration
            // when present. Lets one definition treat e.g. 304 as success
            // without changing the default for the rest of the client.
            let acceptable = executable.acceptableStatusCodes ?? configuration.acceptableStatusCodes
            guard acceptable.contains(networkResponse.statusCode) else {
                throw NetworkError.statusCode(networkResponse)
            }

            executable.logger.log(response: networkResponse, isError: false)
            await eventHub.publish(
                .requestFinished(
                    requestID: requestID,
                    statusCode: networkResponse.statusCode,
                    byteCount: networkResponse.data.count
                ),
                requestID: requestID,
                observers: configuration.eventObservers
            )

            // willDecode runs after response interceptors have settled
            // so adapters that mutate the response (envelope rewriting,
            // header-driven sanitization) observe the same payload the
            // decoder will see. Interceptors fire in declaration order.
            var decodableData = networkResponse.data
            for interceptor in configuration.decodingInterceptors {
                decodableData = try await interceptor.willDecode(
                    data: decodableData,
                    response: networkResponse
                )
            }
            try enforceResponseBodyLimit(data: decodableData, configuration: configuration)

            // Synchronous decode can block for several ms on large payloads;
            // the surrounding async machinery would not check cancellation
            // again until didDecode runs, so insert a checkpoint here.
            try Task.checkCancellation()
            var decoded = try executable.decode(data: decodableData, response: networkResponse)
            for interceptor in configuration.decodingInterceptors {
                decoded = try await interceptor.didDecode(decoded, response: networkResponse)
            }
            return decoded
        } catch let error as NetworkError {
            let surfaced = configuration.captureFailurePayload ? error : error.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            await notifyFailure(surfaced, requestID: requestID, configuration: configuration)
            throw RequestExecutionFailure(error: surfaced, request: retryRequest ?? surfaced.underlyingRequest)
        } catch {
            let mapped = Self.mapTransportError(
                error,
                startedAt: attemptStartedAt
            )
            let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            await notifyFailure(surfaced, requestID: requestID, configuration: configuration)
            throw RequestExecutionFailure(error: surfaced, request: retryRequest ?? surfaced.underlyingRequest)
        }
    }

    private func validateAuthScope<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration
    ) throws {
        guard executable.requiresRefreshTokenPolicy, configuration.refreshTokenPolicy == nil else {
            return
        }
        throw NetworkError.invalidRequestConfiguration(
            "Auth-required endpoints require NetworkConfiguration.refreshTokenPolicy."
        )
    }

    private func executeWithPolicies(
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

            try await prepareConditionalCacheHeaders(
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

            if let substitution = await convertNotModifiedIfNeeded(
                networkResponse,
                cacheKey: cacheKey,
                request: request,
                configuration: configuration
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

    func enforceResponseBodyLimit(
        _ response: Response,
        configuration: NetworkConfiguration
    ) throws {
        try enforceResponseBodyLimit(data: response.data, configuration: configuration)
    }

    func enforceResponseBodyLimit(
        data: Data,
        configuration: NetworkConfiguration
    ) throws {
        guard let limit = configuration.responseBodyBufferingPolicy.maxBytes else { return }
        let observed = Int64(data.count)
        if observed > limit {
            throw NetworkError.responseTooLarge(limit: limit, observed: observed)
        }
    }
}
