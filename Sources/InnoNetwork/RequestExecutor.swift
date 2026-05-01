import Foundation
import OSLog

package struct RequestExecutor {
    private let session: URLSessionProtocol
    private let eventHub: NetworkEventHub

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
        do {
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
                eventObservers: configuration.eventObservers
            )

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
            let mapped = NetworkError.mapTransportError(error)
            let surfaced = configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
            executable.logger.log(error: surfaced)
            await notifyFailure(surfaced, requestID: requestID, configuration: configuration)
            throw RequestExecutionFailure(error: surfaced, request: retryRequest ?? surfaced.underlyingRequest)
        }
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
                runtime: runtime
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
                try enforceResponseBodyLimit(substitution.response, configuration: configuration)
                if notModifiedRevisesVary(
                    cached: substitution.cached,
                    notModifiedHeaders: networkResponse.response?.allHeaderFields
                ) {
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
                } else {
                    await storeCacheIfNeeded(
                        substitution.response,
                        cacheKey: cacheKey,
                        request: request,
                        configuration: configuration
                    )
                }
                return substitution.response
            }

            if let refreshCoordinator = runtime.refreshCoordinator,
                await refreshCoordinator.shouldRefresh(statusCode: networkResponse.statusCode),
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
            // cache. The check is opt-in via `responseBodyLimit`; nil keeps
            // the prior unbounded behaviour.
            try enforceResponseBodyLimit(networkResponse, configuration: configuration)
            await storeCacheIfNeeded(
                networkResponse, cacheKey: cacheKey, request: request, configuration: configuration)
            return networkResponse
        }
    }

    private func enforceResponseBodyLimit(
        _ response: Response,
        configuration: NetworkConfiguration
    ) throws {
        try enforceResponseBodyLimit(data: response.data, configuration: configuration)
    }

    private func enforceResponseBodyLimit(
        data: Data,
        configuration: NetworkConfiguration
    ) throws {
        guard let limit = configuration.responseBodyLimit else { return }
        let observed = Int64(data.count)
        if observed > limit {
            throw NetworkError.responseTooLarge(limit: limit, observed: observed)
        }
    }

    private func performTransport(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        requestID: UUID
    ) async throws -> Response {
        let result = try await performTransportResult(
            request: request,
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
            request: request,
            response: result.response
        )
    }

    private func performTransportResult(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime
    ) async throws -> TransportResult {
        try await runtime.circuitBreakers.prepare(request: request, policy: configuration.circuitBreakerPolicy)

        if case .inline = bodySource,
            let key = RequestDedupKey(request: request, policy: configuration.requestCoalescingPolicy)
        {
            return try await runtime.requestCoalescer.run(key: key) {
                try await self.transportAndRecordCircuit(
                    request: request,
                    bodySource: bodySource,
                    context: context,
                    runtime: runtime,
                    policy: configuration.circuitBreakerPolicy
                )
            }
        }

        return try await transportAndRecordCircuit(
            request: request,
            bodySource: bodySource,
            context: context,
            runtime: runtime,
            policy: configuration.circuitBreakerPolicy
        )
    }

    private func transportAndRecordCircuit(
        request: URLRequest,
        bodySource: BodySource,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime,
        policy: CircuitBreakerPolicy?
    ) async throws -> TransportResult {
        do {
            let result = try await transport(request: request, bodySource: bodySource, context: context)
            await runtime.circuitBreakers.recordStatus(
                request: request,
                policy: policy,
                statusCode: result.response.statusCode
            )
            return result
        } catch {
            if NetworkError.isCancellation(error) {
                await runtime.circuitBreakers.recordCancellation(request: request, policy: policy)
            } else {
                await runtime.circuitBreakers.recordFailure(
                    request: request,
                    policy: policy,
                    error: error
                )
            }
            throw error
        }
    }

    private func transport(
        request: URLRequest,
        bodySource: BodySource,
        context: NetworkRequestContext
    ) async throws -> TransportResult {
        let (data, response): (Data, URLResponse)
        switch bodySource {
        case .inline:
            (data, response) = try await session.data(for: request, context: context)
        case .file(let fileURL, _):
            (data, response) = try await session.upload(for: request, fromFile: fileURL, context: context)
        }

        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.nonHTTPResponse(response)
        }
        return TransportResult(data: data, response: httpResponse)
    }

    private func cachedResponseIfAvailable(
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        bodySource: BodySource,
        runtime: RequestExecutionRuntime
    ) async throws -> Response? {
        guard let cacheKey,
            request.httpMethod?.uppercased() == "GET",
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.isEnabled
        else {
            return nil
        }

        let cached = await cachedRespectingVary(cache, key: cacheKey, request: request)
        switch configuration.responseCachePolicy.prepare(cached: cached) {
        case .bypass, .revalidate:
            return nil
        case .returnCached(let cached):
            guard let httpResponse = cached.response(for: request) else { return nil }
            let response = Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            )
            try enforceResponseBodyLimit(response, configuration: configuration)
            return response
        case .returnStaleAndRevalidate(let cached):
            guard let httpResponse = cached.response(for: request) else { return nil }
            let staleResponse = Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            )
            try enforceResponseBodyLimit(staleResponse, configuration: configuration)

            let revalidationID = UUID()
            let startGate = TaskStartGate()
            let revalidationHandle = InFlightTaskHandle()
            runtime.inFlight.register(id: revalidationID) {
                revalidationHandle.cancel()
            }
            let revalidationTask = Task {
                await startGate.wait()
                defer {
                    runtime.inFlight.deregister(id: revalidationID)
                }

                do {
                    try Task.checkCancellation()

                    var revalidationRequest = request
                    if let etag = cached.etag {
                        revalidationRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
                    }

                    let result = try await revalidateInBackground(
                        request: revalidationRequest,
                        bodySource: bodySource,
                        configuration: configuration,
                        context: context,
                        runtime: runtime
                    )
                    try Task.checkCancellation()

                    let response = Response(
                        statusCode: result.response.statusCode,
                        data: result.data,
                        request: revalidationRequest,
                        response: result.response
                    )
                    if let substitution = await convertNotModifiedIfNeeded(
                        response,
                        cacheKey: cacheKey,
                        request: revalidationRequest,
                        configuration: configuration
                    ) {
                        try Task.checkCancellation()
                        try enforceResponseBodyLimit(substitution.response, configuration: configuration)
                        if notModifiedRevisesVary(
                            cached: substitution.cached,
                            notModifiedHeaders: result.response.allHeaderFields
                        ) {
                            await refreshCachedFreshness(
                                cached: substitution.cached,
                                cacheKey: cacheKey,
                                configuration: configuration
                            )
                        } else {
                            await storeCacheIfNeeded(
                                substitution.response,
                                cacheKey: cacheKey,
                                request: revalidationRequest,
                                configuration: configuration
                            )
                        }
                    } else {
                        try Task.checkCancellation()
                        try enforceResponseBodyLimit(response, configuration: configuration)
                        await storeCacheIfNeeded(
                            response, cacheKey: cacheKey, request: revalidationRequest, configuration: configuration)
                    }
                } catch {
                    if NetworkError.isCancellation(error) {
                        return
                    }
                    let mapped = NetworkError.mapTransportError(error)
                    let surfaced =
                        configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                    Logger.API.error(
                        "Background revalidation failed: \(surfaced.localizedDescription, privacy: .public)"
                    )
                    return
                }
            }
            revalidationHandle.attach(revalidationTask)
            startGate.open()
            return staleResponse
        }
    }

    private func revalidateInBackground(
        request: URLRequest,
        bodySource: BodySource,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        runtime: RequestExecutionRuntime
    ) async throws -> TransportResult {
        let revalidationContext = NetworkRequestContext(
            requestID: UUID(),
            retryIndex: context.retryIndex,
            metricsReporter: context.metricsReporter,
            trustPolicy: context.trustPolicy,
            eventObservers: context.eventObservers
        )
        return try await performTransportResult(
            request: request,
            bodySource: bodySource,
            configuration: configuration,
            context: revalidationContext,
            runtime: runtime
        )
    }

    private func prepareConditionalCacheHeaders(
        request: inout URLRequest,
        cacheKey: ResponseCacheKey?,
        configuration: NetworkConfiguration
    ) async throws {
        guard let cacheKey,
            request.httpMethod?.uppercased() == "GET",
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.isEnabled,
            configuration.responseCachePolicy.allowsConditionalRevalidation,
            let cached = await cachedRespectingVary(cache, key: cacheKey, request: request),
            let etag = cached.etag
        else {
            return
        }
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    private func convertNotModifiedIfNeeded(
        _ response: Response,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration
    ) async -> (response: Response, cached: CachedResponse)? {
        guard response.statusCode == 304,
            configuration.responseCachePolicy.allowsConditionalRevalidation,
            let cacheKey,
            let cache = configuration.responseCache,
            let cached = await cachedRespectingVary(cache, key: cacheKey, request: request),
            let url = request.url,
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: cached.statusCode,
                httpVersion: nil,
                headerFields: mergedCachedHeaders(cached.headers, notModifiedResponse: response.response)
            )
        else {
            return nil
        }
        return (
            response: Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            ),
            cached: cached
        )
    }

    /// Re-stores `cached` under `cacheKey` with a refreshed `storedAt`.
    ///
    /// Used on the 304 substitution path when the not-modified response
    /// advertises a different `Vary` dimension than the stored entry was
    /// keyed on. The stored representation, headers, and Vary snapshot are
    /// preserved verbatim; only the freshness timestamp moves forward so
    /// the entry honours the successful conditional revalidation without
    /// being silently rekeyed.
    private func refreshCachedFreshness(
        cached: CachedResponse,
        cacheKey: ResponseCacheKey?,
        configuration: NetworkConfiguration
    ) async {
        guard let cacheKey,
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheWrite
        else {
            return
        }
        await cache.set(
            cacheKey,
            CachedResponse(
                data: cached.data,
                statusCode: cached.statusCode,
                headers: cached.headers,
                storedAt: Date(),
                requiresRevalidation: cached.requiresRevalidation,
                varyHeaders: cached.varyHeaders
            )
        )
    }

    private func mergedCachedHeaders(
        _ cachedHeaders: [String: String],
        notModifiedResponse: HTTPURLResponse?
    ) -> [String: String] {
        var headers = cachedHeaders
        guard let notModifiedResponse else { return headers }

        for pair in notModifiedResponse.allHeaderFields {
            guard let key = pair.key as? String else { continue }
            let value = pair.value as? String ?? String(describing: pair.value)
            if let existingKey = headers.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                headers.removeValue(forKey: existingKey)
            }
            headers[key] = value
        }
        return headers
    }

    /// Stores the response in cache when the policy allows writes.
    ///
    /// Only GET responses are persisted. InnoNetwork stores the RFC-cacheable
    /// status codes that are safe for whole-response reuse and honours
    /// `Cache-Control: no-store` / `no-cache` without changing the explicit
    /// `ResponseCachePolicy` freshness window selected by the caller.
    private func storeCacheIfNeeded(
        _ response: Response,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration
    ) async {
        guard let cacheKey,
            request.httpMethod?.uppercased() == "GET",
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheWrite
        else {
            return
        }
        let headerSnapshot =
            response.response?.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                guard let key = pair.key as? String, let value = pair.value as? String else { return }
                result[key] = value
            } ?? [:]
        guard Self.cacheableStatusCodes.contains(response.statusCode) else {
            return
        }
        let cacheControl = cacheControlDirectives(in: headerSnapshot)
        if cacheControl.contains("no-store") {
            await cache.invalidate(cacheKey)
            return
        }
        let varyHeaders: [String: String?]?
        switch evaluateVary(responseHeaders: headerSnapshot, request: request) {
        case .wildcardSkipsCache:
            return
        case .noVary:
            varyHeaders = nil
        case .vary(let snapshot):
            varyHeaders = snapshot
        }
        await cache.set(
            cacheKey,
            CachedResponse(
                data: response.data,
                statusCode: response.statusCode,
                headers: headerSnapshot,
                requiresRevalidation: cacheControl.contains("no-cache"),
                varyHeaders: varyHeaders
            )
        )
    }

    /// Status codes that are cacheable by default per RFC 9110 §15. `307`
    /// (Temporary Redirect) is intentionally omitted — RFC 9110 marks it as
    /// not cacheable by default, so caching it would silently change observed
    /// redirect behaviour.
    private static let cacheableStatusCodes: Set<Int> = [
        200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501,
    ]

    /// Parses Cache-Control directive *names* only. Qualified directives whose
    /// quoted values contain commas (e.g. `private="X-Foo, X-Bar"`) will split
    /// into multiple tokens, so this helper must not be used to recover such
    /// values — it only powers the `no-store` / `no-cache` lookups today.
    private func cacheControlDirectives(in headers: [String: String]) -> Set<String> {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else { return [] }
        return Set(
            combined
                .split(separator: ",")
                .map { directive in
                    directive
                        .split(separator: "=", maxSplits: 1)
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() ?? ""
                }
                .filter { !$0.isEmpty }
        )
    }

    /// Returns the cached entry for `key` only when its stored vary snapshot
    /// matches `request`. Skips the result silently otherwise so the executor
    /// falls through to a fresh transport hit.
    private func cachedRespectingVary(
        _ cache: any ResponseCache,
        key: ResponseCacheKey,
        request: URLRequest
    ) async -> CachedResponse? {
        guard let cached = await cache.get(key) else { return nil }
        return cachedResponseMatchesVary(cached, request: request) ? cached : nil
    }

    private func notifyRequestStart(
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

    private func notifyRequestAdapted(
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

    private func notifyFailure(
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
