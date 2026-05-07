//
//  HTTPHeader.swift
//  Network
//
//  Created by Chang Woo Son on 6/21/24.
//

import Foundation

public struct HTTPHeaders: Sendable {
    private var headers: [HTTPHeader] = []

    /// Creates an empty instance.
    public init() {}

    /// Creates an instance from an array of `HTTPHeader`s. Entries are
    /// preserved in order, including multiple entries that share a
    /// case-insensitive name (e.g. `Set-Cookie`).
    public init(_ headers: [HTTPHeader]) {
        self.headers = headers
    }

    /// Creates an instance from a `[String: String]`. The dictionary cannot
    /// represent multi-value headers; callers that need to preserve repeated
    /// `Set-Cookie` or `WWW-Authenticate` entries should use ``init(_:)``
    /// with an array literal instead.
    public init(_ dictionary: [String: String]) {
        self.headers = dictionary.map { HTTPHeader(name: $0.key, value: $0.value) }
    }

    /// Appends an `HTTPHeader` to the instance, preserving any existing
    /// entries that share the same case-insensitive name.
    ///
    /// Use this for headers that legitimately repeat — most commonly
    /// `Set-Cookie` and `WWW-Authenticate` — where collapsing into a
    /// comma-joined string would either be invalid (cookies) or lose
    /// challenge boundaries.
    ///
    /// For headers that should hold a single value, prefer ``update(_:)``
    /// or ``update(name:value:)``.
    ///
    /// - Parameters:
    ///   - name:  The `HTTPHeader` name.
    ///   - value: The `HTTPHeader` value.
    public mutating func add(name: String, value: String) {
        headers.append(HTTPHeader(name: name, value: value))
    }

    /// Appends the provided `HTTPHeader` to the instance, preserving any
    /// existing entries that share the same case-insensitive name.
    ///
    /// - Parameter header: The `HTTPHeader` to append.
    public mutating func add(_ header: HTTPHeader) {
        headers.append(header)
    }

    /// Case-insensitively updates or appends an `HTTPHeader` into the instance using the provided `name` and `value`.
    ///
    /// - Parameters:
    ///   - name:  The `HTTPHeader` name.
    ///   - value: The `HTTPHeader` value.
    public mutating func update(name: String, value: String) {
        update(HTTPHeader(name: name, value: value))
    }

    /// Case-insensitively replaces all existing entries that share the
    /// header name with the provided `HTTPHeader`. If no matching entry
    /// exists, the header is appended.
    ///
    /// Prefer this for single-valued headers (``Authorization``,
    /// ``Content-Type``, etc.) so a misconfigured retry path cannot
    /// accidentally accumulate duplicates.
    ///
    /// - Parameter header: The `HTTPHeader` to update or append.
    public mutating func update(_ header: HTTPHeader) {
        let lowercasedName = header.name.lowercased()
        var didReplace = false
        headers = headers.compactMap { existing in
            if existing.name.lowercased() == lowercasedName {
                if didReplace { return nil }
                didReplace = true
                return header
            }
            return existing
        }
        if !didReplace {
            headers.append(header)
        }
    }

    /// Case-insensitively removes every `HTTPHeader` matching `name`,
    /// including duplicates added via ``add(name:value:)``.
    ///
    /// - Parameter name: The name of the `HTTPHeader` to remove.
    public mutating func remove(name: String) {
        let lowercasedName = name.lowercased()
        headers.removeAll { $0.name.lowercased() == lowercasedName }
    }

    /// Sort the current instance by header name, case insensitively.
    public mutating func sort() {
        headers.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Returns an instance sorted by header name.
    ///
    /// - Returns: A copy of the current instance sorted by name.
    public func sorted() -> HTTPHeaders {
        var headers = self
        headers.sort()

        return headers
    }

    /// Case-insensitively find a header's value by name.
    ///
    /// When several entries share the same case-insensitive name, the
    /// returned value is the joined RFC 7230 §3.2.2 representation
    /// (`value-1, value-2`). Callers that need to inspect each
    /// individual entry — for example to read repeated `Set-Cookie`
    /// headers — should use ``values(for:)`` instead.
    ///
    /// - Parameter name: The name of the header to search for, case-insensitively.
    ///
    /// - Returns:        The value of header, if it exists.
    public func value(for name: String) -> String? {
        let matches = values(for: name)
        guard !matches.isEmpty else { return nil }
        return matches.joined(separator: ", ")
    }

    /// Case-insensitively returns every value associated with `name`, in
    /// the order they were added. Use this for response headers that may
    /// legitimately repeat (`Set-Cookie`, `WWW-Authenticate`).
    ///
    /// - Parameter name: The name of the header to search for, case-insensitively.
    /// - Returns:        Each value associated with `name`, or an empty array.
    public func values(for name: String) -> [String] {
        let lowercasedName = name.lowercased()
        return headers.compactMap { $0.name.lowercased() == lowercasedName ? $0.value : nil }
    }

    /// Case-insensitively access the header with the given name.
    ///
    /// - Parameter name: The name of the header.
    public subscript(_ name: String) -> String? {
        get { value(for: name) }
        set {
            if let value = newValue {
                update(name: name, value: value)
            } else {
                remove(name: name)
            }
        }
    }

    /// The dictionary representation of all headers, suitable for passing
    /// to `URLRequest.allHTTPHeaderFields`.
    ///
    /// Multiple entries that share a case-insensitive name are collapsed
    /// into a single comma-joined value per RFC 7230 §3.2.2. The first
    /// occurrence of the name is preserved as the canonical key. This
    /// representation does not preserve insertion order.
    ///
    /// `Set-Cookie` is the one well-known header where comma-joining is
    /// invalid. The library never sets `Set-Cookie` on outbound requests,
    /// so the join is safe in practice for the request-side use of this
    /// property; consumers reading inbound response headers should iterate
    /// the collection or call ``values(for:)`` instead of going through
    /// this dictionary.
    public var dictionary: [String: String] {
        var canonicalKeys: [String: String] = [:]
        var grouped: [String: [String]] = [:]
        var insertionOrder: [String] = []

        for header in headers {
            let lowercased = header.name.lowercased()
            if canonicalKeys[lowercased] == nil {
                canonicalKeys[lowercased] = header.name
                insertionOrder.append(lowercased)
            }
            grouped[lowercased, default: []].append(header.value)
        }

        var result: [String: String] = [:]
        result.reserveCapacity(insertionOrder.count)
        for key in insertionOrder {
            let canonical = canonicalKeys[key] ?? key
            result[canonical] = grouped[key]?.joined(separator: ", ")
        }
        return result
    }
}

extension HTTPHeaders: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, String)...) {
        elements.forEach { update(name: $0.0, value: $0.1) }
    }
}

extension HTTPHeaders: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: HTTPHeader...) {
        self.init(elements)
    }
}

extension HTTPHeaders: Sequence {
    public func makeIterator() -> IndexingIterator<[HTTPHeader]> {
        headers.makeIterator()
    }
}

extension HTTPHeaders: Collection {
    public var startIndex: Int {
        headers.startIndex
    }

    public var endIndex: Int {
        headers.endIndex
    }

    public subscript(position: Int) -> HTTPHeader {
        headers[position]
    }

    public func index(after i: Int) -> Int {
        headers.index(after: i)
    }
}

extension HTTPHeaders: CustomStringConvertible {
    public var description: String {
        headers.map(\.description)
            .joined(separator: "\n")
    }
}
extension [HTTPHeader] {
    /// Case-insensitively finds the index of an `HTTPHeader` with the provided name, if it exists.
    func index(of name: String) -> Int? {
        let lowercasedName = name.lowercased()
        return firstIndex { $0.name.lowercased() == lowercasedName }
    }
}
