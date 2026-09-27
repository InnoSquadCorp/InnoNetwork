import Foundation

final class JSONEncodingBox {
    enum Value {
        case empty
        case raw(Data)
        case object(JSONObjectBox)
        case array(JSONArrayBox)
    }
    var value: Value = .empty
}

final class JSONObjectBox { var members: [String: JSONEncodingBox] = [:] }
final class JSONArrayBox { var elements: [JSONEncodingBox] = [] }

struct JSONValueEncoder: Encoder {
    let context: JSONCodingContext
    var box = JSONEncodingBox()
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func write<T: Encodable>(_ value: T) throws {
        try context.spend(depth: codingPath.count)
        if let value = value as? PreservedJSON {
            try raw(value.data)
        } else if value is Data || value is Date || value is URL || value is Decimal {
            try scalar(value)
        } else {
            try context.frame { try value.encode(to: self) }
        }
    }

    func scalar<T: Encodable>(_ value: T) throws {
        try context.spend(depth: codingPath.count)
        if let string = value as? String, string.utf8.count > context.limits.maximumBytes {
            throw JSONProcessingError.resourceLimit
        }
        if let data = value as? Data, data.count > context.limits.maximumBytes {
            throw JSONProcessingError.resourceLimit
        }
        try raw(JSONEncoder().encode(value))
    }

    func raw(_ data: Data) throws {
        try context.spend(depth: codingPath.count)
        guard data.count <= context.limits.maximumBytes else { throw JSONProcessingError.resourceLimit }
        guard case .empty = box.value else { throw JSONProcessingError.invalidJSON }
        box.value = .raw(data)
    }

    func child(_ key: any CodingKey, array: Bool = false) -> Self {
        do { try context.spend(depth: codingPath.count + 1) } catch {
            context.failure = .resourceLimit
            return Self(context: context, codingPath: codingPath + [key])
        }
        let next = JSONEncodingBox()
        if array, case .array(let storage) = box.value {
            storage.elements.append(next)
        } else if !array, case .object(let storage) = box.value {
            guard key.stringValue.utf8.count <= context.limits.maximumBytes else {
                context.failure = .resourceLimit
                return Self(context: context, box: next, codingPath: codingPath + [key])
            }
            storage.members[key.stringValue] = next
        } else {
            context.failure = .invalidJSON
        }
        return Self(context: context, box: next, codingPath: codingPath + [key])
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .empty = box.value { box.value = .object(JSONObjectBox()) }
        if case .object = box.value {} else { context.failure = .invalidJSON }
        return KeyedEncodingContainer(JSONKeyedEncoder<Key>(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if case .empty = box.value { box.value = .array(JSONArrayBox()) }
        if case .array = box.value {} else { context.failure = .invalidJSON }
        return JSONUnkeyedEncoder(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { JSONSingleEncoder(encoder: self) }

    func output() throws -> Data {
        if let failure = context.failure { throw failure }
        var data = Data()
        try render(box, into: &data, depth: 1)
        return data
    }

    private func append(_ bytes: Data, to data: inout Data) throws {
        guard bytes.count <= context.limits.maximumBytes - data.count else { throw JSONProcessingError.resourceLimit }
        data.append(bytes)
    }

    private func render(_ box: JSONEncodingBox, into data: inout Data, depth: Int) throws {
        guard depth <= context.limits.maximumDepth else { throw JSONProcessingError.resourceLimit }
        switch box.value {
        case .empty:
            throw JSONProcessingError.invalidJSON
        case .raw(let bytes):
            try append(bytes, to: &data)
        case .object(let storage):
            let members = storage.members
            try append(Data([123]), to: &data)
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { try append(Data([44]), to: &data) }
                try append(JSONEncoder().encode(key), to: &data)
                try append(Data([58]), to: &data)
                try render(members[key]!, into: &data, depth: depth + 1)
            }
            try append(Data([125]), to: &data)
        case .array(let storage):
            let values = storage.elements
            try append(Data([91]), to: &data)
            for (index, value) in values.enumerated() {
                if index > 0 { try append(Data([44]), to: &data) }
                try render(value, into: &data, depth: depth + 1)
            }
            try append(Data([93]), to: &data)
        }
    }
}

private struct JSONSingleEncoder: SingleValueEncodingContainer {
    let encoder: JSONValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    mutating func encodeNil() throws { try encoder.raw(Data("null".utf8)) }
    mutating func encode<T: Encodable>(_ value: T) throws { try encoder.write(value) }
    mutating func encode(_ value: Bool) throws { try encoder.scalar(value) }
    mutating func encode(_ value: String) throws { try encoder.scalar(value) }
    mutating func encode(_ value: Double) throws { try encoder.scalar(value) }
    mutating func encode(_ value: Float) throws { try encoder.scalar(value) }
    mutating func encode(_ value: Int) throws { try encoder.scalar(value) }
    mutating func encode(_ value: Int8) throws { try encoder.scalar(value) }
    mutating func encode(_ value: Int16) throws { try encoder.scalar(value) }
    mutating func encode(_ value: Int32) throws { try encoder.scalar(value) }
    mutating func encode(_ value: Int64) throws { try encoder.scalar(value) }
    mutating func encode(_ value: UInt) throws { try encoder.scalar(value) }
    mutating func encode(_ value: UInt8) throws { try encoder.scalar(value) }
    mutating func encode(_ value: UInt16) throws { try encoder.scalar(value) }
    mutating func encode(_ value: UInt32) throws { try encoder.scalar(value) }
    mutating func encode(_ value: UInt64) throws { try encoder.scalar(value) }
}

private struct JSONKeyedEncoder<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: JSONValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    mutating func encodeNil(forKey key: Key) throws { try encoder.child(key).raw(Data("null".utf8)) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try encoder.child(key).write(value) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: String, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: Int, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try encoder.child(key).scalar(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> { encoder.child(key).container(keyedBy: type) }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        encoder.child(key).unkeyedContainer()
    }
    mutating func superEncoder(forKey key: Key) -> any Encoder { encoder.child(key) }
    mutating func superEncoder() -> any Encoder { encoder.child(JSONIndexKey(stringValue: "super")!) }
}

private struct JSONUnkeyedEncoder: UnkeyedEncodingContainer {
    let encoder: JSONValueEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int {
        if case .array(let storage) = encoder.box.value { return storage.elements.count }
        return 0
    }
    func next() -> JSONValueEncoder { encoder.child(JSONIndexKey(count), array: true) }
    mutating func encodeNil() throws { try next().raw(Data("null".utf8)) }
    mutating func encode<T: Encodable>(_ value: T) throws { try next().write(value) }
    mutating func encode(_ value: Bool) throws { try next().scalar(value) }
    mutating func encode(_ value: String) throws { try next().scalar(value) }
    mutating func encode(_ value: Double) throws { try next().scalar(value) }
    mutating func encode(_ value: Float) throws { try next().scalar(value) }
    mutating func encode(_ value: Int) throws { try next().scalar(value) }
    mutating func encode(_ value: Int8) throws { try next().scalar(value) }
    mutating func encode(_ value: Int16) throws { try next().scalar(value) }
    mutating func encode(_ value: Int32) throws { try next().scalar(value) }
    mutating func encode(_ value: Int64) throws { try next().scalar(value) }
    mutating func encode(_ value: UInt) throws { try next().scalar(value) }
    mutating func encode(_ value: UInt8) throws { try next().scalar(value) }
    mutating func encode(_ value: UInt16) throws { try next().scalar(value) }
    mutating func encode(_ value: UInt32) throws { try next().scalar(value) }
    mutating func encode(_ value: UInt64) throws { try next().scalar(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> { next().container(keyedBy: type) }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { next().unkeyedContainer() }
    mutating func superEncoder() -> any Encoder { next() }
}
