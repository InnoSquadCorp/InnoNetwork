//
//  URLQueryEncoder+Codable.swift
//  Network
//
//  Encoder/Container conformances that drive the URLQueryEncoder pipeline.
//

import Foundation
import os

final class SnakeCaseKeyTransformCache: Sendable {
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

final class _URLQueryValueEncoder: Encoder {
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

struct URLQueryKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
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

struct URLQueryUnkeyedEncodingContainer: UnkeyedEncodingContainer {
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

struct URLQuerySingleValueEncodingContainer: SingleValueEncodingContainer {
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

func encodeQueryValue<T: Encodable>(
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

func makeStorage(from value: QueryValue) -> QueryValueBox.Storage {
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
