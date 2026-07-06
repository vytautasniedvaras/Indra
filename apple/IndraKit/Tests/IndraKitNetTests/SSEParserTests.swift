import Testing

@testable import IndraKitNet

@Suite("SSEParser")
struct SSEParserTests {
    @Test func simpleEvent() {
        var parser = SSEParser()
        let events = parser.feed("event: progress\ndata: {\"a\":1}\n\n")
        #expect(events == [SSEEvent(event: "progress", data: "{\"a\":1}")])
    }

    @Test func eventSplitAcrossChunks() {
        var parser = SSEParser()
        var events = parser.feed("event: prog")
        #expect(events.isEmpty)
        events += parser.feed("ress\ndata: {\"p\":")
        #expect(events.isEmpty)
        events += parser.feed("0.5}\n")
        #expect(events.isEmpty)  // no blank line yet
        events += parser.feed("\n")
        #expect(events == [SSEEvent(event: "progress", data: "{\"p\":0.5}")])
    }

    @Test func multiLineDataJoinsWithNewline() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        #expect(events.first?.data == "line1\nline2")
    }

    @Test func commentAndKeepAliveIgnored() {
        var parser = SSEParser()
        let events = parser.feed(": keep-alive\n\ndata: x\n\n")
        #expect(events == [SSEEvent(event: nil, data: "x")])
    }

    @Test func blankLineWithoutDataDispatchesNothing() {
        var parser = SSEParser()
        #expect(parser.feed("event: ping\n\n").isEmpty)
    }

    @Test func crlfLineEndings() {
        var parser = SSEParser()
        let events = parser.feed("event: done\r\ndata: {}\r\n\r\n")
        #expect(events == [SSEEvent(event: "done", data: "{}")])
    }

    @Test func retryAndIdFields() {
        var parser = SSEParser()
        let events = parser.feed("retry: 3000\nid: 42\ndata: x\n\n")
        #expect(events.first?.retry == 3000)
        #expect(events.first?.id == "42")
    }

    @Test func noSpaceAfterColon() {
        var parser = SSEParser()
        let events = parser.feed("data:tight\n\n")
        #expect(events.first?.data == "tight")
    }

    @Test func multipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed("data: a\n\ndata: b\n\ndata: c\n\n")
        #expect(events.map(\.data) == ["a", "b", "c"])
    }

    @Test func eventNameResetsBetweenEvents() {
        var parser = SSEParser()
        let events = parser.feed("event: progress\ndata: a\n\ndata: b\n\n")
        #expect(events[0].event == "progress")
        #expect(events[1].event == nil)
    }
}
