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
    /// ``NetworkError/invalidRequestConfiguration(_:)`` so streaming-aware
    /// callers see a clear error instead of a confusing fallback to a
    /// buffered response.
    func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    )
    /// Uploads the contents of `fileURL` for the given request without
    /// loading the file into memory. Used by ``RequestPayload/fileURL(_:contentType:)``
    /// payloads (typically multipart bodies spooled with
    /// ``MultipartFormData/writeEncodedData(to:)``).
    ///
    /// The default extension throws
    /// ``NetworkError/invalidRequestConfiguration(_:)`` so non-streaming
    /// stubs do not need to provide an upload path.
    func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (
        Data, URLResponse
    )
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
        throw NetworkError.invalidRequestConfiguration(
            "Streaming bytes are not supported by this URLSessionProtocol implementation."
        )
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (
        Data, URLResponse
    ) {
        _ = (request, fileURL, context)
        throw NetworkError.invalidRequestConfiguration(
            "File-based upload is not supported by this URLSessionProtocol implementation."
        )
    }
}

extension URLSession: URLSessionProtocol {
    public func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        if context.metricsReporter == nil,
           context.trustPolicy.isSystemDefault,
           context.redirectPolicy is DefaultRedirectPolicy {
            return try await data(for: request)
        }

        let delegate = RequestTaskDelegate(request: request, context: context)
        do {
            return try await data(for: request, delegate: delegate)
        } catch {
            if let trustFailureReason = delegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            throw error
        }
    }

    public func bytes(for request: URLRequest, context: NetworkRequestContext) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        if context.metricsReporter == nil,
           context.trustPolicy.isSystemDefault,
           context.redirectPolicy is DefaultRedirectPolicy {
            return try await bytes(for: request, delegate: nil)
        }

        let delegate = RequestTaskDelegate(request: request, context: context)
        do {
            return try await bytes(for: request, delegate: delegate)
        } catch {
            if let trustFailureReason = delegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            throw error
        }
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (
        Data, URLResponse
    ) {
        if context.metricsReporter == nil,
           context.trustPolicy.isSystemDefault,
           context.redirectPolicy is DefaultRedirectPolicy {
            return try await upload(for: request, fromFile: fileURL)
        }

        let delegate = RequestTaskDelegate(request: request, context: context)
        do {
            return try await upload(for: request, fromFile: fileURL, delegate: delegate)
        } catch {
            if let trustFailureReason = delegate.trustFailureReason {
                throw TrustEvaluationError.failed(trustFailureReason, error)
            }
            throw error
        }
    }
}


private final class RequestTaskDelegate: NSObject, URLSessionTaskDelegate {
    private let request: URLRequest
    private let context: NetworkRequestContext
    private let trustFailureReasonLock = OSAllocatedUnfairLock<TrustFailureReason?>(initialState: nil)

    init(request: URLRequest, context: NetworkRequestContext) {
        self.request = request
        self.context = context
    }

    var trustFailureReason: TrustFailureReason? {
        trustFailureReasonLock.withLock { $0 }
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
        let policy = context.redirectPolicy
        let originalRequest = request
        let handler = UncheckedSendableBox(completionHandler)
        Task {
            let result = await policy.redirect(
                request: newRequest,
                response: response,
                originalRequest: originalRequest
            )
            handler.value(result)
        }
    }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
