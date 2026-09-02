import Foundation
import Testing
import os

@testable import InnoNetworkHLS

@Suite("HLS disk capacity policy")
struct HLSDiskCapacityCheckerTests {
    @Test("disabled policy skips capacity lookup")
    func disabledPolicySkipsLookup() throws {
        let invocationCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let checker = HLSDiskCapacityChecker { _ in
            invocationCount.withLock { $0 += 1 }
            return nil
        }

        try checker.validate(
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .disabled
        )

        #expect(invocationCount.withLock { $0 } == 0)
    }

    @Test("required policy fails when capacity is unavailable")
    func requiredPolicyFailsClosed() {
        let checker = HLSDiskCapacityChecker { _ in nil }

        #expect(throws: HLSDownloadError.diskCapacityUnavailable) {
            try checker.validate(
                directoryURL: FileManager.default.temporaryDirectory,
                policy: .required(minimumAvailableCapacity: 1)
            )
        }
    }

    @Test("best effort policy permits an unavailable capacity value")
    func bestEffortPolicyAllowsUnavailableCapacity() throws {
        let checker = HLSDiskCapacityChecker { _ in nil }

        try checker.validate(
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .bestEffort(minimumAvailableCapacity: 1)
        )
    }

    @Test("best effort policy still rejects known insufficient capacity")
    func bestEffortPolicyRejectsKnownInsufficientCapacity() {
        let checker = HLSDiskCapacityChecker { _ in 9 }

        #expect(
            throws: HLSDownloadError.insufficientDiskCapacity(
                required: 10,
                available: 9
            )
        ) {
            try checker.validate(
                directoryURL: FileManager.default.temporaryDirectory,
                policy: .bestEffort(minimumAvailableCapacity: 10)
            )
        }
    }

    @Test("concurrent write reservations share one capacity ceiling")
    func reservationsPreventConcurrentOvercommit() async throws {
        let guardActor = HLSDiskCapacityGuard(
            checker: HLSDiskCapacityChecker { _ in 20 },
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .required(minimumAvailableCapacity: 10)
        )

        try await guardActor.reserve(6)
        await #expect(
            throws: HLSDownloadError.insufficientDiskCapacity(
                required: 21,
                available: 20
            )
        ) {
            try await guardActor.reserve(5)
        }
        await guardActor.release(6)
        try await guardActor.reserve(10)
        await guardActor.release(10)
    }
}
