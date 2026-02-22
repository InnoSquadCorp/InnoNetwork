//
//  URLSessionProtocol.swift
//  Network
//
//  Created by Chang Woo Son on 1/4/26.
//

import Foundation


public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func data(
        for request: URLRequest,
        metricsReporter: (any NetworkMetricsReporting)?
    ) async throws -> (Data, URLResponse)
}

public extension URLSessionProtocol {
    func data(
        for request: URLRequest,
        metricsReporter: (any NetworkMetricsReporting)?
    ) async throws -> (Data, URLResponse) {
        _ = metricsReporter
        return try await data(for: request)
    }
}

extension URLSession: URLSessionProtocol {
    public func data(
        for request: URLRequest,
        metricsReporter: (any NetworkMetricsReporting)?
    ) async throws -> (Data, URLResponse) {
        guard let metricsReporter else {
            return try await data(for: request)
        }

        let delegate = MetricsTaskDelegate(request: request, reporter: metricsReporter)
        return try await data(for: request, delegate: delegate)
    }
}
