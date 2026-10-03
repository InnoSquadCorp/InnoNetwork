import Foundation

/// A deliberately bounded validation subset, not a general JSON Schema engine.
/// References must be resolved by the generator; recursive schema graphs and
/// unsupported keywords must be rejected before constructing this value.
public indirect enum JSONSchema: Sendable {
    /// A JSON object, with required names independent of nullable property values.
    /// Property names match exact Unicode code points, not canonical equivalence.
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
        let schema = try validator.inspect(self, depth: 1)
        return try validator.matches(schema, node: checked.root, depth: 1)
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
        guard case .anyOf(let inspected) = try validator.inspect(.anyOf(alternatives), depth: 1) else {
            throw JSONProcessingError.invalidSchema
        }
        var matches: [Int] = []
        for (index, schema) in inspected.enumerated() {
            if try validator.matches(schema, node: checked.root, depth: 1) { matches.append(index) }
        }
        guard !matches.isEmpty else { throw JSONProcessingError.noMatchingSchema }
        return matches
    }
}

// Prepare schema-owned traversal order once per validation, rather than
// allocating and sorting the same required-name set for every array element.
// Exact Unicode matching and per-node work charges stay in the validator.
private indirect enum InspectedJSONSchema {
    case object(properties: [String: InspectedJSONSchema], required: [String], allowsAdditionalProperties: Bool)
    case array(InspectedJSONSchema)
    case nullable(InspectedJSONSchema)
    case anyOf([InspectedJSONSchema])
    case scalar(JSONSchema)
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

    mutating func inspect(_ schema: JSONSchema, depth: Int) throws -> InspectedJSONSchema {
        try charge(depth: depth)
        switch schema {
        case .object(let properties, let required, let additional):
            for name in required { try charge(name.utf8.count + 1, depth: depth) }
            var inspected: [String: InspectedJSONSchema] = [:]
            inspected.reserveCapacity(min(properties.count, limits.maximumValidationWork - work))
            for (name, child) in properties {
                try charge(name.utf8.count + 1, depth: depth)
                inspected[name] = try inspect(child, depth: depth + 1)
            }
            return .object(properties: inspected, required: required.sorted(), allowsAdditionalProperties: additional)
        case .array(let item):
            return .array(try inspect(item, depth: depth + 1))
        case .nullable(let item):
            return .nullable(try inspect(item, depth: depth + 1))
        case .anyOf(let alternatives):
            guard !alternatives.isEmpty else { throw JSONProcessingError.noMatchingSchema }
            var inspected: [InspectedJSONSchema] = []
            inspected.reserveCapacity(min(alternatives.count, limits.maximumValidationWork - work))
            for child in alternatives { inspected.append(try inspect(child, depth: depth + 1)) }
            return .anyOf(inspected)
        case .string, .number, .integer, .boolean, .null:
            return .scalar(schema)
        }
    }

    mutating func matches(_ schema: InspectedJSONSchema, node: JSONNode, depth: Int) throws -> Bool {
        try charge(depth: depth)
        switch (schema, node.value) {
        case (.scalar(.string), .string), (.scalar(.number), .number), (.scalar(.integer), .number(isInteger: true)),
            (.scalar(.boolean), .boolean), (.scalar(.null), .null):
            return true
        case (.nullable(let child), _):
            if case .null = node.value { return true }
            return try matches(child, node: node, depth: depth + 1)
        case (.object(let properties, let required, let additional), .object(let members)):
            for name in required {
                try charge(depth: depth)
                // Swift Dictionary lookup is canonically equivalent. JSON names
                // instead use exact code points, as in JSONSchemaPlan.
                guard let index = members.index(forKey: name), members.keys[index].utf8.elementsEqual(name.utf8) else {
                    return false
                }
            }
            for name in members.keys.sorted() {
                guard let value = members[name] else { throw JSONProcessingError.invalidJSON }
                try charge(depth: depth)
                if let index = properties.index(forKey: name), properties.keys[index].utf8.elementsEqual(name.utf8) {
                    let child = properties.values[index]
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
