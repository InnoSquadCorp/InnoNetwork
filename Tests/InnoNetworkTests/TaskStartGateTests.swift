import Testing

@testable import InnoNetwork

@Suite("TaskStartGate cancellation tests")
struct TaskStartGateTests {
    @Test("open resumes a waiting task")
    func openResumesWaitingTask() async {
        let gate = TaskStartGate()
        let waiter = Task {
            await gate.wait()
        }

        await Task.yield()
        gate.open()

        let result = await waiter.value
        #expect(result == true)
    }

    @Test("cancellation before open resumes waiter as false")
    func cancellationBeforeOpenResumesWaiterAsFalse() async {
        let gate = TaskStartGate()
        let waiter = Task {
            await gate.wait()
        }

        await Task.yield()
        waiter.cancel()

        let result = await waiter.value
        #expect(result == false)

        gate.open()
    }

    @Test("cancelled waiter does not block a later open")
    func cancelledWaiterDoesNotBlockLaterOpen() async {
        let gate = TaskStartGate()
        let cancelled = Task {
            await gate.wait()
        }

        await Task.yield()
        cancelled.cancel()
        #expect(await cancelled.value == false)

        let live = Task {
            await gate.wait()
        }

        await Task.yield()
        gate.open()
        #expect(await live.value == true)
    }
}
