import Foundation

/// A deliberately bounded validation subset, not a general JSON Schema engine.
/// References must be resolved by the generator; recursive schema graphs and
/// unsupported keywords must be rejected before constructing this value.
public indirect enum JSONSchema: Sendable {
    /// A JSON object, with required names independent of nullable property values.
    case object(properties: [String: JSONSchema], required: Set<String>, allowsAdditionalProperties: Bool)
    /// An array whose every item must match the item schema.
    case array(items: JSONSchema)
    /// A JSON string, with no format, pattern or length constraint.
    case string
    /// Any syntactically valid JSON number, without floating-point conversion.
    case number
    /// A mathematical integer, including `1.0` and `1e3`, without a machine range limit.
    case integer
    /// A JSON boolean (numbers do not count as booleans).
    case boolean
    /// JSON null.
    case null
    /// Null or a value matching the enclosed schema.
    case nullable(JSONSchema)
    /// At least one branch must match; every branch shares a single work budget.
    case anyOf([JSONSchema])

    /// Returns whether the document matches, throwing on invalid limits or budget
    /// exhaustion. Resource exhaustion must never be treated as a branch mismatch.
    public func matches(_ document: PreservedJSON, limits: JSONProcessingLimits = .init()) throws -> Bool {
        try limits.validate()
        let checked = try PreservedJSON(data: document.data, limits: limits)
        var validator = JSONSchemaValidator(limits: limits)
        try validator.inspect(self, depth: 1)
        return try validator.matches(self, node: checked.root, depth: 1)
    }

    /// Validates every alternative and returns all matching zero-based branch indices.
    /// Throws ``JSONProcessingError/noMatchingSchema`` for zero matches. A single
    /// branch's success never hides an invalid schema or an exhausted later branch.
    public static func matchingAlternatives(
        _ alternatives: [JSONSchema], document: PreservedJSON, limits: JSONProcessingLimits = .init()
    ) throws -> [Int] {
        try limits.validate()
        let checked = try PreservedJSON(data: document.data, limits: limits)
        var validator = JSONSchemaValidator(limits: limits)
        try validator.inspect(.anyOf(alternatives), depth: 1)
        var matches: [Int] = []
        for (index, schema) in alternatives.enumerated() {
            if try validator.matches(schema, node: checked.root, depth: 1) { matches.append(index) }
        }
        guard !matches.isEmpty else { throw JSONProcessingError.noMatchingSchema }
        return matches
    }
}

private struct JSONSchemaValidator {
    let limits: JSONProcessingLimits
    var work = 0

    mutating func charge(_ count: Int = 1, depth: Int) throws {
        guard depth <= limits.maximumDepth, count <= limits.maximumValidationWork - work else {
            throw JSONProcessingError.resourceLimit
        }
        work += count
    }

    mutating func inspect(_ schema: JSONSchema, depth: Int) throws {
        try charge(depth: depth)
        switch schema {
        case .object(let properties, let required, _):
            for name in required { try charge(name.utf8.count + 1, depth: depth) }
            for (name, child) in properties {
                try charge(name.utf8.count + 1, depth: depth)
                try inspect(child, depth: depth + 1)
            }
        case .array(let item), .nullable(let item):
            try inspect(item, depth: depth + 1)
        case .anyOf(let alternatives):
            guard !alternatives.isEmpty else { throw JSONProcessingError.noMatchingSchema }
            for child in alternatives { try inspect(child, depth: depth + 1) }
        case .string, .number, .integer, .boolean, .null:
            break
        }
    }

    mutating func matches(_ schema: JSONSchema, node: JSONNode, depth: Int) throws -> Bool {
        try charge(depth: depth)
        switch (schema, node.value) {
        case (.string, .string), (.number, .number), (.integer, .number(isInteger: true)),
            (.boolean, .boolean), (.null, .null):
            return true
        case (.nullable(let child), _):
            if case .null = node.value { return true }
            return try matches(child, node: node, depth: depth + 1)
        case (.object(let properties, let required, let additional), .object(let members)):
            for name in required.sorted() {
                try charge(depth: depth)
                if members[name] == nil { return false }
            }
            for name in members.keys.sorted() {
                let value = members[name]!
                try charge(depth: depth)
                if let child = properties[name] {
                    if try !matches(child, node: value, depth: depth + 1) { return false }
                } else if !additional {
                    return false
                }
            }
            return true
        case (.array(let item), .array(let values)):
            for value in values {
                if try !matches(item, node: value, depth: depth + 1) { return false }
            }
            return true
        case (.anyOf(let alternatives), _):
            var matched = false
            for child in alternatives {
                let result = try matches(child, node: node, depth: depth + 1)
                matched = matched || result
            }
            return matched
        default:
            return false
        }
    }
}
