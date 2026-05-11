import Foundation
import OSLog

/// Conditional revalidation product used by the cache stage when a 304 is
/// received. Carries both a merged-headers `Response` (for storage when the
/// `Vary` dimension matches) and a preserved-headers `Response` (for return
/// when the `Vary` dimension changes), plus the original cached entry.
struct NotModifiedSubstitution {
    let mergedResponse: Response
    let preservedResponse: Response
    let cached: CachedResponse
}

/// Cached snapshot that produced conditional request headers for the
/// transport attempt. A later 304 is valid only while this entry still
/// exists; otherwise the executor has no representation to substitute.
struct ConditionalRevalidationContext {
    let cached: CachedResponse
}

/// Per-request execution coordinator.
///
/// The struct itself only owns the URLSession transport and event hub
/// references plus the `execute(...)` entrypoint. The rest of the pipeline
/// — auth-scope validation, the cache stage, the transport stage, the
/// custom-policy chain, and the event-publication shims — lives in three
/// adjacent extension files (`RequestExecutor+Pipeline.swift`,
/// `RequestExecutor+Cache.swift`, `RequestExecutor+Transport.swift`).
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

            attemptStartedAt = runtime.clock.now()
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
}
