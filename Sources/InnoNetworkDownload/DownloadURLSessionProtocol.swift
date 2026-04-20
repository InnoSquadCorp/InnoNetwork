import Foundation


/// Protocol abstraction over `URLSessionDownloadTask` used internally by the
/// download runtime. The production conformance is `URLSessionDownloadTask`
/// itself; tests can inject a stub implementation.
package protocol DownloadURLTask: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    var state: URLSessionTask.State { get }
    var taskDescription: String? { get set }
    var originalRequest: URLRequest? { get }

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
        await withCheckedContinuation { continuation in
            self.getTasksWithCompletionHandler { _, _, downloadTasks in
                continuation.resume(returning: downloadTasks.map { $0 as any DownloadURLTask })
            }
        }
    }
}
