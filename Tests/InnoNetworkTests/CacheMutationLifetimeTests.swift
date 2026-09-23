import Foundation
import Testing

@testable import InnoNetwork

@Suite("Cache mutation token lifetimes", .timeLimit(.minutes(1)))
struct CacheMutationLifetimeTests {
    @Test("Tokens share a live generation and invalidation fences old writers")
    func generationIdentity() async {
        let coordinator = ResponseCacheMutationCoordinator()
        let first = await coordinator.writeToken(for: "https://example.com/a")
        let same = await coordinator.writeToken(for: "https://example.com/a")
        #expect(first === same)
        await coordinator.advanceGeneration(for: first.targetURI)
        #expect(await coordinator.isCurrent(first) == false)
        let replacement = await coordinator.writeToken(for: first.targetURI)
        #expect(first !== replacement)
        #expect(await coordinator.isCurrent(replacement))
        #expect(await coordinator.trackedTargetCount == 1)
    }

    @Test("Completed unique requests and invalidation-only targets do not accumulate")
    func uniqueTargetsAreReleased() async {
        let coordinator = ResponseCacheMutationCoordinator()
        for index in 0..<1_000 {
            let token = await coordinator.writeToken(for: "https://example.com/\(index)")
            #expect(await coordinator.isCurrent(token))
            await coordinator.advanceGeneration(for: "https://example.com/put-\(index)")
        }
        #expect(await coordinator.trackedTargetCount == 0)
    }

    @Test("Released old generations cannot invalidate a newer writer")
    func oldTokenCleanupPreservesNewGeneration() async {
        let coordinator = ResponseCacheMutationCoordinator()
        var old: ResponseCacheMutationCoordinator.WriteToken? = await coordinator.writeToken(
            for: "https://example.com/a")
        weak let released = old
        await coordinator.advanceGeneration(for: "https://example.com/a")
        let current = await coordinator.writeToken(for: "https://example.com/a")
        old = nil
        #expect(released == nil)
        #expect(await coordinator.trackedTargetCount == 1)
        #expect(await coordinator.isCurrent(current))
    }
}
