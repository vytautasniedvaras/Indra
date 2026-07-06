// Incremental Server-Sent Events parser (WHATWG EventSource framing).
// Feed arbitrary byte/string chunks; events are emitted only when their
// terminating blank line has fully arrived — split-across-chunks safe.

import Foundation

public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

public struct SSEParser: Sendable {
    // Byte-level buffering: Swift Strings treat "\r\n" as one grapheme
    // Character, which breaks Character-based newline scanning on CRLF input.
    private var pending: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastId: String?
    private var retry: Int?

    public init() {}

    public mutating func feed(_ chunk: String) -> [SSEEvent] {
        feed(Data(chunk.utf8))
    }

    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        pending.append(contentsOf: chunk)
        var events: [SSEEvent] = []
        // Process complete lines only; keep the trailing partial line buffered.
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineBytes = Array(pending[..<newline])
            pending.removeFirst(newline + 1)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            if let event = process(line: line) {
                events.append(event)
            }
        }
        return events
    }

    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil  // comment / keep-alive
        }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "id": lastId = value
        case "retry": retry = Int(value)
        default: break  // unknown fields ignored per spec
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(
            event: eventName,
            data: dataLines.joined(separator: "\n"),
            id: lastId,
            retry: retry
        )
    }
}
