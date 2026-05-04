import Foundation
import Testing

@testable import InnoNetwork

@Suite("Server-Sent Event Decoder Tests")
struct ServerSentEventDecoderTests {

    @Test("Blank line dispatches the accumulated event")
    func blankLineDispatchesEvent() {
        let decoder = ServerSentEventDecoder()

        #expect(decoder.decode(line: "data: hello") == nil)
        let event = decoder.decode(line: "")
        #expect(event == ServerSentEvent(data: "hello"))
    }

    @Test("Multi-line data is joined with newlines and stripped of the trailing separator")
    func multiLineDataIsJoined() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "data: first")
        _ = decoder.decode(line: "data: second")
        _ = decoder.decode(line: "data: third")
        let event = decoder.decode(line: "")

        #expect(event?.data == "first\nsecond\nthird")
    }

    @Test("id, event, and retry fields populate alongside data")
    func metadataFieldsPopulate() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "id: 42")
        _ = decoder.decode(line: "event: ping")
        _ = decoder.decode(line: "retry: 5000")
        _ = decoder.decode(line: "data: payload")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(id: "42", event: "ping", data: "payload", retry: 5000))
    }

    @Test("UTF-8 BOM on first line is stripped")
    func firstLineBOMIsStripped() async {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "\u{FEFF}data: hello")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(data: "hello"))
    }

    @Test("UTF-8 BOM stripped again after reconnect on the same decoder")
    func bomStrippedOnSecondStreamAfterReconnect() async {
        // `StreamingExecutor` reuses the same `ServerSentEventDecoder`
        // instance across resume/reconnect attempts. The decoder must
        // therefore reset its first-line state on every event boundary so
        // a fresh HTTP response stream starting with U+FEFF is still
        // stripped. This regression-tests the cross-reconnect bug.
        let decoder = ServerSentEventDecoder()

        // First stream: BOM stripped on the leading line as before.
        _ = decoder.decode(line: "\u{FEFF}data: first")
        let firstEvent = decoder.decode(line: "")
        #expect(firstEvent == ServerSentEvent(data: "first"))

        // Simulated reconnect: the same decoder instance now sees a brand
        // new stream that also starts with U+FEFF. Without resetting the
        // first-line bit on dispatch, the leading BOM would survive into
        // the parsed `data:` value.
        _ = decoder.decode(line: "\u{FEFF}data: second")
        let secondEvent = decoder.decode(line: "")
        #expect(secondEvent == ServerSentEvent(data: "second"))
    }

    @Test("retry field accepts only ASCII digits")
    func retryAcceptsOnlyASCIIDigits() async {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "retry: -100")
        _ = decoder.decode(line: "retry: +100")
        _ = decoder.decode(line: "retry: 10.5")
        _ = decoder.decode(line: "retry: ５")
        _ = decoder.decode(line: "retry: 0050")
        _ = decoder.decode(line: "data: payload")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(data: "payload", retry: 50))
    }

    @Test("id field containing NUL is ignored")
    func idContainingNULIsIgnored() async {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "id: bad\u{0000}id")
        _ = decoder.decode(line: "data: payload")
        let event = decoder.decode(line: "")

        #expect(event == ServerSentEvent(data: "payload"))
    }

    @Test("Comment lines are ignored")
    func commentLinesIgnored() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: ": keep-alive")
        _ = decoder.decode(line: "data: real")
        let event = decoder.decode(line: "")

        #expect(event?.data == "real")
    }

    @Test("Empty frame on initial blank line is filtered")
    func leadingBlankLineFilters() {
        let decoder = ServerSentEventDecoder()
        #expect(decoder.decode(line: "") == nil)
    }

    @Test("Field without colon and an empty data buffer does not dispatch")
    func fieldWithoutColon() {
        let decoder = ServerSentEventDecoder()

        // Per the WHATWG SSE spec, an empty data buffer means no event is
        // dispatched, even if a `data` line was present.
        _ = decoder.decode(line: "data")
        let event = decoder.decode(line: "")
        #expect(event == nil)

        // But the event-type field on its own does dispatch with empty data.
        _ = decoder.decode(line: "event: heartbeat")
        let heartbeat = decoder.decode(line: "")
        #expect(heartbeat == ServerSentEvent(event: "heartbeat", data: ""))
    }

    @Test("Decoder resets after each dispatch")
    func decoderResetsAfterDispatch() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "id: 1")
        _ = decoder.decode(line: "data: first")
        let first = decoder.decode(line: "")
        #expect(first == ServerSentEvent(id: "1", data: "first"))

        // No id or event carried into the next frame.
        _ = decoder.decode(line: "data: second")
        let second = decoder.decode(line: "")
        #expect(second == ServerSentEvent(data: "second"))
    }

    @Test("Single-space prefix on values is consumed")
    func valuePrefixSpaceIsConsumed() {
        let decoder = ServerSentEventDecoder()

        _ = decoder.decode(line: "data:no-space")
        let noSpace = decoder.decode(line: "")
        #expect(noSpace?.data == "no-space")

        _ = decoder.decode(line: "data: with-space")
        let withSpace = decoder.decode(line: "")
        #expect(withSpace?.data == "with-space")
    }
}
