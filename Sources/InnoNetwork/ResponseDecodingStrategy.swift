import Foundation

/// Describes how an endpoint decodes its response body into the typed output.
///
/// Endpoints reach this enum through ``TransportPolicy``; most call sites
/// don't construct a ``ResponseDecodingStrategy`` value directly. Use the
/// ``TransportPolicy`` factories instead.
public enum ResponseDecodingStrategy<Output: Sendable>: Sendable {
    /// Decode the response body as JSON using the supplied decoder.
    case json(JSONDecoder)

    /// Decode the response body as JSON, but treat empty bodies (or HTTP
    /// 204) as the empty value of an `HTTPEmptyResponseDecodable` output.
    case jsonAllowingEmpty(JSONDecoder)

    /// Decode the response body using a custom closure. The closure receives
    /// the raw `Data` plus the wrapping ``Response`` for status / header
    /// inspection.
    case custom(@Sendable (Data, Response) throws -> Output)
}
