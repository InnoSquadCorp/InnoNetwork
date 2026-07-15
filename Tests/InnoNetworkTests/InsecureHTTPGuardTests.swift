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

    @Test("Unsupported schemes and hostless URLs are rejected")
    func unsupportedAndHostlessURLsRejected() {
        #expect(throws: NetworkError.self) {
            _ = try NetworkURLAdmission.validate(
                URL(string: "ftp://api.example.com/archive")!,
                policy: .http(allowsInsecure: true)
            )
        }
        #expect(throws: NetworkError.self) {
            _ = try NetworkURLAdmission.validate(
                URL(string: "https:///users")!,
                policy: .http(allowsInsecure: false)
            )
        }
    }

    @Test("Percent-encoded authority delimiters and controls are rejected in hosts")
    func ambiguousEncodedHostsRejected() {
        let encodedHosts = [
            "good%40evil.example",
            "good%2Fevil.example",
            "good%5Cevil.example",
            "good%3Fevil.example",
            "good%23evil.example",
            "good%3Aevil.example",
            "good%20evil.example",
            "good%00evil.example",
        ]

        for host in encodedHosts {
            #expect(throws: NetworkError.self) {
                _ = try NetworkURLAdmission.validate(
                    URL(string: "https://\(host)/resource")!,
                    policy: .http(allowsInsecure: false)
                )
            }
        }
    }

    @Test("Internationalized hosts and bracketed IPv6 literals remain admissible")
    func internationalizedAndIPv6HostsAccepted() throws {
        let urls = [
            URL(string: "https://한글.example/resource")!,
            URL(string: "https://[::1]/resource")!,
            URL(string: "https://[fe80::1%25en0]/resource")!,
        ]

        for url in urls {
            let admitted = try NetworkURLAdmission.validate(
                url,
                policy: .http(allowsInsecure: false)
            )
            #expect(admitted == url)
        }
    }

    @Test("Raw, encoded, and deeply nested encoded dot segments are rejected")
    func dotSegmentsRejectedAtAdmission() {
        let paths = [
            "/v1/../admin",
            "/v1/%2e%2E/admin",
            "/v1/%252e%252E/admin",
            "/v1/%2F..%2Fadmin",
            "/v1/%FF/%2E%2E/admin",
            "/v1/%5C..%5Cadmin",
            "/v1/%252525252525252e%252525252525252E/admin",
        ]
        for path in paths {
            #expect(throws: NetworkError.self) {
                _ = try NetworkURLAdmission.validate(
                    URL(string: "https://api.example.com\(path)")!,
                    policy: .http(allowsInsecure: false)
                )
            }
        }
    }

    @Test("NetworkConfiguration default allowsInsecureHTTP is false")
    func configDefaultsToSecure() {
        let config = NetworkConfiguration.safeDefaults(baseURL: URL(string: "https://api.example.com")!)
        #expect(config.allowsInsecureHTTP == false)
    }

    @Test("NetworkConfiguration.advanced can opt into HTTP")
    func advancedBuilderOptIn() {
        let config = NetworkConfiguration.advanced(
            baseURL: URL(string: "http://localhost")!,
            transport: TransportPack(allowsInsecureHTTP: true)
        )
        #expect(config.allowsInsecureHTTP == true)
    }
}
