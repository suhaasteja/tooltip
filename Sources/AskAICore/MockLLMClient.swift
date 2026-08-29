import Foundation

/// Canned client so the app demos end-to-end with no API key.
///
/// Enabled by setting `ASKAI_MOCK_LLM=1` in the environment.
public final class MockLLMClient: LLMClient, @unchecked Sendable {

    public static let environmentKey = "ASKAI_MOCK_LLM"

    /// True when the environment asks for the mock.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }

    private let delay: Duration
    private let result: Result<String, LLMError>?

    /// - Parameters:
    ///   - delay: Simulated latency, so the loading state is actually visible.
    ///   - result: Fixed outcome. `nil` echoes the prompt back.
    public init(delay: Duration = .milliseconds(600), result: Result<String, LLMError>? = nil) {
        self.delay = delay
        self.result = result
    }

    public func complete(system: String?, prompt: String) async throws -> String {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()

        switch result {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case nil:
            return """
                [mock reply] \(MockLLMClient.environmentKey) is set, so no request was sent.

                The prompt was:
                \(prompt)
                """
        }
    }
}
