//
//  URLQueryEncoder+Storage.swift
//  Network
//
//  Internal storage and option types backing URLQueryEncoder.
//

import Foundation
import os

enum QueryValue: Sendable {
    case object([String: QueryValue])
    case array([QueryValue])
    case scalar(String)
    case null
}

final class QueryValueBox {
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

struct _URLQueryEncodingOptions: Sendable {
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
