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
        let headers = try await interceptor.signatureHeaders(for: request, body: .data(body))

        let expectedMAC = HMAC<SHA256>.authenticationCode(
            for: body,
            using: SymmetricKey(data: secret)
        )
        let expected = Data(expectedMAC).base64EncodedString()

        #expect(headers.value(for: "X-Signature") == expected)
        #expect(headers.value(for: "X-Signature-Key-Id") == "k1")
    }

    @Test
    func bodylessRequestHashesEmptyData() async throws {
        let secret = Data("k".utf8)
        let interceptor = HMACRequestInterceptor(keyID: "client", secret: secret)
        var request = URLRequest(url: URL(string: "https://api.example.com/health")!)
        request.httpMethod = "GET"

        let headers = try await interceptor.signatureHeaders(for: request, body: .none)

        let expectedMAC = HMAC<SHA256>.authenticationCode(
            for: Data(),
            using: SymmetricKey(data: secret)
        )
        let expected = Data(expectedMAC).base64EncodedString()

        #expect(headers.value(for: "X-Signature") == expected)
    }

    @Test
    func customHeaderNamesAreHonoured() async throws {
        let interceptor = HMACRequestInterceptor(
            keyID: "id",
            secret: Data("s".utf8),
            signatureHeaderName: "X-Hub-Signature-256",
            keyIDHeaderName: "X-Hub-Key-ID"
        )
        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        let headers = try await interceptor.signatureHeaders(for: request, body: .data(Data("{}".utf8)))

        #expect(headers.value(for: "X-Hub-Signature-256") != nil)
        #expect(headers.value(for: "X-Hub-Key-ID") == "id")
        #expect(headers.value(for: "X-Signature") == nil)
    }

    @Test
    func fileBodyMatchesInMemorySignature() async throws {
        let interceptor = HMACRequestInterceptor(keyID: "id", secret: Data("s".utf8))
        let payload = Data(repeating: 0xA5, count: 150_000)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let request = URLRequest(url: URL(string: "https://api.example.com/upload")!)

        let fileHeaders = try await interceptor.signatureHeaders(for: request, body: .file(fileURL))
        let dataHeaders = try await interceptor.signatureHeaders(for: request, body: .data(payload))

        #expect(fileHeaders.value(for: "X-Signature") == dataHeaders.value(for: "X-Signature"))
    }

    @Test
    func sha512AlgorithmProducesDistinctSignature() async throws {
        let secret = Data("k".utf8)
        let body = Data("payload".utf8)

        let sha256 = HMACRequestInterceptor(keyID: "id", secret: secret, algorithm: .sha256)
        let sha512 = HMACRequestInterceptor(keyID: "id", secret: secret, algorithm: .sha512)

        let request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        let h256Headers = try await sha256.signatureHeaders(for: request, body: .data(body))
        let h512Headers = try await sha512.signatureHeaders(for: request, body: .data(body))

        let h256 = h256Headers.value(for: "X-Signature")
        let h512 = h512Headers.value(for: "X-Signature")
        #expect(h256 != nil && h512 != nil)
        #expect(h256 != h512)
    }
}
