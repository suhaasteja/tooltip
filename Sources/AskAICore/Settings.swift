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
        static let model = "llm.model"
        static let maxTokens = "llm.maxTokens"
        static let effort = "llm.effort"
        static let streaming = "llm.streaming"
        static let launchAtLogin = "app.launchAtLogin"
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

    public var model: String {
        get { defaults.string(forKey: Key.model) ?? LLMConfiguration.defaultModel }
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

    /// Current settings as an `LLMConfiguration`.
    public func configuration() -> LLMConfiguration {
        LLMConfiguration(model: model, maxTokens: maxTokens, effort: effort)
    }
}
