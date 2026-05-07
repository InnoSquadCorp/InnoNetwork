//
//  HTTPHeader+SystemTypes.swift
//  Network
//
//  Created by Chang Woo Son on 6/21/24.
//

import Foundation

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
