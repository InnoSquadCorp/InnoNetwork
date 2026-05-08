import Foundation
import OSLog

// Cache lookup, conditional revalidation, Not-Modified merging,
// freshness refresh, and cache-storage helpers extracted from
// RequestExecutor.swift. Keep grouped here so the central
// pipeline file stays focused on dispatch / retry / transport.

struct NotModifiedSubstitution {
    let mergedResponse: Response
    let preservedResponse: Response
    let cached: CachedResponse
}


extension RequestExecutor {
    func cachedResponseIfAvailable(
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration,
        context: NetworkRequestContext,
        bodySource: BodySource,
        runtime: RequestExecutionRuntime,
        originalRequestID: UUID
    ) async throws -> Response? {
        guard let cacheKey,
            request.httpMethod?.uppercased() == "GET",
            let cache = configuration.responseCache,
            configuration.responseCachePolicy.allowsCacheRead
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
            let eventHub = self.eventHub
            let revalidationTask = Task {
                await startGate.wait()
                defer {
                    runtime.inFlight.deregister(id: revalidationID)
                }
                var revalidationStartedAt: Date?
                let observers = context.eventObservers
                await eventHub.publish(
                    .cacheRevalidation(originalID: originalRequestID, state: .scheduled),
                    requestID: revalidationID,
                    observers: observers
                )

                do {
                    try Task.checkCancellation()

                    var revalidationRequest = request
                    if let etag = cached.etag {
                        revalidationRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
                    }

                    revalidationStartedAt = Date()
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
                    let terminalState: CacheRevalidationState
                    if let substitution = await convertNotModifiedIfNeeded(
                        response,
                        cacheKey: cacheKey,
                        request: revalidationRequest,
                        configuration: configuration
                    ) {
                        try Task.checkCancellation()
                        if notModifiedRevisesVary(
                            cached: substitution.cached,
                            notModifiedHeaders: result.response.allHeaderFields
                        ) {
                            try enforceResponseBodyLimit(
                                substitution.preservedResponse,
                                configuration: configuration
                            )
                            await refreshCachedFreshness(
                                cached: substitution.cached,
                                cacheKey: cacheKey,
                                configuration: configuration
                            )
                        } else {
                            try enforceResponseBodyLimit(
                                substitution.mergedResponse,
                                configuration: configuration
                            )
                            await storeCacheIfNeeded(
                                substitution.mergedResponse,
                                cacheKey: cacheKey,
                                request: revalidationRequest,
                                configuration: configuration
                            )
                        }
                        terminalState = .notModified
                    } else {
                        try Task.checkCancellation()
                        try enforceResponseBodyLimit(response, configuration: configuration)
                        await storeCacheIfNeeded(
                            response, cacheKey: cacheKey, request: revalidationRequest, configuration: configuration)
                        terminalState = .completed(statusCode: result.response.statusCode)
                    }
                    await eventHub.publish(
                        .cacheRevalidation(originalID: originalRequestID, state: terminalState),
                        requestID: revalidationID,
                        observers: observers
                    )
                } catch {
                    if !NetworkError.isCancellation(error) {
                        let mapped = Self.mapTransportError(
                            error,
                            startedAt: revalidationStartedAt
                        )
                        let surfaced =
                            configuration.captureFailurePayload ? mapped : mapped.redactingFailurePayload()
                        Logger.API.error(
                            "Background revalidation failed: \(surfaced.localizedDescription, privacy: .public)"
                        )
                        await eventHub.publish(
                            .cacheRevalidation(
                                originalID: originalRequestID,
                                state: .failed(
                                    errorCode: surfaced.errorCode,
                                    message: surfaced.localizedDescription
                                )
                            ),
                            requestID: revalidationID,
                            observers: observers
                        )
                    }
                }
                await eventHub.finish(requestID: revalidationID)
            }
            revalidationHandle.attach(revalidationTask)
            startGate.open()
            return staleResponse
        }
    }

    func revalidateInBackground(
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
            eventObservers: context.eventObservers,
            redirectPolicy: context.redirectPolicy
        )
        return try await performTransportResult(
            request: request,
            bodySource: bodySource,
            configuration: configuration,
            context: revalidationContext,
            runtime: runtime
        )
    }

    func prepareConditionalCacheHeaders(
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

    func convertNotModifiedIfNeeded(
        _ response: Response,
        cacheKey: ResponseCacheKey?,
        request: URLRequest,
        configuration: NetworkConfiguration
    ) async -> NotModifiedSubstitution? {
        guard response.statusCode == 304,
            configuration.responseCachePolicy.allowsConditionalRevalidation,
            let cacheKey,
            let cache = configuration.responseCache,
            let cached = await cachedRespectingVary(cache, key: cacheKey, request: request),
            let url = request.url,
            let preservedHTTPResponse = cached.response(for: request),
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: cached.statusCode,
                httpVersion: nil,
                headerFields: mergedCachedHeaders(cached.headers, notModifiedResponse: response.response)
            )
        else {
            return nil
        }
        return NotModifiedSubstitution(
            mergedResponse: Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: httpResponse
            ),
            preservedResponse: Response(
                statusCode: cached.statusCode,
                data: cached.data,
                request: request,
                response: preservedHTTPResponse
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
    func refreshCachedFreshness(
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

    func mergedCachedHeaders(
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
    /// `Cache-Control: no-store` / `private` / `no-cache` without changing the
    /// explicit `ResponseCachePolicy` freshness window selected by the caller.
    func storeCacheIfNeeded(
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
        if cacheControl.contains("no-store") || cacheControl.contains("private") {
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

    /// Parses Cache-Control directive *names* only. Quoted-string aware
    /// (RFC 9110 §5.6.4) so qualified directives like
    /// `private="X-Foo, X-Bar"` are not shredded into spurious tokens.
    func cacheControlDirectives(in headers: [String: String]) -> Set<String> {
        let combined =
            headers
            .filter { $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame }
            .map { $0.value }
            .joined(separator: ",")
        guard !combined.isEmpty else { return [] }
        return Set(
            HTTPListParser.split(combined)
                .map(HTTPListParser.directiveName(of:))
                .filter { !$0.isEmpty }
        )
    }

    /// Returns the cached entry for `key` only when its stored vary snapshot
    /// matches `request`. Skips the result silently otherwise so the executor
    /// falls through to a fresh transport hit.
    func cachedRespectingVary(
        _ cache: any ResponseCache,
        key: ResponseCacheKey,
        request: URLRequest
    ) async -> CachedResponse? {
        guard let cached = await cache.get(key) else { return nil }
        return cachedResponseMatchesVary(cached, request: request) ? cached : nil
    }

}
