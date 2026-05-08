import CryptoKit
import Foundation
import Testing

@testable import InnoNetwork

@Suite
struct HMACRequestInterceptorTests {
    @Test
    func sha256SignaturesMatchCryptoKitReference() async throws {
        let secret = Data("super-secret".utf8)
        let body = Data("{\"hello\":\"world\"}".utf8)

        let interceptor = HMACRequestInterceptor(keyID: "k1", secret: secret)
        var request = URLRequest(url: URL(string: "https://api.example.com/webhook")!)
        request.httpMethod = "POST"
        request.httpBody = body

        let signed = try await interceptor.adapt(request)

        let expectedMAC = HMAC<SHA256>.authenticationCode(
            for: body,
            using: SymmetricKey(data: secret)
        )
        let expected = Data(expectedMAC).base64EncodedString()

        #expect(signed.value(forHTTPHeaderField: "X-Signature") == expected)
        #expect(signed.value(forHTTPHeaderField: "X-Signature-Key-Id") == "k1")
    }

    @Test
    func bodylessRequestHashesEmptyData() async throws {
        let secret = Data("k".utf8)
        let interceptor = HMACRequestInterceptor(keyID: "client", secret: secret)
        var request = URLRequest(url: URL(string: "https://api.example.com/health")!)
        request.httpMethod = "GET"

        let signed = try await interceptor.adapt(request)

        let expectedMAC = HMAC<SHA256>.authenticationCode(
            for: Data(),
            using: SymmetricKey(data: secret)
        )
        let expected = Data(expectedMAC).base64EncodedString()

        #expect(signed.value(forHTTPHeaderField: "X-Signature") == expected)
    }

    @Test
    func customHeaderNamesAreHonoured() async throws {
        let interceptor = HMACRequestInterceptor(
            keyID: "id",
            secret: Data("s".utf8),
            signatureHeaderName: "X-Hub-Signature-256",
            keyIDHeaderName: "X-Hub-Key-ID"
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        request.httpBody = Data("{}".utf8)

        let signed = try await interceptor.adapt(request)

        #expect(signed.value(forHTTPHeaderField: "X-Hub-Signature-256") != nil)
        #expect(signed.value(forHTTPHeaderField: "X-Hub-Key-ID") == "id")
        #expect(signed.value(forHTTPHeaderField: "X-Signature") == nil)
    }

    @Test
    func streamingBodyIsRejected() async throws {
        let interceptor = HMACRequestInterceptor(keyID: "id", secret: Data("s".utf8))
        var request = URLRequest(url: URL(string: "https://api.example.com/upload")!)
        request.httpBodyStream = InputStream(data: Data("streamed".utf8))

        do {
            _ = try await interceptor.adapt(request)
            Issue.record("Expected streaming body to be rejected")
        } catch let error as NetworkError {
            guard case .configuration(reason: .invalidRequest) = error else {
                Issue.record("Expected .invalidRequestConfiguration, got \(error)")
                return
            }
        }
    }

    @Test
    func sha512AlgorithmProducesDistinctSignature() async throws {
        let secret = Data("k".utf8)
        let body = Data("payload".utf8)

        let sha256 = HMACRequestInterceptor(keyID: "id", secret: secret, algorithm: .sha256)
        let sha512 = HMACRequestInterceptor(keyID: "id", secret: secret, algorithm: .sha512)

        var request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        request.httpBody = body

        let s256 = try await sha256.adapt(request)
        let s512 = try await sha512.adapt(request)

        let h256 = s256.value(forHTTPHeaderField: "X-Signature")
        let h512 = s512.value(forHTTPHeaderField: "X-Signature")
        #expect(h256 != nil && h512 != nil)
        #expect(h256 != h512)
    }
}
