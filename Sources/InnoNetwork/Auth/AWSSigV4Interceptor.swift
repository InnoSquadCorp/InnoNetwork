import CryptoKit
import Foundation

/// `RequestInterceptor` that signs outgoing requests with the AWS
/// Signature Version 4 (SigV4) algorithm.
///
/// Targets the **single-shot, in-memory body** flow that covers the
/// majority of AWS service calls (DynamoDB, S3 GET / small PUT,
/// CloudWatch, SQS, …). Out of scope:
///
/// - **Streaming SigV4** (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`). The
///   interceptor surface runs before the upload pipeline owns the
///   body, so chunk signing needs a deeper hook than this contract.
///   Streaming uploads to S3 must use a per-call custom interceptor
///   or fall back to the AWS SDK.
/// - **Presigned URLs** (query-string signing). Use the AWS SDK or a
///   purpose-built signer; the SigV4 flow for that variant differs
///   meaningfully (no body, signature in query params).
/// - **STS session tokens** are honoured when supplied via
///   ``sessionToken`` — the interceptor adds `X-Amz-Security-Token`
///   automatically — but the rotation is the caller's responsibility.
///
/// The interceptor recomputes the signature on every attempt because
/// the canonical request includes `X-Amz-Date`, which advances every
/// time the clock is sampled. There is no caching layer.
///
/// > Important: This is a **reference implementation**, not a
/// > drop-in replacement for the AWS SDK. Validate it against your
/// > target service with the published AWS SigV4 test vectors before
/// > shipping; the interceptor exposes ``canonicalRequest(for:date:)``
/// > and ``stringToSign(canonicalRequest:date:)`` for that purpose.
public struct AWSSigV4Interceptor: RequestInterceptor {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?
    public let region: String
    public let service: String

    /// Closure that returns the timestamp used for `X-Amz-Date` and the
    /// credential scope. Override for deterministic tests; production
    /// callers should leave the default (`Date()`).
    public let now: @Sendable () -> Date

    public init(
        accessKeyID: String,
        secretAccessKey: String,
        region: String,
        service: String,
        sessionToken: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.service = service
        self.now = now
    }

    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        if urlRequest.httpBodyStream != nil {
            throw NetworkError.configuration(
                reason: .invalidRequest(
                    "AWSSigV4Interceptor cannot sign streaming bodies; use a chunk-signed implementation."
                ))
        }

        var request = urlRequest
        let date = now()
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        if request.value(forHTTPHeaderField: "Host") == nil,
           let host = request.url?.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        let canonicalRequest = canonicalRequest(for: request)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n" + Self.hex(Self.sha256(Data(canonicalRequest.utf8)))
        let signingKey = derivedSigningKey(dateStamp: dateStamp)
        let signature = Self.hex(Self.hmacSHA256(Data(stringToSign.utf8), key: signingKey))

        let signedHeaders = self.signedHeaders(of: request)
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        return request
    }

    // MARK: - Probes for tests

    /// Exposes the canonical-request string for the supplied request.
    /// Adopters can run this against the AWS SigV4 published test
    /// vectors to verify the interceptor matches the spec.
    public func canonicalRequest(for request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url
        let path = url?.path.isEmpty == false ? Self.uriEncode(url!.path, allowSlash: true) : "/"
        let query = canonicalQueryString(from: url)
        let (headers, signed) = canonicalHeaders(of: request)
        let body = request.httpBody ?? Data()
        let payloadHash = Self.hex(Self.sha256(body))
        return "\(method)\n\(path)\n\(query)\n\(headers)\n\(signed)\n\(payloadHash)"
    }

    /// Exposes the string-to-sign for the supplied canonical request.
    public func stringToSign(canonicalRequest: String, date: Date) -> String {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        return "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n" + Self.hex(Self.sha256(Data(canonicalRequest.utf8)))
    }

    // MARK: - Internals

    private func canonicalQueryString(from url: URL?) -> String {
        guard let url else { return "" }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        guard let items = components.queryItems else { return "" }

        var encoded: [(String, String)] = []
        encoded.reserveCapacity(items.count)
        for item in items {
            let name = Self.uriEncode(item.name, allowSlash: false)
            let value = Self.uriEncode(item.value ?? "", allowSlash: false)
            encoded.append((name, value))
        }

        encoded.sort { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }

        return encoded.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private func canonicalHeaders(of request: URLRequest) -> (canonical: String, signed: String) {
        let pairs: [(String, String)] = (request.allHTTPHeaderFields ?? [:])
            .map { ($0.key.lowercased(), Self.collapseWhitespace($0.value)) }
            .sorted { $0.0 < $1.0 }
        let canonical = pairs.map { "\($0.0):\($0.1)\n" }.joined()
        let signed = pairs.map(\.0).joined(separator: ";")
        return (canonical, signed)
    }

    private func signedHeaders(of request: URLRequest) -> String {
        (request.allHTTPHeaderFields ?? [:]).keys
            .map { $0.lowercased() }
            .sorted()
            .joined(separator: ";")
    }

    private func derivedSigningKey(dateStamp: String) -> SymmetricKey {
        let kSecret = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        let kDate = Self.hmacSHA256(Data(dateStamp.utf8), key: kSecret)
        let kRegion = Self.hmacSHA256(Data(region.utf8), key: SymmetricKey(data: kDate))
        let kService = Self.hmacSHA256(Data(service.utf8), key: SymmetricKey(data: kRegion))
        let kSigning = Self.hmacSHA256(Data("aws4_request".utf8), key: SymmetricKey(data: kService))
        return SymmetricKey(data: kSigning)
    }

    // MARK: - Static helpers

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func hmacSHA256(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3986 percent-encoding for SigV4 (`A-Z a-z 0-9 - _ . ~`
    /// unreserved; everything else encoded). Forward slashes are left
    /// alone in the path component but encoded inside query strings,
    /// per the SigV4 reference.
    private static func uriEncode(_ string: String, allowSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if allowSlash { allowed.insert(charactersIn: "/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func collapseWhitespace(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var collapsed = ""
        var lastWasSpace = false
        for character in trimmed {
            if character.isWhitespace {
                if !lastWasSpace {
                    collapsed.append(" ")
                    lastWasSpace = true
                }
            } else {
                collapsed.append(character)
                lastWasSpace = false
            }
        }
        return collapsed
    }

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}
