import Foundation

/// Selects keyword semantics, not a promise of complete dialect support.
public enum JSONSchemaDialect: Sendable {
    /// OpenAPI 3.0 nullable and boolean exclusive-bound semantics.
    case openAPI30
    /// The documented JSON Schema 2020-12 / OpenAPI 3.1 subset.
    case jsonSchema202012
}

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
        dialect: JSONSchemaDialect = .openAPI30,
        limits: JSONProcessingLimits = .init()
    ) throws {
        try limits.validate()
        var compiler = JSONSchemaCompiler(definitions: definitions, dialect: dialect, budget: .init(limits: limits))
        var bytes = schema.data.count
        for (name, definition) in definitions {
            guard definition.data.count <= limits.maximumBytes - bytes else { throw JSONProcessingError.resourceLimit }
            bytes += definition.data.count
            try compiler.budget.charge(name.utf8.count + 1)
        }
        let checked = try PreservedJSON(data: schema.data, limits: limits)
        if dialect == .jsonSchema202012, case .object(let members) = checked.root.value, let defs = members["$defs"] {
            guard case .object(let entries) = defs.value else { throw JSONProcessingError.invalidSchema }
            for (name, node) in entries {
                compiler.localDefinitions[name] = try PreservedJSON(
                    data: checked.data.subdata(in: node.range), limits: limits)
            }
        }
        root = try compiler.compile(checked, node: checked.root, depth: 1)
        try compiler.validateProgress()
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
    var types: [String]?
    var boolean: Bool?
    var nullable = false
    var properties: [String: Int] = [:]
    var required: [String] = []
    var additional = true
    var items: Int?
    var reference: Int?
    var anyOf: [Int]?
    var allOf: [Int]?
    var oneOf: [Int]?
    var enumeration: [PreservedJSON]?
    var minimum: JSONSchemaNumber?
    var maximum: JSONSchemaNumber?
    var exclusiveMinimum = false
    var exclusiveMaximum = false
    var exclusiveMinimumValue: JSONSchemaNumber?
    var exclusiveMaximumValue: JSONSchemaNumber?
    var multipleOf: JSONSchemaNumber?
    var sizes: [String: Int] = [:]
    var pattern: JSONSchemaPattern?
}

struct JSONSchemaCompiler {
    let definitions: [String: PreservedJSON]
    let dialect: JSONSchemaDialect
    var localDefinitions: [String: PreservedJSON] = [:]
    var budget: JSONSchemaBudget
    var rules: [JSONSchemaRule] = []
    var named: [String: Int] = [:]

    mutating func compile(_ document: PreservedJSON, node: JSONNode, depth: Int, reserved: Int? = nil) throws -> Int {
        try budget.charge(depth: depth)
        let index = reserved ?? rules.count
        if reserved == nil { rules.append(JSONSchemaRule()) }
        if case .boolean = node.value, dialect == .jsonSchema202012 {
            rules[index].boolean = try scalar(Bool.self, document, node)
            return index
        }
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
            let modern =
                dialect == .jsonSchema202012
                && ["$schema", "$defs", "const", "allOf", "oneOf", "examples", "default", "$comment"].contains(name)
            guard supported.contains(name) || modern, !(dialect == .jsonSchema202012 && name == "nullable") else {
                throw JSONProcessingError.unsupportedSchema
            }
        }
        var rule = JSONSchemaRule()
        if let schema = members["$schema"] {
            let name = try scalar(String.self, document, schema)
            guard
                ["https://json-schema.org/draft/2020-12/schema", "https://spec.openapis.org/oas/3.1/dialect/base"]
                    .contains(name)
            else {
                throw JSONProcessingError.unsupportedSchema
            }
        }
        if members["$defs"] != nil, depth != 1 { throw JSONProcessingError.unsupportedSchema }
        if let pattern = members["pattern"] {
            rule.pattern = try JSONSchemaPattern(scalar(String.self, document, pattern), budget: &budget)
        }
        // Format is annotation-only in compiled plans; never infer assertions
        // from Foundation decoders or silently reinterpret a regex dialect.
        if let format = members["format"] { _ = try scalar(String.self, document, format) }
        if let reference = members["$ref"] {
            let name = try scalar(String.self, document, reference)
            guard
                dialect == .jsonSchema202012
                    || members.keys.allSatisfy({ ["$ref", "title", "description"].contains($0) })
            else {
                throw JSONProcessingError.unsupportedSchema
            }
            let prefix =
                dialect == .jsonSchema202012 && name.hasPrefix("#/$defs/") ? "#/$defs/" : "#/components/schemas/"
            guard name.hasPrefix(prefix) else { throw JSONProcessingError.unsupportedSchema }
            let key = String(name.dropFirst(prefix.count)).replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            // Reject invalid pointer escapes instead of inventing a different name.
            let token = String(name.dropFirst(prefix.count))
            guard
                !token.replacingOccurrences(of: "~0", with: "").replacingOccurrences(of: "~1", with: "").contains("~"),
                !token.contains("/"), let definition = (prefix == "#/$defs/" ? localDefinitions[key] : definitions[key])
            else {
                throw JSONProcessingError.unsupportedSchema
            }
            if let existing = named[name] {
                rule.reference = existing
            } else {
                let value = rules.count
                rules.append(JSONSchemaRule())
                named[name] = value
                let checked = try PreservedJSON(data: definition.data, limits: budget.limits)
                _ = try compile(checked, node: checked.root, depth: depth + 1, reserved: value)
                rule.reference = value
            }
        }
        if let type = members["type"] {
            if case .array = type.value, dialect == .jsonSchema202012 {
                rule.types = try scalar([String].self, document, type)
            } else {
                rule.types = [try scalar(String.self, document, type)]
            }
            let allowed =
                ["object", "array", "string", "number", "integer", "boolean"]
                + (dialect == .jsonSchema202012 ? ["null"] : [])
            guard let types = rule.types, !types.isEmpty, Set(types).count == types.count,
                types.allSatisfy(allowed.contains)
            else {
                throw JSONProcessingError.unsupportedSchema
            }
        }
        if let nullable = members["nullable"] { rule.nullable = try scalar(Bool.self, document, nullable) }
        if let properties = members["properties"] {
            guard case .object(let children) = properties.value else { throw JSONProcessingError.invalidSchema }
            for key in children.keys.sorted() {
                try budget.charge(key.utf8.count + 1)
                guard let child = children[key] else { throw JSONProcessingError.invalidSchema }
                rule.properties[key] = try compile(document, node: child, depth: depth + 1)
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
            guard case .array(let values) = enumeration.value else {
                throw JSONProcessingError.invalidSchema
            }
            rule.enumeration = []
            for value in values {
                try budget.charge(value.range.count)
                rule.enumeration?.append(
                    try PreservedJSON(data: document.data.subdata(in: value.range), limits: budget.limits))
            }
        }
        if let allOf = members["allOf"] {
            guard case .array(let children) = allOf.value, !children.isEmpty else {
                throw JSONProcessingError.invalidSchema
            }
            rule.allOf = []
            for child in children { rule.allOf?.append(try compile(document, node: child, depth: depth + 1)) }
        }
        if let constant = members["const"] {
            try budget.charge(constant.range.count)
            let value = try PreservedJSON(data: document.data.subdata(in: constant.range), limits: budget.limits)
            let identifier = rules.count
            rules.append(JSONSchemaRule(enumeration: [value]))
            rule.allOf = (rule.allOf ?? []) + [identifier]
        }
        if let oneOf = members["oneOf"] {
            guard case .array(let children) = oneOf.value, !children.isEmpty else {
                throw JSONProcessingError.invalidSchema
            }
            rule.oneOf = []
            for child in children { rule.oneOf?.append(try compile(document, node: child, depth: depth + 1)) }
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
            if dialect == .jsonSchema202012 {
                guard case .number = exclusive.value else { throw JSONProcessingError.invalidSchema }
                rule.exclusiveMinimumValue = try JSONSchemaNumber(
                    document.data.subdata(in: exclusive.range), budget: &budget)
            } else {
                rule.exclusiveMinimum = try scalar(Bool.self, document, exclusive)
                guard rule.minimum != nil else { throw JSONProcessingError.invalidSchema }
            }
        }
        if let exclusive = members["exclusiveMaximum"] {
            if dialect == .jsonSchema202012 {
                guard case .number = exclusive.value else { throw JSONProcessingError.invalidSchema }
                rule.exclusiveMaximumValue = try JSONSchemaNumber(
                    document.data.subdata(in: exclusive.range), budget: &budget)
            } else {
                rule.exclusiveMaximum = try scalar(Bool.self, document, exclusive)
                guard rule.maximum != nil else { throw JSONProcessingError.invalidSchema }
            }
        }
        for key in ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"] {
            if let node = members[key] {
                let value = try scalar(Int.self, document, node)
                guard value >= 0 else { throw JSONProcessingError.invalidSchema }
                rule.sizes[key] = value
            }
        }
        rules[index] = rule
        return index
    }

    /// Only edges that do not consume an instance child participate here. A
    /// property/items edge is productive recursion; an alias/anyOf cycle is not.
    mutating func validateProgress() throws {
        var finished: Set<Int> = []
        var active: Set<Int> = []
        func visit(_ index: Int, depth: Int) throws {
            try budget.charge(depth: depth)
            guard !active.contains(index) else { throw JSONProcessingError.unsupportedSchema }
            if finished.contains(index) { return }
            active.insert(index)
            let edges =
                (rules[index].reference.map { [$0] } ?? []) + (rules[index].anyOf ?? []) + (rules[index].allOf ?? [])
                + (rules[index].oneOf ?? [])
            for child in edges { try visit(child, depth: depth + 1) }
            active.remove(index)
            finished.insert(index)
        }
        for index in rules.indices { try visit(index, depth: 1) }
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
    struct Visit: Hashable {
        let schema: Int
        let offset: Int
    }
    var active: Set<Visit> = []

    mutating func matches(_ index: Int, _ node: JSONNode, depth: Int) throws -> Bool {
        try budget.charge(depth: depth)
        let visit = Visit(schema: index, offset: node.range.lowerBound)
        guard active.insert(visit).inserted else { throw JSONProcessingError.invalidSchema }
        defer { active.remove(visit) }
        let rule = rules[index]
        if let boolean = rule.boolean { return boolean }
        if let reference = rule.reference, try !matches(reference, node, depth: depth + 1) { return false }
        if let types = rule.types {
            var valid = false
            for type in types {
                try budget.charge()
                switch (type, node.value) {
                case ("object", .object), ("array", .array), ("string", .string), ("number", .number),
                    ("integer", .number(isInteger: true)), ("boolean", .boolean), ("null", .null):
                    valid = true
                case (_, .null): valid = valid || rule.nullable
                default: break
                }
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
            if rule.minimum != nil || rule.maximum != nil || rule.multipleOf != nil
                || rule.exclusiveMinimumValue != nil || rule.exclusiveMaximumValue != nil
            {
                let number = try JSONSchemaNumber(document.data.subdata(in: node.range), budget: &budget)
                if let minimum = rule.minimum {
                    let order = try number.compare(minimum, budget: &budget)
                    if order < 0 || (order == 0 && rule.exclusiveMinimum) { return false }
                }
                if let maximum = rule.maximum {
                    let order = try number.compare(maximum, budget: &budget)
                    if order > 0 || (order == 0 && rule.exclusiveMaximum) { return false }
                }
                if let minimum = rule.exclusiveMinimumValue, try number.compare(minimum, budget: &budget) <= 0 {
                    return false
                }
                if let maximum = rule.exclusiveMaximumValue, try number.compare(maximum, budget: &budget) >= 0 {
                    return false
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
                    guard let member = members[key] else { throw JSONProcessingError.invalidJSON }
                    if try !matches(child, member, depth: depth + 1) { return false }
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
        if let children = rule.allOf {
            var valid = true
            for child in children {
                let result = try matches(child, node, depth: depth + 1)
                valid = valid && result
            }
            if !valid { return false }
        }
        if let children = rule.oneOf {
            var count = 0
            for child in children { if try matches(child, node, depth: depth + 1) { count += 1 } }
            if count != 1 { return false }
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
                guard let member = a[key] else { throw JSONProcessingError.invalidJSON }
                if try !equal(lhs, member, rhs, b.values[position], depth: depth + 1) { return false }
            }
            return true
        default: return false
        }
    }
}
