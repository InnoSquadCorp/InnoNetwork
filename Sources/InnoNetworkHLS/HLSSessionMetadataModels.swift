import Foundation

/// The content carried by one `EXT-X-SESSION-DATA` declaration.
public enum HLSSessionDataContent: Equatable, Sendable {
    /// An inline session value.
    case value(String)

    /// A resolved remote session-data resource and its declared format.
    case remote(URL, format: HLSSessionDataFormat)
}

/// The representation of a remote `EXT-X-SESSION-DATA` resource.
public enum HLSSessionDataFormat: Equatable, Sendable {
    /// A JSON document.
    case json

    /// An application-defined binary resource.
    case raw
}

/// Multivariant session metadata shared by every media selection.
public struct HLSSessionData: Equatable, Sendable {
    /// The application-defined data identifier.
    public let dataID: String

    /// The optional BCP 47 language tag.
    public let language: String?

    /// The inline value or resolved remote resource.
    public let content: HLSSessionDataContent

    /// Custom extension attribute names, without their values.
    public let extensionAttributeNames: Set<String>
}

/// A multivariant `EXT-X-SESSION-KEY` declaration.
///
/// This model exposes key-delivery metadata only. It never fetches or stores
/// key bytes.
public struct HLSSessionKey: Equatable, Sendable {
    /// The HLS encryption method, such as `AES-128` or `SAMPLE-AES`.
    public let method: String

    /// The resolved key-delivery URL.
    public let url: URL

    /// The key format, defaulting to `identity`.
    public let keyFormat: String

    /// Supported key-format versions in declaration order.
    public let keyFormatVersions: [Int]

    /// The optional 128-bit initialization vector.
    public let initializationVector: Data?

    /// Whether the declaration uses the identity key format.
    public var isIdentityFormat: Bool {
        keyFormat.lowercased() == "identity"
    }

    /// Custom extension attribute names, without their values.
    public let extensionAttributeNames: Set<String>
}
