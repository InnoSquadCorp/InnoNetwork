import Foundation

/// Percent-encoding helpers that adhere to RFC 3986 §2.3 unreserved set
/// (`ALPHA / DIGIT / "-" / "." / "_" / "~"`), as opposed to WHATWG
/// `application/x-www-form-urlencoded`. Use these for URI path segments,
/// path components, and OAuth/OIDC artifacts that are required to be
/// invariant under round-trip encoding (PKCE `code_verifier` per RFC 7636
/// §4.1, `state`, `nonce`).
public enum RFC3986Encoding {
    /// Returns `value` percent-encoded using the RFC 3986 §2.3 unreserved
    /// set. Bytes outside that set are escaped as their UTF-8 octets in
    /// uppercase hexadecimal. `~` is left literal — this is the only
    /// difference from `application/x-www-form-urlencoded`-style encoders
    /// that historically escape `~` and break PKCE round-trips on RFC 7636
    /// servers that compare the verifier byte-for-byte.
    public static func encode(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                0x2D, 0x2E, 0x5F, 0x7E:
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
}
