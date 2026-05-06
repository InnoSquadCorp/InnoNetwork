import Foundation
import os

public enum URLQueryArrayEncodingStrategy: Sendable, Equatable {
    /// Encodes arrays as `tags[0]=swift&tags[1]=ios`.
    case indexed
    /// Encodes arrays as `tags[]=swift&tags[]=ios`.
    case bracketed
    /// Encodes arrays as `tags=swift&tags=ios`.
    case repeated
}

/// Controls how `Float`/`Double` values that cannot be expressed in a query
/// string (NaN, +/-infinity) are encoded. Default is `.throw`, which surfaces
/// the bad value as a typed error so misconfigured payloads do not silently
/// land on the wire as Swift's `"nan"` / `"inf"` debug spellings.
public enum URLQueryFloatEncodingStrategy: Sendable, Equatable {
    case `throw`
    case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
}

public struct URLQueryEncoder: Sendable {
    public enum EncodingError: Error, Sendable, Equatable {
        case unsupportedTopLevelValue
        case unsupportedValue(reason: String)
    }

    public var keyEncodingStrategy: URLQueryKeyEncodingStrategy
    public var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    public var arrayEncodingStrategy: URLQueryArrayEncodingStrategy
    public var nonConformingFloatEncodingStrategy: URLQueryFloatEncodingStrategy

    public init(
        keyEncodingStrategy: URLQueryKeyEncodingStrategy = .useDefaultKeys,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil,
        arrayEncodingStrategy: URLQueryArrayEncodingStrategy = .indexed,
        nonConformingFloatEncodingStrategy: URLQueryFloatEncodingStrategy = .throw
    ) {
        self.keyEncodingStrategy = keyEncodingStrategy
        self.dateEncodingStrategy = dateEncodingStrategy ?? .formatted(defaultDateFormatter)
        self.arrayEncodingStrategy = arrayEncodingStrategy
        self.nonConformingFloatEncodingStrategy = nonConformingFloatEncodingStrategy
    }

    public init(
        keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil,
        arrayEncodingStrategy: URLQueryArrayEncodingStrategy = .indexed,
        nonConformingFloatEncodingStrategy: URLQueryFloatEncodingStrategy = .throw
    ) {
        self.init(
            keyEncodingStrategy: URLQueryKeyEncodingStrategy(keyEncodingStrategy),
            dateEncodingStrategy: dateEncodingStrategy,
            arrayEncodingStrategy: arrayEncodingStrategy,
            nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy
        )
    }

    public func encode<T: Encodable>(_ value: T, rootKey: String? = nil) throws -> [URLQueryItem] {
        let box = QueryValueBox()
        let encoder = _URLQueryValueEncoder(options: options, box: box)
        try value.encode(to: encoder)
        return try flattenRoot(try box.makeValue(), rootKey: rootKey)
    }

    public func encodeForm<T: Encodable>(_ value: T, rootKey: String? = nil) throws -> Data {
        let queryItems = try encode(value, rootKey: rootKey)
        let pairs: [String] = queryItems.map { item in
            let name = Self.formEscape(item.name)
            let value = Self.formEscape(item.value ?? "")
            return "\(name)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// Percent-encodes per the `application/x-www-form-urlencoded` rules
    /// (HTML5 form submission): unreserved alphanumerics and `*-._` pass
    /// through unchanged, space becomes `+`, and everything else is escaped
    /// as percent-encoded UTF-8 octets. This differs from
    /// `URLComponents.percentEncodedQuery`, which leaves `space` as `%20`.
    ///
    /// **Use ``RFC3986Encoding/encode(_:)`` instead** for URI path segments
    /// or OAuth artifacts (PKCE `code_verifier`, `state`, `nonce`) that
    /// require RFC 3986 §2.3 unreserved-set semantics — those callers must
    /// preserve `~` and percent-encode `+`/space identically (`%2B`/`%20`).
    /// Form encoding is reserved for `application/x-www-form-urlencoded`
    /// request bodies.
    static func formEscape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x20:
                escaped.append("+")
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                0x2A, 0x2D, 0x2E, 0x5F:
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

    private var options: _URLQueryEncodingOptions {
        _URLQueryEncodingOptions(
            keyEncodingStrategy: keyEncodingStrategy,
            dateEncodingStrategy: dateEncodingStrategy,
            arrayEncodingStrategy: arrayEncodingStrategy,
            nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy
        )
    }

    private func flattenRoot(
        _ value: QueryValue,
        rootKey: String?
    ) throws -> [URLQueryItem] {
        switch value {
        case .object(let object):
            return object
                .sorted { $0.key < $1.key }
                .flatMap { key, value in
                    flatten(key: key, value: value)
                }
        case .array, .scalar, .null:
            guard let rootKey else {
                throw EncodingError.unsupportedTopLevelValue
            }
            return flatten(key: rootKey, value: value)
        }
    }

    private func flatten(key: String, value: QueryValue) -> [URLQueryItem] {
        switch value {
        case .object(let object):
            return object
                .sorted { $0.key < $1.key }
                .flatMap { nestedKey, nestedValue in
                    flatten(key: "\(key)[\(nestedKey)]", value: nestedValue)
                }
        case .array(let array):
            return array.enumerated().flatMap { index, element in
                flatten(key: arrayKey(parentKey: key, index: index), value: element)
            }
        case .scalar(let string):
            return [URLQueryItem(name: key, value: string)]
        case .null:
            return []
        }
    }

    private func arrayKey(parentKey: String, index: Int) -> String {
        switch arrayEncodingStrategy {
        case .indexed:
            return "\(parentKey)[\(index)]"
        case .bracketed:
            return "\(parentKey)[]"
        case .repeated:
            return parentKey
        }
    }
}

private enum QueryValue: Sendable {
    case object([String: QueryValue])
    case array([QueryValue])
    case scalar(String)
    case null
}

private final class QueryValueBox {
    enum Storage {
        case unset
        case object([String: QueryValueBox])
        case array([QueryValueBox])
        case scalar(String)
        case null
    }

    var storage: Storage = .unset

    func makeValue() throws -> QueryValue {
        switch storage {
        case .unset:
            return .object([:])
        case .object(let object):
            var mapped: [String: QueryValue] = [:]
            for (key, value) in object {
                mapped[key] = try value.makeValue()
            }
            return .object(mapped)
        case .array(let array):
            return .array(try array.map { try $0.makeValue() })
        case .scalar(let string):
            return .scalar(string)
        case .null:
            return .null
        }
    }

    @discardableResult
    func makeObject() -> [String: QueryValueBox] {
        switch storage {
        case .object(let object):
            return object
        case .unset:
            let object: [String: QueryValueBox] = [:]
            storage = .object(object)
            return object
        default:
            storage = .object([:])
            return [:]
        }
    }

    @discardableResult
    func makeArray() -> [QueryValueBox] {
        switch storage {
        case .array(let array):
            return array
        case .unset:
            let array: [QueryValueBox] = []
            storage = .array(array)
            return array
        default:
            storage = .array([])
            return []
        }
    }

    func setObject(_ object: [String: QueryValueBox]) {
        storage = .object(object)
    }

    func setArray(_ array: [QueryValueBox]) {
        storage = .array(array)
    }

    func appendArrayElement(_ element: QueryValueBox) {
        switch storage {
        case .array(var array):
            array.append(element)
            storage = .array(array)
        default:
            storage = .array([element])
        }
    }

    func setScalar(_ value: String) {
        storage = .scalar(value)
    }

    func setNull() {
        storage = .null
    }
}

private struct _URLQueryEncodingOptions: Sendable {
    let keyEncodingStrategy: URLQueryKeyEncodingStrategy
    let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    let arrayEncodingStrategy: URLQueryArrayEncodingStrategy
    let nonConformingFloatEncodingStrategy: URLQueryFloatEncodingStrategy
    /// Sendable, Foundation-cached ISO 8601 formatter equivalent to
    /// `ISO8601DateFormatter()` with the default `.withInternetDateTime`
    /// options (e.g. `2026-05-04T01:23:45Z`). `Date.ISO8601FormatStyle` is
    /// `Sendable` so it doesn't need the `nonisolated(unsafe)` escape hatch
    /// that `ISO8601DateFormatter` did under Swift 6 strict concurrency.
    static let iso8601FormatStyle = Date.ISO8601FormatStyle.iso8601

    /// Stringifies a `Double` for the wire. Returns `nil` if the value is
    /// non-conforming and the strategy is `.throw`; the caller is expected
    /// to convert that into a typed encoding error so the bad value never
    /// silently lands as `"nan"` / `"inf"`.
    func stringForDouble(_ value: Double) throws -> String {
        if value.isFinite { return String(value) }
        switch nonConformingFloatEncodingStrategy {
        case .throw:
            throw URLQueryEncoder.EncodingError.unsupportedValue(
                reason: value.isNaN ? "NaN" : (value > 0 ? "+Infinity" : "-Infinity")
            )
        case .convertToString(let pos, let neg, let nan):
            if value.isNaN { return nan }
            return value > 0 ? pos : neg
        }
    }

    func stringForFloat(_ value: Float) throws -> String {
        if value.isFinite { return String(value) }
        switch nonConformingFloatEncodingStrategy {
        case .throw:
            throw URLQueryEncoder.EncodingError.unsupportedValue(
                reason: value.isNaN ? "NaN" : (value > 0 ? "+Infinity" : "-Infinity")
            )
        case .convertToString(let pos, let neg, let nan):
            if value.isNaN { return nan }
            return value > 0 ? pos : neg
        }
    }

    func transform(key: String, codingPath: [CodingKey]) -> String {
        switch keyEncodingStrategy {
        case .useDefaultKeys:
            return key
        case .convertToSnakeCase:
            return Self.convertToSnakeCase(key)
        case .custom(let transform):
            return transform.transform(codingPath + [AnyCodingKey(key)])
        }
    }

    func convert(date: Date, codingPath: [CodingKey]) throws -> QueryValue {
        switch dateEncodingStrategy {
        case .deferredToDate:
            let box = QueryValueBox()
            let encoder = _URLQueryValueEncoder(options: self, codingPath: codingPath, box: box)
            try date.encode(to: encoder)
            return try box.makeValue()
        case .secondsSince1970:
            return .scalar(String(date.timeIntervalSince1970))
        case .millisecondsSince1970:
            return .scalar(String(date.timeIntervalSince1970 * 1000.0))
        case .iso8601:
            return .scalar(Self.iso8601FormatStyle.format(date))
        case .formatted(let formatter):
            return .scalar(formatter.string(from: date))
        case .custom(let encode):
            let box = QueryValueBox()
            let encoder = _URLQueryValueEncoder(options: self, codingPath: codingPath, box: box)
            try encode(date, encoder)
            return try box.makeValue()
        @unknown default:
            return .scalar(String(date.timeIntervalSinceReferenceDate))
        }
    }

    private static func convertToSnakeCase(_ stringKey: String) -> String {
        SnakeCaseKeyTransformCache.shared.transform(stringKey)
    }
}

private final class SnakeCaseKeyTransformCache: Sendable {
    static let shared = SnakeCaseKeyTransformCache()
    static let capacity: Int = 4096

    private struct FIFOKeyBuffer {
        private var storage: [String?] = Array(repeating: nil, count: SnakeCaseKeyTransformCache.capacity)
        private var head = 0
        private var tail = 0
        private var count = 0

        mutating func append(_ key: String) {
            if count == storage.count {
                _ = removeFirst()
            }
            storage[tail] = key
            tail = (tail + 1) % storage.count
            count += 1
        }

        mutating func removeFirst() -> String? {
            guard count > 0 else { return nil }
            let key = storage[head]
            storage[head] = nil
            head = (head + 1) % storage.count
            count -= 1
            return key
        }
    }

    private struct State {
        var entries: [String: String] = [:]
        /// FIFO insertion order for eviction. We do not promote on read —
        /// a true LRU promotion would double the contended write paths,
        /// and the cache holds enough capacity that simple FIFO eviction is
        /// good enough to bound memory under runaway dynamic-key payloads.
        var insertionOrder = FIFOKeyBuffer()
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private init() {}

    func transform(_ key: String) -> String {
        if let cached = state.withLock({ $0.entries[key] }) {
            return cached
        }

        let transformed = Self.convertToSnakeCase(key)

        state.withLock { state in
            if state.entries[key] != nil { return }
            if state.entries.count >= Self.capacity, let oldest = state.insertionOrder.removeFirst() {
                state.entries.removeValue(forKey: oldest)
            }
            state.entries[key] = transformed
            state.insertionOrder.append(key)
        }
        return transformed
    }

    /// Converts `camelCase` keys to `snake_case` using the same word-splitting
    /// rules as Foundation's `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase`.
    ///
    /// The algorithm walks the string detecting transitions between lowercase
    /// and uppercase characters, treating runs of consecutive uppercase as a
    /// single word that ends one character before the next lowercase letter
    /// (so `myURLProperty` becomes `my_url_property`, not `my_u_r_l_property`).
    /// Empty strings, leading/trailing underscores, and non-alphabetic content
    /// are preserved as-is.
    ///
    /// This mirrors Foundation's behavior closely enough that consumers
    /// migrating from `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase`
    /// see the same wire-format keys; the parity is verified by the test
    /// target's `APIDefinitionEncodingTests` snake-case suite.
    static func convertToSnakeCase(_ stringKey: String) -> String {
        guard !stringKey.isEmpty else { return stringKey }

        var words: [Range<String.Index>] = []
        var wordStart = stringKey.startIndex
        var searchRange = stringKey.index(after: wordStart)..<stringKey.endIndex

        while let upperCaseRange = stringKey.rangeOfCharacter(
            from: .uppercaseLetters,
            options: [],
            range: searchRange
        ) {
            let untilUpperCase = wordStart..<upperCaseRange.lowerBound
            words.append(untilUpperCase)

            searchRange = upperCaseRange.lowerBound..<searchRange.upperBound
            guard
                let lowerCaseRange = stringKey.rangeOfCharacter(
                    from: .lowercaseLetters,
                    options: [],
                    range: searchRange
                )
            else {
                wordStart = searchRange.lowerBound
                break
            }

            let nextCharacterAfterCapital = stringKey.index(after: upperCaseRange.lowerBound)
            if lowerCaseRange.lowerBound == nextCharacterAfterCapital {
                wordStart = upperCaseRange.lowerBound
            } else {
                let beforeLowerIndex = stringKey.index(before: lowerCaseRange.lowerBound)
                words.append(upperCaseRange.lowerBound..<beforeLowerIndex)
                wordStart = beforeLowerIndex
            }
            searchRange = lowerCaseRange.upperBound..<searchRange.upperBound
        }
        words.append(wordStart..<searchRange.upperBound)

        return
            words
            .map { stringKey[$0].lowercased() }
            .joined(separator: "_")
    }
}

private final class _URLQueryValueEncoder: Encoder {
    let options: _URLQueryEncodingOptions
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    fileprivate let box: QueryValueBox

    init(
        options: _URLQueryEncodingOptions,
        codingPath: [CodingKey] = [],
        box: QueryValueBox
    ) {
        self.options = options
        self.codingPath = codingPath
        self.box = box
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let container = URLQueryKeyedEncodingContainer<Key>(encoder: self, box: box)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        URLQueryUnkeyedEncodingContainer(encoder: self, box: box)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        URLQuerySingleValueEncodingContainer(encoder: self, box: box)
    }
}

private struct URLQueryKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    typealias K = Key

    private let encoder: _URLQueryValueEncoder
    private let box: QueryValueBox

    init(encoder: _URLQueryValueEncoder, box: QueryValueBox) {
        self.encoder = encoder
        self.box = box
        if case .object = box.storage {
            return
        }
        box.setObject([:])
    }

    var codingPath: [CodingKey] { encoder.codingPath }

    mutating func encodeNil(forKey key: Key) throws {
        childBox(for: key).setNull()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        childBox(for: key).setScalar(value ? "true" : "false")
    }
    mutating func encode(_ value: String, forKey key: Key) throws { childBox(for: key).setScalar(value) }
    mutating func encode(_ value: Double, forKey key: Key) throws {
        childBox(for: key).setScalar(try encoder.options.stringForDouble(value))
    }
    mutating func encode(_ value: Float, forKey key: Key) throws {
        childBox(for: key).setScalar(try encoder.options.stringForFloat(value))
    }
    mutating func encode(_ value: Int, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let child = childBox(for: key)
        try encodeQueryValue(
            value,
            in: child,
            codingPath: codingPath + [key],
            options: encoder.options
        )
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = childBox(for: key)
        if case .object = child.storage {} else { child.setObject([:]) }
        let nestedEncoder = _URLQueryValueEncoder(options: encoder.options, codingPath: codingPath + [key], box: child)
        return nestedEncoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = childBox(for: key)
        if case .array = child.storage {} else { child.setArray([]) }
        return URLQueryUnkeyedEncodingContainer(
            encoder: _URLQueryValueEncoder(options: encoder.options, codingPath: codingPath + [key], box: child),
            box: child
        )
    }

    mutating func superEncoder() -> Encoder {
        _URLQueryValueEncoder(options: encoder.options, codingPath: codingPath, box: box)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let child = childBox(for: key)
        return _URLQueryValueEncoder(options: encoder.options, codingPath: codingPath + [key], box: child)
    }

    private func childBox(for key: Key) -> QueryValueBox {
        let transformedKey = encoder.options.transform(key: key.stringValue, codingPath: codingPath)
        var object: [String: QueryValueBox]
        switch box.storage {
        case .object(let existing):
            object = existing
        default:
            object = [:]
        }

        if let existing = object[transformedKey] {
            return existing
        }

        let child = QueryValueBox()
        object[transformedKey] = child
        box.setObject(object)
        return child
    }
}

private struct URLQueryUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    private let encoder: _URLQueryValueEncoder
    private let box: QueryValueBox

    init(encoder: _URLQueryValueEncoder, box: QueryValueBox) {
        self.encoder = encoder
        self.box = box
        if case .array = box.storage {
            return
        }
        box.setArray([])
    }

    var codingPath: [CodingKey] { encoder.codingPath }
    var count: Int {
        switch box.storage {
        case .array(let array): return array.count
        default: return 0
        }
    }

    mutating func encodeNil() throws {
        let child = appendChild()
        child.setNull()
    }

    mutating func encode(_ value: Bool) throws { appendChild().setScalar(value ? "true" : "false") }
    mutating func encode(_ value: String) throws { appendChild().setScalar(value) }
    mutating func encode(_ value: Double) throws { appendChild().setScalar(try encoder.options.stringForDouble(value)) }
    mutating func encode(_ value: Float) throws { appendChild().setScalar(try encoder.options.stringForFloat(value)) }
    mutating func encode(_ value: Int) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: Int8) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: Int16) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: Int32) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: Int64) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: UInt) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: UInt8) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: UInt16) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: UInt32) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: UInt64) throws { appendChild().setScalar(String(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let child = appendChild()
        try encodeQueryValue(
            value,
            in: child,
            codingPath: codingPath + [AnyCodingKey(intValue: count - 1)],
            options: encoder.options
        )
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = appendChild()
        child.setObject([:])
        let nestedEncoder = _URLQueryValueEncoder(
            options: encoder.options,
            codingPath: codingPath + [AnyCodingKey(intValue: count - 1)],
            box: child
        )
        return nestedEncoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = appendChild()
        child.setArray([])
        return URLQueryUnkeyedEncodingContainer(
            encoder: _URLQueryValueEncoder(
                options: encoder.options,
                codingPath: codingPath + [AnyCodingKey(intValue: count - 1)],
                box: child
            ),
            box: child
        )
    }

    mutating func superEncoder() -> Encoder {
        let child = appendChild()
        return _URLQueryValueEncoder(
            options: encoder.options,
            codingPath: codingPath + [AnyCodingKey(intValue: count - 1)],
            box: child
        )
    }

    private func appendChild() -> QueryValueBox {
        let child = QueryValueBox()
        box.appendArrayElement(child)
        return child
    }
}

private struct URLQuerySingleValueEncodingContainer: SingleValueEncodingContainer {
    private let encoder: _URLQueryValueEncoder
    private let box: QueryValueBox

    init(encoder: _URLQueryValueEncoder, box: QueryValueBox) {
        self.encoder = encoder
        self.box = box
    }

    var codingPath: [CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws { box.setNull() }
    mutating func encode(_ value: Bool) throws { box.setScalar(value ? "true" : "false") }
    mutating func encode(_ value: String) throws { box.setScalar(value) }
    mutating func encode(_ value: Double) throws { box.setScalar(try encoder.options.stringForDouble(value)) }
    mutating func encode(_ value: Float) throws { box.setScalar(try encoder.options.stringForFloat(value)) }
    mutating func encode(_ value: Int) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: Int8) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: Int16) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: Int32) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: Int64) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: UInt) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: UInt8) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: UInt16) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: UInt32) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: UInt64) throws { box.setScalar(String(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try encodeQueryValue(
            value,
            in: box,
            codingPath: codingPath,
            options: encoder.options
        )
    }
}

private func encodeQueryValue<T: Encodable>(
    _ value: T,
    in box: QueryValueBox,
    codingPath: [CodingKey],
    options: _URLQueryEncodingOptions
) throws {
    switch value {
    case let string as String:
        box.setScalar(string)
    case let bool as Bool:
        box.setScalar(bool ? "true" : "false")
    case let number as Int:
        box.setScalar(String(number))
    case let number as Int8:
        box.setScalar(String(number))
    case let number as Int16:
        box.setScalar(String(number))
    case let number as Int32:
        box.setScalar(String(number))
    case let number as Int64:
        box.setScalar(String(number))
    case let number as UInt:
        box.setScalar(String(number))
    case let number as UInt8:
        box.setScalar(String(number))
    case let number as UInt16:
        box.setScalar(String(number))
    case let number as UInt32:
        box.setScalar(String(number))
    case let number as UInt64:
        box.setScalar(String(number))
    case let number as Float:
        box.setScalar(try options.stringForFloat(number))
    case let number as Double:
        box.setScalar(try options.stringForDouble(number))
    case let date as Date:
        box.storage = try makeStorage(from: options.convert(date: date, codingPath: codingPath))
    case let data as Data:
        box.setScalar(data.base64EncodedString())
    case let decimal as Decimal:
        // `NSDecimalNumber.stringValue` honours the user's locale, so values
        // like `1.5` round-trip as `"1,5"` in comma-decimal locales, which
        // is invalid for any HTTP server expecting POSIX numeric form. The
        // `Decimal.description` representation is locale-independent.
        box.setScalar(decimal.description)
    case let url as URL:
        box.setScalar(url.absoluteString)
    default:
        let nestedEncoder = _URLQueryValueEncoder(
            options: options,
            codingPath: codingPath,
            box: box
        )
        try value.encode(to: nestedEncoder)
    }
}

private func makeStorage(from value: QueryValue) -> QueryValueBox.Storage {
    switch value {
    case .object(let object):
        let mapped = object.mapValues { value -> QueryValueBox in
            let box = QueryValueBox()
            box.storage = makeStorage(from: value)
            return box
        }
        return .object(mapped)
    case .array(let array):
        return .array(
            array.map { value in
                let box = QueryValueBox()
                box.storage = makeStorage(from: value)
                return box
            })
    case .scalar(let string):
        return .scalar(string)
    case .null:
        return .null
    }
}
