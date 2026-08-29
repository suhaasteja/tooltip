import Testing
@testable import AskAICore

/// Records what the orchestrator sent, and lets a test hold a request open.
private final class SpyClient: LLMClient, @unchecked Sendable {
    var lastSystem: String?
    var lastPrompt: String?
    var result: Result<String, LLMError> = .success("ok")
    /// Simulated latency; the default is instant.
    var delay: Duration = .zero

    func complete(system: String?, prompt: String) async throws -> String {
        lastSystem = system
        lastPrompt = prompt
        if delay != .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        return try result.get()
    }
}

@Suite("Ask orchestrator")
struct AskOrchestratorTests {

    @Test("success path lands in .success with the model's answer")
    func successPath() async {
        let machine = PanelViewModel()
        let client = SpyClient()
        client.result = .success("Plants turn light into sugar.")
        let orchestrator = AskOrchestrator(client: client, machine: machine)

        await orchestrator.ask(selection: "photosynthesis").value

        #expect(machine.state == .success(selection: "photosynthesis",
                                          answer: "Plants turn light into sugar."))
    }

    @Test("the rendered prompt and system prompt reach the client")
    func passesRenderedPrompt() async {
        let machine = PanelViewModel()
        let client = SpyClient()
        let orchestrator = AskOrchestrator(client: client, machine: machine)

        await orchestrator.ask(
            selection: "abc", template: "Define: {{selection}}", system: "be terse").value

        #expect(client.lastPrompt == "Define: abc")
        #expect(client.lastSystem == "be terse")
    }

    @Test("panel enters .loading synchronously, before any await")
    func loadsImmediately() {
        let machine = PanelViewModel()
        let client = SpyClient()
        client.delay = .milliseconds(200)
        let orchestrator = AskOrchestrator(client: client, machine: machine)

        let task = orchestrator.ask(selection: "abc")
        // The service handler must never block, so this must already be true.
        #expect(machine.state == .loading(selection: "abc"))
        task.cancel()
    }

    @Test("an LLM error becomes a retryable failure with a readable message")
    func errorPath() async {
        let machine = PanelViewModel()
        let client = SpyClient()
        client.result = .failure(.rateLimited)
        let orchestrator = AskOrchestrator(client: client, machine: machine)

        await orchestrator.ask(selection: "abc").value

        #expect(machine.state == .failure(selection: "abc",
                                          message: LLMError.rateLimited.userMessage,
                                          retryable: true))
    }

    @Test("a non-retryable error does not offer Retry")
    func nonRetryableError() async {
        let machine = PanelViewModel()
        let client = SpyClient()
        client.result = .failure(.missingAPIKey)
        let orchestrator = AskOrchestrator(client: client, machine: machine)

        await orchestrator.ask(selection: "abc").value

        #expect(machine.state == .failure(selection: "abc",
                                          message: LLMError.missingAPIKey.userMessage,
                                          retryable: false))
    }

    @Test("a second invocation cancels the first and only the second lands")
    func secondInvocationCancelsFirst() async {
        let machine = PanelViewModel()
        let slow = SpyClient()
        slow.delay = .milliseconds(400)
        slow.result = .success("STALE")
        let orchestrator = AskOrchestrator(client: slow, machine: machine)

        let first = orchestrator.ask(selection: "one")

        let fast = SpyClient()
        fast.result = .success("FRESH")
        let orchestrator2 = AskOrchestrator(client: fast, machine: machine)
        // Same machine: the id bump is what invalidates the first request.
        let second = orchestrator2.ask(selection: "two")

        await second.value
        await first.value

        #expect(machine.state == .success(selection: "two", answer: "FRESH"))
    }

    @Test("cancel() returns the panel to idle and drops the in-flight reply")
    func cancelResets() async {
        let machine = PanelViewModel()
        let client = SpyClient()
        client.delay = .milliseconds(300)
        let orchestrator = AskOrchestrator(client: client, machine: machine)

        let task = orchestrator.ask(selection: "abc")
        orchestrator.cancel()
        await task.value

        #expect(machine.state == .idle)
    }

    @Test("the mock client round-trips through the orchestrator")
    func worksWithMockClient() async {
        let machine = PanelViewModel()
        let orchestrator = AskOrchestrator(
            client: MockLLMClient(delay: .milliseconds(1)), machine: machine)

        await orchestrator.ask(selection: "photosynthesis").value

        guard case .success(_, let answer) = machine.state else {
            Issue.record("expected success, got \(machine.state)")
            return
        }
        #expect(answer.contains("mock reply"))
        #expect(answer.contains("photosynthesis"))
    }
}
