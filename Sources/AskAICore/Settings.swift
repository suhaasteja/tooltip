import Foundation

/// One Services-menu entry.
///
/// The *titles* are fixed at build time because `NSServices` is read from
/// Info.plist at registration and cannot be edited at runtime without
/// re-signing the bundle. The *prompt bodies* are user-editable and live in
/// `UserDefaults`. This is the honest ceiling on "configurable prompts" for a
/// Services-based app; see the README.
public struct PromptSlot: Equatable, Identifiable, Sendable {
    public let id: Int
    /// Must match `NSMenuItem.default` for this slot in Info.plist.
    public let title: String
    public let defaultTemplate: String

    public init(id: Int, title: String, defaultTemplate: String) {
        self.id = id
        self.title = title
        self.defaultTemplate = defaultTemplate
    }

    /// The four shipped slots. Changing a `title` here means changing
    /// Info.plist and re-installing.
    public static let all: [PromptSlot] = [
        PromptSlot(
            id: 1, title: "Ask AI: Explain",
            defaultTemplate:
                "Explain the following concisely, in plain language:\n\n\(PromptTemplate.placeholder)"),
        PromptSlot(
            id: 2, title: "Ask AI: Summarise",
            defaultTemplate:
                "Summarise the following in a few sentences:\n\n\(PromptTemplate.placeholder)"),
        PromptSlot(
            id: 3, title: "Ask AI: Translate",
            defaultTemplate:
                "Translate the following into English. If it is already English, "
                + "translate it into Spanish. Reply with the translation only:"
                + "\n\n\(PromptTemplate.placeholder)"),
        PromptSlot(
            id: 4, title: "Ask AI: Custom",
            defaultTemplate: PromptTemplate.placeholder),
    ]

    public static func slot(id: Int) -> PromptSlot? {
        all.first { $0.id == id }
    }
}

/// User-editable settings, backed by `UserDefaults`.
///
/// Only the API key is excluded — that lives in the Keychain.
public final class SettingsStore {

    private enum Key {
        static func template(_ slot: Int) -> String { "prompt.template.\(slot)" }
        static let provider = "llm.provider"
        static let baseURL = "llm.baseURL"
        static let presetID = "llm.presetID"
        static let model = "llm.model"
        static let maxTokens = "llm.maxTokens"
        static let effort = "llm.effort"
        static let streaming = "llm.streaming"
        static let launchAtLogin = "app.launchAtLogin"
        static let spriteSet = "sprite.activeSetID"
        static let hideBuiltInSprite = "sprite.hideBuiltIn"
        static let thinkingPrompt = "sprite.prompt.thinking"
        static let posesPrompt = "sprite.prompt.poses"
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: injected so tests use a throwaway suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Prompt templates

    /// The user's template for a slot, or the slot's default if unset or blank.
    public func template(for slot: Int) -> String {
        let stored = defaults.string(forKey: Key.template(slot))
        if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return PromptSlot.slot(id: slot)?.defaultTemplate ?? PromptTemplate.defaultTemplate
    }

    /// Saves a template. Blank input clears the override and restores the default.
    public func setTemplate(_ template: String, for slot: Int) {
        if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: Key.template(slot))
        } else {
            defaults.set(template, forKey: Key.template(slot))
        }
    }

    public func resetTemplate(for slot: Int) {
        defaults.removeObject(forKey: Key.template(slot))
    }

    /// True when the slot is using its shipped default.
    public func isTemplateCustomized(slot: Int) -> Bool {
        guard let stored = defaults.string(forKey: Key.template(slot)) else { return false }
        return stored != PromptSlot.slot(id: slot)?.defaultTemplate
    }

    // MARK: Model

    /// Which wire protocol to speak. Defaults to Anthropic for existing installs.
    public var provider: LLMProvider {
        get {
            guard let raw = defaults.string(forKey: Key.provider),
                  let provider = LLMProvider(rawValue: raw) else { return .anthropic }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
    }

    /// Endpoint URL. Falls back to the provider default if unset or unparseable,
    /// so a mistyped URL degrades to "works against the default" rather than
    /// throwing on every request.
    public var baseURL: URL {
        get {
            if let string = defaults.string(forKey: Key.baseURL),
               let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
               url.scheme != nil {
                return url
            }
            return LLMConfiguration(provider: provider).baseURL
        }
        set { defaults.set(newValue.absoluteString, forKey: Key.baseURL) }
    }

    /// Raw string as typed, so the Settings field can show invalid input back
    /// to the user instead of silently replacing it.
    public var baseURLString: String {
        get {
            defaults.string(forKey: Key.baseURL)
                ?? LLMConfiguration(provider: provider).baseURL.absoluteString
        }
        set { defaults.set(newValue, forKey: Key.baseURL) }
    }

    /// Which preset the user last picked, for the Settings UI only.
    public var presetID: String {
        get { defaults.string(forKey: Key.presetID) ?? "anthropic" }
        set { defaults.set(newValue, forKey: Key.presetID) }
    }

    /// Applies a preset's provider, URL and sample model in one step.
    public func apply(preset: ProviderPreset) {
        presetID = preset.id
        provider = preset.provider
        baseURLString = preset.baseURL
        model = preset.sampleModel
    }

    public var model: String {
        get {
            if let stored = defaults.string(forKey: Key.model), !stored.isEmpty { return stored }
            return ProviderPreset.preset(id: presetID)?.sampleModel
                ?? LLMConfiguration.defaultModel
        }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    /// Clamped: too low truncates answers (this model tier spends part of the
    /// budget on thinking), too high is pointless for a tooltip.
    public var maxTokens: Int {
        get {
            let stored = defaults.integer(forKey: Key.maxTokens)
            return stored == 0 ? 2048 : min(max(stored, 256), 8192)
        }
        set { defaults.set(min(max(newValue, 256), 8192), forKey: Key.maxTokens) }
    }

    public var effort: String {
        get { defaults.string(forKey: Key.effort) ?? "low" }
        set { defaults.set(newValue, forKey: Key.effort) }
    }

    public static let effortLevels = ["low", "medium", "high"]

    public var isStreamingEnabled: Bool {
        get { defaults.object(forKey: Key.streaming) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.streaming) }
    }

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// Whether the built-in character is hidden from the Settings picker.
    ///
    /// Presentation only. The built-in character can never actually be removed —
    /// it ships read-only inside the bundle and is the fallback whenever a
    /// generated one is missing, corrupt or half-written. Hiding it takes it out
    /// of a list the user has outgrown without taking away the safety net.
    public var hidesBuiltInSprite: Bool {
        get { defaults.bool(forKey: Key.hideBuiltInSprite) }
        set { defaults.set(newValue, forKey: Key.hideBuiltInSprite) }
    }

    /// Which character the panel draws. Defaults to the one in the app bundle.
    public var activeSpriteSetID: String {
        get { defaults.string(forKey: Key.spriteSet) ?? SpriteSet.builtInID }
        set { defaults.set(newValue, forKey: Key.spriteSet) }
    }

    // MARK: Sprite prompts

    /// The two sheet prompts, editable like the four Services prompt slots.
    ///
    /// Blank restores the default, matching how `template(for:)` behaves — so
    /// "clear the field" is a working undo everywhere in this app.
    public var thinkingPrompt: String {
        get { nonEmpty(Key.thinkingPrompt) ?? SpritePrompts.defaultThinkingTemplate }
        set { setOrClear(newValue, Key.thinkingPrompt) }
    }

    public var posesPrompt: String {
        get { nonEmpty(Key.posesPrompt) ?? SpritePrompts.defaultPosesTemplate }
        set { setOrClear(newValue, Key.posesPrompt) }
    }

    public var isThinkingPromptCustomised: Bool { nonEmpty(Key.thinkingPrompt) != nil }
    public var isPosesPromptCustomised: Bool { nonEmpty(Key.posesPrompt) != nil }

    public func restoreSpritePrompts() {
        defaults.removeObject(forKey: Key.thinkingPrompt)
        defaults.removeObject(forKey: Key.posesPrompt)
    }

    private func nonEmpty(_ key: String) -> String? {
        guard let stored = defaults.string(forKey: key),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return stored
    }

    private func setOrClear(_ value: String, _ key: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
    }

    /// Whether the configured LLM key can also be used for image generation.
    ///
    /// True when the app is already pointed at Google: a Google AI Studio key
    /// works for both the chat endpoint and `generateContent`, so those users
    /// need not paste a second credential. Everyone else does.
    ///
    /// Deliberately checks the host rather than the preset id, because the base
    /// URL is user-editable and the preset is only a UI hint.
    public var llmKeyWorksForImages: Bool {
        baseURL.host?.hasSuffix("generativelanguage.googleapis.com") ?? false
    }

    /// The active set, or the built-in one if it is missing, unreadable, or has
    /// lost its frames.
    ///
    /// Resolved here rather than at the call site so there is exactly one place
    /// that decides what "the current character" means, and one place that has
    /// to get the fallback right.
    public func activeSpriteSet(store: SpriteSetStore = SpriteSetStore()) -> SpriteSet {
        guard let set = store.set(id: activeSpriteSetID), store.isComplete(set) else {
            return SpriteSet.builtIn
        }
        return set
    }

    /// Current settings as an `LLMConfiguration`.
    public func configuration() -> LLMConfiguration {
        LLMConfiguration(
            provider: provider,
            baseURL: baseURL,
            model: model,
            maxTokens: maxTokens,
            effort: effort
        )
    }
}
