import Testing
import Foundation
@testable import AskAICore

/// Throwaway suite per test so nothing touches real preferences.
private func makeStore() -> (SettingsStore, UserDefaults, String) {
    let name = "com.yourname.AskAI.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (SettingsStore(defaults: defaults), defaults, name)
}

@Suite("Settings store")
struct SettingsTests {

    @Test("there are exactly four slots with unique ids and titles")
    func slotShape() {
        #expect(PromptSlot.all.count == 4)
        #expect(Set(PromptSlot.all.map(\.id)) == [1, 2, 3, 4])
        #expect(Set(PromptSlot.all.map(\.title)).count == 4)
        for slot in PromptSlot.all {
            #expect(slot.title.hasPrefix("Ask AI"))
            #expect(slot.defaultTemplate.contains(PromptTemplate.placeholder))
        }
    }

    @Test("an unset slot returns its shipped default")
    func defaultTemplate() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        for slot in PromptSlot.all {
            #expect(store.template(for: slot.id) == slot.defaultTemplate)
            #expect(store.isTemplateCustomized(slot: slot.id) == false)
        }
    }

    @Test("an edited template persists and is reported as customized")
    func editTemplate() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        store.setTemplate("Rewrite as a haiku:\n\n{{selection}}", for: 2)
        #expect(store.template(for: 2) == "Rewrite as a haiku:\n\n{{selection}}")
        #expect(store.isTemplateCustomized(slot: 2))
        // Other slots are untouched.
        #expect(store.template(for: 1) == PromptSlot.slot(id: 1)!.defaultTemplate)
    }

    @Test("blank input clears the override rather than sending an empty prompt")
    func blankRestoresDefault() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        store.setTemplate("custom", for: 3)
        store.setTemplate("   \n  ", for: 3)
        #expect(store.template(for: 3) == PromptSlot.slot(id: 3)!.defaultTemplate)
    }

    @Test("reset restores the default")
    func resetTemplate() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        store.setTemplate("custom", for: 1)
        store.resetTemplate(for: 1)
        #expect(store.template(for: 1) == PromptSlot.slot(id: 1)!.defaultTemplate)
    }

    @Test("an unknown slot id still yields a usable template")
    func unknownSlot() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(store.template(for: 99) == PromptTemplate.defaultTemplate)
    }

    @Test("model and effort default sensibly and round-trip")
    func modelAndEffort() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        #expect(store.model == LLMConfiguration.defaultModel)
        #expect(store.effort == "low")
        store.model = "claude-sonnet-5"
        store.effort = "medium"
        #expect(store.model == "claude-sonnet-5")
        #expect(store.effort == "medium")
    }

    @Test("maxTokens defaults to 2048 and clamps out-of-range input")
    func maxTokensClamping() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        #expect(store.maxTokens == 2048)
        store.maxTokens = 10
        #expect(store.maxTokens == 256)
        store.maxTokens = 999_999
        #expect(store.maxTokens == 8192)
        store.maxTokens = 4096
        #expect(store.maxTokens == 4096)
    }

    @Test("streaming defaults on and survives being turned off")
    func streamingToggle() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        #expect(store.isStreamingEnabled)
        store.isStreamingEnabled = false
        #expect(store.isStreamingEnabled == false)
    }

    @Test("configuration() reflects the stored settings")
    func buildsConfiguration() {
        let (store, _, name) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        store.model = "claude-sonnet-5"
        store.maxTokens = 1024
        store.effort = "high"

        let config = store.configuration()
        #expect(config.model == "claude-sonnet-5")
        #expect(config.maxTokens == 1024)
        #expect(config.effort == "high")
    }
}
