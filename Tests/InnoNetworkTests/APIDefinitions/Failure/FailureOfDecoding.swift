//
//  FailureOfDecoding.swift
//  InnoNetworkTests
//
//  Created by Chang Woo Son on 6/27/24.
//

import Foundation
@testable import InnoNetwork

struct FailureOfDecoding: APIDefinition {
    struct GetResponse: Decodable, Sendable {
        let userId: Int
        let id: Int
        let title: Int
        let completed: Bool
    }

    typealias Parameter = EmptyParameter

    typealias APIResponse = [GetResponse]

    var method: HTTPMethod { .get }

    var path: String { "/todos" }
}
