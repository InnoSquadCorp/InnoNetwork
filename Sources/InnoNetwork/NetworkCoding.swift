import Foundation

/// Module-level cache for the canonical InnoNetwork date formatter.
///
/// `DateFormatter` is the heaviest object on the default request/response
/// coding hot path. Foundation guarantees thread-safety for read-only use, so
/// every default encoder/decoder shares this single instance. Do not mutate
/// the shared formatter; create a fresh `DateFormatter` if you need different
/// configuration.
package let defaultDateFormatter: DateFormatter = makeDefaultDateFormatter()

/// Canonical default `JSONEncoder` for InnoNetwork request bodies. Used as the
/// implicit default when a ``TransportPolicy`` factory does not receive an
/// explicit encoder. **Do not mutate this instance** — create a fresh
/// `JSONEncoder` if you need different configuration; the cached instance is
/// shared across the package.
public let defaultRequestEncoder: JSONEncoder = makeDefaultRequestEncoder()

/// Canonical default `JSONDecoder` for InnoNetwork response bodies. Used as
/// the implicit default when a ``TransportPolicy`` factory does not receive
/// an explicit decoder. **Do not mutate this instance** — create a fresh
/// `JSONDecoder` if you need different configuration; the cached instance is
/// shared across the package.
public let defaultResponseDecoder: JSONDecoder = makeDefaultResponseDecoder()

package func makeDefaultDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

package func makeDefaultRequestEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(defaultDateFormatter)
    return encoder
}

package func makeDefaultResponseDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .formatted(defaultDateFormatter)
    return decoder
}
