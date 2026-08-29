import Foundation

/// Configuration for `AnthropicClient`.
public struct LLMConfiguration: Equatable, Sendable {

    /// Default model.
    ///
    /// Fetched from the live model docs rather than recalled: `claude-opus-5`
    /// is the current Opus-tier id. Note the id is complete as written — never
    /// append a date suffix.
    public static let defaultModel = "claude-opus-5"

    /// Base URL. Configurable so the same client can point at a key-proxy
    /// worker instead of the API directly (see NOTES.md on key handling).
    public var baseURL: URL
    public var model: String
    public var maxTokens: Int
    /// `low` keeps a tooltip feeling like a tooltip. See NOTES.md for why this
    /// is preferred over disabling thinking outright on this model.
    public var effort: String

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        model: String = LLMConfiguration.defaultModel,
        maxTokens: Int = 2048,
        effort: String = "low"
    ) {
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
    }
}

/// Minimal Anthropic Messages API client.
///
/// Notable omissions, all deliberate for the current model tier: no
/// `temperature`, no `top_p`, no `top_k`, and no `thinking.budget_tokens` —
/// every one of those is rejected with a 400 on Opus-5-tier models. Depth is
/// controlled with `output_config.effort` instead.
public final class AnthropicClient: LLMClient, @unchecked Sendable {

    public static let apiVersion = "2023-06-01"

    private let apiKey: String?
    private let configuration: LLMConfiguration
    private let session: URLSession

    /// - Parameter session: injected so tests can supply a stubbed
    ///   `URLProtocol` and exercise every branch offline.
    public init(
        apiKey: String?,
        configuration: LLMConfiguration = LLMConfiguration(),
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Request

    /// Builds the POST. Exposed for tests so header/URL/body assertions do not
    /// need a live request.
    public func makeRequest(
        system: String?, prompt: String, streaming: Bool = false
    ) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "output_config": ["effort": configuration.effort],
            "messages": [["role": "user", "content": prompt]],
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
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
            throw LLMError.network(error.localizedDescription)
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
            throw LLMError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            // The error body is not SSE; drain it so the message survives.
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
            // A mid-stream transport drop with usable text is better surfaced
            // as a truncated answer than as a total failure.
            guard full.isEmpty else { return full }
            throw LLMError.network(error.localizedDescription)
        }

        guard !full.isEmpty else { throw LLMError.decoding }
        return full
    }

    /// Extracts the text fragment from one SSE line, or `nil` if the line
    /// carries no text (event names, pings, `[DONE]`, thinking deltas, blanks).
    ///
    /// Pure and `internal` so the wire format is unit-testable without a
    /// network or a live stream.
    static func textDelta(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }

        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }

        guard
            let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Only text deltas contribute. `thinking_delta` is explicitly ignored:
        // reasoning must never be rendered as the answer.
        guard object["type"] as? String == "content_block_delta",
              let delta = object["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String
        else { return nil }

        return text
    }

    // MARK: - Response handling

    /// Concatenates every `type == "text"` block.
    ///
    /// Blocks of other types (notably `thinking`, which this model tier emits
    /// by default) are skipped rather than treated as an error.
    static func parseText(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else { throw LLMError.decoding }

        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard !text.isEmpty else { throw LLMError.decoding }
        return text
    }

    static func mapFailure(status: Int, body: Data) -> LLMError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .badRequest(apiErrorMessage(from: body))
        }
    }

    /// Pulls `error.message` out of an API error envelope, if present.
    private static func apiErrorMessage(from data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return "" }
        return message
    }
}
