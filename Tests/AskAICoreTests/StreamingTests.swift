import Testing
import Foundation
@testable import AskAICore

@Suite("SSE parsing")
struct SSEParsingTests {

    private func delta(_ text: String) -> String {
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"# + "\"\(text)\"" + #"}}"#
    }

    @Test("extracts text from a content_block_delta")
    func extractsTextDelta() {
        let line = delta("Hello")
        #expect(AnthropicClient.textDelta(fromSSELine: line) == "Hello")
    }

    @Test("ignores event lines, blanks, pings and [DONE]")
    func ignoresNonData() {
        let noise = [
            "", "   ",
            "event: content_block_delta",
            "event: message_stop",
            "data: [DONE]",
            "data:",
            ": this is a comment",
        ]
        for line in noise {
            #expect(AnthropicClient.textDelta(fromSSELine: line) == nil, "leaked on: \(line)")
        }
    }

    @Test("ignores non-text event types")
    func ignoresOtherEventTypes() {
        let lines = [
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            #"data: {"type":"content_block_start","content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"data: {"type":"ping"}"#,
        ]
        for line in lines {
            #expect(AnthropicClient.textDelta(fromSSELine: line) == nil, "leaked on: \(line)")
        }
    }

    @Test("thinking deltas never reach the answer")
    func ignoresThinkingDeltas() {
        // This model tier thinks by default; rendering reasoning as the answer
        // would be a visible bug.
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        #expect(AnthropicClient.textDelta(fromSSELine: line) == nil)
    }

    @Test("malformed JSON is skipped rather than throwing")
    func skipsMalformed() {
        #expect(AnthropicClient.textDelta(fromSSELine: "data: {not json") == nil)
    }

    @Test("tolerates no space after data:")
    func toleratesNoSpace() {
        let line = #"data:{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#
        #expect(AnthropicClient.textDelta(fromSSELine: line) == "x")
    }

    @Test("preserves whitespace and newlines inside a delta")
    func preservesWhitespace() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world\n\nnext"}}"#
        #expect(AnthropicClient.textDelta(fromSSELine: line) == " world\n\nnext")
    }

    @Test("concatenated deltas reconstruct the full answer")
    func reassembles() {
        let lines = ["Plants ", "turn ", "light ", "into sugar."].map(delta)
        let joined = lines.compactMap(AnthropicClient.textDelta(fromSSELine:)).joined()
        #expect(joined == "Plants turn light into sugar.")
    }

    @Test("streaming requests set stream:true; non-streaming ones do not")
    func streamFlagInBody() throws {
        let client = AnthropicClient(apiKey: "k", session: StubURLProtocol.makeSession())

        let streamingBody = try JSONSerialization.jsonObject(
            with: #require(client.makeRequest(
                system: nil, prompt: "p", streaming: true).httpBody)) as! [String: Any]
        #expect(streamingBody["stream"] as? Bool == true)

        let plainBody = try JSONSerialization.jsonObject(
            with: #require(client.makeRequest(
                system: nil, prompt: "p").httpBody)) as! [String: Any]
        #expect(plainBody["stream"] == nil)
    }
}

/// Emits deltas so the orchestrator's streaming path can be driven offline.
private final class FakeStreamingClient: LLMClient, @unchecked Sendable {
    var chunks: [String] = []
    var error: LLMError?

    func complete(system: String?, prompt: String) async throws -> String {
        if let error { throw error }
        return chunks.joined()
    }

    func stream(
        system: String?, prompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        if let error { throw error }
        var full = ""
        for chunk in chunks {
            try Task.checkCancellation()
            full += chunk
            onDelta(chunk)
        }
        return full
    }
}

@Suite("Streaming into the panel")
struct StreamingPanelTests {

    @Test("deltas accumulate; loading becomes success on the first one")
    func accumulates() {
        let machine = PanelViewModel()
        let id = machine.startLoading(selection: "sel")

        #expect(machine.appendDelta(requestID: id, "Hello"))
        #expect(machine.state == .success(selection: "sel", answer: "Hello"))

        #expect(machine.appendDelta(requestID: id, ", world"))
        #expect(machine.state == .success(selection: "sel", answer: "Hello, world"))
    }

    @Test("deltas from a superseded request are dropped")
    func dropsStaleDeltas() {
        let machine = PanelViewModel()
        let first = machine.startLoading(selection: "one")
        let second = machine.startLoading(selection: "two")

        #expect(machine.appendDelta(requestID: first, "STALE") == false)
        #expect(machine.state == .loading(selection: "two"))
        #expect(machine.appendDelta(requestID: second, "FRESH"))
        #expect(machine.state == .success(selection: "two", answer: "FRESH"))
    }

    @Test("deltas after dismissal cannot reopen the panel")
    func dropsDeltasAfterReset() {
        let machine = PanelViewModel()
        let id = machine.startLoading(selection: "sel")
        machine.reset()
        #expect(machine.appendDelta(requestID: id, "late") == false)
        #expect(machine.state == .idle)
    }

    @Test("the orchestrator streams into the panel and finishes consistently")
    func orchestratorStreams() async {
        let machine = PanelViewModel()
        let client = FakeStreamingClient()
        client.chunks = ["Plants ", "turn light ", "into sugar."]
        let orchestrator = AskOrchestrator(client: client, machine: machine, streaming: true)

        await orchestrator.ask(selection: "photosynthesis").value

        #expect(machine.state == .success(selection: "photosynthesis",
                                          answer: "Plants turn light into sugar."))
    }

    @Test("finish after streaming does not duplicate the text")
    func noDuplicationOnFinish() async {
        let machine = PanelViewModel()
        let client = FakeStreamingClient()
        client.chunks = ["abc", "def"]
        let orchestrator = AskOrchestrator(client: client, machine: machine, streaming: true)

        await orchestrator.ask(selection: "x").value

        guard case .success(_, let answer) = machine.state else {
            Issue.record("expected success")
            return
        }
        #expect(answer == "abcdef")
    }

    @Test("a streaming failure still lands in the failure state")
    func streamingError() async {
        let machine = PanelViewModel()
        let client = FakeStreamingClient()
        client.error = .rateLimited
        let orchestrator = AskOrchestrator(client: client, machine: machine, streaming: true)

        await orchestrator.ask(selection: "x").value

        #expect(machine.state == .failure(selection: "x",
                                          message: LLMError.rateLimited.userMessage,
                                          retryable: true))
    }

    @Test("the default stream implementation works for non-streaming clients")
    func defaultStreamImplementation() async throws {
        let mock = MockLLMClient(delay: .milliseconds(1), result: .success("one shot"))
        var received: [String] = []
        let lock = NSLock()

        let full = try await mock.stream(system: nil, prompt: "p") { delta in
            lock.withLock { received.append(delta) }
        }
        #expect(full == "one shot")
        #expect(received == ["one shot"])
    }
}
