import Foundation
import Testing

@testable import InnoNetwork

@Suite("SendableUnderlyingError chain capture")
struct SendableUnderlyingErrorTests {

    @Test("init(_:) captures NSUnderlyingErrorKey chain bounded by maxUnderlyingDepth")
    func capturesUnderlyingChain() {
        let kernel = NSError(
            domain: NSPOSIXErrorDomain,
            code: 60, // ETIMEDOUT
            userInfo: [NSLocalizedDescriptionKey: "Operation timed out"]
        )
        let cfNetwork = NSError(
            domain: kCFErrorDomainCFNetwork as String,
            code: -1001,
            userInfo: [
                NSLocalizedDescriptionKey: "The request timed out.",
                NSUnderlyingErrorKey: kernel,
            ]
        )
        let urlError = NSError(
            domain: NSURLErrorDomain,
            code: -1001,
            userInfo: [
                NSLocalizedDescriptionKey: "The request timed out.",
                NSUnderlyingErrorKey: cfNetwork,
            ]
        )

        let captured = SendableUnderlyingError(urlError)
        #expect(captured.domain == NSURLErrorDomain)
        #expect(captured.underlyingChain.count == 2)
        #expect(captured.underlyingChain[0].domain == (kCFErrorDomainCFNetwork as String))
        #expect(captured.underlyingChain[1].domain == NSPOSIXErrorDomain)
        #expect(captured.underlyingChain[1].code == 60)
        #expect(captured.underlying?.domain == (kCFErrorDomainCFNetwork as String))
    }

    @Test("Chain capture stops at maxUnderlyingDepth even when chain is longer")
    func chainBoundedByDepthLimit() {
        let depth = SendableUnderlyingError.maxUnderlyingDepth + 5
        var current: NSError = NSError(domain: "leaf", code: 0)
        for index in 0..<depth {
            current = NSError(
                domain: "level-\(index)",
                code: index,
                userInfo: [NSUnderlyingErrorKey: current]
            )
        }
        let captured = SendableUnderlyingError(current)
        // Top-level + maxUnderlyingDepth-1 frames in the chain.
        #expect(captured.underlyingChain.count == SendableUnderlyingError.maxUnderlyingDepth - 1)
    }

    @Test("description renders the chain with arrows so logs preserve the cause path")
    func descriptionRendersChain() {
        let inner = NSError(domain: "kernel", code: 60, userInfo: [NSLocalizedDescriptionKey: "ETIMEDOUT"])
        let outer = NSError(
            domain: "transport",
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "timed out", NSUnderlyingErrorKey: inner]
        )
        let captured = SendableUnderlyingError(outer)
        let rendered = captured.description
        #expect(rendered.contains("transport(-1001)"))
        #expect(rendered.contains("←"))
        #expect(rendered.contains("kernel(60)"))
    }

    @Test("Errors without NSUnderlyingErrorKey produce an empty chain")
    func leafErrorHasEmptyChain() {
        let leaf = NSError(domain: "leaf", code: 0)
        let captured = SendableUnderlyingError(leaf)
        #expect(captured.underlyingChain.isEmpty)
        #expect(captured.underlying == nil)
    }
}
