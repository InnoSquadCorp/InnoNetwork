import Testing

@testable import InnoNetworkUpload

@Suite("Upload task identifier ranges")
struct UploadTaskIdentifierRangesTests {
    @Test("consecutive identifiers use one exact range")
    func compressesConsecutiveIdentifiers() {
        var identifiers = UploadTaskIdentifierRanges()
        for identifier in 1...10_000 {
            let inserted = identifiers.insert(identifier)
            #expect(inserted)
        }
        #expect(identifiers.rangeCount == 1)
        #expect(identifiers.contains(1))
        #expect(identifiers.contains(10_000))
        #expect(!identifiers.contains(10_001))
        let duplicateInserted = identifiers.insert(5_000)
        #expect(!duplicateInserted)
        identifiers.removeAll()
        #expect(identifiers.rangeCount == 0)
    }

    @Test("out-of-order sparse identifiers never gain false membership")
    func retainsExactSparseMembership() {
        var identifiers = UploadTaskIdentifierRanges()
        for identifier in [8, 2, 10, 4, 6, 7, 3, 5, 9] {
            let inserted = identifiers.insert(identifier)
            #expect(inserted)
        }
        #expect(identifiers.rangeCount == 1)
        #expect(identifiers.ranges == [2...10])
        #expect(!identifiers.contains(1))
        #expect(!identifiers.contains(11))
        let sparseInserted = identifiers.insert(100)
        #expect(sparseInserted)
        #expect(identifiers.rangeCount == 2)
        #expect(!identifiers.contains(50))
    }

    @Test("integer endpoints merge without overflow")
    func handlesIntegerEndpoints() {
        var identifiers = UploadTaskIdentifierRanges()
        _ = identifiers.insert(Int.max)
        _ = identifiers.insert(Int.max - 1)
        _ = identifiers.insert(Int.min)
        _ = identifiers.insert(Int.min + 1)
        #expect(identifiers.rangeCount == 2)
        #expect(identifiers.contains(Int.max))
        #expect(identifiers.contains(Int.min))
        #expect(!identifiers.contains(0))
    }
}
