import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("DownloadTask state transition guard")
struct DownloadTaskStateTransitionTests {

    private func makeTask() -> DownloadTask {
        DownloadTask(
            url: URL(string: "https://example.com/file.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.zip")
        )
    }

    private static let allStates: [DownloadState] = [
        .idle, .waiting, .downloading, .paused, .completed, .failed, .cancelled,
    ]

    // MARK: - canTransition matrix

    @Test("canTransition matrix matches the documented nextStates table")
    func canTransitionMatrixIsConsistent() async {
        for from in Self.allStates {
            for to in Self.allStates {
                let allowed = from.canTransition(to: to)
                let expected = (to == from) || from.nextStates.contains(to)
                #expect(allowed == expected, "transition \(from) -> \(to) consistency")
            }
        }
    }

    @Test("DownloadLifecycleReducer emits rejection effects for illegal transitions")
    func lifecycleReducerRejectsIllegalTransitions() {
        let reduction = DownloadLifecycleReducer.reduce(
            state: .completed,
            event: .transition(to: .downloading)
        )

        #expect(reduction.state == .completed)
        #expect(reduction.effects == [.rejectIllegalTransition(from: .completed, to: .downloading)])
    }

    @Test("Terminal states only self-loop")
    func terminalStatesOnlySelfLoop() async {
        for terminal in [DownloadState.completed, .cancelled] {
            for to in Self.allStates {
                let allowed = terminal.canTransition(to: to)
                #expect(
                    allowed == (to == terminal), "\(terminal) must only self-loop, got transition to \(to)=\(allowed)")
            }
        }
    }

    @Test("failed only transitions back to idle (or self)")
    func failedTransitionsOnlyToIdle() async {
        for to in Self.allStates {
            let allowed = DownloadState.failed.canTransition(to: to)
            let expected = (to == .failed) || (to == .idle)
            #expect(allowed == expected, "failed -> \(to) expected=\(expected) actual=\(allowed)")
        }
    }

    // MARK: - updateState honours legal transitions

    @Test("updateState applies every legal transition for every source state")
    func updateStateAppliesLegalTransitions() async {
        for from in Self.allStates {
            for to in from.nextStates {
                let task = makeTask()
                await task.restoreState(from)
                await task.updateState(to)
                let observed = await task.state
                #expect(observed == to, "legal transition \(from) -> \(to) was rejected (observed=\(observed))")
            }
        }
    }

    @Test("updateState to the same state is a no-op self-loop")
    func updateStateAcceptsSelfLoop() async {
        for state in Self.allStates {
            let task = makeTask()
            await task.restoreState(state)
            await task.updateState(state)
            #expect(await task.state == state, "self-loop on \(state) should keep state unchanged")
        }
    }

    // MARK: - Documented happy path

    @Test("Idle → waiting → downloading → completed flows through every legal hop")
    func canonicalSuccessLifecycle() async {
        let task = makeTask()
        await task.updateState(.waiting)
        #expect(await task.state == .waiting)
        await task.updateState(.downloading)
        #expect(await task.state == .downloading)
        await task.updateState(.completed)
        #expect(await task.state == .completed)
    }

    @Test("Pause / resume lifecycle: downloading ↔ paused → downloading → completed")
    func pauseResumeLifecycle() async {
        let task = makeTask()
        await task.updateState(.downloading)
        await task.updateState(.paused)
        #expect(await task.state == .paused)
        await task.updateState(.downloading)
        #expect(await task.state == .downloading)
        await task.updateState(.completed)
        #expect(await task.state == .completed)
    }

    @Test("Failure recovery lifecycle: downloading → failed → idle → downloading")
    func failureRecoveryLifecycle() async {
        let task = makeTask()
        await task.updateState(.downloading)
        await task.updateState(.failed)
        #expect(await task.state == .failed)
        await task.updateState(.idle)
        #expect(await task.state == .idle)
        await task.updateState(.downloading)
        #expect(await task.state == .downloading)
    }

    // MARK: - restoreState escape hatch

    @Test("restoreState bypasses guard for every illegal pair")
    func restoreStateBypassesGuardForEveryIllegalPair() async {
        for from in Self.allStates {
            for to in Self.allStates where !from.canTransition(to: to) {
                let task = makeTask()
                await task.restoreState(from)
                await task.restoreState(to)
                #expect(await task.state == to, "restoreState must bypass guard for \(from) -> \(to)")
            }
        }
    }
}
