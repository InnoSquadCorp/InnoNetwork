import Foundation
import Testing

@testable import InnoNetwork

@Suite("Plain HTTP guard — invalidBaseURL unless allowsInsecureHTTP opts in")
struct InsecureHTTPGuardTests {
    @Test("HTTP base URL throws invalidBaseURL by default")
    func httpBaseURLRejected() {
        #expect(throws: NetworkError.self) {
            _ = try EndpointPathBuilder.makeURL(
                baseURL: URL(string: "http://api.example.com")!,
                endpointPath: "/users/1"
            )
        }
    }

    @Test("HTTPS base URL is accepted")
    func httpsBaseURLAccepted() throws {
        let url = try EndpointPathBuilder.makeURL(
            baseURL: URL(string: "https://api.example.com")!,
            endpointPath: "/users/1"
        )
        #expect(url.scheme == "https")
    }

    @Test("HTTP base URL accepted when allowsInsecureHTTP: true")
    func httpAcceptedWhenOptedIn() throws {
        let url = try EndpointPathBuilder.makeURL(
            baseURL: URL(string: "http://localhost:8080")!,
            endpointPath: "/health",
            allowsInsecureHTTP: true
        )
        #expect(url.scheme == "http")
        #expect(url.host == "localhost")
    }

    @Test("HTTP scheme is matched case-insensitively")
    func httpUppercaseRejected() {
        #expect(throws: NetworkError.self) {
            _ = try EndpointPathBuilder.makeURL(
                baseURL: URL(string: "HTTP://api.example.com")!,
                endpointPath: "/x"
            )
        }
    }

    @Test("NetworkConfiguration default allowsInsecureHTTP is false")
    func configDefaultsToSecure() {
        let config = NetworkConfiguration.safeDefaults(baseURL: URL(string: "https://api.example.com")!)
        #expect(config.allowsInsecureHTTP == false)
    }

    @Test("NetworkConfiguration.advanced can opt into HTTP")
    func advancedBuilderOptIn() {
        let config = NetworkConfiguration.advanced(baseURL: URL(string: "http://localhost")!) {
            $0.allowsInsecureHTTP = true
        }
        #expect(config.allowsInsecureHTTP == true)
    }
}
