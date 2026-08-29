import Foundation

/// Anything that can turn a prompt into an answer.
///
/// Deliberately narrow: the app only ever needs one completion at a time, so
/// the whole surface is a single call. Keeps `MockLLMClient` trivial and makes
/// the orchestrator testable without a network.
public protocol LLMClient: Sendable {
    func complete(system: String?, prompt: String) async throws -> String

    /// Streams the answer, invoking `onDelta` with each text fragment as it
    /// arrives, and returning the full text.
    ///
    /// Has a default implementation that simply calls `complete` and emits one
    /// delta, so conformers only override it if they can genuinely stream. That
    /// keeps the non-streaming path — and every test written against it —
    /// intact.
    func stream(
        system: String?,
        prompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

public extension LLMClient {
    func stream(
        system: String?,
        prompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let text = try await complete(system: system, prompt: prompt)
        onDelta(text)
        return text
    }
}

/// Everything that can go wrong, mapped to something a user can act on.
public enum LLMError: Error, Equatable {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case server(Int)
    /// The response was not the shape we expect.
    case decoding
    /// Transport failure. Carries the underlying description only, so the enum
    /// stays `Equatable` for tests.
    case network(String)
    case cancelled
    /// A 4xx that isn't one of the specific cases above.
    case badRequest(String)

    /// Text shown in the panel's failure state.
    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            return "No API key set. Add one in Settings."
        case .unauthorized:
            return "API key rejected. Check it in Settings."
        case .rateLimited:
            return "Rate limited. Try again in a moment."
        case .server(let code):
            return "The service is having trouble (HTTP \(code)). Try again."
        case .decoding:
            return "Couldn't read the response."
        case .network(let detail):
            return "Network problem: \(detail)"
        case .cancelled:
            return "Cancelled."
        case .badRequest(let detail):
            return detail.isEmpty ? "The request was rejected." : detail
        }
    }

    /// Whether offering a Retry button makes sense.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network, .decoding: return true
        case .missingAPIKey, .unauthorized, .cancelled, .badRequest: return false
        }
    }
}
