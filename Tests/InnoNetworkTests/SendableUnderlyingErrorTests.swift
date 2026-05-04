import Foundation
import Testing

@testable import InnoNetwork

@Suite("SendableUnderlyingError chain capture")
struct SendableUnderlyingErrorTests {

    @Test("init(_:) captures NSUnderlyingErrorKey chain bounded by maxUnderlyingDepth")
    func capturesUnderlyingChain() async {
        let kernel = NSError(
            domain: NSPOSIXErrorDomain,
            code: 60,  // ETIMEDOUT
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
    func chainBoundedByDepthLimit() async {
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
        // The chain captures up to ``maxUnderlyingDepth`` frames in
        // addition to the top-level error itself, so a deeper underlying
        // chain is truncated exactly at the documented depth.
        #expect(captured.underlyingChain.count == SendableUnderlyingError.maxUnderlyingDepth)
    }

    @Test("description renders the chain with arrows so logs preserve the cause path")
    func descriptionRendersChain() async {
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
    func leafErrorHasEmptyChain() async {
        let leaf = NSError(domain: "leaf", code: 0)
        let captured = SendableUnderlyingError(leaf)
        #expect(captured.underlyingChain.isEmpty)
        #expect(captured.underlying == nil)
    }

    @Test("Equality uses domain and code so localized messages do not affect identity")
    func equalityUsesDomainAndCodeOnly() async {
        let english = SendableUnderlyingError(
            domain: NSURLErrorDomain,
            code: -1001,
            message: "The request timed out.",
            failureReason: "A server did not respond.",
            recoverySuggestion: "Try again later.",
            underlyingChain: [
                .init(domain: NSPOSIXErrorDomain, code: 60, message: "Operation timed out")
            ]
        )
        let localized = SendableUnderlyingError(
            domain: NSURLErrorDomain,
            code: -1001,
            message: "Zeituberschreitung bei der Anforderung.",
            failureReason: "Der Server hat nicht geantwortet.",
            recoverySuggestion: "Versuchen Sie es spater erneut.",
            underlyingChain: [
                .init(domain: NSPOSIXErrorDomain, code: 61, message: "Connection refused")
            ]
        )

        #expect(english == localized)
    }

    @Test("Equality still distinguishes domain and code changes")
    func equalityDistinguishesDomainAndCode() async {
        let timeout = SendableUnderlyingError(domain: NSURLErrorDomain, code: -1001, message: "Timed out")
        let unavailable = SendableUnderlyingError(domain: NSURLErrorDomain, code: -1009, message: "Offline")
        let cacheTimeout = SendableUnderlyingError(domain: "InnoNetwork.Cache", code: -1001, message: "Timed out")

        #expect(timeout != unavailable)
        #expect(timeout != cacheTimeout)
    }

    @Test("Frame equality uses domain and code so wrapped messages stay diagnostic only")
    func frameEqualityUsesDomainAndCodeOnly() async {
        let english = SendableUnderlyingError.Frame(
            domain: NSPOSIXErrorDomain,
            code: 60,
            message: "Operation timed out"
        )
        let localized = SendableUnderlyingError.Frame(
            domain: NSPOSIXErrorDomain,
            code: 60,
            message: "Zeituberschreitung"
        )

        #expect(english == localized)
    }
}
