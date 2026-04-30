import Foundation

/// Canonical InnoNetwork date formatter.
///
/// Each access returns a freshly configured formatter so mutable Foundation
/// formatter state cannot leak across concurrent requests or endpoints.
package var defaultDateFormatter: DateFormatter { makeDefaultDateFormatter() }

/// Canonical default `JSONEncoder` for InnoNetwork request bodies. Used as the
/// implicit default when a ``TransportPolicy`` factory does not receive an
/// explicit encoder. Each access returns a freshly configured encoder so caller
/// mutation cannot leak across endpoints or concurrent requests.
public var defaultRequestEncoder: JSONEncoder { makeDefaultRequestEncoder() }

/// Canonical default `JSONDecoder` for InnoNetwork response bodies. Used as
/// the implicit default when a ``TransportPolicy`` factory does not receive
/// an explicit decoder. Each access returns a freshly configured decoder so
/// caller mutation cannot leak across endpoints or concurrent requests.
public var defaultResponseDecoder: JSONDecoder { makeDefaultResponseDecoder() }

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
