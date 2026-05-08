import Foundation
import os

public enum URLQueryArrayEncodingStrategy: Sendable, Equatable {
    /// Encodes arrays as `tags[0]=swift&tags[1]=ios`.
    case indexed
    /// Encodes arrays as `tags[]=swift&tags[]=ios`.
    case bracketed
    /// Encodes arrays as `tags=swift&tags=ios`.
    case repeated
}

/// Controls how `Float`/`Double` values that cannot be expressed in a query
/// string (NaN, +/-infinity) are encoded. Default is `.throw`, which surfaces
/// the bad value as a typed error so misconfigured payloads do not silently
/// land on the wire as Swift's `"nan"` / `"inf"` debug spellings.
public enum URLQueryFloatEncodingStrategy: Sendable, Equatable {
    case `throw`
    case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
}

public struct URLQueryEncoder: Sendable {
    public enum EncodingError: Error, Sendable, Equatable {
        case unsupportedTopLevelValue
        case unsupportedValue(reason: String)
    }

    public var keyEncodingStrategy: URLQueryKeyEncodingStrategy
    public var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    public var arrayEncodingStrategy: URLQueryArrayEncodingStrategy
    public var nonConformingFloatEncodingStrategy: URLQueryFloatEncodingStrategy

    public init(
        keyEncodingStrategy: URLQueryKeyEncodingStrategy = .useDefaultKeys,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil,
        arrayEncodingStrategy: URLQueryArrayEncodingStrategy = .indexed,
        nonConformingFloatEncodingStrategy: URLQueryFloatEncodingStrategy = .throw
    ) {
        self.keyEncodingStrategy = keyEncodingStrategy
        self.dateEncodingStrategy = dateEncodingStrategy ?? .formatted(defaultDateFormatter)
        self.arrayEncodingStrategy = arrayEncodingStrategy
        self.nonConformingFloatEncodingStrategy = nonConformingFloatEncodingStrategy
    }

    public init(
        keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil,
        arrayEncodingStrategy: URLQueryArrayEncodingStrategy = .indexed,
        nonConformingFloatEncodingStrategy: URLQueryFloatEncodingStrategy = .throw
    ) {
        self.init(
            keyEncodingStrategy: URLQueryKeyEncodingStrategy(keyEncodingStrategy),
            dateEncodingStrategy: dateEncodingStrategy,
            arrayEncodingStrategy: arrayEncodingStrategy,
            nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy
        )
    }

    public func encode<T: Encodable>(_ value: T, rootKey: String? = nil) throws -> [URLQueryItem] {
        let box = QueryValueBox()
        let encoder = _URLQueryValueEncoder(options: options, box: box)
        try value.encode(to: encoder)
        return try flattenRoot(try box.makeValue(), rootKey: rootKey)
    }

    public func encodeForm<T: Encodable>(_ value: T, rootKey: String? = nil) throws -> Data {
        let queryItems = try encode(value, rootKey: rootKey)
        let pairs: [String] = queryItems.map { item in
            let name = Self.formEscape(item.name)
            let value = Self.formEscape(item.value ?? "")
            return "\(name)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// Percent-encodes per the `application/x-www-form-urlencoded` rules
    /// (HTML5 form submission): unreserved alphanumerics and `*-._` pass
    /// through unchanged, space becomes `+`, and everything else is escaped
    /// as percent-encoded UTF-8 octets. This differs from
    /// `URLComponents.percentEncodedQuery`, which leaves `space` as `%20`.
    ///
    /// **Use ``RFC3986Encoding/encode(_:)`` instead** for URI path segments
    /// or OAuth artifacts (PKCE `code_verifier`, `state`, `nonce`) that
    /// require RFC 3986 §2.3 unreserved-set semantics — those callers must
    /// preserve `~` and percent-encode `+`/space identically (`%2B`/`%20`).
    /// Form encoding is reserved for `application/x-www-form-urlencoded`
    /// request bodies.
    static func formEscape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x20:
                escaped.append("+")
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                0x2A, 0x2D, 0x2E, 0x5F:
                escaped.append(Character(UnicodeScalar(byte)))
            default:
                let hex = String(byte, radix: 16, uppercase: true)
                escaped.append("%")
                if hex.count == 1 { escaped.append("0") }
                escaped.append(hex)
            }
        }
        return escaped
    }

    private var options: _URLQueryEncodingOptions {
        _URLQueryEncodingOptions(
            keyEncodingStrategy: keyEncodingStrategy,
            dateEncodingStrategy: dateEncodingStrategy,
            arrayEncodingStrategy: arrayEncodingStrategy,
            nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy
        )
    }

    private func flattenRoot(
        _ value: QueryValue,
        rootKey: String?
    ) throws -> [URLQueryItem] {
        switch value {
        case .object(let object):
            return
                object
                .sorted { $0.key < $1.key }
                .flatMap { key, value in
                    flatten(key: key, value: value)
                }
        case .array, .scalar, .null:
            guard let rootKey else {
                throw EncodingError.unsupportedTopLevelValue
            }
            return flatten(key: rootKey, value: value)
        }
    }

    private func flatten(key: String, value: QueryValue) -> [URLQueryItem] {
        switch value {
        case .object(let object):
            return
                object
                .sorted { $0.key < $1.key }
                .flatMap { nestedKey, nestedValue in
                    flatten(key: "\(key)[\(nestedKey)]", value: nestedValue)
                }
        case .array(let array):
            return array.enumerated().flatMap { index, element in
                flatten(key: arrayKey(parentKey: key, index: index), value: element)
            }
        case .scalar(let string):
            return [URLQueryItem(name: key, value: string)]
        case .null:
            return []
        }
    }

    private func arrayKey(parentKey: String, index: Int) -> String {
        switch arrayEncodingStrategy {
        case .indexed:
            return "\(parentKey)[\(index)]"
        case .bracketed:
            return "\(parentKey)[]"
        case .repeated:
            return parentKey
        }
    }
}
