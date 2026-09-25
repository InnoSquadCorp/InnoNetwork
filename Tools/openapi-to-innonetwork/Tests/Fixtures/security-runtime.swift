import Foundation
import InnoNetwork
import os

private struct Provider: RequestCredentialProvider {
    var alternative = 0
    func select(alternatives: [[RequestSecurity.Scheme]], origin: URL) -> RequestSecurity.Selection {
        .init(alternative: alternative, realm: "fixture", principal: "user")
    }
    func credential(for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL)
        -> RequestSecurity.Credential
    {
        .init(value: "fixture-secret", realm: selection.realm, principal: selection.principal)
    }
}

// URLProtocol is Foundation's test seam; mutable capture is lock-protected.
private final class CredentialURLProtocol: URLProtocol, @unchecked Sendable {
    static let captured = OSAllocatedUnfairLock(initialState: [URLRequest]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct GeneratedCredentialSmoke {
    static func main() async throws {
        let origin = URL(string: "https://api.example.com")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = DefaultNetworkClient(configuration: .safeDefaults(baseURL: origin), session: session)
        _ = try await client.request(HeaderCredential(credentialOrigin: origin, credentialProvider: Provider()))
        _ = try await client.request(
            QueryCredential(credentialOrigin: origin, credentialProvider: Provider(), allowsQueryCredentials: true))
        _ = try await client.request(
            CookieCredential(credentialOrigin: origin, credentialProvider: Provider(), allowsCookieCredentials: true))
        _ = try await client.request(CombinedCredential(credentialOrigin: origin, credentialProvider: Provider()))
        _ = try await client.request(
            AlternativeCredential(
                credentialOrigin: origin, credentialProvider: Provider(alternative: 2), allowsQueryCredentials: true))
        _ = try await client.request(RemovedCredential())
        let requests = CredentialURLProtocol.captured.withLock { $0 }
        precondition(requests.count == 6)
        precondition(requests[0].value(forHTTPHeaderField: "X-Custom-Credential") == "fixture-secret")
        precondition(requests[1].url?.query == "customQuery=fixture-secret")
        precondition(requests[2].value(forHTTPHeaderField: "Cookie") == "customCookie=fixture-secret")
        precondition(requests[3].value(forHTTPHeaderField: "X-Custom-Credential") == "fixture-secret")
        precondition(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
        precondition(requests[4].value(forHTTPHeaderField: "X-Custom-Credential") == nil)
        precondition(requests[5].value(forHTTPHeaderField: "X-Custom-Credential") == nil)
        print("Generated credential runtime passed (6 requests).")
    }
}
