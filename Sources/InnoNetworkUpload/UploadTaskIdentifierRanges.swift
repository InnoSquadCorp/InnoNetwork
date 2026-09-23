/// Exact membership for URLSession task identifiers. Adjacent IDs
/// share one interval, but sparse or out-of-order IDs remain individually
/// represented: no monotonic task-identifier guarantee is assumed.
struct UploadTaskIdentifierRanges: Sendable {
    private(set) var ranges: [ClosedRange<Int>] = []

    var rangeCount: Int { ranges.count }

    func contains(_ identifier: Int) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let range = ranges[middle]
            if identifier < range.lowerBound {
                upper = middle
            } else if identifier > range.upperBound {
                lower = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    @discardableResult
    mutating func insert(_ identifier: Int) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].lowerBound <= identifier {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var index = lower
        if index > 0, ranges[index - 1].contains(identifier) { return false }

        var first = identifier
        var last = identifier
        if index > 0,
            ranges[index - 1].upperBound != Int.max,
            ranges[index - 1].upperBound + 1 == identifier
        {
            first = ranges[index - 1].lowerBound
            ranges.remove(at: index - 1)
            index -= 1
        }
        if index < ranges.count,
            identifier != Int.max,
            identifier + 1 == ranges[index].lowerBound
        {
            last = ranges[index].upperBound
            ranges.remove(at: index)
        }
        ranges.insert(first...last, at: index)
        return true
    }

    mutating func removeAll() {
        ranges.removeAll(keepingCapacity: false)
    }
}
