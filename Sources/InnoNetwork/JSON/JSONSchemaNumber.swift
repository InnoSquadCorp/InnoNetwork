import Foundation

/// Decimal digits, never a binary floating-point approximation. Exponents stay
/// compressed even when their magnitude is larger than a machine integer.
struct JSONSchemaNumber: Sendable {
    let negative: Bool
    let digits: [UInt8]
    let scale: JSONSchemaExponent

    init(_ data: Data, budget: inout JSONSchemaBudget) throws {
        try budget.charge(data.count)
        let bytes = Array(data)
        var index = bytes.first == 45 ? 1 : 0
        let negative = index == 1
        var coefficient: [UInt8] = []
        var fraction = 0
        var decimal = false
        while index < bytes.count, bytes[index] != 101, bytes[index] != 69 {
            if bytes[index] == 46 {
                decimal = true
            } else {
                coefficient.append(bytes[index] - 48)
                if decimal { fraction += 1 }
            }
            index += 1
        }
        let start = coefficient.firstIndex(where: { $0 != 0 }) ?? coefficient.count
        var end = coefficient.count
        while end > start, coefficient[end - 1] == 0 { end -= 1 }
        self.negative = start < end && negative
        self.digits = Array(coefficient[start..<end])
        var exponent = JSONSchemaExponent(0)
        if index < bytes.count {
            index += 1
            var minus = false
            if bytes[index] == 43 || bytes[index] == 45 {
                minus = bytes[index] == 45
                index += 1
            }
            exponent = JSONSchemaExponent(negative: minus, digits: bytes[index...].map { $0 - 48 })
        }
        self.scale = digits.isEmpty ? JSONSchemaExponent(0) : exponent.adding(coefficient.count - end - fraction)
    }

    func compare(_ other: Self, budget: inout JSONSchemaBudget) throws -> Int {
        try budget.charge(digits.count + other.digits.count + scale.digits.count + other.scale.digits.count)
        if digits.isEmpty && other.digits.isEmpty { return 0 }
        if negative != other.negative { return negative ? -1 : 1 }
        let direction = negative ? -1 : 1
        if digits.isEmpty { return -direction }
        if other.digits.isEmpty { return direction }
        let order = scale.adding(digits.count).compare(other.scale.adding(other.digits.count))
        if order != 0 { return direction * order }
        for index in 0..<max(digits.count, other.digits.count) {
            let lhs = index < digits.count ? digits[index] : 0
            let rhs = index < other.digits.count ? other.digits[index] : 0
            if lhs != rhs { return direction * (lhs < rhs ? -1 : 1) }
        }
        return 0
    }

    func isMultiple(of divisor: Self, budget: inout JSONSchemaBudget) throws -> Bool {
        if digits.isEmpty { return true }
        let exponent = scale.subtracting(divisor.scale)
        try budget.charge(scale.digits.count + divisor.scale.digits.count)
        if exponent.negative { return false }
        // Once the denominator's factors of 2 and 5 have been exhausted, another
        // power of ten cannot make a nonzero remainder zero. 4 * decimal digits
        // bounds both valuations, so a huge exponent never expands into zeros.
        let steps = min(exponent.smallValue ?? Int.max, divisor.digits.count * 4)
        var remainder: [UInt8] = []
        for digit in digits {
            remainder = try Self.remainder(remainder + [digit], divisor.digits, budget: &budget)
        }
        for _ in 0..<steps {
            if remainder.isEmpty { return true }
            remainder = try Self.remainder(remainder + [0], divisor.digits, budget: &budget)
        }
        return remainder.isEmpty
    }

    private static func remainder(_ value: [UInt8], _ divisor: [UInt8], budget: inout JSONSchemaBudget) throws
        -> [UInt8]
    {
        var result = Array(value.drop(while: { $0 == 0 }))
        while result.count > divisor.count
            || (result.count == divisor.count && !result.lexicographicallyPrecedes(divisor))
        {
            try budget.charge(result.count + divisor.count)
            var borrow = 0
            for offset in 0..<result.count {
                let index = result.count - 1 - offset
                let rhs = offset < divisor.count ? Int(divisor[divisor.count - 1 - offset]) : 0
                let difference = Int(result[index]) - rhs - borrow
                result[index] = UInt8((difference + 10) % 10)
                borrow = difference < 0 ? 1 : 0
            }
            result = Array(result.drop(while: { $0 == 0 }))
        }
        try budget.charge(result.count + 1)
        return result
    }
}

struct JSONSchemaExponent: Sendable {
    let negative: Bool
    let digits: [UInt8]

    init(_ value: Int) { self.init(negative: value < 0, digits: String(value.magnitude).utf8.map { $0 - 48 }) }
    init(negative: Bool, digits: [UInt8]) {
        self.digits = Array(digits.drop(while: { $0 == 0 }))
        self.negative = !self.digits.isEmpty && negative
    }
    var smallValue: Int? {
        guard digits.count <= 18 else { return nil }
        let value = digits.reduce(0) { $0 * 10 + Int($1) }
        return negative ? -value : value
    }
    func compare(_ other: Self) -> Int {
        if negative != other.negative { return negative ? -1 : 1 }
        let sign = negative ? -1 : 1
        if digits.count != other.digits.count { return sign * (digits.count < other.digits.count ? -1 : 1) }
        if digits == other.digits { return 0 }
        return sign * (digits.lexicographicallyPrecedes(other.digits) ? -1 : 1)
    }
    func adding(_ value: Int) -> Self { adding(Self(value)) }
    func subtracting(_ other: Self) -> Self { adding(Self(negative: !other.negative, digits: other.digits)) }
    func adding(_ other: Self) -> Self {
        if negative == other.negative {
            var result: [UInt8] = []
            var carry = 0
            for index in 0..<max(digits.count, other.digits.count) {
                let lhs = index < digits.count ? Int(digits[digits.count - 1 - index]) : 0
                let rhs = index < other.digits.count ? Int(other.digits[other.digits.count - 1 - index]) : 0
                let sum = lhs + rhs + carry
                result.append(UInt8(sum % 10))
                carry = sum / 10
            }
            if carry > 0 { result.append(UInt8(carry)) }
            return Self(negative: negative, digits: result.reversed())
        }
        let lhsLarger =
            digits.count > other.digits.count
            || (digits.count == other.digits.count && !digits.lexicographicallyPrecedes(other.digits))
        let larger = lhsLarger ? self : other
        let smaller = lhsLarger ? other : self
        var result = larger.digits
        var borrow = 0
        for index in 0..<result.count {
            let rhs = index < smaller.digits.count ? Int(smaller.digits[smaller.digits.count - 1 - index]) : 0
            let offset = result.count - 1 - index
            let difference = Int(result[offset]) - rhs - borrow
            result[offset] = UInt8((difference + 10) % 10)
            borrow = difference < 0 ? 1 : 0
        }
        return Self(negative: larger.negative, digits: result)
    }
}
