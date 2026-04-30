import Foundation

/// Module-level cache for the canonical InnoNetwork date formatter.
///
/// `DateFormatter` is the heaviest object on the default request/response
/// coding hot path. Foundation guarantees thread-safety for read-only use, so
/// every default encoder/decoder shares this single instance. Do not mutate
/// the shared formatter; create a fresh `DateFormatter` if you need different
/// configuration.
package let defaultDateFormatter: DateFormatter = makeDefaultDateFormatter()

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
