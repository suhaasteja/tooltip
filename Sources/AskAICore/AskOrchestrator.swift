import Foundation

/// Drives one selection through templating, the LLM, and back into the panel
/// state machine.
///
/// Lives in the core library so the whole flow is testable against
/// `MockLLMClient` with no AppKit involved.
public final class AskOrchestrator {

    private let client: LLMClient
    private let machine: PanelViewModel
    private var inFlight: Task<Void, Never>?

    public init(client: LLMClient, machine: PanelViewModel) {
        self.client = client
        self.machine = machine
    }

    /// Starts a request, cancelling any previous one.
    ///
    /// Returns immediately — the service handler must never block. The returned
    /// task is exposed so tests can await completion deterministically; callers
    /// in the app ignore it.
    @discardableResult
    public func ask(
        selection: String,
        template: String = PromptTemplate.defaultTemplate,
        system: String? = PromptTemplate.defaultSystem
    ) -> Task<Void, Never> {
        // Cancel first: `startLoading` bumps the request id, which is what makes
        // a late reply from the previous task a no-op even if cancellation
        // loses the race.
        inFlight?.cancel()

        let requestID = machine.startLoading(selection: selection)
        let prompt = PromptTemplate.render(template: template, selection: selection)

        let task = Task { [client, machine] in
            do {
                let answer = try await client.complete(system: system, prompt: prompt)
                try Task.checkCancellation()
                machine.finish(requestID: requestID, answer: answer)
            } catch is CancellationError {
                // Superseded or dismissed: leave the state alone. Whatever
                // replaced this request owns the panel now.
                return
            } catch let error as LLMError {
                guard error != .cancelled else { return }
                machine.fail(
                    requestID: requestID,
                    message: error.userMessage,
                    retryable: error.isRetryable
                )
            } catch {
                machine.fail(
                    requestID: requestID,
                    message: LLMError.network(error.localizedDescription).userMessage,
                    retryable: true
                )
            }
        }
        inFlight = task
        return task
    }

    /// Cancels in-flight work and returns the panel to idle.
    public func cancel() {
        inFlight?.cancel()
        inFlight = nil
        machine.reset()
    }
}
