import Foundation
import os

/// Protocol abstraction over `URLSessionDownloadTask` used internally by the
/// download runtime. The production conformance is `URLSessionDownloadTask`
/// itself; tests can inject a stub implementation.
package protocol DownloadURLTask: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    var state: URLSessionTask.State { get }
    var taskDescription: String? { get set }
    var originalRequest: URLRequest? { get }
    var currentRequest: URLRequest? { get }

    func resume()
    func suspend()
    func cancel()
    func cancelByProducingResumeData() async -> Data?
}


/// Protocol abstraction over `URLSession` for download task creation.
/// The production conformance is `URLSession`; tests can inject a stub.
package protocol DownloadURLSession: AnyObject, Sendable {
    func makeDownloadTask(with url: URL) -> any DownloadURLTask
    func makeDownloadTask(withResumeData data: Data) -> any DownloadURLTask
    func allDownloadTasks() async -> [any DownloadURLTask]
    func finishTasksAndInvalidate()
    func invalidateAndCancel()
}


extension URLSessionDownloadTask: DownloadURLTask {}


extension URLSession: DownloadURLSession {
    package func makeDownloadTask(with url: URL) -> any DownloadURLTask {
        let task: URLSessionDownloadTask = self.downloadTask(with: url)
        return task
    }

    package func makeDownloadTask(withResumeData data: Data) -> any DownloadURLTask {
        let task: URLSessionDownloadTask = self.downloadTask(withResumeData: data)
        return task
    }

    package func allDownloadTasks() async -> [any DownloadURLTask] {
        let gate = DownloadTaskQueryGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                self.getTasksWithCompletionHandler { _, _, downloadTasks in
                    gate.complete(downloadTasks.map { $0 as any DownloadURLTask })
                }
            }
        } onCancel: {
            // `getTasksWithCompletionHandler` has no cancellation API. Resume
            // the async bridge immediately and ignore a later Foundation
            // callback so shutdown can await restoration without hanging.
            gate.cancel()
        }
    }
}


private final class DownloadTaskQueryGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[any DownloadURLTask], Never>?
        var result: [any DownloadURLTask]?
        var isCompleted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<[any DownloadURLTask], Never>) {
        let immediateResult = state.withLock { state -> [any DownloadURLTask]? in
            guard state.isCompleted else {
                state.continuation = continuation
                return nil
            }
            return state.result ?? []
        }
        if let immediateResult {
            continuation.resume(returning: immediateResult)
        }
    }

    func complete(_ tasks: [any DownloadURLTask]) {
        let continuation = state.withLock { state -> CheckedContinuation<[any DownloadURLTask], Never>? in
            guard !state.isCompleted else { return nil }
            state.isCompleted = true
            state.result = tasks
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: tasks)
    }

    func cancel() {
        complete([])
    }
}
