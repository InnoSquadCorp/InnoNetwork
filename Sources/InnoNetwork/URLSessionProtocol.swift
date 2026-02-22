//
//  URLSessionProtocol.swift
//  Network
//
//  Created by Chang Woo Son on 1/4/26.
//

import Foundation


public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse)
}

public extension URLSessionProtocol {
    func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        _ = context
        return try await data(for: request)
    }
}

extension URLSession: URLSessionProtocol {
    public func data(for request: URLRequest, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        if context.metricsReporter == nil, context.trustPolicy.isSystemDefault {
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
}


private final class RequestTaskDelegate: NSObject, URLSessionTaskDelegate {
    private let request: URLRequest
    private let context: NetworkRequestContext
    private let lock = NSLock()
    private var _trustFailureReason: TrustFailureReason?

    init(request: URLRequest, context: NetworkRequestContext) {
        self.request = request
        self.context = context
    }

    var trustFailureReason: TrustFailureReason? {
        lock.lock()
        defer { lock.unlock() }
        return _trustFailureReason
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
            lock.lock()
            _trustFailureReason = reason
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
