import Foundation
import Testing

@testable import InnoNetwork

@Suite("Multipart awaited delivery", .timeLimit(.minutes(1)))
struct MultipartBackpressureTests {
    @Test(arguments: ["success", "callbackFailure", "cancel"])
    func consumerControlsProgress(mode: String) async throws {
        let payload = Data(repeating: 65, count: 2 * 1024 * 1024)
        let cursor = Cursor(chunks: [
            Data("--b\r\n\r\n".utf8) + payload + Data("\r\n--b--\r\n".utf8),
            Data(repeating: 69, count: 2 * 1024 * 1024),
        ])
        let sink = Sink(fail: mode == "callbackFailure")
        let task = Task {
            defer { sink.finishObservation() }
            try await MultipartStreamingResponseDecoder().decode(
                Input(cursor: cursor), contentType: "multipart/mixed; boundary=b"
            ) {
                try await sink.receive($0)
            }
        }
        try await withTaskCancellationHandler {
            guard await sink.waitForEntry() else {
                task.cancel()
                try await task.value
                Issue.record("Decoder ended without entering the callback")
                return
            }
            #expect(await cursor.reads == 1)
            #expect(await sink.events == [.partStarted(headers: [:])])
            if mode == "cancel" { task.cancel() }
            sink.release()
            switch mode {
            case "callbackFailure": await #expect(throws: Failure.callback) { try await task.value }
            case "cancel": await #expect(throws: CancellationError.self) { try await task.value }
            default:
                try await task.value
                let events = await sink.events
                #expect(events.last == .partEnded)
                #expect(events.filter { $0 == .partEnded }.count == 1)
                let body = events.reduce(into: Data()) { data, event in
                    if case .bodyChunk(let bytes) = event { data.append(bytes) }
                }
                #expect(body == payload)
                #expect(await cursor.reads == 3)
            }
            if mode != "success" { #expect(await cursor.reads == 1) }
        } onCancel: {
            task.cancel()
            sink.finishObservation()
            sink.release()
        }
    }

    @Test func failureBeforeCallbackClosesEntryWait() async {
        let sink = Sink(fail: false)
        let task = Task {
            defer { sink.finishObservation() }
            try await MultipartStreamingResponseDecoder().decode(
                Input(cursor: Cursor(chunks: [], failAtEnd: true)), contentType: "multipart/mixed; boundary=b"
            ) { try await sink.receive($0) }
        }
        await withTaskCancellationHandler {
            #expect(await !sink.waitForEntry())
            await #expect(throws: Failure.upstream) { try await task.value }
        } onCancel: {
            task.cancel()
            sink.finishObservation()
            sink.release()
        }
    }

    @Test func upstreamFailurePropagates() async {
        let cursor = Cursor(chunks: [Data("--b\r\n\r\nbody".utf8)], failAtEnd: true)
        await #expect(throws: Failure.upstream) {
            try await MultipartStreamingResponseDecoder().decode(
                Input(cursor: cursor), contentType: "multipart/mixed; boundary=b"
            ) { _ in }
        }
    }

    @Test func completedParserDiscardsEpilogueAndBoundsPadding() throws {
        var parser = try MultipartResponseParser(boundary: "b")
        parser.append(Data("--b--\r\n".utf8))
        #expect(try parser.next() == nil)
        for _ in 0..<100 {
            parser.append(Data(repeating: 69, count: 16 * 1024))
            #expect(try parser.next() == nil)
        }
        #expect(try parser.next(isFinal: true) == nil)
        var padded = try MultipartResponseParser(boundary: "b")
        padded.append(Data("--b".utf8) + Data(repeating: 32, count: 1024 * 1024 + 1))
        #expect(throws: NetworkError.self) { try padded.next() }
        #expect(throws: NetworkError.self) { try MultipartResponseParser(boundary: String(repeating: "a", count: 71)) }
    }

    private enum Failure: Error { case callback, upstream }
    private struct Input: AsyncSequence, Sendable {
        typealias Element = Data
        let cursor: Cursor
        func makeAsyncIterator() -> Iterator { Iterator(cursor: cursor) }
        struct Iterator: AsyncIteratorProtocol {
            let cursor: Cursor
            mutating func next() async throws -> Data? { try await cursor.next() }
        }
    }
    private actor Cursor {
        let chunks: [Data]
        let failAtEnd: Bool
        var reads = 0
        init(chunks: [Data], failAtEnd: Bool = false) {
            self.chunks = chunks
            self.failAtEnd = failAtEnd
        }
        func next() throws -> Data? {
            try Task.checkCancellation()
            let index = reads
            reads += 1
            if index < chunks.count { return chunks[index] }
            if failAtEnd { throw Failure.upstream }
            return nil
        }
    }
    private actor Sink {
        let fail: Bool
        var events: [MultipartStreamingEvent] = []
        private let entry: AsyncStream<Void>
        private nonisolated let entryContinuation: AsyncStream<Void>.Continuation
        private let released: AsyncStream<Void>
        private nonisolated let releaseContinuation: AsyncStream<Void>.Continuation
        init(fail: Bool) {
            self.fail = fail
            (entry, entryContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            (released, releaseContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }
        func receive(_ event: MultipartStreamingEvent) async throws {
            events.append(event)
            if events.count == 1 {
                entryContinuation.yield(())
                var wait = released.makeAsyncIterator()
                _ = await wait.next()
                try Task.checkCancellation()
                if fail { throw Failure.callback }
            }
        }
        func waitForEntry() async -> Bool {
            var wait = entry.makeAsyncIterator()
            return await wait.next() != nil
        }
        nonisolated func finishObservation() { entryContinuation.finish() }
        nonisolated func release() {
            releaseContinuation.yield(())
            releaseContinuation.finish()
        }
    }
}
