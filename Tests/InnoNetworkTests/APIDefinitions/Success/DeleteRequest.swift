//
//  DeleteRequest.swift
//  InnoNetworkTests
//
//  Created by Chang Woo Son on 6/28/24.
//

import Foundation
@testable import InnoNetwork

struct DeleteRequest: APIDefinition {
    typealias Parameter = EmptyParameter

    typealias APIResponse = EmptyResponse

    var method: HTTPMethod { .delete }

    var path: String { "/posts/1" }
}
