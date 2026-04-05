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
    /// Verifies the parser recognizes CRLF-framed SSE events and keeps partial tails buffered.
    @Test("Splits complete events for CRLF and preserves tail", .tags(.unit))
    func splitCompleteEventsWithCRLF() {
        let service = ClaudeService()
        var textBuffer = "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hello\"}}\r\n\r\nevent: ping\r\ndata: {}\r\n\r\nincomplete"

        let events = service.splitCompleteEvents(from: &textBuffer)

        #expect(events.count == 2)
        #expect(events[0].contains("event: content_block_delta"))
        #expect(events[1].contains("event: ping"))
        #expect(textBuffer == "incomplete")
    }

    /// Verifies content deltas are extracted from valid `content_block_delta` events.
    @Test("Parses text delta from content_block_delta", .tags(.unit))
    func parseContentBlockDelta() throws {
        let service = ClaudeService()
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
        let service = ClaudeService()
        let event = """
        event: error
        data: {"type":"error","error":{"type":"invalid_request_error","message":"bad request"}}
        """

        #expect(throws: QueryError.self) {
            _ = try service.parseSSEEvent(event)
        }
    }
}
