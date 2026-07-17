import Foundation
import Testing

@testable import InnoNetwork

@Suite("Default network client convenience")
struct DefaultNetworkClientConvenienceTests {
    @Test("Base URL entry point creates and shuts down a safe-default client")
    func baseURLClientLifecycle() async throws {
        let baseURL = try #require(URL(string: "https://api.example.com/v1"))
        let client = DefaultNetworkClient(baseURL: baseURL)

        await client.shutdown()
    }
}
