import Testing
import Foundation
@testable import AskAICore

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

/// Builds a well-formed SSE line. Encoding via JSONSerialization rather than
/// string-splicing avoids quoting mistakes that would silently make every
/// delta unparseable — and make the test pass for the wrong reason.
private func deltaLine(_ text: String) -> String {
    let payload = try! JSONSerialization.data(
        withJSONObject: ["choices": [["delta": ["content": text], "index": 0]]])
    return "data: " + String(data: payload, encoding: .utf8)!
}

private func makeClient(
    key: String? = "sk-test",
    url: String = "http://localhost:4000/v1/chat/completions",
    model: String = "gemini/gemini-2.5-flash"
) -> OpenAICompatibleClient {
    OpenAICompatibleClient(
        apiKey: key,
        configuration: LLMConfiguration(
            provider: .openAICompatible, baseURL: URL(string: url)!, model: model),
        session: StubURLProtocol.makeSession()
    )
}

@Suite("OpenAI-compatible client", .serialized)
struct OpenAICompatibleClientTests {

    // MARK: Request

    @Test("uses Bearer auth and the configured endpoint")
    func requestShape() throws {
        let request = try makeClient().makeRequest(system: nil, prompt: "hi")
        #expect(request.url?.absoluteString == "http://localhost:4000/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        // Anthropic-only headers must not leak into this shape.
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == nil)
    }

    @Test("the system prompt becomes a system message, not a top-level field")
    func systemBecomesMessage() throws {
        let request = try makeClient().makeRequest(system: "be terse", prompt: "explain")
        let body = try JSONSerialization.jsonObject(
            with: #require(request.httpBody)) as! [String: Any]

        #expect(body["system"] == nil)
        #expect(body["output_config"] == nil)
        #expect(body["model"] as? String == "gemini/gemini-2.5-flash")
        #expect(body["max_tokens"] as? Int == 2048)

        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "be terse")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "explain")
    }

    @Test("omits the system message when there is none")
    func noSystemMessage() throws {
        let request = try makeClient().makeRequest(system: nil, prompt: "hi")
        let body = try JSONSerialization.jsonObject(
            with: #require(request.httpBody)) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
    }

    @Test("a missing key is allowed — local servers need none")
    func keyIsOptional() throws {
        // The Anthropic client throws .missingAPIKey here; this one must not.
        for key in [nil, ""] as [String?] {
            let request = try makeClient(key: key).makeRequest(system: nil, prompt: "hi")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("streaming requests set stream:true")
    func streamFlag() throws {
        let body = try JSONSerialization.jsonObject(
            with: #require(makeClient().makeRequest(
                system: nil, prompt: "p", streaming: true).httpBody)) as! [String: Any]
        #expect(body["stream"] as? Bool == true)
    }

    // MARK: Response

    @Test("reads choices[0].message.content")
    func parsesContent() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 200, body: json([
            "choices": [["message": ["role": "assistant", "content": "Hello, world."]]],
        ]))
        let text = try await makeClient().complete(system: nil, prompt: "hi")
        #expect(text == "Hello, world.")
    }

    @Test("malformed and empty responses map to .decoding")
    func decodingFailures() async {
        for body in [Data("{not json".utf8), json(["choices": []])] {
            StubURLProtocol.reset()
            StubURLProtocol.stub = .init(status: 200, body: body)
            await #expect(throws: LLMError.decoding) {
                try await makeClient().complete(system: nil, prompt: "hi")
            }
        }
    }

    @Test("status codes map the same way as the Anthropic client")
    func statusMapping() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 401, body: Data())
        await #expect(throws: LLMError.unauthorized) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 429, body: Data())
        await #expect(throws: LLMError.rateLimited) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 503, body: Data())
        await #expect(throws: LLMError.server(503)) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
    }

    @Test("a 404 explains the likely cause rather than saying 'HTTP 404'")
    func notFoundIsActionable() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 404, body: Data())
        let error = await #expect(throws: LLMError.self) {
            try await makeClient().complete(system: nil, prompt: "hi")
        }
        #expect(error?.userMessage.contains("base URL") == true)
    }

    @Test("error messages are read from all three common envelope shapes")
    func errorEnvelopes() {
        // OpenAI / LiteLLM
        #expect(OpenAICompatibleClient.mapFailure(
            status: 400, body: json(["error": ["message": "bad model"]]))
            == .badRequest("bad model"))
        // Ollama
        #expect(OpenAICompatibleClient.mapFailure(
            status: 400, body: json(["error": "model not found"]))
            == .badRequest("model not found"))
        // FastAPI / LiteLLM proxy
        #expect(OpenAICompatibleClient.mapFailure(
            status: 400, body: json(["detail": "no deployments available"]))
            == .badRequest("no deployments available"))
    }

    @Test("a refused connection says the server may not be running")
    func connectionRefused() {
        let error = OpenAICompatibleClient.mapTransport(URLError(.cannotConnectToHost))
        #expect(error.userMessage.contains("Is it running?"))
        #expect(error.isRetryable)
    }

    // MARK: SSE

    @Test("extracts choices[0].delta.content")
    func parsesDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"},"index":0}]}"#
        #expect(OpenAICompatibleClient.textDelta(fromSSELine: line) == "Hello")
    }

    @Test("ignores [DONE], role-only openers, empty content and noise")
    func ignoresNonText() {
        let lines = [
            "", "   ", "data: [DONE]", "data:", ": comment",
            #"data: {"choices":[{"delta":{"role":"assistant"},"index":0}]}"#,
            #"data: {"choices":[{"delta":{"content":""},"index":0}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: {not json",
        ]
        for line in lines {
            #expect(OpenAICompatibleClient.textDelta(fromSSELine: line) == nil,
                    "leaked on: \(line)")
        }
    }

    @Test("reasoning_content never reaches the answer")
    func ignoresReasoning() {
        // DeepSeek-R1 style, passed through by LiteLLM.
        let line = #"data: {"choices":[{"delta":{"reasoning_content":"hmm..."},"index":0}]}"#
        #expect(OpenAICompatibleClient.textDelta(fromSSELine: line) == nil)
    }

    @Test("concatenated deltas reconstruct the answer")
    func reassembles() {
        let lines = ["Plants ", "turn light ", "into sugar."].map(deltaLine)
        let joined = lines.compactMap(OpenAICompatibleClient.textDelta(fromSSELine:)).joined()
        #expect(joined == "Plants turn light into sugar.")
    }
}

@Suite("Provider selection")
struct ProviderTests {

    @Test("the factory returns the client matching the provider")
    func factoryPicksClient() {
        let anthropic = LLMClientFactory.make(
            configuration: LLMConfiguration(provider: .anthropic), apiKey: "k")
        #expect(anthropic is AnthropicClient)

        let openAI = LLMClientFactory.make(
            configuration: LLMConfiguration(provider: .openAICompatible), apiKey: "k")
        #expect(openAI is OpenAICompatibleClient)
    }

    @Test("presets are well formed and cover local plus hosted options")
    func presets() {
        #expect(ProviderPreset.all.count >= 5)
        #expect(Set(ProviderPreset.all.map(\.id)).count == ProviderPreset.all.count)
        for preset in ProviderPreset.all {
            #expect(URL(string: preset.baseURL)?.scheme != nil, "bad URL: \(preset.id)")
            #expect(!preset.sampleModel.isEmpty)
        }
        // Local servers must not demand a key.
        #expect(ProviderPreset.preset(id: "ollama")?.needsKey == false)
        #expect(ProviderPreset.preset(id: "litellm")?.needsKey == false)
        // Only Anthropic exposes effort.
        #expect(LLMProvider.anthropic.supportsEffort)
        #expect(!LLMProvider.openAICompatible.supportsEffort)
    }

    @Test("settings round-trip a provider change and build the right configuration")
    func settingsRoundTrip() {
        let name = "com.yourname.AskAI.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        // Defaults to Anthropic so existing installs are unaffected.
        #expect(store.provider == .anthropic)
        #expect(store.configuration().baseURL.host == "api.anthropic.com")

        store.apply(preset: ProviderPreset.preset(id: "ollama")!)
        let config = store.configuration()
        #expect(config.provider == .openAICompatible)
        #expect(config.baseURL.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(config.model == "llama3.2")
    }

    @Test("a mistyped base URL falls back instead of breaking every request")
    func malformedURLFallsBack() {
        let name = "com.yourname.AskAI.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        store.baseURLString = "not a url"
        #expect(store.baseURL.scheme != nil)
        // The raw text is preserved so Settings can show the user what they typed.
        #expect(store.baseURLString == "not a url")
    }
}
