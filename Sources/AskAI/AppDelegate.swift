import AppKit
import AskAICore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let serviceProvider = ServiceProvider()
    let resultPanel = ResultPanel()

    private let keychain = KeychainStore()
    private let settings = SettingsStore()
    private var orchestrator: AskOrchestrator?
    private var settingsWindow: SettingsWindowController?
    /// Slot of the most recent invocation, so Retry re-runs the same prompt.
    private var lastSlot = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installServicesProvider()
        resultPanel.onRetry = { [weak self] selection in
            guard let self else { return }
            self.ask(selection: selection, slot: self.lastSlot)
        }
        Log.app.notice("AskAI launched (core \(AskAICore.version, privacy: .public))")

        if ProcessInfo.processInfo.environment["ASKAI_KEYCHAIN_SELFTEST"] == "1" {
            runKeychainSelfTest()
        }
    }

    /// Round-trips a throwaway secret through the Keychain and logs the result.
    ///
    /// Worth having as a launch-time diagnostic because a sandboxed,
    /// ad-hoc-signed app is exactly the configuration where `SecItemAdd` can
    /// fail with `errSecMissingEntitlement` (-34018) — which would make the
    /// Settings key field silently useless. Enabled with
    /// `ASKAI_KEYCHAIN_SELFTEST=1`; never runs in normal use.
    private func runKeychainSelfTest() {
        let probe = KeychainStore(service: "com.yourname.AskAI.selftest",
                                  account: "probe")
        do {
            try probe.save("round-trip-value")
            let read = try probe.read()
            try probe.delete()
            let gone = try probe.read()
            Log.app.notice(
                """
                keychain selftest: write+read=\(read == "round-trip-value", privacy: .public) \
                delete=\(gone == nil, privacy: .public)
                """
            )
        } catch {
            Log.app.error(
                "keychain selftest FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - LLM wiring

    /// Built lazily so a key added in Settings takes effect without relaunching,
    /// and cached so a second invocation can cancel the first one's request.
    private func makeOrchestrator() -> AskOrchestrator {
        let client: LLMClient
        if MockLLMClient.isEnabled() {
            Log.llm.notice(
                "using MockLLMClient (\(MockLLMClient.environmentKey, privacy: .public)=1)")
            client = MockLLMClient()
        } else {
            // Distinguish "no key stored" from "keychain refused us". An
            // ad-hoc-signed sandboxed app can fail with errSecMissingEntitlement
            // (-34018), which would otherwise look identical to an empty
            // keychain and send the user hunting in Settings for nothing.
            var key: String?
            do {
                key = try keychain.read()
                Log.llm.notice("keychain read ok, hasKey=\(key != nil, privacy: .public)")
            } catch {
                Log.llm.error(
                    "keychain read FAILED: \(String(describing: error), privacy: .public)")
                key = nil
            }
            client = AnthropicClient(apiKey: key, configuration: settings.configuration())
        }
        return AskOrchestrator(client: client, machine: resultPanel.machine)
    }

    private func ask(selection: String, slot: Int) {
        lastSlot = slot
        let orchestrator = self.orchestrator ?? makeOrchestrator()
        self.orchestrator = orchestrator
        Log.llm.notice(
            "asking slot=\(slot, privacy: .public) chars=\(selection.count, privacy: .public)")
        orchestrator.ask(
            selection: selection,
            template: settings.template(for: slot)
        )
    }

    /// Discards the cached orchestrator so the next ask picks up new settings.
    func invalidateOrchestrator() {
        orchestrator = nil
    }

    // MARK: - Services

    private func installServicesProvider() {
        serviceProvider.onSelection = { [weak self] selection, slot in
            guard let self else { return }
            self.resultPanel.show()
            self.ask(selection: selection.text, slot: slot)
        }
        serviceProvider.onEmptySelection = { [weak self] in
            guard let self else { return }
            self.resultPanel.machine.showEmptySelection()
            self.resultPanel.show()
        }

        // Held as a stored property: `servicesProvider` is an unowned reference,
        // so a temporary here would be deallocated and invocations would go
        // nowhere.
        NSApp.servicesProvider = serviceProvider
        // Forces an immediate rescan so a freshly installed/re-signed bundle is
        // picked up without logging out.
        NSUpdateDynamicServices()
        Log.app.notice("services provider registered")
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "sparkle",
                accessibilityDescription: "Ask AI"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        // Temporary, for manual verification. Removed in Stage 8.
        menu.addItem(
            withTitle: "Show test panel",
            action: #selector(showTestPanel),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Open Services Shortcuts…",
            action: #selector(openServicesShortcuts),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit AskAI",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self

        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(
                store: settings,
                keychain: keychain,
                onChange: { [weak self] in self?.invalidateOrchestrator() }
            )
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    /// Deep-links to the pane where each slot's keyboard shortcut is bound.
    @objc private func openServicesShortcuts() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showTestPanel() {
        resultPanel.show()
        ask(selection: "The mitochondria is the powerhouse of the cell.", slot: 1)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
