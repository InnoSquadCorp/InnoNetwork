import Crypto
import Foundation
@_exported import InnoNetwork

/// ``RequestSigner`` that signs outgoing requests with the AWS
/// Signature Version 4 (SigV4) algorithm.
///
/// This product is a reference signer, not a replacement for the AWS SDK. It
/// targets the single-shot data and stable-file body flows that cover many AWS
/// service calls (DynamoDB, S3 GET/PUT, CloudWatch, SQS) and intentionally
/// leaves streaming SigV4, presigned URLs, credential rotation, and
/// service-specific SDK behaviours to the caller or to AWS-provided SDKs.
public struct AWSSigV4Interceptor: RequestSigner {
    public let accessKeyID: String
    /// Holds the long-term IAM secret used to derive the signing key.
    /// Kept `internal` so it cannot be read back through the public
    /// surface — adopters wire the value through `init` once and the
    /// interceptor uses it internally for HMAC derivation only.
    let secretAccessKey: String
    /// Optional STS session token; same visibility rationale as
    /// `secretAccessKey`.
    let sessionToken: String?
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

    public func signatureHeaders(
        for urlRequest: URLRequest,
        body: RequestBody
    ) async throws -> HTTPHeaders {
        var request = urlRequest
        // Authorization is the product of SigV4, never an input to the
        // canonical request. This also makes re-signing after a refresh replay
        // deterministic when the adapted request carries an older signature.
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let date = now()
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        if request.value(forHTTPHeaderField: "Host") == nil,
            let url = request.url,
            let host = url.host
        {
            request.setValue(
                Self.canonicalHostValue(host: host, scheme: url.scheme, port: url.port),
                forHTTPHeaderField: "Host"
            )
        }

        let payloadHash = try Self.payloadHash(for: body)
        if service.lowercased() == "s3" {
            // S3 requires the payload hash as a wire header, and that header
            // itself must participate in canonicalization/signing.
            request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-SHA256")
        }

        let canonicalRequest = canonicalRequest(for: request, payloadHash: payloadHash)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign =
            "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n" + Self.hex(Self.sha256(Data(canonicalRequest.utf8)))
        let signingKey = derivedSigningKey(dateStamp: dateStamp)
        let signature = Self.hex(Self.hmacSHA256(Data(stringToSign.utf8), key: signingKey))

        let signedHeaders = self.signedHeaders(of: request)
        let authorization =
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var headers = HTTPHeaders()
        headers.update(name: "X-Amz-Date", value: amzDate)
        if let sessionToken {
            headers.update(name: "X-Amz-Security-Token", value: sessionToken)
        }
        if let host = request.value(forHTTPHeaderField: "Host") {
            headers.update(name: "Host", value: host)
        }
        if service.lowercased() == "s3" {
            headers.update(name: "X-Amz-Content-SHA256", value: payloadHash)
        }
        headers.update(name: "Authorization", value: authorization)
        return headers
    }

    /// Exposes the canonical-request string for the supplied request.
    /// Adopters can run this against the AWS SigV4 published test vectors to
    /// verify the interceptor matches the spec.
    public func canonicalRequest(for request: URLRequest) -> String {
        let payloadHash = Self.hex(Self.sha256(request.httpBody ?? Data()))
        return canonicalRequestIncludingS3PayloadHeader(request, payloadHash: payloadHash)
    }

    /// Exposes canonicalization for an explicit data/file transport body.
    public func canonicalRequest(for request: URLRequest, body: RequestBody) throws -> String {
        let payloadHash = try Self.payloadHash(for: body)
        return canonicalRequestIncludingS3PayloadHeader(request, payloadHash: payloadHash)
    }

    private func canonicalRequestIncludingS3PayloadHeader(
        _ request: URLRequest,
        payloadHash: String
    ) -> String {
        var canonicalRequest = request
        if service.lowercased() == "s3" {
            canonicalRequest.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-SHA256")
        }
        return self.canonicalRequest(for: canonicalRequest, payloadHash: payloadHash)
    }

    private func canonicalRequest(for request: URLRequest, payloadHash: String) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url
        let urlPath = url?.path ?? ""
        let firstPass = urlPath.isEmpty ? "/" : Self.uriEncode(urlPath, allowSlash: true)
        // SigV4: S3 uses single-encoded paths; every other service expects
        // the canonical URI to be encoded again (percent signs re-escaped).
        let path = service.lowercased() == "s3" ? firstPass : Self.uriEncode(firstPass, allowSlash: true)
        let query = canonicalQueryString(from: url)
        let (headers, signed) = canonicalHeaders(of: request)
        return "\(method)\n\(path)\n\(query)\n\(headers)\n\(signed)\n\(payloadHash)"
    }

    /// Exposes the string-to-sign for the supplied canonical request.
    public func stringToSign(canonicalRequest: String, date: Date) -> String {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        return "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n" + Self.hex(Self.sha256(Data(canonicalRequest.utf8)))
    }

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

    private static func canonicalHostValue(host: String, scheme: String?, port: Int?) -> String {
        guard let port else { return host }
        let isDefault: Bool
        switch scheme?.lowercased() {
        case "https": isDefault = port == 443
        case "http": isDefault = port == 80
        default: isDefault = false
        }
        return isDefault ? host : "\(host):\(port)"
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func payloadHash(for body: RequestBody) throws -> String {
        var hasher = SHA256()
        try body.forEachChunk { hasher.update(data: $0) }
        return hex(Data(hasher.finalize()))
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
