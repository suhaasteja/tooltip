import Foundation

/// Which wire protocol to speak.
///
/// Only two are needed: Anthropic's native Messages API, and the
/// OpenAI-compatible `/chat/completions` shape that nearly everything else
/// exposes — LiteLLM proxy, Ollama, LM Studio, vLLM, OpenRouter, and Gemini's
/// compatibility endpoint. Adding "support for Gemini" or "support for local
/// models" is therefore a base-URL change, not a new client.
public enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAICompatible = "openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Anthropic's `output_config.effort` has no OpenAI-compatible equivalent,
    /// so the setting is hidden rather than silently ignored.
    public var supportsEffort: Bool { self == .anthropic }
}

/// A named base URL + model, for the Settings picker.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let provider: LLMProvider
    public let baseURL: String
    public let sampleModel: String
    /// Local servers usually accept any key, or none at all.
    public let needsKey: Bool

    public init(
        id: String, name: String, provider: LLMProvider,
        baseURL: String, sampleModel: String, needsKey: Bool
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.sampleModel = sampleModel
        self.needsKey = needsKey
    }

    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "anthropic", name: "Anthropic (native)", provider: .anthropic,
            baseURL: "https://api.anthropic.com/v1/messages",
            sampleModel: LLMConfiguration.defaultModel, needsKey: true),
        ProviderPreset(
            id: "litellm", name: "LiteLLM proxy (local)", provider: .openAICompatible,
            baseURL: "http://localhost:4000/v1/chat/completions",
            sampleModel: "gemini/gemini-2.5-flash", needsKey: false),
        ProviderPreset(
            id: "ollama", name: "Ollama (local)", provider: .openAICompatible,
            baseURL: "http://localhost:11434/v1/chat/completions",
            sampleModel: "llama3.2", needsKey: false),
        ProviderPreset(
            id: "lmstudio", name: "LM Studio (local)", provider: .openAICompatible,
            baseURL: "http://localhost:1234/v1/chat/completions",
            sampleModel: "local-model", needsKey: false),
        ProviderPreset(
            id: "gemini", name: "Gemini (OpenAI-compatible)", provider: .openAICompatible,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            sampleModel: "gemini-2.5-flash", needsKey: true),
        ProviderPreset(
            id: "openai", name: "OpenAI", provider: .openAICompatible,
            baseURL: "https://api.openai.com/v1/chat/completions",
            sampleModel: "gpt-4o", needsKey: true),
    ]

    public static func preset(id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }
}

/// Everything the client layer needs to build a request.
public struct LLMConfiguration: Equatable, Sendable {

    /// Fetched from the live model docs rather than recalled. Complete as
    /// written — never append a date suffix.
    public static let defaultModel = "claude-opus-5"

    public var provider: LLMProvider
    public var baseURL: URL
    public var model: String
    public var maxTokens: Int
    /// Anthropic only; ignored by the OpenAI-compatible client.
    public var effort: String

    public init(
        provider: LLMProvider = .anthropic,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        model: String = LLMConfiguration.defaultModel,
        maxTokens: Int = 2048,
        effort: String = "low"
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
    }
}

/// Builds the right client for a configuration.
public enum LLMClientFactory {
    public static func make(
        configuration: LLMConfiguration,
        apiKey: String?,
        session: URLSession = .shared
    ) -> LLMClient {
        switch configuration.provider {
        case .anthropic:
            return AnthropicClient(
                apiKey: apiKey, configuration: configuration, session: session)
        case .openAICompatible:
            return OpenAICompatibleClient(
                apiKey: apiKey, configuration: configuration, session: session)
        }
    }
}
