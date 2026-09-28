import Foundation

/// An immutable, offline validation plan for the documented OpenAPI schema subset.
/// Compilation inspects every branch and rejects unsupported keywords. Numeric
/// constants and enum members retain their exact JSON representation. This is not
/// a complete JSON Schema implementation; see the keyword support matrix.
public struct JSONSchemaPlan: Sendable {
    let rules: [JSONSchemaRule]
    let root: Int

    /// Compiles one schema and its named local `#/components/schemas/` definitions.
    /// Limits bound aggregate schema input bytes and compilation work independently
    /// from each later validation call. No reference causes network or file IO.
    public init(
        schema: PreservedJSON, definitions: [String: PreservedJSON] = [:],
        limits: JSONProcessingLimits = .init()
    ) throws {
        try limits.validate()
        var compiler = JSONSchemaCompiler(definitions: definitions, budget: .init(limits: limits))
        var bytes = schema.data.count
        for (name, definition) in definitions {
            guard definition.data.count <= limits.maximumBytes - bytes else { throw JSONProcessingError.resourceLimit }
            bytes += definition.data.count
            try compiler.budget.charge(name.utf8.count + 1)
        }
        let checked = try PreservedJSON(data: schema.data, limits: limits)
        root = try compiler.compile(checked, node: checked.root, depth: 1)
        rules = compiler.rules
    }

    /// Validates with a fresh shared work budget. Exhaustion throws, never false.
    public func matches(_ document: PreservedJSON, limits: JSONProcessingLimits = .init()) throws -> Bool {
        let checked = try PreservedJSON(data: document.data, limits: limits)
        var validator = JSONPlanValidator(rules: rules, document: checked, budget: .init(limits: limits))
        return try validator.matches(root, checked.root, depth: 1)
    }

    /// Returns every matching top-level `anyOf` index. Throws for zero matches or
    /// a plan without a top-level anyOf. Sibling constraints also have to match.
    public func matchingAlternatives(
        _ document: PreservedJSON, limits: JSONProcessingLimits = .init()
    ) throws -> [Int] {
        let checked = try PreservedJSON(data: document.data, limits: limits)
        guard let alternatives = rules[root].anyOf else { throw JSONProcessingError.invalidSchema }
        var validator = JSONPlanValidator(rules: rules, document: checked, budget: .init(limits: limits))
        guard try validator.matches(root, checked.root, depth: 1) else { throw JSONProcessingError.noMatchingSchema }
        var matches: [Int] = []
        for (index, rule) in alternatives.enumerated() {
            if try validator.matches(rule, checked.root, depth: 1) { matches.append(index) }
        }
        guard !matches.isEmpty else { throw JSONProcessingError.noMatchingSchema }
        return matches
    }
}

struct JSONSchemaBudget {
    let limits: JSONProcessingLimits
    var work = 0
    mutating func charge(_ count: Int = 1, depth: Int = 1) throws {
        guard depth <= limits.maximumDepth, count <= limits.maximumValidationWork - work else {
            throw JSONProcessingError.resourceLimit
        }
        work += count
    }
}

struct JSONSchemaRule: Sendable {
    var type: String?
    var nullable = false
    var properties: [String: Int] = [:]
    var required: [String] = []
    var additional = true
    var items: Int?
    var reference: Int?
    var anyOf: [Int]?
    var enumeration: [PreservedJSON]?
    var minimum: JSONSchemaNumber?
    var maximum: JSONSchemaNumber?
    var exclusiveMinimum = false
    var exclusiveMaximum = false
    var multipleOf: JSONSchemaNumber?
    var sizes: [String: Int] = [:]
    var pattern: JSONSchemaPattern?
}

struct JSONSchemaCompiler {
    let definitions: [String: PreservedJSON]
    var budget: JSONSchemaBudget
    var rules: [JSONSchemaRule] = []
    var named: [String: Int] = [:]
    var visiting: Set<String> = []

    mutating func compile(_ document: PreservedJSON, node: JSONNode, depth: Int) throws -> Int {
        try budget.charge(depth: depth)
        guard case .object(let members) = node.value else { throw JSONProcessingError.invalidSchema }
        let supported: Set<String> = [
            "$ref", "type", "properties", "required", "additionalProperties", "items", "anyOf", "nullable",
            "enum", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
            "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
            "title", "description", "example", "deprecated", "externalDocs",
            "pattern", "format",
        ]
        for name in members.keys {
            try budget.charge(name.utf8.count + 1)
            guard supported.contains(name) else { throw JSONProcessingError.unsupportedSchema }
        }
        var rule = JSONSchemaRule()
        if let pattern = members["pattern"] {
            rule.pattern = try JSONSchemaPattern(scalar(String.self, document, pattern), budget: &budget)
        }
        // Format is annotation-only in compiled plans; never infer assertions
        // from Foundation decoders or silently reinterpret a regex dialect.
        if let format = members["format"] { _ = try scalar(String.self, document, format) }
        if let reference = members["$ref"] {
            let name = try scalar(String.self, document, reference)
            guard members.keys.allSatisfy({ ["$ref", "title", "description"].contains($0) }) else {
                throw JSONProcessingError.unsupportedSchema
            }
            let prefix = "#/components/schemas/"
            guard name.hasPrefix(prefix) else { throw JSONProcessingError.unsupportedSchema }
            let key = String(name.dropFirst(prefix.count)).replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard !visiting.contains(key), let definition = definitions[key] else {
                throw JSONProcessingError.unsupportedSchema
            }
            if let existing = named[key] {
                rule.reference = existing
            } else {
                visiting.insert(key)
                let checked = try PreservedJSON(data: definition.data, limits: budget.limits)
                let value = try compile(checked, node: checked.root, depth: depth + 1)
                named[key] = value
                visiting.remove(key)
                rule.reference = value
            }
        }
        if let type = members["type"] {
            rule.type = try scalar(String.self, document, type)
            guard ["object", "array", "string", "number", "integer", "boolean"].contains(rule.type) else {
                throw JSONProcessingError.unsupportedSchema
            }
        }
        if let nullable = members["nullable"] { rule.nullable = try scalar(Bool.self, document, nullable) }
        if let properties = members["properties"] {
            guard case .object(let children) = properties.value else { throw JSONProcessingError.invalidSchema }
            for key in children.keys.sorted() {
                try budget.charge(key.utf8.count + 1)
                rule.properties[key] = try compile(document, node: children[key]!, depth: depth + 1)
            }
        }
        if let required = members["required"] {
            rule.required = try scalar([String].self, document, required)
            guard Set(rule.required).count == rule.required.count else { throw JSONProcessingError.invalidSchema }
            for name in rule.required { try budget.charge(name.utf8.count + 1) }
        }
        if let additional = members["additionalProperties"] {
            rule.additional = try scalar(Bool.self, document, additional)
        }
        if let items = members["items"] { rule.items = try compile(document, node: items, depth: depth + 1) }
        if let anyOf = members["anyOf"] {
            guard case .array(let children) = anyOf.value, !children.isEmpty else {
                throw JSONProcessingError.invalidSchema
            }
            rule.anyOf = []
            for child in children { rule.anyOf?.append(try compile(document, node: child, depth: depth + 1)) }
        }
        if let enumeration = members["enum"] {
            guard case .array(let values) = enumeration.value, !values.isEmpty else {
                throw JSONProcessingError.invalidSchema
            }
            rule.enumeration = []
            for value in values {
                try budget.charge(value.range.count)
                rule.enumeration?.append(
                    try PreservedJSON(data: document.data.subdata(in: value.range), limits: budget.limits))
            }
        }
        for key in ["minimum", "maximum", "multipleOf"] {
            guard let node = members[key] else { continue }
            guard case .number = node.value else { throw JSONProcessingError.invalidSchema }
            let value = try JSONSchemaNumber(document.data.subdata(in: node.range), budget: &budget)
            switch key {
            case "minimum": rule.minimum = value
            case "maximum": rule.maximum = value
            default:
                guard !value.negative, !value.digits.isEmpty else { throw JSONProcessingError.invalidSchema }
                rule.multipleOf = value
            }
        }
        if let exclusive = members["exclusiveMinimum"] {
            rule.exclusiveMinimum = try scalar(Bool.self, document, exclusive)
            guard rule.minimum != nil else { throw JSONProcessingError.invalidSchema }
        }
        if let exclusive = members["exclusiveMaximum"] {
            rule.exclusiveMaximum = try scalar(Bool.self, document, exclusive)
            guard rule.maximum != nil else { throw JSONProcessingError.invalidSchema }
        }
        for key in ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"] {
            if let node = members[key] {
                let value = try scalar(Int.self, document, node)
                guard value >= 0 else { throw JSONProcessingError.invalidSchema }
                rule.sizes[key] = value
            }
        }
        let index = rules.count
        rules.append(rule)
        return index
    }

    func scalar<T: Decodable>(_ type: T.Type, _ document: PreservedJSON, _ node: JSONNode) throws -> T {
        do { return try JSONDecoder().decode(type, from: document.data.subdata(in: node.range)) } catch {
            throw JSONProcessingError.invalidSchema
        }
    }
}

struct JSONPlanValidator {
    let rules: [JSONSchemaRule]
    let document: PreservedJSON
    var budget: JSONSchemaBudget

    mutating func matches(_ index: Int, _ node: JSONNode, depth: Int) throws -> Bool {
        try budget.charge(depth: depth)
        let rule = rules[index]
        if let reference = rule.reference, try !matches(reference, node, depth: depth + 1) { return false }
        if let type = rule.type {
            let valid: Bool
            switch (type, node.value) {
            case ("object", .object), ("array", .array), ("string", .string), ("number", .number),
                ("integer", .number(isInteger: true)), ("boolean", .boolean):
                valid = true
            case (_, .null): valid = rule.nullable
            default: valid = false
            }
            if !valid { return false }
        }
        if let values = rule.enumeration {
            var found = false
            for value in values {
                let same = try equal(document, node, value, value.root, depth: depth)
                found = found || same
            }
            if !found { return false }
        }
        switch node.value {
        case .number:
            if rule.minimum != nil || rule.maximum != nil || rule.multipleOf != nil {
                let number = try JSONSchemaNumber(document.data.subdata(in: node.range), budget: &budget)
                if let minimum = rule.minimum {
                    let order = try number.compare(minimum, budget: &budget)
                    if order < 0 || (order == 0 && rule.exclusiveMinimum) { return false }
                }
                if let maximum = rule.maximum {
                    let order = try number.compare(maximum, budget: &budget)
                    if order > 0 || (order == 0 && rule.exclusiveMaximum) { return false }
                }
                if let multiple = rule.multipleOf, try !number.isMultiple(of: multiple, budget: &budget) {
                    return false
                }
            }
        case .string:
            if !rule.sizes.isEmpty || rule.pattern != nil {
                try budget.charge(node.range.count)
                let text = try JSONDecoder().decode(String.self, from: document.data.subdata(in: node.range))
                if !size(text.unicodeScalars.count, "Length", rule) { return false }
                if let pattern = rule.pattern, try !pattern.matches(text, budget: &budget) { return false }
            }
        case .array(let children):
            if !size(children.count, "Items", rule) { return false }
            if let item = rule.items {
                for child in children { if try !matches(item, child, depth: depth + 1) { return false } }
            }
        case .object(let members):
            if !size(members.count, "Properties", rule) { return false }
            for key in rule.required {
                try budget.charge(key.utf8.count + 1)
                guard let index = members.index(forKey: key), members.keys[index].utf8.elementsEqual(key.utf8) else {
                    return false
                }
            }
            for key in members.keys.sorted() {
                try budget.charge(key.utf8.count + 1)
                if let position = rule.properties.index(forKey: key),
                    rule.properties.keys[position].utf8.elementsEqual(key.utf8)
                {
                    let child = rule.properties.values[position]
                    if try !matches(child, members[key]!, depth: depth + 1) { return false }
                } else if !rule.additional {
                    return false
                }
            }
        default: break
        }
        if let children = rule.anyOf {
            var found = false
            for child in children {
                let valid = try matches(child, node, depth: depth + 1)
                found = found || valid
            }
            if !found { return false }
        }
        return true
    }

    func size(_ count: Int, _ suffix: String, _ rule: JSONSchemaRule) -> Bool {
        count >= (rule.sizes["min" + suffix] ?? 0) && count <= (rule.sizes["max" + suffix] ?? Int.max)
    }

    mutating func equal(_ lhs: PreservedJSON, _ left: JSONNode, _ rhs: PreservedJSON, _ right: JSONNode, depth: Int)
        throws -> Bool
    {
        try budget.charge(depth: depth)
        switch (left.value, right.value) {
        case (.null, .null): return true
        case (.number, .number):
            let a = try JSONSchemaNumber(lhs.data.subdata(in: left.range), budget: &budget)
            let b = try JSONSchemaNumber(rhs.data.subdata(in: right.range), budget: &budget)
            return try a.compare(b, budget: &budget) == 0
        case (.string, .string):
            try budget.charge(left.range.count + right.range.count)
            let a = try JSONDecoder().decode(String.self, from: lhs.data.subdata(in: left.range))
            let b = try JSONDecoder().decode(String.self, from: rhs.data.subdata(in: right.range))
            return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.boolean, .boolean): return lhs.data[left.range.lowerBound] == rhs.data[right.range.lowerBound]
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (left, right) in zip(a, b) { if try !equal(lhs, left, rhs, right, depth: depth + 1) { return false } }
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for key in a.keys.sorted() {
                try budget.charge(key.utf8.count + 1)
                // Dictionary lookup uses Swift canonical equivalence; schema equality
                // must additionally compare the actual member name's code points.
                guard let position = b.index(forKey: key), b.keys[position].utf8.elementsEqual(key.utf8) else {
                    return false
                }
                if try !equal(lhs, a[key]!, rhs, b.values[position], depth: depth + 1) { return false }
            }
            return true
        default: return false
        }
    }
}
