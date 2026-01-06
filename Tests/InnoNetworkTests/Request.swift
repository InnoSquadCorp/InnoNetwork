//
//  Request.swift
//  InnoNetworkTests
//
//  Created by Chang Woo Son on 6/25/24.
//

import Foundation
import Testing
import XCTest
@testable import InnoNetwork



@Suite
struct Request {
    let client = try! DefaultNetworkClient(configuration: RequestAPI())

    @Test
    func getRequestSuccess() async throws {
        let getResponseList = try await client.request(GetRequest())
        #expect(getResponseList.first?.id == 1)
    }

    @Test
    func postRequestSuccess() async throws {
        let response = try await client.request(PostRequest(title: "post request", body: "test", userId: 1))
        #expect(response.title == "post request")
        #expect(response.body == "test")
        #expect(response.userId == 1)
    }

    @Test
    func putRequestSuccess() async throws {
        let response = try await client.request(PutRequest(id: 1, title: "put request", body: "test", userId: 1))
        #expect(response.id == 1)
    }

    @Test
    func patchRequestSuccess() async throws {
        let response = try await client.request(PatchRequest(title: "patch test"))
        #expect(response.id == 1)
    }

    @Test
    func deleteRequestSuccess() async throws {
        _ = try await client.request(DeleteRequest())
    }

    @Test
    func getRequestFailureOfDecoding() async {
        await #expect(throws: NetworkError.self) {
            try await client.request(FailureOfDecoding())
        }
    }
}

struct RequestAPI: APIConfigure {
    var host: String { "https://jsonplaceholder.typicode.com" }
    var basePath: String { "" }
}


