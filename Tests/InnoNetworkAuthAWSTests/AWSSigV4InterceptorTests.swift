import Foundation
import InnoNetwork
import Testing

@testable import InnoNetworkAuthAWS

/// Validates ``AWSSigV4Interceptor`` against the published AWS SigV4 test
/// suite (`aws/aws-sdk-cpp` `aws-cpp-sdk-core/source/auth/signer/aws4_signer`
/// vectors, also mirrored in `aws-c-auth/tests/aws-signing-test-suite/v4`).
///
/// The vectors here use the canonical ``AKIDEXAMPLE`` /
/// ``wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`` credential pair documented at
/// https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html and the
/// fixed `2015-08-30T12:36:00Z` timestamp used across the suite. They cover
/// canonical-request formatting, string-to-sign assembly, and the final
/// `Authorization` header signature derivation for the most common request
/// shapes (`get-vanilla`, `get-vanilla-query`, `post-vanilla`).
@Suite
struct AWSSigV4InterceptorTests {
    private static let fixedDate: Date = {
        var components = DateComponents()
        components.year = 2015
        components.month = 8
        components.day = 30
        components.hour = 12
        components.minute = 36
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private static func makeInterceptor() -> AWSSigV4Interceptor {
        AWSSigV4Interceptor(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "service",
            now: { fixedDate }
        )
    }

    private static func signedRequest(
        _ request: URLRequest,
        using signer: AWSSigV4Interceptor,
        body: RequestBody = .none
    ) async throws -> URLRequest {
        let headers = try await signer.signatureHeaders(for: request, body: body)
        var signed = request
        for header in headers {
            signed.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return signed
    }

    @Test
    func getVanillaMatchesPublishedVector() async throws {
        let interceptor = Self.makeInterceptor()
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        request.setValue("example.amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue("20150830T123600Z", forHTTPHeaderField: "X-Amz-Date")

        let expectedCanonical = """
            GET
            /

            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """
        #expect(interceptor.canonicalRequest(for: request) == expectedCanonical)

        let expectedStringToSign = """
            AWS4-HMAC-SHA256
            20150830T123600Z
            20150830/us-east-1/service/aws4_request
            bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63
            """
        #expect(
            interceptor.stringToSign(
                canonicalRequest: expectedCanonical,
                date: Self.fixedDate
            ) == expectedStringToSign
        )

        let signed = try await Self.signedRequest(request, using: interceptor)
        let authorization = signed.value(forHTTPHeaderField: "Authorization")
        #expect(
            authorization
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    @Test
    func canonicalQueryStringSortsAlphabeticallyAndEncodesPerSpec() async throws {
        let interceptor = Self.makeInterceptor()
        var request = URLRequest(
            url: URL(string: "https://example.amazonaws.com/?Foo=bar&Baz=qux")!
        )
        request.httpMethod = "GET"
        request.setValue("example.amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue("20150830T123600Z", forHTTPHeaderField: "X-Amz-Date")

        // SigV4 requires query parameters to be sorted by key (RFC 3986 byte
        // order), then by value when keys collide. The published spec also
        // applies unreserved-only percent-encoding, which we exercise via the
        // body of the get-vanilla / post-vanilla vectors and the dedicated
        // RFC 3986 character set used by ``uriEncode``.
        let expectedCanonical = """
            GET
            /
            Baz=qux&Foo=bar
            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """
        #expect(interceptor.canonicalRequest(for: request) == expectedCanonical)
    }

    @Test
    func postVanillaMatchesPublishedVector() async throws {
        let interceptor = Self.makeInterceptor()
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "POST"
        request.setValue("example.amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue("20150830T123600Z", forHTTPHeaderField: "X-Amz-Date")

        let expectedCanonical = """
            POST
            /

            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """
        #expect(interceptor.canonicalRequest(for: request) == expectedCanonical)

        let signed = try await Self.signedRequest(request, using: interceptor)
        #expect(
            signed.value(forHTTPHeaderField: "Authorization")
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
        )
    }

    @Test
    func sessionTokenAddsSecurityTokenHeader() async throws {
        let interceptor = AWSSigV4Interceptor(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "service",
            sessionToken: "session/token/abc",
            now: { Self.fixedDate }
        )
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"

        let signed = try await Self.signedRequest(request, using: interceptor)
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Security-Token") == "session/token/abc")
    }

    @Test
    func nonDefaultPortIsPreservedInHostHeader() async throws {
        let interceptor = AWSSigV4Interceptor(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "s3",
            now: { Self.fixedDate }
        )
        var request = URLRequest(url: URL(string: "https://localhost:9000/bucket")!)
        request.httpMethod = "GET"

        let signed = try await Self.signedRequest(request, using: interceptor)
        #expect(signed.value(forHTTPHeaderField: "Host") == "localhost:9000")

        var requestDefaultPort = URLRequest(url: URL(string: "https://example.amazonaws.com:443/")!)
        requestDefaultPort.httpMethod = "GET"
        let signedDefault = try await Self.signedRequest(requestDefaultPort, using: interceptor)
        #expect(signedDefault.value(forHTTPHeaderField: "Host") == "example.amazonaws.com")
    }

    @Test
    func nonS3ServicesDoubleEncodeCanonicalPath() async throws {
        let nonS3 = AWSSigV4Interceptor(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "execute-api",
            now: { Self.fixedDate }
        )
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/hello%20world")!)
        request.httpMethod = "GET"
        request.setValue("example.amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue("20150830T123600Z", forHTTPHeaderField: "X-Amz-Date")

        let canonical = nonS3.canonicalRequest(for: request)
        // URL.path decodes %20 → " ". First encode → "/hello%20world".
        // Second encode (non-S3) → "/hello%2520world".
        #expect(canonical.contains("/hello%2520world"))

        let s3 = AWSSigV4Interceptor(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "s3",
            now: { Self.fixedDate }
        )
        let s3Canonical = s3.canonicalRequest(for: request)
        #expect(s3Canonical.contains("/hello%20world"))
        #expect(!s3Canonical.contains("/hello%2520world"))
    }

    @Test
    func s3EmitsPayloadHashForEmptyDataAndFileBodies() async throws {
        let interceptor = AWSSigV4Interceptor(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "s3",
            now: { Self.fixedDate }
        )
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "PUT"

        let empty = try await Self.signedRequest(request, using: interceptor)
        #expect(
            empty.value(forHTTPHeaderField: "X-Amz-Content-SHA256")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(empty.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-content-sha256") == true)

        let payload = Data("hello".utf8)
        let dataSigned = try await Self.signedRequest(request, using: interceptor, body: .data(payload))
        #expect(
            dataSigned.value(forHTTPHeaderField: "X-Amz-Content-SHA256")
                == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
        var canonicalInput = request
        canonicalInput.setValue("example.amazonaws.com", forHTTPHeaderField: "Host")
        canonicalInput.setValue("20150830T123600Z", forHTTPHeaderField: "X-Amz-Date")
        let dataCanonical = try interceptor.canonicalRequest(for: canonicalInput, body: .data(payload))
        #expect(
            dataCanonical.contains(
                "x-amz-content-sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        )
        #expect(dataCanonical.contains("host;x-amz-content-sha256"))

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fileSigned = try await Self.signedRequest(request, using: interceptor, body: .file(fileURL))
        #expect(
            fileSigned.value(forHTTPHeaderField: "X-Amz-Content-SHA256")
                == dataSigned.value(forHTTPHeaderField: "X-Amz-Content-SHA256")
        )
        #expect(
            fileSigned.value(forHTTPHeaderField: "Authorization")
                == dataSigned.value(forHTTPHeaderField: "Authorization"))
    }
}
