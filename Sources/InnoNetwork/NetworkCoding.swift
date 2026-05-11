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
/// snake_case property names should opt in via
/// ``makeDefaultRequestEncoder(keyEncodingStrategy:)`` (or assign on the
/// returned instance) — InnoNetwork stays neutral by default so models with
/// custom `CodingKeys` are not silently double-translated.
public var defaultRequestEncoder: JSONEncoder { makeDefaultRequestEncoder() }

/// Canonical default `JSONDecoder` for InnoNetwork response bodies. Used as
/// the implicit default when a ``TransportPolicy`` factory does not receive
/// an explicit decoder. Each access returns a freshly configured decoder so
/// caller mutation cannot leak across endpoints or concurrent requests.
///
/// The default `keyDecodingStrategy` is `.useDefaultKeys`; opt in to
/// snake_case translation through
/// ``makeDefaultResponseDecoder(keyDecodingStrategy:)``.
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
package enum SharedCoders {
    /// Cached request encoder. Do not mutate.
    package static let requestEncoder: JSONEncoder = makeDefaultRequestEncoder()
    /// Cached response decoder. Do not mutate.
    package static let responseDecoder: JSONDecoder = makeDefaultResponseDecoder()
}
