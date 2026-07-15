import Foundation
import Testing

@testable import InnoNetworkDownload

@Suite("Download delegate event channel")
struct DownloadDelegateEventChannelTests {
    @Test("A progress flood coalesces into one bounded pending event")
    func progressFloodCoalesces() async {
        let channel = DownloadDelegateEventChannel()

        for index in 1...10_000 {
            channel.sendProgress(
                taskIdentifier: 42,
                bytesWritten: 1,
                totalBytesWritten: Int64(index),
                totalBytesExpectedToWrite: 20_000
            )
        }
        channel.finish()

        guard let event = await channel.next() else {
            Issue.record("Expected one coalesced progress event")
            return
        }
        guard
            case .progress(
                let taskIdentifier,
                let bytesWritten,
                let totalBytesWritten,
                let totalBytesExpectedToWrite
            ) = event
        else {
            Issue.record("Expected one coalesced progress event")
            return
        }

        #expect(taskIdentifier == 42)
        #expect(bytesWritten == 10_000)
        #expect(totalBytesWritten == 10_000)
        #expect(totalBytesExpectedToWrite == 20_000)
        #expect(isNil(await channel.next()))
    }

    @Test("Progress byte aggregation saturates instead of overflowing")
    func progressAggregationSaturates() async {
        let channel = DownloadDelegateEventChannel()
        channel.sendProgress(
            taskIdentifier: 7,
            bytesWritten: .max,
            totalBytesWritten: .max,
            totalBytesExpectedToWrite: .max
        )
        channel.sendProgress(
            taskIdentifier: 7,
            bytesWritten: 1,
            totalBytesWritten: .max,
            totalBytesExpectedToWrite: .max
        )
        channel.finish()

        guard
            let event = await channel.next(),
            case .progress(_, let bytesWritten, _, _) = event
        else {
            Issue.record("Expected a coalesced progress event")
            return
        }
        #expect(bytesWritten == .max)
    }

    @Test("Completions remain lossless and FIFO")
    func completionsRemainLosslessAndFIFO() async {
        let channel = DownloadDelegateEventChannel()
        let expectedIdentifiers = Array(0..<1_024)

        for identifier in expectedIdentifiers {
            channel.sendCompletion(
                taskIdentifier: identifier,
                location: nil,
                error: nil
            )
        }
        channel.finish()

        var identifiers: [Int] = []
        while let event = await channel.next() {
            guard case .completion(let taskIdentifier, _, _, _, _, _) = event else {
                Issue.record("Expected only completion events")
                continue
            }
            identifiers.append(taskIdentifier)
        }

        #expect(identifiers == expectedIdentifiers)
    }

    @Test("Completion closes a progress segment without reordering later progress")
    func completionSeparatesProgressSegments() async {
        let channel = DownloadDelegateEventChannel()

        channel.sendProgress(
            taskIdentifier: 9,
            bytesWritten: 2,
            totalBytesWritten: 2,
            totalBytesExpectedToWrite: 10
        )
        channel.sendCompletion(taskIdentifier: 10, location: nil, error: nil)
        channel.sendProgress(
            taskIdentifier: 9,
            bytesWritten: 3,
            totalBytesWritten: 5,
            totalBytesExpectedToWrite: 10
        )
        channel.finish()

        guard
            let firstEvent = await channel.next(),
            case .progress(_, let firstBytes, _, _) = firstEvent
        else {
            Issue.record("Expected progress before completion")
            return
        }
        guard
            let completionEvent = await channel.next(),
            case .completion(let completedIdentifier, _, _, _, _, _) = completionEvent
        else {
            Issue.record("Expected completion between progress segments")
            return
        }
        guard
            let secondEvent = await channel.next(),
            case .progress(_, let secondBytes, _, _) = secondEvent
        else {
            Issue.record("Expected progress after completion")
            return
        }

        #expect(firstBytes == 2)
        #expect(completedIdentifier == 10)
        #expect(secondBytes == 3)
        #expect(isNil(await channel.next()))
    }

    @Test("Finish terminates an empty consumer and cleans rejected staged files")
    func finishTerminatesAndCleansRejectedCompletion() async throws {
        let channel = DownloadDelegateEventChannel()
        channel.finish()

        let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-channel-finished-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        try Data("staged".utf8).write(to: stagedURL)

        channel.sendCompletion(
            taskIdentifier: 1,
            location: stagedURL,
            error: nil
        )

        #expect(FileManager.default.fileExists(atPath: stagedURL.path) == false)
        #expect(isNil(await channel.next()))
    }

    private func isNil(_ event: DownloadManager.DelegateEvent?) -> Bool {
        if case .none = event { return true }
        return false
    }
}
