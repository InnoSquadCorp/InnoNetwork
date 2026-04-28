//
//  GetRequest.swift
//  InnoNetworkTests
//
//  Created by Chang Woo Son on 6/26/24.
//

import Foundation

@testable import InnoNetwork

struct GetRequest: APIDefinition {
    struct GetResponse: Decodable, Sendable {
        let userId: Int
        let id: Int
        let title: String
        let completed: Bool
    }

    typealias Parameter = EmptyParameter

    typealias APIResponse = [GetResponse]

    var method: HTTPMethod { .get }

    var path: String { "/todos" }
}
