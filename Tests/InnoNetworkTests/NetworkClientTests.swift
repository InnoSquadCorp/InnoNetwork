import Foundation
import Testing

@testable import InnoNetwork

struct GetProfile: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}


struct Profile: Decodable, Sendable {
    let id: Int
    let name: String
}


@Suite
struct NetworkClientTests {
    let client = DefaultNetworkClient(
        configuration: makeTestNetworkConfiguration(baseURL: "https://jsonplaceholder.typicode.com")
    )

    private var runIntegrationTests: Bool {
        ProcessInfo.processInfo.environment["INNO_LIVE"] == "1"
    }

    @Test func defaultSessionUsesFreshConfigurationDerivedInstance() {
        let configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            timeout: 7,
            cachePolicy: .reloadIgnoringLocalCacheData,
            allowsCellularAccess: false,
            allowsExpensiveNetworkAccess: false,
            allowsConstrainedNetworkAccess: false
        )

        let session = DefaultNetworkClient.makeDefaultURLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        #expect(session !== URLSession.shared)
        #expect(session.configuration.timeoutIntervalForRequest == 7)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(session.configuration.allowsCellularAccess == false)
        #expect(session.configuration.allowsExpensiveNetworkAccess == false)
        #expect(session.configuration.allowsConstrainedNetworkAccess == false)
        if let cookieStorage = session.configuration.httpCookieStorage {
            #expect(cookieStorage !== HTTPCookieStorage.shared)
        } else {
            Issue.record("Expected default session to install per-client cookie storage")
        }
        if let urlCache = session.configuration.urlCache {
            #expect(urlCache !== URLCache.shared)
            #expect(urlCache.diskCapacity == 0)
        } else {
            Issue.record("Expected default session to install per-client URL cache")
        }
    }

    @Test func getRequestSuccess() async throws {
        guard runIntegrationTests else { return }
        let profile = try await client.request(GetProfile())
        #expect(profile.id == 1)
        #expect(profile.name == "Leanne Graham")
    }
}
