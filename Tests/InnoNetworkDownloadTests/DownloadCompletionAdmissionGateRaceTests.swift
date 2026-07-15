import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download completion admission gate races")
struct DownloadCompletionAdmissionGateRaceTests {
    @Test("A journal established during staging wins a concurrent cancel")
    func journalWinsConcurrentCancel() async {
        let gate = DownloadCompletionAdmissionGate()
        let taskID = "stage-vs-cancel-\(UUID().uuidString)"

        #expect(gate.beginStaging(taskID: taskID))
        async let cancelWasAdmitted = gate.claimDestructiveLifecycle(taskID: taskID)

        gate.finishStaging(taskID: taskID, journaled: true)

        #expect(await cancelWasAdmitted == false)
        #expect(await gate.hasJournalAfterStaging(taskID: taskID))
        #expect(gate.beginStaging(taskID: taskID) == false)

        gate.release(taskID: taskID)
        gate.openAttempt(taskID: taskID, taskIdentifier: 2)
        #expect(gate.beginStaging(taskID: taskID, taskIdentifier: 2))
        gate.finishStaging(
            taskID: taskID,
            taskIdentifier: 2,
            journaled: false
        )
    }

    @Test("A failed stage admits every concurrent shutdown claim and closes later staging")
    func failedStageAdmitsConcurrentShutdownClaims() async {
        let gate = DownloadCompletionAdmissionGate()
        let taskID = "stage-vs-shutdown-\(UUID().uuidString)"

        #expect(gate.beginStaging(taskID: taskID))
        let claims = Task {
            await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        await gate.claimDestructiveLifecycle(taskID: taskID)
                    }
                }

                var results: [Bool] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }

        gate.finishStaging(taskID: taskID, journaled: false)

        let results = await claims.value
        #expect(results.count == 16)
        #expect(results.allSatisfy { $0 })
        #expect(await gate.hasJournalAfterStaging(taskID: taskID) == false)
        #expect(gate.beginStaging(taskID: taskID) == false)
    }

    @Test("A staged journal rejects every concurrent cancel-all claim")
    func journalRejectsConcurrentCancelAllClaims() async {
        let gate = DownloadCompletionAdmissionGate()
        let taskID = "stage-vs-cancel-all-\(UUID().uuidString)"

        #expect(gate.beginStaging(taskID: taskID))
        let claims = Task {
            await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        await gate.claimDestructiveLifecycle(taskID: taskID)
                    }
                }

                var results: [Bool] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }

        gate.finishStaging(taskID: taskID, journaled: true)

        let results = await claims.value
        #expect(results.count == 16)
        #expect(results.allSatisfy { !$0 })
        #expect(await gate.hasJournalAfterStaging(taskID: taskID))
    }

    @Test("Opening a retry attempt never reopens the retired attempt")
    func retryAttemptDoesNotReopenRetiredAttempt() async {
        let gate = DownloadCompletionAdmissionGate()
        let taskID = "attempt-generation-\(UUID().uuidString)"
        gate.openAttempt(taskID: taskID, taskIdentifier: 101)

        #expect(await gate.claimDestructiveLifecycle(taskID: taskID))
        gate.openAttempt(taskID: taskID, taskIdentifier: 202)

        #expect(gate.beginStaging(taskID: taskID, taskIdentifier: 101) == false)
        #expect(gate.beginStaging(taskID: taskID, taskIdentifier: 202))
        gate.finishStaging(
            taskID: taskID,
            taskIdentifier: 202,
            journaled: false
        )
    }
}
