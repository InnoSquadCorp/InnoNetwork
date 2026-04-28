//
//  PutRequest.swift
//  InnoNetworkTests
//
//  Created by Chang Woo Son on 6/28/24.
//

import Foundation

@testable import InnoNetwork

struct PutRequest: APIDefinition {
    let parameters: PutParameter?

    struct PutResponse: Decodable, Sendable {
        let id: Int
    }

    struct PutParameter: Encodable, Sendable {
        let id: Int
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PutParameter

    typealias APIResponse = PutResponse

    var method: HTTPMethod { .put }

    var path: String { "/posts/1" }

    init(id: Int, title: String, body: String, userId: Int) {
        self.parameters = PutParameter(
            id: id,
            title: title,
            body: body,
            userId: userId
        )
    }
}
