import Foundation

/// Client for the OpenAI `/chat/completions` shape.
///
/// Works against LiteLLM proxy, Ollama, LM Studio, vLLM, OpenRouter, Gemini's
/// compatibility endpoint, and OpenAI itself. Differences from
/// `AnthropicClient` that matter:
///
/// - auth is `Authorization: Bearer …`, not `x-api-key`, and there is no
///   version header;
/// - the system prompt is a `role: "system"` entry in `messages`, not a
///   top-level field;
/// - the reply is a single string at `choices[0].message.content`, not an
///   array of typed blocks;
/// - **an API key is optional** — local servers routinely accept none, so an
///   empty key is not an error here (it is on Anthropic).
public final class OpenAICompatibleClient: LLMClient, @unchecked Sendable {

    private let apiKey: String?
    private let configuration: LLMConfiguration
    private let session: URLSession

    public init(
        apiKey: String?,
        configuration: LLMConfiguration,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Request

    public func makeRequest(
        system: String?, prompt: String, streaming: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // Deliberately tolerant: a local Ollama or LM Studio server needs no
        // credential, so only send the header when there is something to send.
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [[String: Any]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "messages": messages,
        ]
        if streaming {
            body["stream"] = true
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: - Completion

    public func complete(system: String?, prompt: String) async throws -> String {
        let request = try makeRequest(system: system, prompt: prompt)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw LLMError.cancelled
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch {
            throw Self.mapTransport(error)
        }

        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else { throw LLMError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapFailure(status: http.statusCode, body: data)
        }
        return try Self.parseText(from: data)
    }

    // MARK: - Streaming

    public func stream(
        system: String?,
        prompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let request = try makeRequest(system: system, prompt: prompt, streaming: true)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw LLMError.cancelled
        } catch {
            throw Self.mapTransport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw Self.mapFailure(status: http.statusCode, body: body)
        }

        var full = ""
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let delta = Self.textDelta(fromSSELine: line) {
                    full += delta
                    onDelta(delta)
                }
            }
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw LLMError.cancelled
        } catch let error as LLMError {
            throw error
        } catch {
            // Partial text beats losing the answer entirely.
            guard full.isEmpty else { return full }
            throw Self.mapTransport(error)
        }

        guard !full.isEmpty else { throw LLMError.decoding }
        return full
    }

    /// Extracts the text fragment from one SSE line, or `nil` if it carries no
    /// answer text.
    ///
    /// Pure and `internal` so the wire format is unit-testable offline.
    static func textDelta(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }

        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }

        guard
            let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any]
        else { return nil }

        // `reasoning_content` (DeepSeek-R1 and friends, passed through by
        // LiteLLM) is skipped for the same reason Anthropic's thinking_delta
        // is: reasoning must never be rendered as the answer.
        guard let text = delta["content"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Response handling

    static func parseText(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String,
            !text.isEmpty
        else { throw LLMError.decoding }
        return text
    }

    static func mapFailure(status: Int, body: Data) -> LLMError {
        switch status {
        case 401, 403: return .unauthorized
        case 404:
            // Overwhelmingly a wrong base URL or an unpulled local model, not a
            // missing remote resource — say so instead of "HTTP 404".
            let detail = apiErrorMessage(from: body)
            return .badRequest(detail.isEmpty
                ? "Not found. Check the base URL and that the model is available."
                : detail)
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .badRequest(apiErrorMessage(from: body))
        }
    }

    /// Local servers are frequently just not running; that deserves a better
    /// message than the raw URLError text.
    static func mapTransport(_ error: Error) -> LLMError {
        if let urlError = error as? URLError,
           urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost {
            return .network("Could not reach the server. Is it running?")
        }
        return .network(error.localizedDescription)
    }

    /// Pulls `error.message` out of the response, tolerating the several shapes
    /// in the wild: OpenAI's `{"error":{"message":…}}`, a bare
    /// `{"error":"…"}` (Ollama), and `{"detail":…}` (LiteLLM/FastAPI).
    private static func apiErrorMessage(from data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }

        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let error = root["error"] as? String { return error }
        if let detail = root["detail"] as? String { return detail }
        if let detail = root["detail"] as? [String: Any],
           let message = detail["message"] as? String {
            return message
        }
        return ""
    }
}
