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
        let delegate = RequestTaskDelegate(request: request, context: context)
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
        let delegate = RequestTaskDelegate(request: request, context: context)
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
        let delegate = RequestTaskDelegate(request: request, context: context)
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

extension URLSession: BoundedFileUploadSession {
    package func bytes(
        for request: URLRequest,
        uploadingFileAt fileURL: URL,
        context: NetworkRequestContext
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try validateRedirectControllableSession()
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
        let delegate = RequestTaskDelegate(
            request: request,
            context: context,
            uploadBodyFileURL: fileURL
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
    private let trustFailureReasonLock = OSAllocatedUnfairLock<TrustFailureReason?>(initialState: nil)
    private let redirectFailureLock = OSAllocatedUnfairLock<NetworkError?>(initialState: nil)

    init(request: URLRequest, context: NetworkRequestContext, uploadBodyFileURL: URL? = nil) {
        self.request = request
        self.context = context
        self.uploadBodyFileURL = uploadBodyFileURL
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
            let result = policy.redirect(
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
