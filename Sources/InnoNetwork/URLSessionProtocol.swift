//
//  URLSessionProtocol.swift
//  Network
//
//  Created by Chang Woo Son on 1/4/26.
//

import Foundation
import os

public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse)
    /// Begins a streaming byte transfer for the given request and returns
    /// the associated `URLSession.AsyncBytes` plus the response metadata.
    ///
    /// Implementations that do not support streaming (typed test stubs,
    /// the instant in-memory benchmark mock, and so on) can leave the
    /// default extension in place — it throws
    /// ``NetworkError/configuration(reason:)`` with
    /// ``NetworkConfigurationFailureReason/invalidRequest(_:)`` so
    /// streaming-aware callers see a clear error instead of a confusing
    /// fallback to a buffered response.
    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    )
    /// Uploads the contents of `fileURL` for the given request without
    /// loading the file into memory. Used by ``RequestPayload/fileURL(_:contentType:)``
    /// payloads (typically multipart bodies spooled with
    /// ``MultipartFormData/writeEncodedData(to:)``).
    ///
    /// The default extension throws
    /// ``NetworkError/configuration(reason:)`` with
    /// ``NetworkConfigurationFailureReason/invalidRequest(_:)`` so
    /// non-streaming stubs do not need to provide an upload path.
    func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (
        Data, URLResponse
    )
}

/// Package-only capability for file uploads whose response body must be
/// bounded while it is being received. Keeping this separate from the public
/// ``URLSessionProtocol`` avoids expanding the consumer-facing mocking
/// surface: custom sessions either opt in inside this package, or fail closed
/// when a bounded file-upload response is requested.
package protocol BoundedFileUploadSession: URLSessionProtocol {
    func bytes(
        for request: URLRequest,
        uploadingFileAt fileURL: URL,
        context: NetworkRequestContext
    ) async throws -> (URLSession.AsyncBytes, URLResponse)
}

/// Package-only capability for deterministic first-party test sessions whose
/// current response already exists as in-memory `Data`. It lets the executor
/// preserve the public 5 MiB default for supported `InnoNetworkTestSupport`
/// modes without pretending that arbitrary consumer sessions can enforce a
/// bound before buffering. The normal post-transport body-limit checks remain
/// authoritative for these test doubles.
package protocol BoundedBufferedTestSession: URLSessionProtocol {
    var allowsBoundedBufferedFallback: Bool { get }
}

/// Package-only capability for chunk-granular streaming collection.
///
/// `URLSession.AsyncBytes` vends one byte per `next()` call, and each call
/// crosses Foundation's resilience boundary — measured at well under
/// 1 MiB/s, which made the default `.streaming` buffering policy pay a
/// four-orders-of-magnitude collection penalty against `data(for:)`.
/// Sessions that can deliver the response body as `Data` chunks (one await
/// per transport chunk) conform here; the executor prefers this path and
/// falls back to the byte-wise `bytes(for:context:)` seam for custom
/// consumer sessions.
package protocol ChunkedTransferSession: URLSessionProtocol {
    /// Starts the request and resumes once response metadata is available.
    ///
    /// `maxBytes` is enforced incrementally inside the transport bridge:
    /// the underlying task is cancelled and the chunk stream finishes with
    /// ``NetworkErrorCode/responseBodyLimitExceeded`` as soon as the
    /// received byte count crosses the ceiling, so buffered memory stays
    /// bounded regardless of consumer pacing.
    func chunkedTransfer(
        for request: URLRequest,
        context: NetworkRequestContext,
        maxBytes: Int64?
    ) async throws -> ChunkedTransfer

    /// Chunked twin of ``BoundedFileUploadSession/bytes(for:uploadingFileAt:context:)``:
    /// streams the file body without loading it into memory and delivers the
    /// response as bounded `Data` chunks.
    func chunkedTransfer(
        for request: URLRequest,
        uploadingFileAt fileURL: URL,
        context: NetworkRequestContext,
        maxBytes: Int64?
    ) async throws -> ChunkedTransfer
}

/// Response metadata plus the chunk stream produced by a
/// ``ChunkedTransferSession``.
package struct ChunkedTransfer: Sendable {
    package let response: URLResponse
    /// The task's `currentRequest` snapshot at response time — the
    /// post-redirect request whose method governs body semantics.
    package let finalRequest: URLRequest?
    package let chunks: AsyncThrowingStream<Data, Error>
    /// Stops the underlying transport task. Abandoning the chunk stream is
    /// not a documented cancellation boundary, so failure paths call this
    /// explicitly (mirroring the `bytes.task.cancel()` contract).
    package let cancel: @Sendable () -> Void
}

public extension URLSessionProtocol {
    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        _ = context
        return try await data(for: request)
    }

    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        _ = (request, context)
        throw NetworkError.configuration(
            reason: .invalidRequest("Streaming bytes are not supported by this URLSessionProtocol implementation."))
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (
        Data, URLResponse
    ) {
        _ = (request, fileURL, context)
        throw NetworkError.configuration(
            reason: .invalidRequest("File-based upload is not supported by this URLSessionProtocol implementation."))
    }
}

extension URLSession: URLSessionProtocol {
    public func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        try validateRedirectControllableSession()
        // Always install the delegate so the configured ``RedirectPolicy``
        // can enforce downgrade, unsafe replay, and sensitive-header
        // boundaries. URLSession's native redirect handling does not apply
        // our policy.
        let delegate = RequestTaskDelegate(
            request: request,
            context: context,
            sessionHeaderNames: redirectSensitiveSessionHeaderNames
        )
        do {
            let result = try await data(for: request, delegate: delegate)
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            return result
        } catch {
            if let trustFailureReason = delegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            throw error
        }
    }

    public func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        try validateRedirectControllableSession()
        let delegate = RequestTaskDelegate(
            request: request,
            context: context,
            sessionHeaderNames: redirectSensitiveSessionHeaderNames
        )
        do {
            let result = try await bytes(for: request, delegate: delegate)
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            return result
        } catch {
            if let trustFailureReason = delegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            throw error
        }
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (
        Data, URLResponse
    ) {
        try validateRedirectControllableSession()
        let delegate = RequestTaskDelegate(
            request: request,
            context: context,
            sessionHeaderNames: redirectSensitiveSessionHeaderNames
        )
        do {
            let result = try await upload(for: request, fromFile: fileURL, delegate: delegate)
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            return result
        } catch {
            if let trustFailureReason = delegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            throw error
        }
    }
}

extension URLSession {
    /// Prepares the streamed-body request shape shared by the byte-wise and
    /// chunked bounded file-upload paths: validates caller framing headers
    /// against the immutable file snapshot and installs the body stream.
    fileprivate func makeFileUploadStreamingRequest(
        from request: URLRequest,
        uploadingFileAt fileURL: URL
    ) throws -> URLRequest {
        var streamingRequest = request
        streamingRequest.httpBody = nil
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Unable to determine the file-based upload body length.")
            )
        }
        guard streamingRequest.value(forHTTPHeaderField: "Transfer-Encoding") == nil else {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "File-based uploads must not provide Transfer-Encoding; InnoNetwork owns request framing."
                )
            )
        }
        if let suppliedLength = streamingRequest.value(forHTTPHeaderField: "Content-Length") {
            let normalizedLength = suppliedLength.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCanonicalDecimal =
                !normalizedLength.isEmpty
                && normalizedLength.utf8.allSatisfy { byte in
                    byte >= 0x30 && byte <= 0x39
                }
            guard isCanonicalDecimal, Int64(normalizedLength) == fileSize else {
                throw NetworkError.configuration(
                    reason: .invalidRequest(
                        "File-based upload Content-Length must match the immutable upload snapshot size."
                    )
                )
            }
        }
        guard let bodyStream = InputStream(url: fileURL) else {
            throw NetworkError.configuration(
                reason: .invalidRequest("Unable to open the file-based upload body stream.")
            )
        }
        streamingRequest.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        streamingRequest.httpBodyStream = bodyStream
        return streamingRequest
    }
}

extension URLSession: BoundedFileUploadSession {
    package func bytes(
        for request: URLRequest,
        uploadingFileAt fileURL: URL,
        context: NetworkRequestContext
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try validateRedirectControllableSession()
        let streamingRequest = try makeFileUploadStreamingRequest(
            from: request,
            uploadingFileAt: fileURL
        )
        let delegate = RequestTaskDelegate(
            request: request,
            context: context,
            uploadBodyFileURL: fileURL,
            sessionHeaderNames: redirectSensitiveSessionHeaderNames
        )
        do {
            let result = try await bytes(for: streamingRequest, delegate: delegate)
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            return result
        } catch {
            if let trustFailureReason = delegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            if let redirectFailure = delegate.redirectFailure {
                throw redirectFailure
            }
            throw error
        }
    }
}

private extension URLSession {
    var redirectSensitiveSessionHeaderNames: Set<String> {
        Set(
            configuration.httpAdditionalHeaders?.keys.compactMap { key in
                key as? String
            } ?? []
        )
    }

    func validateRedirectControllableSession() throws {
        guard configuration.identifier == nil else {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "Background URLSession instances always follow redirects and cannot enforce InnoNetwork redirect admission. Use a default or ephemeral URLSession."
                )
            )
        }
    }
}


private final class RequestTaskDelegate: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let context: NetworkRequestContext
    private let uploadBodyFileURL: URL?
    private let sessionHeaderNames: Set<String>
    private let trustFailureReasonLock = OSAllocatedUnfairLock<TrustFailureReason?>(initialState: nil)
    private let redirectFailureLock = OSAllocatedUnfairLock<NetworkError?>(initialState: nil)

    init(
        request: URLRequest,
        context: NetworkRequestContext,
        uploadBodyFileURL: URL? = nil,
        sessionHeaderNames: Set<String>
    ) {
        self.request = request
        self.context = context
        self.uploadBodyFileURL = uploadBodyFileURL
        self.sessionHeaderNames = sessionHeaderNames
    }

    var trustFailureReason: TrustFailureReason? {
        trustFailureReasonLock.withLock { $0 }
    }

    var redirectFailure: NetworkError? {
        redirectFailureLock.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        context.metricsReporter?.report(metrics: metrics, for: request, response: task.response)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        guard let uploadBodyFileURL else {
            completionHandler(nil)
            return
        }
        completionHandler(InputStream(url: uploadBodyFileURL))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let disposition = TrustEvaluator.evaluate(challenge: challenge, policy: context.trustPolicy)
        switch disposition {
        case .performDefaultHandling:
            completionHandler(.performDefaultHandling, nil)
        case .useCredential(let credential):
            completionHandler(.useCredential, credential)
        case .cancel(let reason):
            trustFailureReasonLock.withLock { $0 = reason }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard context.allowsAutomaticRedirects else {
            completionHandler(nil)
            return
        }
        let policy = context.redirectPolicy
        let originalRequest = request
        guard
            var result = policy.redirect(
                request: newRequest,
                response: response,
                originalRequest: originalRequest
            )
        else {
            completionHandler(nil)
            return
        }
        do {
            try NetworkURLAdmission.validate(
                result,
                policy: .http(allowsInsecure: context.allowsInsecureHTTP)
            )
            if !DefaultRedirectPolicy.isSameOrigin(originalRequest.url, result.url) {
                // Foundation re-applies `httpAdditionalHeaders` after this
                // callback when a field is absent. An explicit empty value
                // prevents session-configured credentials from crossing an
                // origin boundary outside the redirect policy's control.
                for name in sessionHeaderNames {
                    result.setValue("", forHTTPHeaderField: name)
                }
            }
            completionHandler(result)
        } catch let error as NetworkError {
            redirectFailureLock.withLock { failure in
                if failure == nil {
                    failure = error
                }
            }
            completionHandler(nil)
        } catch {
            // NetworkURLAdmission currently throws only NetworkError. Keep the
            // callback total if that implementation changes in the future.
            redirectFailureLock.withLock { failure in
                if failure == nil {
                    failure = .configuration(
                        reason: .invalidRequest("Redirect target failed network URL admission.")
                    )
                }
            }
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(context.allowsURLCacheStorage ? proposedResponse : nil)
    }
}


extension URLSession: ChunkedTransferSession {
    package func chunkedTransfer(
        for request: URLRequest,
        context: NetworkRequestContext,
        maxBytes: Int64?
    ) async throws -> ChunkedTransfer {
        try validateRedirectControllableSession()
        let policyDelegate = RequestTaskDelegate(
            request: request,
            context: context,
            sessionHeaderNames: redirectSensitiveSessionHeaderNames
        )
        return try await runChunkedTransfer(
            transportRequest: request,
            policyDelegate: policyDelegate,
            maxBytes: maxBytes
        )
    }

    package func chunkedTransfer(
        for request: URLRequest,
        uploadingFileAt fileURL: URL,
        context: NetworkRequestContext,
        maxBytes: Int64?
    ) async throws -> ChunkedTransfer {
        try validateRedirectControllableSession()
        let streamingRequest = try makeFileUploadStreamingRequest(
            from: request,
            uploadingFileAt: fileURL
        )
        // `uploadBodyFileURL` lets the shared policy delegate replay the body
        // stream when Foundation asks for a new one (redirects, retries of
        // the transport handshake).
        let policyDelegate = RequestTaskDelegate(
            request: request,
            context: context,
            uploadBodyFileURL: fileURL,
            sessionHeaderNames: redirectSensitiveSessionHeaderNames
        )
        return try await runChunkedTransfer(
            transportRequest: streamingRequest,
            policyDelegate: policyDelegate,
            maxBytes: maxBytes
        )
    }

    private func runChunkedTransfer(
        transportRequest: URLRequest,
        policyDelegate: RequestTaskDelegate,
        maxBytes: Int64?
    ) async throws -> ChunkedTransfer {
        let bridge = ChunkedTransferBridge(
            forwardingPolicyCallbacksTo: policyDelegate,
            maxBytes: maxBytes
        )
        let task = dataTask(with: transportRequest)
        task.delegate = bridge
        do {
            let transfer = try await bridge.start(task: task)
            if let redirectFailure = policyDelegate.redirectFailure {
                task.cancel()
                throw redirectFailure
            }
            return transfer
        } catch {
            if let trustFailureReason = policyDelegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            if let redirectFailure = policyDelegate.redirectFailure {
                throw redirectFailure
            }
            throw error
        }
    }
}

/// Bridges a delegate-driven data task into a response continuation plus an
/// `AsyncThrowingStream<Data, Error>` of body chunks. Policy callbacks
/// (redirects, trust, metrics, caching, upload body streams) forward to the
/// shared ``RequestTaskDelegate`` so the chunked path enforces exactly the
/// same admission rules as the buffered and byte-wise paths.
private final class ChunkedTransferBridge: NSObject, URLSessionDataDelegate {
    private struct State {
        var responseContinuation: CheckedContinuation<(URLResponse, URLRequest?), Error>?
        var chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        var observedBytes: Int64 = 0
        var limitFinished = false
    }

    private let policyDelegate: RequestTaskDelegate
    private let maxBytes: Int64?
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(forwardingPolicyCallbacksTo policyDelegate: RequestTaskDelegate, maxBytes: Int64?) {
        self.policyDelegate = policyDelegate
        self.maxBytes = maxBytes
    }

    func start(task: URLSessionDataTask) async throws -> ChunkedTransfer {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation.onTermination = { [weak task] _ in
            task?.cancel()
        }
        state.withLock { $0.chunkContinuation = continuation }

        let (response, finalRequest) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (checked: CheckedContinuation<(URLResponse, URLRequest?), Error>) in
                state.withLock { $0.responseContinuation = checked }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        return ChunkedTransfer(
            response: response,
            finalRequest: finalRequest,
            chunks: stream,
            cancel: { [weak task] in task?.cancel() }
        )
    }

    // MARK: Data delivery

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let continuation = state.withLock { state -> CheckedContinuation<(URLResponse, URLRequest?), Error>? in
            let continuation = state.responseContinuation
            state.responseContinuation = nil
            return continuation
        }
        continuation?.resume(returning: (response, dataTask.currentRequest))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        enum Action {
            case yield(AsyncThrowingStream<Data, Error>.Continuation)
            case exceeded(AsyncThrowingStream<Data, Error>.Continuation, observed: Int64, limit: Int64)
            case drop
        }
        let action: Action = state.withLock { state in
            guard let continuation = state.chunkContinuation, !state.limitFinished else { return .drop }
            let (observed, overflowed) = state.observedBytes.addingReportingOverflow(Int64(data.count))
            guard !overflowed else {
                state.limitFinished = true
                return .exceeded(continuation, observed: .max, limit: maxBytes ?? .max)
            }
            state.observedBytes = observed
            if let maxBytes, observed > maxBytes {
                state.limitFinished = true
                return .exceeded(continuation, observed: observed, limit: maxBytes)
            }
            return .yield(continuation)
        }
        switch action {
        case .yield(let continuation):
            continuation.yield(data)
        case .exceeded(let continuation, let observed, let limit):
            // Cancel before finishing so the origin cannot keep streaming
            // into a stream nobody admits, then surface the same
            // fail-closed error the byte-wise collector produces.
            dataTask.cancel()
            continuation.finish(
                throwing: NetworkError.underlying(
                    SendableUnderlyingError(
                        domain: NetworkError.errorDomain,
                        code: NetworkErrorCode.responseBodyLimitExceeded.rawValue,
                        message:
                            "Response body of \(observed) bytes exceeded the configured limit of \(limit) bytes."
                    ),
                    nil
                )
            )
        case .drop:
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (responseContinuation, chunkContinuation) = state.withLock {
            state -> (
                CheckedContinuation<(URLResponse, URLRequest?), Error>?,
                AsyncThrowingStream<Data, Error>.Continuation?
            ) in
            let response = state.responseContinuation
            let chunks = state.limitFinished ? nil : state.chunkContinuation
            state.responseContinuation = nil
            state.chunkContinuation = nil
            return (response, chunks)
        }
        if let responseContinuation {
            responseContinuation.resume(
                throwing: error ?? URLError(.badServerResponse)
            )
        }
        if let chunkContinuation {
            if let error {
                chunkContinuation.finish(throwing: error)
            } else {
                chunkContinuation.finish()
            }
        }
    }

    // MARK: Policy forwarding

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        policyDelegate.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        policyDelegate.urlSession(session, task: task, needNewBodyStream: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        policyDelegate.urlSession(
            session,
            task: task,
            didReceive: challenge,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        policyDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: newRequest,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        policyDelegate.urlSession(
            session,
            dataTask: dataTask,
            willCacheResponse: proposedResponse,
            completionHandler: completionHandler
        )
    }
}
