//
//  ClaudeServiceSSEParsingTests.swift
//  EasydictTests
//
//  Created by Codex on 2026/4/5.
//

import Testing

@testable import Easydict

/// Unit tests for Claude SSE event splitting and parsing behavior.
@Suite("Claude Service SSE Parsing", .tags(.unit))
struct ClaudeServiceSSEParsingTests {
    private let service = ClaudeService()

    /// Verifies the parser recognizes CRLF-framed SSE events and keeps partial tails buffered.
    @Test("Splits complete events for CRLF and preserves tail", .tags(.unit))
    func splitCompleteEventsWithCRLF() {
        var textBuffer = "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hello\"}}\r\n\r\nevent: ping\r\ndata: {}\r\n\r\nincomplete"

        let events = service.splitCompleteEvents(from: &textBuffer)

        #expect(events.count == 2)
        #expect(events[0].contains("event: content_block_delta"))
        #expect(events[1].contains("event: ping"))
        #expect(textBuffer == "incomplete")
    }

    /// Verifies that a trailing `\r` is preserved across calls so a split `\r\n` pair
    /// does not create a false `\n\n` event boundary.
    @Test("Preserves trailing CR across chunk boundaries", .tags(.unit))
    func splitCRLFAcrossChunks() {
        // Simulate chunk 1 ending with \r (first half of \r\n).
        var textBuffer = "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"A\"}}\r\n\r"

        // First call: no false boundary should be produced from the trailing \r.
        let firstEvents = service.splitCompleteEvents(from: &textBuffer)
        #expect(firstEvents.isEmpty)
        #expect(textBuffer.hasSuffix("\r"))

        // Simulate chunk 2 arriving with the matching \n plus a full second event.
        textBuffer += "\nevent: ping\r\ndata: {}\r\n\r\ndone"

        let secondEvents = service.splitCompleteEvents(from: &textBuffer)
        #expect(secondEvents.count == 2)
        #expect(secondEvents[0].contains("content_block_delta"))
        #expect(secondEvents[1].contains("event: ping"))
        #expect(textBuffer == "done")
    }

    /// Verifies content deltas are extracted from valid `content_block_delta` events.
    @Test("Parses text delta from content_block_delta", .tags(.unit))
    func parseContentBlockDelta() throws {
        let event = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """

        let parsedText = try service.parseSSEEvent(event)

        #expect(parsedText == "Hello")
    }

    /// Verifies stream-level SSE error events are converted into API query errors.
    @Test("Throws query error for SSE error events", .tags(.unit))
    func throwsOnSSEErrorEvent() {
        let event = """
        event: error
        data: {"type":"error","error":{"type":"invalid_request_error","message":"bad request"}}
        """

        #expect(throws: QueryError.self) {
            _ = try service.parseSSEEvent(event)
        }
    }
}
