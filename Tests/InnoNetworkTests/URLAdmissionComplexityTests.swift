import Foundation
import Testing

@testable import InnoNetwork

@Suite("URL admission bounded work")
struct URLAdmissionComplexityTests {
    @Test(arguments: [1, 64, 512, 2048, 8192, 32768])
    func nestedEscapesHaveLinearWork(depth: Int) {
        let prefix = "/%" + String(repeating: "25", count: depth)
        for (suffix, rejected) in [
            ("2E", true), ("2e%2E%2Fadmin", true), ("5C..%2Fadmin", true), ("41", false), ("2Efile", false),
        ] {
            let path = prefix + suffix
            let scan = NetworkURLAdmission.DotSegmentScan(path)
            #expect(scan.containsDotSegment == rejected)
            #expect(NetworkURLAdmission.containsDotSegment(path) == rejected)
            #if DEBUG
            #expect(scan.scannedByteCount <= path.utf8.count * 8)
            #endif
        }
    }

    @Test("Structural decoder agrees with a byte-delimited fixed-point oracle")
    func differentialStructuralAdmission() {
        let fragments = [
            "/", "\\", ".", "..", "%", "2", "5", "E", "C", "%25", "%2e", "%2F", "%5c", "%FF", "%41", "%32", "a", "é",
            "\u{0301}",
        ]
        for first in fragments {
            for second in fragments {
                for third in fragments {
                    let value = "/" + first + second + third + "/"
                    #expect(NetworkURLAdmission.containsDotSegment(value) == reference(value), "\(value)")
                }
            }
        }
    }

    @Test("A combining scalar cannot hide the separator after a dot segment")
    func combiningSeparatorControls() {
        for dot in [".", "..", "%2e"] {
            for separator in ["/", "\\", "%2F", "%5c"] {
                #expect(NetworkURLAdmission.containsDotSegment("/" + dot + separator + "\u{0301}/"))
            }
        }
        #expect(!NetworkURLAdmission.containsDotSegment("/.\u{0301}/"))
        #expect(!NetworkURLAdmission.containsDotSegment("/file/\u{0301}/"))
    }

    // Deliberately simple, bounded-input oracle for fixed-point decoding.
    // Separators are bytes: the old Character split missed /./ + combining mark.
    private func reference(_ path: String) -> Bool {
        var candidate = path
        while true {
            if candidate.utf8.split(whereSeparator: { $0 == 47 || $0 == 92 }).contains(where: {
                ($0.count == 1 || $0.count == 2) && $0.allSatisfy { $0 == 46 }
            }) {
                return true
            }
            let bytes = Array(candidate.utf8)
            var output: [UInt8] = []
            var index = 0
            while index < bytes.count {
                if bytes[index] == 37, index + 2 < bytes.count,
                    let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2])
                {
                    let decoded = high * 16 + low
                    if [37, 46, 47, 92].contains(decoded) {
                        output.append(decoded)
                    } else {
                        output.append(contentsOf: bytes[index...index + 2])
                    }
                    index += 3
                } else {
                    output.append(bytes[index])
                    index += 1
                }
            }
            let next = String(decoding: output, as: UTF8.self)
            if next == candidate { return false }
            candidate = next
        }
    }

    private func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
