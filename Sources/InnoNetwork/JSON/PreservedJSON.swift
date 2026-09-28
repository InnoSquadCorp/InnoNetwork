import Foundation

/// Resource limits shared by preserved JSON parsing and schema validation.
/// Values outside the documented hard ceilings fail, rather than disabling a limit.
public struct JSONProcessingLimits: Sendable, Equatable {
    /// Maximum UTF-8 input/output bytes (hard ceiling: 16 MiB). Encoding also
    /// bounds the live intermediate representation's raw bytes, escaped keys and
    /// delimiters by this value, including detached containers still held by the
    /// caller. Overwrites release their old charge when the old value is released.
    /// This is not a peak-RSS bound: Foundation scalar temporaries, container
    /// overhead and arbitrary application `Encodable` work are not included.
    public let maximumBytes: Int
    /// Maximum container/value nesting, counting the root as one (hard ceiling: 128).
    public let maximumDepth: Int
    /// Maximum parsed values (hard ceiling: 1,000,000).
    public let maximumNodes: Int
    /// Work budget per codec call and per schema validation (hard ceiling: 1,000,000).
    /// A validation shares this budget across inspection and all alternatives.
    public let maximumValidationWork: Int

    /// Creates limits. Invalid settings throw when used, including for empty input.
    public init(
        maximumBytes: Int = 1_048_576, maximumDepth: Int = 64,
        maximumNodes: Int = 100_000, maximumValidationWork: Int = 100_000
    ) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumValidationWork = maximumValidationWork
    }

    func validate() throws {
        guard (1...16_777_216).contains(maximumBytes), (1...128).contains(maximumDepth),
            (1...1_000_000).contains(maximumNodes), (1...1_000_000).contains(maximumValidationWork)
        else { throw JSONProcessingError.invalidLimits }
    }
}

/// Payload-free errors: diagnostics never include JSON values, keys, or credentials.
public enum JSONProcessingError: Error, Sendable, Equatable {
    /// The configured limits are zero, negative, or exceed hard ceilings.
    case invalidLimits
    /// Input is not one strict UTF-8 JSON value.
    case invalidJSON
    /// Two object keys compare equal in Swift, including canonically equivalent Unicode keys.
    case duplicateKey
    /// Parsing, schema inspection, or validation exhausted its resource budget.
    case resourceLimit
    /// No schema alternative matched the preserved value.
    case noMatchingSchema
    /// A Foundation or third-party codec cannot expose/preserve original JSON tokens.
    case unsupportedCoder
    /// A schema has malformed keyword values or references.
    case invalidSchema
    /// A schema uses a dialect feature outside the documented validation subset.
    case unsupportedSchema
}

/// An immutable, bounded JSON document retaining original bytes and number lexemes.
///
/// Parsing never converts numbers to `Double` or `Decimal`. Unknown object fields,
/// whitespace, and number spellings round-trip through ``data`` unchanged. Duplicate
/// keys (including Swift Unicode-equivalent keys), invalid UTF-8, and unpaired Unicode
/// surrogates are rejected. Codable support requires ``PreservedJSONCoding``:
/// an ordinary Foundation `Decoder` cannot provide the original numeric tokens.
public struct PreservedJSON: Sendable, Equatable, Codable {
    /// Original validated UTF-8 bytes, including surrounding whitespace.
    public let data: Data
    let root: JSONNode

    /// Parses exactly one JSON value under the supplied resource limits.
    public init(data: Data, limits: JSONProcessingLimits = .init()) throws {
        try limits.validate()
        guard data.count <= limits.maximumBytes else { throw JSONProcessingError.resourceLimit }
        var parser = JSONParser(bytes: Array(data), limits: limits)
        self.root = try parser.parse()
        self.data = Data(data)
    }

    /// Produces an application-owned typed view without modifying the preserved bytes.
    /// The supplied decoder's numeric range, rounding, date and key strategies apply
    /// only to the view; successful decoding is not JSON Schema validation.
    public func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Equality compares exact document bytes, not mathematical or structural equality.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.data == rhs.data }

    /// Decodes only through ``PreservedJSONCoding``; ordinary codecs fail explicitly.
    public init(from decoder: any Decoder) throws {
        guard let decoder = decoder as? JSONValueDecoder else { throw JSONProcessingError.unsupportedCoder }
        try self.init(data: decoder.data, limits: decoder.context.limits)
    }

    /// Encodes only through ``PreservedJSONCoding``, preserving original number tokens.
    public func encode(to encoder: any Encoder) throws {
        guard let encoder = encoder as? JSONValueEncoder else { throw JSONProcessingError.unsupportedCoder }
        try encoder.raw(data)
    }
}

struct JSONNode: Sendable {
    let range: Range<Int>
    let value: Value

    indirect enum Value: Sendable {
        case object([String: JSONNode])
        case array([JSONNode])
        case string
        case number(isInteger: Bool)
        case boolean
        case null
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    let limits: JSONProcessingLimits
    var index = 0
    var nodes = 0

    mutating func parse() throws -> JSONNode {
        let result = try value(depth: 1)
        whitespace()
        guard index == bytes.count else { throw JSONProcessingError.invalidJSON }
        return result
    }

    mutating func value(depth: Int) throws -> JSONNode {
        guard depth <= limits.maximumDepth, nodes < limits.maximumNodes else {
            throw JSONProcessingError.resourceLimit
        }
        nodes += 1
        whitespace()
        let start = index
        guard index < bytes.count else { throw JSONProcessingError.invalidJSON }
        let result: JSONNode.Value
        switch bytes[index] {
        case 123:
            index += 1
            var members: [String: JSONNode] = [:]
            whitespace()
            if !take(125) {
                repeat {
                    whitespace()
                    let key = try string()
                    guard members[key] == nil else { throw JSONProcessingError.duplicateKey }
                    whitespace()
                    guard take(58) else { throw JSONProcessingError.invalidJSON }
                    members[key] = try value(depth: depth + 1)
                    whitespace()
                    if take(125) { break }
                    guard take(44) else { throw JSONProcessingError.invalidJSON }
                } while true
            }
            result = .object(members)
        case 91:
            index += 1
            var elements: [JSONNode] = []
            whitespace()
            if !take(93) {
                repeat {
                    elements.append(try value(depth: depth + 1))
                    whitespace()
                    if take(93) { break }
                    guard take(44) else { throw JSONProcessingError.invalidJSON }
                } while true
            }
            result = .array(elements)
        case 34:
            _ = try string()
            result = .string
        case 116:
            try literal([116, 114, 117, 101])
            result = .boolean
        case 102:
            try literal([102, 97, 108, 115, 101])
            result = .boolean
        case 110:
            try literal([110, 117, 108, 108])
            result = .null
        default:
            result = .number(isInteger: try number())
        }
        return JSONNode(range: start..<index, value: result)
    }

    mutating func string() throws -> String {
        let start = index
        guard take(34) else { throw JSONProcessingError.invalidJSON }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                // Foundation handles escape decoding only, never JSON numeric conversion.
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                    throw JSONProcessingError.invalidJSON
                }
                return value
            }
            guard byte >= 32 else { throw JSONProcessingError.invalidJSON }
            if byte == 92 {
                guard index < bytes.count else { throw JSONProcessingError.invalidJSON }
                let escape = bytes[index]
                index += 1
                if escape == 117 {
                    let first = try hexQuad()
                    if (0xD800...0xDBFF).contains(first) {
                        guard take(92), take(117), (0xDC00...0xDFFF).contains(try hexQuad()) else {
                            throw JSONProcessingError.invalidJSON
                        }
                    } else if (0xDC00...0xDFFF).contains(first) {
                        throw JSONProcessingError.invalidJSON
                    }
                } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) {
                    throw JSONProcessingError.invalidJSON
                }
            }
        }
        throw JSONProcessingError.invalidJSON
    }

    mutating func hexQuad() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw JSONProcessingError.invalidJSON }
            let byte = bytes[index]
            index += 1
            let digit: Int
            switch byte {
            case 48...57: digit = Int(byte - 48)
            case 65...70: digit = Int(byte - 55)
            case 97...102: digit = Int(byte - 87)
            default: throw JSONProcessingError.invalidJSON
            }
            value = value * 16 + digit
        }
        return value
    }

    mutating func number() throws -> Bool {
        _ = take(45)
        var nonzero = false
        var trailingZeros = 0
        func track(_ byte: UInt8, nonzero: inout Bool, zeros: inout Int) {
            nonzero = nonzero || byte != 48
            zeros = byte == 48 ? zeros + 1 : 0
        }
        if take(48) {
            trailingZeros = 1
        } else {
            guard index < bytes.count, (49...57).contains(bytes[index]) else {
                throw JSONProcessingError.invalidJSON
            }
            while index < bytes.count, (48...57).contains(bytes[index]) {
                track(bytes[index], nonzero: &nonzero, zeros: &trailingZeros)
                index += 1
            }
        }
        var fraction = 0
        if take(46) {
            while index < bytes.count, (48...57).contains(bytes[index]) {
                track(bytes[index], nonzero: &nonzero, zeros: &trailingZeros)
                index += 1
                fraction += 1
            }
            guard fraction > 0 else { throw JSONProcessingError.invalidJSON }
        }
        var exponent = 0
        if take(101) || take(69) {
            let negative = take(45)
            if !negative { _ = take(43) }
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) {
                // Saturation is sufficient for the integer comparison, without overflow
                // or allocating a power-of-ten expansion for adversarial exponents.
                exponent = min(bytes.count + 1, exponent * 10 + Int(bytes[index] - 48))
                index += 1
            }
            guard index > start else { throw JSONProcessingError.invalidJSON }
            if negative { exponent = -exponent }
        }
        return !nonzero || exponent >= fraction - trailingZeros
    }

    mutating func literal(_ expected: [UInt8]) throws {
        for byte in expected {
            guard take(byte) else { throw JSONProcessingError.invalidJSON }
        }
    }

    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
