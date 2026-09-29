import Foundation

/// Single-pass RFC 9110 media-type parameters. Quoted semicolons are data,
/// quoted pairs contribute their escaped byte, and duplicate boundaries fail
/// closed. Unknown values are validated without retaining their decoded bytes.
struct MultipartBoundaryParameter {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ contentType: String) { bytes = Array(contentType.utf8) }

    mutating func parse() -> String? {
        skipWhitespace()
        guard token() != nil, consume(47), token() != nil else { return nil }
        skipWhitespace()
        var boundary: String?
        while cursor < bytes.count {
            guard consume(59) else { return nil }
            skipWhitespace()
            // RFC parameters permit an empty entry after a semicolon.
            if cursor == bytes.count || bytes[cursor] == 59 { continue }
            guard let nameRange = token(), consume(61) else { return nil }
            let isBoundary = String(decoding: bytes[nameRange], as: UTF8.self).lowercased() == "boundary"
            // No whitespace is allowed on either side of '='.
            guard let value = value(capture: isBoundary) else { return nil }
            if isBoundary {
                guard boundary == nil else { return nil }
                boundary = String(bytes: value, encoding: .utf8)
                guard boundary != nil else { return nil }
            }
            skipWhitespace()
        }
        return boundary
    }

    private mutating func value(capture: Bool) -> [UInt8]? {
        guard consume(34) else {
            guard let range = token() else { return nil }
            if capture {
                guard range.count <= 70 else { return nil }
                return Array(bytes[range])
            }
            return []
        }
        var value: [UInt8] = []
        while cursor < bytes.count {
            var byte = bytes[cursor]
            cursor += 1
            if byte == 34 { return value }
            if byte == 92 {
                guard cursor < bytes.count else { return nil }
                byte = bytes[cursor]
                cursor += 1
            }
            // HTAB / SP / VCHAR / obs-text; quotes and backslashes above
            // are either syntax or a permitted quoted-pair payload.
            guard byte == 9 || byte == 32 || (33...126).contains(byte) || byte >= 128 else { return nil }
            if capture {
                guard value.count < 70 else { return nil }
                value.append(byte)
            }
        }
        return nil
    }

    private mutating func token() -> Range<Int>? {
        let start = cursor
        while cursor < bytes.count, Self.isTokenByte(bytes[cursor]) { cursor += 1 }
        return cursor > start ? start..<cursor : nil
    }

    private mutating func skipWhitespace() {
        while cursor < bytes.count, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard cursor < bytes.count, bytes[cursor] == byte else { return false }
        cursor += 1
        return true
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126: true
        default: false
        }
    }
}
