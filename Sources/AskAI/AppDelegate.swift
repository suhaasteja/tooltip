import AppKit
import AskAICore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let serviceProvider = ServiceProvider()
    let resultPanel = ResultPanel()

    private let keychain = KeychainStore()
    private var orchestrator: AskOrchestrator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installServicesProvider()
        resultPanel.onRetry = { [weak self] selection in
            self?.ask(selection: selection)
        }
        Log.app.notice("AskAI launched (core \(AskAICore.version, privacy: .public))")
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
            let key = try? keychain.read()
            if key == nil { Log.llm.notice("no API key in keychain") }
            client = AnthropicClient(apiKey: key)
        }
        return AskOrchestrator(client: client, machine: resultPanel.machine)
    }

    private func ask(selection: String) {
        let orchestrator = self.orchestrator ?? makeOrchestrator()
        self.orchestrator = orchestrator
        Log.llm.notice("asking, chars=\(selection.count, privacy: .public)")
        orchestrator.ask(selection: selection)
    }

    /// Discards the cached orchestrator so the next ask picks up new settings.
    func invalidateOrchestrator() {
        orchestrator = nil
    }

    // MARK: - Services

    private func installServicesProvider() {
        serviceProvider.onSelection = { [weak self] selection in
            guard let self else { return }
            self.resultPanel.show()
            self.ask(selection: selection.text)
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
        // Stage 7.
        Log.app.notice("settings requested")
    }

    @objc private func showTestPanel() {
        resultPanel.show()
        ask(selection: "The mitochondria is the powerhouse of the cell.")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
