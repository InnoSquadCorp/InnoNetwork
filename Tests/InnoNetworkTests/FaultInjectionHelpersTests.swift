import Foundation
import Testing

@testable import InnoNetwork
@testable import InnoNetworkTestSupport

@Suite("Fault-injection test helpers")
struct FaultInjectionHelpersTests {

    @Test("ClockFailureInjector injects scheduled errors and forwards otherwise")
    func clockFailureInjector() async throws {
        let injector = ClockFailureInjector(wrapping: SystemClock())
        struct Boom: Error, Equatable {}

        injector.setFailureMode(.onCall(2, Boom()))
        try await injector.sleep(for: .milliseconds(1))
        await #expect(throws: Boom.self) {
            try await injector.sleep(for: .milliseconds(1))
        }
        try await injector.sleep(for: .milliseconds(1))
        #expect(injector.callCount == 3)
    }

    @Test("FsyncFailureInjector counts and toggles")
    func fsyncFailureInjector() async {
        let injector = FsyncFailureInjector()
        await injector.setMode(.failNext(2))
        let r1 = await injector.performFsync()
        let r2 = await injector.performFsync()
        let r3 = await injector.performFsync()
        let count = await injector.fsyncCallCount
        #expect(r1 == false)
        #expect(r2 == false)
        #expect(r3 == true)
        #expect(count == 3)
    }

    @Test("FlockSimulator denies on contention")
    func flockSimulator() async {
        let sim = FlockSimulator()
        let first = await sim.tryAcquire()
        let second = await sim.tryAcquire()
        await sim.release()
        let third = await sim.tryAcquire()
        if case .acquired = first {
        } else {
            Issue.record("expected acquired")
            return
        }
        if case .wouldBlock = second {
        } else {
            Issue.record("expected wouldBlock")
            return
        }
        if case .acquired = third {} else { Issue.record("expected acquired again") }
    }

    @Test("FailingFileHandle fails on configured write index")
    func failingFileHandle() throws {
        let handle = FailingFileHandle(plan: .init(failWriteAt: 2))
        try handle.write(contentsOf: Data([0x01]))
        #expect(throws: (any Error).self) { try handle.write(contentsOf: Data([0x02])) }
        try handle.write(contentsOf: Data([0x03]))
        #expect(handle.bytesWritten == Data([0x01, 0x03]))
        try handle.close()
        #expect(handle.isClosed)
    }

    @Test("CountingURLSession captures requests and counts completions")
    func countingURLSession() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let session = CountingURLSession(initial: .success((Data("ok".utf8), response)))
        let request = URLRequest(url: URL(string: "https://example.com/")!)
        _ = try await session.data(for: request)
        _ = try await session.data(for: request)
        #expect(session.dataCallCount == 2)
        #expect(session.completionCount == 2)
        #expect(session.capturedRequests.count == 2)
    }
}
