import Foundation
import ServiceManagement
import AskAICore

/// Backing store for the settings window.
///
/// Writes through to `SettingsStore` / `KeychainStore` as the user edits, and
/// tells the app to rebuild its LLM client so changes apply without a relaunch.
final class SettingsModel: ObservableObject {

    private let store: SettingsStore
    private let keychain: KeychainStore
    /// Called after any change that affects outgoing requests.
    private let onChange: () -> Void

    @Published var apiKey: String = ""
    @Published private(set) var hasStoredKey = false
    @Published private(set) var keyStatus = ""
    @Published var launchAtLoginWarning: String?

    @Published var presetID: String {
        didSet { applyPreset() }
    }
    @Published var baseURL: String {
        didSet { store.baseURLString = baseURL; onChange() }
    }
    @Published var modelID: String {
        didSet { store.model = modelID; onChange() }
    }
    @Published var maxTokens: Int {
        didSet { store.maxTokens = maxTokens; onChange() }
    }
    @Published var effort: String {
        didSet { store.effort = effort; onChange() }
    }
    @Published var streaming: Bool {
        didSet { store.isStreamingEnabled = streaming; onChange() }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedSlot: Int = 1 {
        didSet { currentTemplate = store.template(for: selectedSlot) }
    }
    @Published var currentTemplate: String = "" {
        didSet { store.setTemplate(currentTemplate, for: selectedSlot) }
    }

    /// True when the selected provider supports Anthropic's effort parameter.
    var showsEffort: Bool {
        ProviderPreset.preset(id: presetID)?.provider.supportsEffort ?? true
    }

    /// Local servers usually need no credential; say so instead of nagging.
    var keyIsOptional: Bool {
        ProviderPreset.preset(id: presetID)?.needsKey == false
    }

    /// Swapping preset rewrites URL + model together, so a half-applied
    /// combination (new provider, old endpoint) is never reachable.
    private func applyPreset() {
        guard let preset = ProviderPreset.preset(id: presetID) else { return }
        store.apply(preset: preset)
        baseURL = preset.baseURL
        modelID = preset.sampleModel
        onChange()
    }

    var selectedSlotTitle: String {
        PromptSlot.slot(id: selectedSlot)?.title ?? ""
    }

    init(store: SettingsStore, keychain: KeychainStore, onChange: @escaping () -> Void) {
        self.store = store
        self.keychain = keychain
        self.onChange = onChange

        self.presetID = store.presetID
        self.baseURL = store.baseURLString
        self.modelID = store.model
        self.maxTokens = store.maxTokens
        self.effort = store.effort
        self.streaming = store.isStreamingEnabled
        self.launchAtLogin = SettingsModel.isLaunchAtLoginEnabled()
        self.currentTemplate = store.template(for: 1)

        refreshKeyStatus()
    }

    // MARK: API key

    func saveAPIKey() {
        do {
            try keychain.save(apiKey)
            apiKey = ""
            refreshKeyStatus()
            keyStatus = "Key saved."
            onChange()
        } catch {
            keyStatus = "Could not save key."
            Log.app.error("keychain save failed: \(String(describing: error), privacy: .public)")
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete()
            refreshKeyStatus()
            keyStatus = "Key removed."
            onChange()
        } catch {
            keyStatus = "Could not remove key."
        }
    }

    private func refreshKeyStatus() {
        let stored = (try? keychain.read()) ?? nil
        hasStoredKey = !(stored ?? "").isEmpty
        keyStatus = hasStoredKey ? "A key is stored." : "No key stored."
    }

    // MARK: Prompts

    func restoreCurrentTemplate() {
        store.resetTemplate(for: selectedSlot)
        currentTemplate = store.template(for: selectedSlot)
    }

    // MARK: Launch at login

    private static func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        store.launchAtLogin = enabled
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginWarning = nil
        } catch {
            // Ad-hoc signed builds outside /Applications are commonly rejected
            // here; surface it rather than silently lying about the toggle.
            launchAtLoginWarning =
                "Could not \(enabled ? "enable" : "disable") launch at login. "
                + "The app may need to be in /Applications."
            Log.app.error(
                "SMAppService failed: \(String(describing: error), privacy: .public)")
        }
    }
}
