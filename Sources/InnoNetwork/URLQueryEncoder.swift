import Foundation
import os


public struct URLQueryEncoder: Sendable {
    public enum EncodingError: Error, Sendable {
        case unsupportedTopLevelValue
    }

    public var keyEncodingStrategy: URLQueryKeyEncodingStrategy
    public var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy

    public init(
        keyEncodingStrategy: URLQueryKeyEncodingStrategy = .useDefaultKeys,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil
    ) {
        self.keyEncodingStrategy = keyEncodingStrategy
        self.dateEncodingStrategy = dateEncodingStrategy ?? .formatted(makeDefaultDateFormatter())
    }

    public init(
        keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil
    ) {
        self.init(
            keyEncodingStrategy: URLQueryKeyEncodingStrategy(keyEncodingStrategy),
            dateEncodingStrategy: dateEncodingStrategy
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
        var components = URLComponents()
        components.queryItems = queryItems
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private var options: _URLQueryEncodingOptions {
        _URLQueryEncodingOptions(
            keyEncodingStrategy: keyEncodingStrategy,
            dateEncodingStrategy: dateEncodingStrategy
        )
    }

    private func flattenRoot(
        _ value: QueryValue,
        rootKey: String?
    ) throws -> [URLQueryItem] {
        switch value {
        case .object(let object):
            return object.keys.sorted().flatMap { key in
                flatten(key: key, value: object[key]!)
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
            return object.keys.sorted().flatMap { nestedKey in
                flatten(key: "\(key)[\(nestedKey)]", value: object[nestedKey]!)
            }
        case .array(let array):
            return array.enumerated().flatMap { index, element in
                flatten(key: "\(key)[\(index)]", value: element)
            }
        case .scalar(let string):
            return [URLQueryItem(name: key, value: string)]
        case .null:
            return []
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
            return .scalar(ISO8601DateFormatter().string(from: date))
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

private struct SnakeCaseKeyProbe: Encodable {
    let key: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(true, forKey: AnyCodingKey(key))
    }
}

private final class SnakeCaseKeyTransformCache: Sendable {
    static let shared = SnakeCaseKeyTransformCache()

    private let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private init() {}

    func transform(_ key: String) -> String {
        if let cached = cache.withLock({ $0[key] }) {
            return cached
        }

        let transformed = (try? computeTransform(for: key)) ?? key

        cache.withLock { $0[key] = transformed }
        return transformed
    }

    private func computeTransform(for key: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(SnakeCaseKeyProbe(key: key))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        return object?.keys.first ?? key
    }
}

private final class _URLQueryValueEncoder: Encoder {
    let options: _URLQueryEncodingOptions
    var codingPath: [CodingKey]
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

    mutating func encode(_ value: Bool, forKey key: Key) throws { childBox(for: key).setScalar(value ? "true" : "false") }
    mutating func encode(_ value: String, forKey key: Key) throws { childBox(for: key).setScalar(value) }
    mutating func encode(_ value: Double, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { childBox(for: key).setScalar(String(value)) }
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
    mutating func encode(_ value: Double) throws { appendChild().setScalar(String(value)) }
    mutating func encode(_ value: Float) throws { appendChild().setScalar(String(value)) }
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
        let array: [QueryValueBox]
        switch box.storage {
        case .array(let existing):
            array = existing + [child]
        default:
            array = [child]
        }
        box.setArray(array)
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
    mutating func encode(_ value: Double) throws { box.setScalar(String(value)) }
    mutating func encode(_ value: Float) throws { box.setScalar(String(value)) }
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
        box.setScalar(String(number))
    case let number as Double:
        box.setScalar(String(number))
    case let date as Date:
        box.storage = try makeStorage(from: options.convert(date: date, codingPath: codingPath))
    case let data as Data:
        box.setScalar(data.base64EncodedString())
    case let decimal as Decimal:
        box.setScalar(NSDecimalNumber(decimal: decimal).stringValue)
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
        return .array(array.map { value in
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
