import Foundation

/// Describes how an endpoint serializes its request body or query string.
///
/// Endpoints reach this enum through ``TransportPolicy``; most call sites
/// don't construct a ``RequestEncodingPolicy`` value directly. Use the
/// ``TransportPolicy`` factories (`.json`, `.query`, `.formURLEncoded`,
/// `.multipart`, `.custom`) instead.
public enum RequestEncodingPolicy: Sendable {
    /// No encoding. Used by multipart endpoints (the body is encoded
    /// separately) and by `.custom` transports that build the body manually.
    case none

    /// Encode parameters as a query string using the supplied encoder.
    /// `rootKey` wraps top-level scalar/array values into a single named
    /// parameter when set.
    case query(URLQueryEncoder, rootKey: String?)

    /// Encode parameters as a JSON request body using the supplied encoder.
    case json(JSONEncoder)

    /// Encode parameters as a form-url-encoded request body using the
    /// supplied query encoder. `rootKey` follows the same semantics as
    /// ``query(_:rootKey:)``.
    case formURLEncoded(URLQueryEncoder, rootKey: String?)
}
