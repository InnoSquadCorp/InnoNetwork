//
//  URLSessionProtocol.swift
//  Network
//
//  Created by Chang Woo Son on 1/4/26.
//

import Foundation


public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
