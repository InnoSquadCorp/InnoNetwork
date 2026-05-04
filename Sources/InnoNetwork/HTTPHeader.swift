//
//  HTTPHeader.swift
//  Network
//
//  Created by Chang Woo Son on 6/21/24.
//

import Foundation

/// An order-preserving and case-insensitive representation of HTTP headers.
public struct HTTPHeaders: Sendable {
    private var headers: [HTTPHeader] = []

    /// Creates an empty instance.
    public init() {}

    /// Creates an instance from an array of `HTTPHeader`s. Entries are
    /// preserved in order, including multiple entries that share a
    /// case-insensitive name (e.g. `Set-Cookie`).
    public init(_ headers: [HTTPHeader]) {
        self.headers = headers
    }

    /// Creates an instance from a `[String: String]`. The dictionary cannot
    /// represent multi-value headers; callers that need to preserve repeated
    /// `Set-Cookie` or `WWW-Authenticate` entries should use ``init(_:)``
    /// with an array literal instead.
    public init(_ dictionary: [String: String]) {
        self.headers = dictionary.map { HTTPHeader(name: $0.key, value: $0.value) }
    }

    /// Appends an `HTTPHeader` to the instance, preserving any existing
    /// entries that share the same case-insensitive name.
    ///
    /// Use this for headers that legitimately repeat — most commonly
    /// `Set-Cookie` and `WWW-Authenticate` — where collapsing into a
    /// comma-joined string would either be invalid (cookies) or lose
    /// challenge boundaries.
    ///
    /// For headers that should hold a single value, prefer ``update(_:)``
    /// or ``update(name:value:)``.
    ///
    /// - Parameters:
    ///   - name:  The `HTTPHeader` name.
    ///   - value: The `HTTPHeader` value.
    public mutating func add(name: String, value: String) {
        headers.append(HTTPHeader(name: name, value: value))
    }

    /// Appends the provided `HTTPHeader` to the instance, preserving any
    /// existing entries that share the same case-insensitive name.
    ///
    /// - Parameter header: The `HTTPHeader` to append.
    public mutating func add(_ header: HTTPHeader) {
        headers.append(header)
    }

    /// Case-insensitively updates or appends an `HTTPHeader` into the instance using the provided `name` and `value`.
    ///
    /// - Parameters:
    ///   - name:  The `HTTPHeader` name.
    ///   - value: The `HTTPHeader` value.
    public mutating func update(name: String, value: String) {
        update(HTTPHeader(name: name, value: value))
    }

    /// Case-insensitively replaces all existing entries that share the
    /// header name with the provided `HTTPHeader`. If no matching entry
    /// exists, the header is appended.
    ///
    /// Prefer this for single-valued headers (``Authorization``,
    /// ``Content-Type``, etc.) so a misconfigured retry path cannot
    /// accidentally accumulate duplicates.
    ///
    /// - Parameter header: The `HTTPHeader` to update or append.
    public mutating func update(_ header: HTTPHeader) {
        let lowercasedName = header.name.lowercased()
        var didReplace = false
        headers = headers.compactMap { existing in
            if existing.name.lowercased() == lowercasedName {
                if didReplace { return nil }
                didReplace = true
                return header
            }
            return existing
        }
        if !didReplace {
            headers.append(header)
        }
    }

    /// Case-insensitively removes every `HTTPHeader` matching `name`,
    /// including duplicates added via ``add(name:value:)``.
    ///
    /// - Parameter name: The name of the `HTTPHeader` to remove.
    public mutating func remove(name: String) {
        let lowercasedName = name.lowercased()
        headers.removeAll { $0.name.lowercased() == lowercasedName }
    }

    /// Sort the current instance by header name, case insensitively.
    public mutating func sort() {
        headers.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Returns an instance sorted by header name.
    ///
    /// - Returns: A copy of the current instance sorted by name.
    public func sorted() -> HTTPHeaders {
        var headers = self
        headers.sort()

        return headers
    }

    /// Case-insensitively find a header's value by name.
    ///
    /// When several entries share the same case-insensitive name, the
    /// returned value is the joined RFC 7230 §3.2.2 representation
    /// (`value-1, value-2`). Callers that need to inspect each
    /// individual entry — for example to read repeated `Set-Cookie`
    /// headers — should use ``values(for:)`` instead.
    ///
    /// - Parameter name: The name of the header to search for, case-insensitively.
    ///
    /// - Returns:        The value of header, if it exists.
    public func value(for name: String) -> String? {
        let matches = values(for: name)
        guard !matches.isEmpty else { return nil }
        return matches.joined(separator: ", ")
    }

    /// Case-insensitively returns every value associated with `name`, in
    /// the order they were added. Use this for response headers that may
    /// legitimately repeat (`Set-Cookie`, `WWW-Authenticate`).
    ///
    /// - Parameter name: The name of the header to search for, case-insensitively.
    /// - Returns:        Each value associated with `name`, or an empty array.
    public func values(for name: String) -> [String] {
        let lowercasedName = name.lowercased()
        return headers.compactMap { $0.name.lowercased() == lowercasedName ? $0.value : nil }
    }

    /// Case-insensitively access the header with the given name.
    ///
    /// - Parameter name: The name of the header.
    public subscript(_ name: String) -> String? {
        get { value(for: name) }
        set {
            if let value = newValue {
                update(name: name, value: value)
            } else {
                remove(name: name)
            }
        }
    }

    /// The dictionary representation of all headers, suitable for passing
    /// to `URLRequest.allHTTPHeaderFields`.
    ///
    /// Multiple entries that share a case-insensitive name are collapsed
    /// into a single comma-joined value per RFC 7230 §3.2.2. The first
    /// occurrence of the name is preserved as the canonical key. This
    /// representation does not preserve insertion order.
    ///
    /// `Set-Cookie` is the one well-known header where comma-joining is
    /// invalid. The library never sets `Set-Cookie` on outbound requests,
    /// so the join is safe in practice for the request-side use of this
    /// property; consumers reading inbound response headers should iterate
    /// the collection or call ``values(for:)`` instead of going through
    /// this dictionary.
    public var dictionary: [String: String] {
        var canonicalKeys: [String: String] = [:]
        var grouped: [String: [String]] = [:]
        var insertionOrder: [String] = []

        for header in headers {
            let lowercased = header.name.lowercased()
            if canonicalKeys[lowercased] == nil {
                canonicalKeys[lowercased] = header.name
                insertionOrder.append(lowercased)
            }
            grouped[lowercased, default: []].append(header.value)
        }

        var result: [String: String] = [:]
        result.reserveCapacity(insertionOrder.count)
        for key in insertionOrder {
            let canonical = canonicalKeys[key] ?? key
            result[canonical] = grouped[key]?.joined(separator: ", ")
        }
        return result
    }
}

extension HTTPHeaders: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, String)...) {
        elements.forEach { update(name: $0.0, value: $0.1) }
    }
}

extension HTTPHeaders: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: HTTPHeader...) {
        self.init(elements)
    }
}

extension HTTPHeaders: Sequence {
    public func makeIterator() -> IndexingIterator<[HTTPHeader]> {
        headers.makeIterator()
    }
}

extension HTTPHeaders: Collection {
    public var startIndex: Int {
        headers.startIndex
    }

    public var endIndex: Int {
        headers.endIndex
    }

    public subscript(position: Int) -> HTTPHeader {
        headers[position]
    }

    public func index(after i: Int) -> Int {
        headers.index(after: i)
    }
}

extension HTTPHeaders: CustomStringConvertible {
    public var description: String {
        headers.map(\.description)
            .joined(separator: "\n")
    }
}

// MARK: - HTTPHeader

/// A representation of a single HTTP header's name / value pair.
public struct HTTPHeader: Hashable, Sendable {
    /// Name of the header.
    public let name: String

    /// Value of the header.
    public let value: String

    /// Creates an instance from the given `name` and `value`.
    ///
    /// - Parameters:
    ///   - name:  The name of the header.
    ///   - value: The value of the header.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension HTTPHeader: CustomStringConvertible {
    public var description: String {
        "\(name): \(value)"
    }
}

extension HTTPHeader {
    /// Returns an `Accept` header.
    ///
    /// - Parameter value: The `Accept` value.
    /// - Returns:         The header.
    public static func accept(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept", value: value)
    }

    /// Returns an `Accept-Charset` header.
    ///
    /// - Parameter value: The `Accept-Charset` value.
    /// - Returns:         The header.
    public static func acceptCharset(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Charset", value: value)
    }

    /// Returns an `Accept-Language` header.
    ///
    /// For a default value generated from the system's preferred languages,
    /// use ``HTTPHeader/defaultAcceptLanguage``.
    ///
    /// - Parameter value: The `Accept-Language` value.
    ///
    /// - Returns:         The header.
    public static func acceptLanguage(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Language", value: value)
    }

    /// Returns an `Accept-Encoding` header.
    ///
    /// For a default value covering the encodings supported by the current
    /// platform, use ``HTTPHeader/defaultAcceptEncoding``.
    ///
    /// - Parameter value: The `Accept-Encoding` value.
    ///
    /// - Returns:         The header
    public static func acceptEncoding(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Encoding", value: value)
    }

    /// Returns a `Basic` `Authorization` header using the `username` and `password` provided.
    ///
    /// Credentials are normalized to Unicode NFC and encoded as UTF-8 before
    /// Base64 encoding. RFC 7617 defines the `charset=UTF-8` parameter only
    /// on `WWW-Authenticate` challenges; `Authorization` credentials remain a
    /// single token68 value, so this helper does not append auth parameters.
    ///
    /// - Parameters:
    ///   - username: The username of the header.
    ///   - password: The password of the header.
    ///
    /// - Returns:    The header.
    public static func authorization(username: String, password: String) -> HTTPHeader {
        let userPass = "\(username):\(password)" as NSString
        let normalizedUserPass = userPass.precomposedStringWithCanonicalMapping
        let credential = Data(normalizedUserPass.utf8).base64EncodedString()

        return authorization("Basic \(credential)")
    }

    /// Returns a `Bearer` `Authorization` header using the `bearerToken` provided.
    ///
    /// - Parameter bearerToken: The bearer token.
    ///
    /// - Returns:               The header.
    public static func authorization(bearerToken: String) -> HTTPHeader {
        authorization("Bearer \(bearerToken)")
    }

    /// Returns an `Authorization` header.
    ///
    /// Convenience constructors are provided for the two most common
    /// schemes: ``authorization(username:password:)`` for Basic auth and
    /// ``authorization(bearerToken:)`` for Bearer tokens. Reach for this
    /// raw constructor only when neither helper fits.
    ///
    /// - Parameter value: The `Authorization` value.
    ///
    /// - Returns:         The header.
    public static func authorization(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Authorization", value: value)
    }

    /// Returns a `Content-Disposition` header.
    ///
    /// - Parameter value: The `Content-Disposition` value.
    ///
    /// - Returns:         The header.
    public static func contentDisposition(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Disposition", value: value)
    }

    /// Returns a `Content-Encoding` header.
    ///
    /// - Parameter value: The `Content-Encoding`.
    ///
    /// - Returns:         The header.
    public static func contentEncoding(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Encoding", value: value)
    }

    /// Returns a `Content-Type` header.
    ///
    /// `APIDefinition.contentType` and `MultipartAPIDefinition` set the
    /// `Content-Type` automatically when an encoded body is present, so manual
    /// configuration is rarely needed for the standard request encoding paths.
    ///
    /// - Parameter value: The `Content-Type` value.
    ///
    /// - Returns:         The header.
    public static func contentType(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Type", value: value)
    }

    /// Returns a `User-Agent` header.
    ///
    /// - Parameter value: The `User-Agent` value.
    ///
    /// - Returns:         The header.
    public static func userAgent(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "User-Agent", value: value)
    }

    /// Returns a `Sec-WebSocket-Protocol` header.
    ///
    /// - Parameter value: The `Sec-WebSocket-Protocol` value.
    /// - Returns:         The header.
    public static func websocketProtocol(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Sec-WebSocket-Protocol", value: value)
    }
}

extension [HTTPHeader] {
    /// Case-insensitively finds the index of an `HTTPHeader` with the provided name, if it exists.
    func index(of name: String) -> Int? {
        let lowercasedName = name.lowercased()
        return firstIndex { $0.name.lowercased() == lowercasedName }
    }
}

// MARK: - Defaults

extension HTTPHeaders {
    /// The default set of `HTTPHeaders` attached to every `APIDefinition`
    /// request. Includes `Accept-Encoding`, `Accept-Language`, and
    /// `User-Agent` derived from the current process.
    public static var `default`: HTTPHeaders {
        [
            .defaultAcceptEncoding,
            .defaultAcceptLanguage,
            .defaultUserAgent,
        ]
    }
}

extension HTTPHeader {
    /// The library default `Accept-Encoding` header, covering the encodings
    /// supported by the current platform.
    ///
    /// See the [Accept-Encoding HTTP header documentation](https://tools.ietf.org/html/rfc7230#section-4.2.3) .
    public static let defaultAcceptEncoding: HTTPHeader = {
        let encodings: [String]
        if #available(iOS 11.0, macOS 10.13, tvOS 11.0, watchOS 4.0, *) {
            encodings = ["br", "gzip", "deflate"]
        } else {
            encodings = ["gzip", "deflate"]
        }

        return .acceptEncoding(encodings.qualityEncoded())
    }()

    /// The library default `Accept-Language` header, generated by querying
    /// `Locale` for the user's `preferredLanguages`.
    ///
    /// See the [Accept-Language HTTP header documentation](https://tools.ietf.org/html/rfc7231#section-5.3.5).
    public static var defaultAcceptLanguage: HTTPHeader {
        makeDefaultAcceptLanguage(preferredLanguages: Locale.preferredLanguages)
    }

    /// Builds a default `Accept-Language` header from an explicit preferred
    /// language list. Useful for tests and clients that own locale selection
    /// outside `Locale.preferredLanguages`.
    public static func makeDefaultAcceptLanguage(preferredLanguages: [String]) -> HTTPHeader {
        .acceptLanguage(preferredLanguages.prefix(6).qualityEncoded())
    }

    /// The library default `User-Agent` header, derived from the running
    /// process and platform.
    ///
    /// See the [User-Agent header documentation](https://tools.ietf.org/html/rfc7231#section-5.5.3).
    ///
    /// Example: `MyApp/1.0 (com.example.MyApp; build:1; iOS 18.0.0)`
    public static var defaultUserAgent: HTTPHeader {
        makeDefaultUserAgent(bundle: .main)
    }

    /// Builds a default `User-Agent` header from an explicit bundle.
    public static func makeDefaultUserAgent(bundle: Bundle) -> HTTPHeader {
        let info = bundle.infoDictionary
        let executable =
            (info?["CFBundleExecutable"] as? String)
            ?? (ProcessInfo.processInfo.arguments.first?.split(separator: "/").last.map(String.init)) ?? "Unknown"
        let bundle = info?["CFBundleIdentifier"] as? String ?? "Unknown"
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let appBuild = info?["CFBundleVersion"] as? String ?? "Unknown"

        let osNameVersion: String = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            let osName: String = {
                #if os(iOS)
                #if targetEnvironment(macCatalyst)
                return "macOS(Catalyst)"
                #else
                return "iOS"
                #endif
                #elseif os(watchOS)
                return "watchOS"
                #elseif os(tvOS)
                return "tvOS"
                #elseif os(macOS)
                #if targetEnvironment(macCatalyst)
                return "macOS(Catalyst)"
                #else
                return "macOS"
                #endif
                #elseif swift(>=5.9.2) && os(visionOS)
                return "visionOS"
                #elseif os(Linux)
                return "Linux"
                #elseif os(Windows)
                return "Windows"
                #elseif os(Android)
                return "Android"
                #else
                return "Unknown"
                #endif
            }()

            return "\(osName) \(versionString)"
        }()

        let userAgent = "\(executable)/\(appVersion) (\(bundle); build:\(appBuild); \(osNameVersion))"

        return .userAgent(userAgent)
    }
}

extension Collection<String> {
    func qualityEncoded() -> String {
        enumerated().map { index, encoding in
            let quality = Swift.min(1.0, Swift.max(0.0, 1.0 - (Double(index) * 0.1)))
            guard quality < 1 else { return encoding }
            return "\(encoding);q=\(formattedQualityValue(quality))"
        }.joined(separator: ", ")
    }
}

private func formattedQualityValue(_ quality: Double) -> String {
    var formatted = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), quality)
    while formatted.last == "0" {
        formatted.removeLast()
    }
    if formatted.last == "." {
        formatted.removeLast()
    }
    return formatted
}

// MARK: - System Type Extensions

/// Lowercased names of request headers that are semantically single-valued
/// per RFC 7230/9110/6265. `URLRequest.headers` setter forces last-write-wins
/// on these so a duplicate entry in the input cannot accumulate via
/// `addValue`. Notably:
///
/// - `Cookie` (RFC 6265 §5.4): clients MUST NOT attach more than one
///   `Cookie` header field; some strict origins reject duplicates.
/// - `Authorization`/`Proxy-Authorization`: a single credential per request.
/// - `Content-Type`/`Content-Length`/`Host`/`User-Agent`/`From`/`Referer`:
///   list-tokenization is undefined and proxies/origins disagree on
///   handling, so duplicates are unsafe wire-format.
private let singleValueRequestHeaderNames: Set<String> = [
    "authorization",
    "proxy-authorization",
    "content-type",
    "content-length",
    "host",
    "user-agent",
    "from",
    "referer",
    "cookie",
]

private func requestHeaderDictionary(from headers: HTTPHeaders) -> [String: String] {
    var canonicalKeys: [String: String] = [:]
    var result: [String: String] = [:]

    for header in headers {
        let lowercased = header.name.lowercased()
        if singleValueRequestHeaderNames.contains(lowercased) {
            if let existingKey = canonicalKeys[lowercased], existingKey != header.name {
                result.removeValue(forKey: existingKey)
            }
            canonicalKeys[lowercased] = header.name
            result[header.name] = header.value
            continue
        }

        if let existingKey = canonicalKeys[lowercased], let existingValue = result[existingKey] {
            result[existingKey] = "\(existingValue), \(header.value)"
        } else {
            canonicalKeys[lowercased] = header.name
            result[header.name] = header.value
        }
    }

    return result
}

extension URLRequest {
    /// Returns `allHTTPHeaderFields` as `HTTPHeaders`.
    ///
    /// The setter routes per-header through `setValue`/`addValue` so that
    /// in-memory duplicate entries in `HTTPHeaders` are applied to the
    /// request via Foundation's documented `addValue` path rather than
    /// collapsed through the `[String: String]` dictionary projection.
    /// `HTTPURLResponse.allHeaderFields` has already collapsed duplicate
    /// response header lines into one dictionary value before they can reach
    /// this setter, so response round-trips cannot recover the original
    /// repeated-line structure. The first occurrence per case-insensitive
    /// name uses `setValue` to clear any pre-existing entry; subsequent
    /// occurrences use `addValue` so Foundation can apply its
    /// request-header concatenation rules.
    ///
    /// Headers that are semantically single-valued on requests
    /// (`Authorization`, `Content-Type`, `Content-Length`, `Host`,
    /// `User-Agent`) always use `setValue` so a duplicate entry in
    /// `newValue` cannot accumulate via `addValue` — last write wins,
    /// which matches the wire-protocol contract for those names.
    public var headers: HTTPHeaders {
        get { allHTTPHeaderFields.map(HTTPHeaders.init) ?? HTTPHeaders() }
        set {
            if let existing = allHTTPHeaderFields {
                for key in existing.keys {
                    setValue(nil, forHTTPHeaderField: key)
                }
            }
            var seenLowercased: Set<String> = []
            for header in newValue {
                let lowercased = header.name.lowercased()
                let isSingleValue = singleValueRequestHeaderNames.contains(lowercased)
                if isSingleValue || seenLowercased.insert(lowercased).inserted {
                    setValue(header.value, forHTTPHeaderField: header.name)
                } else {
                    addValue(header.value, forHTTPHeaderField: header.name)
                }
            }
        }
    }
}

extension HTTPURLResponse {
    /// Returns `allHeaderFields` as `HTTPHeaders`.
    public var headers: HTTPHeaders {
        (allHeaderFields as? [String: String]).map(HTTPHeaders.init) ?? HTTPHeaders()
    }
}

extension URLSessionConfiguration {
    /// Returns `httpAdditionalHeaders` as `HTTPHeaders`.
    public var headers: HTTPHeaders {
        get { (httpAdditionalHeaders as? [String: String]).map(HTTPHeaders.init) ?? HTTPHeaders() }
        set { httpAdditionalHeaders = requestHeaderDictionary(from: newValue) }
    }
}
