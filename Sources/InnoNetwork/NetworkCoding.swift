import Foundation

/// Canonical InnoNetwork date formatter.
///
/// Returns a freshly configured `DateFormatter` on every access so callers
/// can mutate the instance and concurrent encoders/decoders never share
/// formatter state.
package var defaultDateFormatter: DateFormatter { makeDefaultDateFormatter() }

/// Canonical default `JSONEncoder` for InnoNetwork request bodies. Used as the
/// implicit default when a ``TransportPolicy`` factory does not receive an
/// explicit encoder. Each access returns a freshly configured encoder so caller
/// mutation cannot leak across endpoints or concurrent requests.
///
/// The default `keyEncodingStrategy` is `.useDefaultKeys`. Codebases that ship
/// snake_case property names should copy `defaultRequestEncoder`, assign its
/// `keyEncodingStrategy`, and pass it to the relevant ``TransportPolicy``
/// factory. InnoNetwork stays neutral by default so models with custom
/// `CodingKeys` are not silently double-translated.
public var defaultRequestEncoder: JSONEncoder { makeDefaultRequestEncoder() }

/// Canonical default `JSONDecoder` for InnoNetwork response bodies. Used as
/// the implicit default when a ``TransportPolicy`` factory does not receive
/// an explicit decoder. Each access returns a freshly configured decoder so
/// caller mutation cannot leak across endpoints or concurrent requests.
///
/// The default `keyDecodingStrategy` is `.useDefaultKeys`; opt in to
/// snake_case translation by copying `defaultResponseDecoder`, assigning its
/// `keyDecodingStrategy`, and passing it to the relevant ``TransportPolicy``
/// factory.
public var defaultResponseDecoder: JSONDecoder { makeDefaultResponseDecoder() }

package func makeDefaultDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

package func makeDefaultRequestEncoder(
    keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys
) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(defaultDateFormatter)
    encoder.keyEncodingStrategy = keyEncodingStrategy
    return encoder
}

package func makeDefaultResponseDecoder(
    keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .formatted(defaultDateFormatter)
    decoder.keyDecodingStrategy = keyDecodingStrategy
    return decoder
}

/// Shared, *non-mutated* coder/decoder used by InnoNetwork's internal hot
/// paths (e.g., the promoted-empty-JSON response decoder) where a fresh
/// instance allocation on every call adds measurable overhead.
///
/// The public ``defaultRequestEncoder``/``defaultResponseDecoder``
/// accessors continue to return fresh instances — caller mutation is part
/// of the documented contract. These shared instances are package-private
/// and must **never** be mutated; treat their configuration as frozen
/// after module load. `JSONEncoder`/`JSONDecoder` are documented as
/// concurrency-safe for read-only use once configured.
///
/// Enforcement: the cached coder instances stay private. Internal call sites
/// can only reach them through wrapper methods that perform a single
/// `decode` operation, so property mutation cannot compile.
package enum SharedCoders {
    private static let responseDecoder: JSONDecoder = makeDefaultResponseDecoder()

    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try responseDecoder.decode(type, from: data)
    }
}
