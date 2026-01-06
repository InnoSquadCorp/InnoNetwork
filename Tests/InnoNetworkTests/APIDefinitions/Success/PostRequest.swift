//
//  PostRequest.swift
//  InnoNetworkTests
//
//  Created by Chang Woo Son on 6/28/24.
//

import Foundation
@testable import InnoNetwork

struct PostRequest: APIDefinition {
    let parameters: PostParameter?

    struct PostResponse: Decodable, Sendable {
        let id: Int
        let title: String
        let body: String
        let userId: Int
    }

    struct PostParameter: Encodable, Sendable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter

    typealias APIResponse = PostResponse

    var method: HTTPMethod { .post }

    var path: String { "/posts" }

    init(title: String, body: String, userId: Int) {
        self.parameters = PostParameter(
            title: title, body: body, userId: userId
        )
    }
}
