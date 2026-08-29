import Testing
import Foundation
@testable import AskAICore

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func makeClient(key: String? = "sk-test-key") -> AnthropicClient {
    AnthropicClient(apiKey: key, session: StubURLProtocol.makeSession())
}

@Suite("Anthropic client", .serialized)
struct AnthropicClientTests {

    // MARK: Request building

    @Test("sets all three required headers and the right URL")
    func requestShape() throws {
        let client = makeClient()
        let request = try client.makeRequest(system: "sys", prompt: "hello")

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test("body carries model, max_tokens, effort, system and the user message")
    func requestBody() throws {
        let client = makeClient()
        let request = try client.makeRequest(system: "be terse", prompt: "explain photosynthesis")
        let body = try JSONSerialization.jsonObject(
            with: #require(request.httpBody)) as! [String: Any]

        #expect(body["model"] as? String == LLMConfiguration.defaultModel)
        #expect(body["max_tokens"] as? Int == 2048)
        #expect(body["system"] as? String == "be terse")
        let output = body["output_config"] as? [String: Any]
        #expect(output?["effort"] as? String == "low")

        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "explain photosynthesis")
    }

    @Test("omits system when absent, and never sends rejected sampling params")
    func requestOmitsFields() throws {
        let client = makeClient()
        let request = try client.makeRequest(system: nil, prompt: "hi")
        let body = try JSONSerialization.jsonObject(
            with: #require(request.httpBody)) as! [String: Any]

        #expect(body["system"] == nil)
        // These are 400s on this model tier -- their absence is load-bearing.
        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)
        #expect(body["top_k"] == nil)
        #expect(body["thinking"] == nil)
    }

    @Test("a missing or empty key fails before any request is made")
    func missingKey() async {
        StubURLProtocol.reset()
        for key in [nil, ""] as [String?] {
            let client = makeClient(key: key)
            await #expect(throws: LLMError.missingAPIKey) {
                try await client.complete(system: nil, prompt: "hi")
            }
        }
        #expect(StubURLProtocol.lastRequest == nil)
    }

    // MARK: Response parsing

    @Test("multiple text blocks are concatenated")
    func parsesMultipleBlocks() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 200, body: json([
            "content": [
                ["type": "text", "text": "Hello, "],
                ["type": "text", "text": "world."],
            ],
        ]))
        let text = try await makeClient().complete(system: nil, prompt: "hi")
        #expect(text == "Hello, world.")
    }

    @Test("non-text blocks are skipped, not treated as an error")
    func skipsNonTextBlocks() async throws {
        StubURLProtocol.reset()
        // Thinking blocks are emitted by default on this model tier.
        StubURLProtocol.stub = .init(status: 200, body: json([
            "content": [
                ["type": "thinking", "thinking": ""],
                ["type": "text", "text": "The answer."],
            ],
        ]))
        let text = try await makeClient().complete(system: nil, prompt: "hi")
        #expect(text == "The answer.")
    }

    @Test("malformed JSON maps to .decoding")
    func malformedJSON() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 200, body: Data("{not json".utf8))
        await #expect(throws: LLMError.decoding) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
    }

    @Test("a 200 with no text blocks maps to .decoding")
    func emptyContent() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 200, body: json(["content": []]))
        await #expect(throws: LLMError.decoding) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
    }

    // MARK: Status mapping

    @Test("401 and 403 map to .unauthorized")
    func unauthorized() async {
        for status in [401, 403] {
            StubURLProtocol.reset()
            StubURLProtocol.stub = .init(status: status, body: Data())
            await #expect(throws: LLMError.unauthorized) {
                try await makeClient().complete(system: nil, prompt: "hi")
            }
        }
    }

    @Test("429 maps to .rateLimited")
    func rateLimited() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 429, body: Data())
        await #expect(throws: LLMError.rateLimited) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
    }

    @Test("500 maps to .server(500)")
    func serverError() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 500, body: Data())
        await #expect(throws: LLMError.server(500)) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
    }

    @Test("a 400 surfaces the API's own error message")
    func badRequestCarriesMessage() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 400, body: json([
            "error": ["type": "invalid_request_error", "message": "max_tokens too large"],
        ]))
        await #expect(throws: LLMError.badRequest("max_tokens too large")) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
    }

    @Test("transport failure maps to .network")
    func networkFailure() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            status: 0, body: Data(),
            error: URLError(.notConnectedToInternet)
        )
        let error = await #expect(throws: LLMError.self) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
        guard case .network = error else {
            Issue.record("expected .network, got \(String(describing: error))")
            return
        }
    }

    // MARK: Error presentation

    @Test("every error has a non-empty user message")
    func userMessages() {
        let all: [LLMError] = [
            .missingAPIKey, .unauthorized, .rateLimited, .server(503),
            .decoding, .network("offline"), .cancelled, .badRequest("nope"),
        ]
        for error in all {
            #expect(!error.userMessage.isEmpty, "\(error) has no message")
        }
    }

    @Test("only errors worth retrying offer a Retry button")
    func retryability() {
        #expect(LLMError.rateLimited.isRetryable)
        #expect(LLMError.server(500).isRetryable)
        #expect(LLMError.network("x").isRetryable)
        #expect(!LLMError.missingAPIKey.isRetryable)
        #expect(!LLMError.unauthorized.isRetryable)
        #expect(!LLMError.cancelled.isRetryable)
    }
}
