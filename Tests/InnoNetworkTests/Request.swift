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
    let client = DefaultNetworkClient(
        configuration: makeTestNetworkConfiguration(baseURL: "https://jsonplaceholder.typicode.com")
    )

    private var runIntegrationTests: Bool {
        ProcessInfo.processInfo.environment["INNONETWORK_RUN_INTEGRATION_TESTS"] == "1"
    }

    @Test
    func getRequestSuccess() async throws {
        guard runIntegrationTests else { return }
        let getResponseList = try await client.request(GetRequest())
        #expect(getResponseList.first?.id == 1)
    }

    @Test
    func postRequestSuccess() async throws {
        guard runIntegrationTests else { return }
        let response = try await client.request(PostRequest(title: "post request", body: "test", userId: 1))
        #expect(response.title == "post request")
        #expect(response.body == "test")
        #expect(response.userId == 1)
    }

    @Test
    func putRequestSuccess() async throws {
        guard runIntegrationTests else { return }
        let response = try await client.request(PutRequest(id: 1, title: "put request", body: "test", userId: 1))
        #expect(response.id == 1)
    }

    @Test
    func patchRequestSuccess() async throws {
        guard runIntegrationTests else { return }
        let response = try await client.request(PatchRequest(title: "patch test"))
        #expect(response.id == 1)
    }

    @Test
    func deleteRequestSuccess() async throws {
        guard runIntegrationTests else { return }
        _ = try await client.request(DeleteRequest())
    }

    @Test
    func getRequestFailureOfDecoding() async {
        guard runIntegrationTests else { return }
        await #expect(throws: NetworkError.self) {
            try await client.request(FailureOfDecoding())
        }
    }
}
