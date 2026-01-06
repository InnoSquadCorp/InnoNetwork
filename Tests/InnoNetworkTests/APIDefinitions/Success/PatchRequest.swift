//
//  PatchRequest.swift
//  InnoNetworkTests
//
//  Created by Chang Woo Son on 6/28/24.
//

import Foundation
@testable import InnoNetwork

struct PatchRequest: APIDefinition {
    let parameters: PatchParameter?

    struct PatchResponse: Decodable, Sendable {
        let id: Int
        let title: String
        let body: String
        let userId: Int
    }

    struct PatchParameter: Encodable, Sendable {
        let title: String
    }

    typealias Parameter = PatchParameter

    typealias APIResponse = PatchResponse

    var method: HTTPMethod { .patch }

    var path: String { "/posts/1" }

    init(title: String) {
        self.parameters = PatchParameter(title: title)
    }
}
