import Foundation

/// Lossless document-aware Codable entry points for generated JSON models.
/// Unlike Foundation's codecs, these recognize nested `PreservedJSON` values.
/// Uses default keys, deferred dates, base64 Data and Foundation URL/Decimal scalar
/// behavior; configurable Foundation coding strategies are intentionally not exposed.
public enum PreservedJSONCoding {
    /// Decodes a model while supplying original subdocument bytes to preserved values.
    public static func decode<T: Decodable>(
        _ type: T.Type, from data: Data, limits: JSONProcessingLimits = .init()
    ) throws -> T {
        let document = try PreservedJSON(data: data, limits: limits)
        let context = JSONCodingContext(limits: limits)
        return try JSONValueDecoder(document: document, node: document.root, context: context).decode(type)
    }

    /// Encodes a model without rewriting numbers or dropping fields in preserved values.
    public static func encode<T: Encodable>(
        _ value: T, limits: JSONProcessingLimits = .init()
    ) throws -> Data {
        try limits.validate()
        let context = JSONCodingContext(limits: limits)
        let encoder = JSONValueEncoder(context: context)
        try encoder.write(value)
        let data = try encoder.output()
        _ = try PreservedJSON(data: data, limits: limits)
        return data
    }
}

// Synchronous, per-call, non-Sendable bookkeeping never crosses a task boundary.
final class JSONCodingContext {
    let limits: JSONProcessingLimits
    var work = 0
    var failure: JSONProcessingError?
    private var frames = 0

    init(limits: JSONProcessingLimits) { self.limits = limits }

    func frame<T>(_ body: () throws -> T) throws -> T {
        guard frames < limits.maximumDepth else { throw JSONProcessingError.resourceLimit }
        frames += 1
        defer { frames -= 1 }
        return try body()
    }

    func spend(depth: Int) throws {
        if let failure { throw failure }
        guard depth < limits.maximumDepth, work < limits.maximumValidationWork else {
            failure = .resourceLimit
            throw JSONProcessingError.resourceLimit
        }
        work += 1
    }
}

struct JSONIndexKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ name: String) {
        stringValue = name
        intValue = nil
    }
    init(_ index: Int) {
        stringValue = String(index)
        intValue = index
    }
    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }
    init?(intValue: Int) { self.init(intValue) }
}

struct JSONValueDecoder: Decoder {
    let document: PreservedJSON
    let node: JSONNode
    let context: JSONCodingContext
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    var data: Data { codingPath.isEmpty ? document.data : document.data.subdata(in: node.range) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try context.spend(depth: codingPath.count)
        if type == Data.self || type == Date.self || type == URL.self || type == Decimal.self {
            return try scalar(type)
        }
        return try context.frame { try T(from: self) }
    }

    func scalar<T: Decodable>(_ type: T.Type) throws -> T {
        try context.spend(depth: codingPath.count)
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw DecodingError.typeMismatch(
                type, .init(codingPath: codingPath, debugDescription: "Invalid JSON scalar"))
        }
    }

    func child(_ node: JSONNode, key: any CodingKey) -> Self {
        Self(document: document, node: node, context: context, codingPath: codingPath + [key])
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try context.spend(depth: codingPath.count)
        guard case .object(let members) = node.value else { throw JSONProcessingError.invalidJSON }
        return KeyedDecodingContainer(JSONKeyedDecoder<Key>(decoder: self, members: members))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try context.spend(depth: codingPath.count)
        guard case .array(let values) = node.value else { throw JSONProcessingError.invalidJSON }
        return JSONUnkeyedDecoder(decoder: self, values: values)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        try context.spend(depth: codingPath.count)
        return JSONSingleDecoder(decoder: self)
    }
}

private struct JSONSingleDecoder: SingleValueDecodingContainer {
    let decoder: JSONValueDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }
    func decodeNil() -> Bool {
        if case .null = decoder.node.value { return true }
        return false
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type) }
    func decode(_ type: Bool.Type) throws -> Bool { try decoder.scalar(type) }
    func decode(_ type: String.Type) throws -> String { try decoder.scalar(type) }
    func decode(_ type: Double.Type) throws -> Double { try decoder.scalar(type) }
    func decode(_ type: Float.Type) throws -> Float { try decoder.scalar(type) }
    func decode(_ type: Int.Type) throws -> Int { try decoder.scalar(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decoder.scalar(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decoder.scalar(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decoder.scalar(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decoder.scalar(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try decoder.scalar(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decoder.scalar(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decoder.scalar(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decoder.scalar(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decoder.scalar(type) }
}

private struct JSONKeyedDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: JSONValueDecoder
    let members: [String: JSONNode]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { members.keys.sorted().compactMap(Key.init(stringValue:)) }
    func contains(_ key: Key) -> Bool { members[key.stringValue] != nil }
    func child(_ key: Key) throws -> JSONValueDecoder {
        guard let node = members[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing JSON member"))
        }
        return decoder.child(node, key: key)
    }
    func decodeNil(forKey key: Key) throws -> Bool {
        if case .null = try child(key).node.value { return true }
        return false
    }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try child(key).decode(type) }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try child(key).scalar(type) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try child(key).scalar(type) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try child(key).scalar(type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try child(key).scalar(type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try child(key).scalar(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try child(key).scalar(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try child(key).scalar(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try child(key).scalar(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try child(key).scalar(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try child(key).scalar(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try child(key).scalar(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try child(key).scalar(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try child(key).scalar(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try child(key).scalar(type) }
    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> { try child(key).container(keyedBy: type) }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try child(key).unkeyedContainer()
    }
    func superDecoder(forKey key: Key) throws -> any Decoder { try child(key) }
    func superDecoder() throws -> any Decoder {
        guard let node = members["super"] else { throw JSONProcessingError.invalidJSON }
        return decoder.child(node, key: JSONIndexKey("super"))
    }
}

private struct JSONUnkeyedDecoder: UnkeyedDecodingContainer {
    let decoder: JSONValueDecoder
    let values: [JSONNode]
    var currentIndex = 0
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex == values.count }
    mutating func next() throws -> JSONValueDecoder {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                PreservedJSON.self, .init(codingPath: codingPath, debugDescription: "End of JSON array"))
        }
        defer { currentIndex += 1 }
        return decoder.child(values[currentIndex], key: JSONIndexKey(currentIndex))
    }
    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw JSONProcessingError.invalidJSON }
        if case .null = values[currentIndex].value {
            currentIndex += 1
            return true
        }
        return false
    }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().decode(type) }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try next().scalar(type) }
    mutating func decode(_ type: String.Type) throws -> String { try next().scalar(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try next().scalar(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try next().scalar(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try next().scalar(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try next().scalar(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try next().scalar(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try next().scalar(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try next().scalar(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try next().scalar(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next().scalar(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next().scalar(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next().scalar(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next().scalar(type) }
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> { try next().container(keyedBy: type) }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { try next().unkeyedContainer() }
    mutating func superDecoder() throws -> any Decoder { try next() }
}
