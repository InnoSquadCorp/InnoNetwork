import Foundation

/// A documented ECMA-262 Unicode-mode subset. Thompson-style state sets avoid
/// backtracking; every transition, epsilon edge and character-class test is charged.
struct JSONSchemaPattern: Sendable {
    enum State: Sendable {
        case accept
        case character(CharacterSet, next: Int)
        case split(Int, Int)
        case start(Int)
        case end(Int)
    }
    struct CharacterSet: Sendable {
        let ranges: [ClosedRange<UInt32>]
        var inverted = false
        func contains(_ scalar: UInt32, budget: inout JSONSchemaBudget) throws -> Bool {
            var found = false
            for range in ranges {
                try budget.charge()
                if range.contains(scalar) { found = true }
            }
            return inverted != found
        }
    }
    struct Atom {
        let characters: CharacterSet
        var minimum = 1
        var maximum: Int? = 1
    }
    let states: [State]
    let start: Int

    init(_ pattern: String, budget: inout JSONSchemaBudget) throws {
        try budget.charge(pattern.utf8.count)
        var parser = Parser(input: Array(pattern.unicodeScalars.map(\.value)))
        let anchoredStart = parser.take(94)
        var atoms: [Atom] = []
        var anchoredEnd = false
        while parser.index < parser.input.count {
            if parser.input[parser.index] == 36, parser.index == parser.input.count - 1 {
                anchoredEnd = true
                parser.index += 1
                break
            }
            var atom = Atom(characters: try parser.character())
            if parser.take(42) {
                atom.minimum = 0
                atom.maximum = nil
            } else if parser.take(43) {
                atom.maximum = nil
            } else if parser.take(63) {
                atom.minimum = 0
            } else if parser.take(123) {
                atom.minimum = try parser.count()
                atom.maximum = atom.minimum
                if parser.take(44) { atom.maximum = parser.peek(125) ? nil : try parser.count() }
                guard parser.take(125), atom.maximum.map({ $0 >= atom.minimum }) ?? true else {
                    throw JSONProcessingError.unsupportedSchema
                }
            }
            atoms.append(atom)
        }
        var states: [State] = [.accept]
        var next = 0
        func append(_ state: State) throws -> Int {
            try budget.charge()
            guard states.count < 4096 else { throw JSONProcessingError.resourceLimit }
            states.append(state)
            return states.count - 1
        }
        if anchoredEnd { next = try append(.end(next)) }
        for atom in atoms.reversed() {
            if let maximum = atom.maximum {
                for _ in atom.minimum..<maximum {
                    let character = try append(.character(atom.characters, next: next))
                    next = try append(.split(character, next))
                }
            } else {
                let split = try append(.accept)
                let character = try append(.character(atom.characters, next: split))
                states[split] = .split(character, next)
                next = split
            }
            for _ in 0..<atom.minimum { next = try append(.character(atom.characters, next: next)) }
        }
        if anchoredStart { next = try append(.start(next)) }
        self.states = states
        self.start = next
    }

    func matches(_ string: String, budget: inout JSONSchemaBudget) throws -> Bool {
        let scalars = Array(string.unicodeScalars.map(\.value))
        var active: Set<Int> = []
        for position in 0...scalars.count {
            // A new start at each position implements unanchored JSON Schema search.
            active.insert(start)
            var pending = active.sorted()
            var seen: Set<Int> = []
            var consuming: Set<Int> = []
            while let state = pending.popLast() {
                try budget.charge()
                guard seen.insert(state).inserted else { continue }
                switch states[state] {
                case .accept: return true
                case .character: consuming.insert(state)
                case .split(let a, let b):
                    pending.append(a)
                    pending.append(b)
                case .start(let next): if position == 0 { pending.append(next) }
                case .end(let next): if position == scalars.count { pending.append(next) }
                }
            }
            if position == scalars.count { break }
            active = []
            for state in consuming.sorted() {
                try budget.charge()
                if case .character(let characters, let next) = states[state],
                    try characters.contains(scalars[position], budget: &budget)
                {
                    active.insert(next)
                }
            }
        }
        return false
    }

    private struct Parser {
        let input: [UInt32]
        var index = 0
        func peek(_ value: UInt32) -> Bool { index < input.count && input[index] == value }
        mutating func take(_ value: UInt32) -> Bool {
            guard peek(value) else { return false }
            index += 1
            return true
        }
        mutating func count() throws -> Int {
            var value = 0
            let start = index
            while index < input.count, (48...57).contains(input[index]) {
                value = value * 10 + Int(input[index] - 48)
                index += 1
                guard value <= 4096 else { throw JSONProcessingError.resourceLimit }
            }
            guard index != start else { throw JSONProcessingError.unsupportedSchema }
            return value
        }
        mutating func escaped() throws -> CharacterSet {
            guard index < input.count else { throw JSONProcessingError.unsupportedSchema }
            let value = input[index]
            index += 1
            switch value {
            case 100, 68: return CharacterSet(ranges: [48...57], inverted: value == 68)
            case 119, 87: return CharacterSet(ranges: [48...57, 65...90, 95...95, 97...122], inverted: value == 87)
            case 110: return CharacterSet(ranges: [10...10])
            case 114: return CharacterSet(ranges: [13...13])
            case 116: return CharacterSet(ranges: [9...9])
            case 102: return CharacterSet(ranges: [12...12])
            case 118: return CharacterSet(ranges: [11...11])
            case 46, 92, 91, 93, 123, 125, 40, 41, 42, 43, 63, 94, 36, 124, 45, 47:
                return CharacterSet(ranges: [value...value])
            default: throw JSONProcessingError.unsupportedSchema
            }
        }
        mutating func character() throws -> CharacterSet {
            guard index < input.count else { throw JSONProcessingError.unsupportedSchema }
            if take(92) {
                guard !peek(45) else { throw JSONProcessingError.unsupportedSchema }
                return try escaped()
            }
            if take(46) { return CharacterSet(ranges: [10...10, 13...13, 0x2028...0x2029], inverted: true) }
            if take(91) {
                let inverted = take(94)
                var ranges: [ClosedRange<UInt32>] = []
                while index < input.count, !peek(93) {
                    let first = try classCharacter()
                    if take(45) {
                        guard !peek(93) else {
                            ranges += first.ranges + [45...45]
                            continue
                        }
                        let last = try classCharacter()
                        guard first.ranges.count == 1, last.ranges.count == 1,
                            first.ranges[0].lowerBound == first.ranges[0].upperBound,
                            last.ranges[0].lowerBound == last.ranges[0].upperBound,
                            first.ranges[0].lowerBound <= last.ranges[0].lowerBound
                        else { throw JSONProcessingError.unsupportedSchema }
                        ranges.append(first.ranges[0].lowerBound...last.ranges[0].lowerBound)
                    } else {
                        ranges += first.ranges
                    }
                }
                guard take(93) else { throw JSONProcessingError.unsupportedSchema }
                return CharacterSet(ranges: ranges, inverted: inverted)
            }
            let value = input[index]
            index += 1
            guard ![94, 36, 40, 41, 123, 125, 93, 42, 43, 63, 124].contains(value) else {
                throw JSONProcessingError.unsupportedSchema
            }
            return CharacterSet(ranges: [value...value])
        }
        mutating func classCharacter() throws -> CharacterSet {
            if take(92) {
                let set = try escaped()
                guard !set.inverted else { throw JSONProcessingError.unsupportedSchema }
                return set
            }
            guard index < input.count else { throw JSONProcessingError.unsupportedSchema }
            let value = input[index]
            index += 1
            return CharacterSet(ranges: [value...value])
        }
    }
}
