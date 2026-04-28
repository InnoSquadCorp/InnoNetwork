import Foundation

package struct FIFOBuffer<Element> {
    private var storage: [Element?] = []
    private var headIndex = 0

    package var isEmpty: Bool {
        count == 0
    }

    package var count: Int {
        storage.count - headIndex
    }

    package var first: Element? {
        guard headIndex < storage.count else { return nil }
        return storage[headIndex]
    }

    package init() {}

    package mutating func append(_ element: Element) {
        storage.append(element)
    }

    package mutating func popFirst() -> Element? {
        guard headIndex < storage.count else { return nil }
        let element = storage[headIndex]
        storage[headIndex] = nil
        headIndex += 1
        compactIfNeeded()
        return element
    }

    package mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        headIndex = 0
    }

    @discardableResult
    package mutating func removeLast() -> Element? {
        while storage.last == nil {
            storage.removeLast()
        }
        return storage.popLast() ?? nil
    }

    private mutating func compactIfNeeded() {
        guard headIndex > 32, headIndex * 2 >= storage.count else { return }
        storage.removeFirst(headIndex)
        headIndex = 0
    }
}
