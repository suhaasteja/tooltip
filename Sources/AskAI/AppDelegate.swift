import AppKit
import AskAICore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let serviceProvider = ServiceProvider()
    let resultPanel = ResultPanel()
    private let pointerTracker = PointerTracker()

    private let keychain = KeychainStore()
    private let settings = SettingsStore()
    private var orchestrator: AskOrchestrator?
    private var settingsWindow: SettingsWindowController?
    /// Slot of the most recent invocation, so Retry re-runs the same prompt.
    private var lastSlot = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installStatusItem()
        installServicesProvider()
        pointerTracker.start()
        // Decode the sprite PNGs now, not on the first invocation while the
        // user is waiting for an answer.
        SpriteLoader.preload()
        // Same idea, and far more important: get the Keychain dialog out of the
        // way at launch rather than in the middle of the first question.
        warmKeychain()
        resultPanel.onRetry = { [weak self] selection in
            guard let self else { return }
            self.ask(selection: selection, slot: self.lastSlot)
        }
        Log.app.notice("AskAI launched (core \(AskAICore.version, privacy: .public))")

        if ProcessInfo.processInfo.environment["ASKAI_KEYCHAIN_SELFTEST"] == "1" {
            runKeychainSelfTest()
        }
        if ProcessInfo.processInfo.environment["ASKAI_DPKEYCHAIN_TEST"] == "1" {
            runDataProtectionKeychainTest()
        }
        if ProcessInfo.processInfo.environment["ASKAI_SPRITE_PREVIEW"] == "1" {
            startSpritePreview()
        }
        if let dir = ProcessInfo.processInfo.environment["ASKAI_SPRITE_SNAPSHOT"] {
            SpriteSnapshot.run(into: dir)
        }
    }

    // MARK: - Sprite preview

    private var previewTimer: Timer?

    /// Cycles the panel through every state so the character can be iterated on
    /// without installing to /Applications and right-clicking in another app.
    ///
    /// Drives the real `PanelViewModel`, not a parallel fake, so what you see is
    /// what a genuine invocation produces. `ASKAI_SPRITE_PREVIEW=1`.
    private func startSpritePreview() {
        Log.app.notice("sprite preview mode")
        let machine = resultPanel.machine
        var step = 0

        let advance: () -> Void = { [weak self] in
            guard let self else { return }
            let id = machine.currentRequestID
            switch step % 4 {
            case 0:
                machine.startLoading(selection: "The mitochondria is the powerhouse of the cell.")
            case 1:
                machine.finish(
                    requestID: id,
                    answer: "Mitochondria generate most of the chemical energy a cell "
                        + "needs, which is why they get called its powerhouse.")
            case 2:
                machine.fail(requestID: id, message: "Rate limited. Try again in a moment.",
                             retryable: true)
            default:
                machine.showEmptySelection()
            }
            step += 1
            self.resultPanel.show(at: NSEvent.mouseLocation)
        }

        advance()
        // .common so it keeps running while menus track.
        let timer = Timer(timeInterval: 2.5, repeats: true) { _ in advance() }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    /// Round-trips a throwaway secret through BOTH keychains and reports each
    /// step's status, so it is knowable rather than assumed whether this bundle
    /// can use the data protection keychain.
    ///
    /// The interesting failure is `errSecMissingEntitlement` (-34018) on the
    /// data protection side, which means the signature carries no usable team
    /// identifier. `ASKAI_DPKEYCHAIN_TEST=1`; must be run from the signed,
    /// sandboxed bundle, because that is the only configuration whose answer
    /// counts.
    private func runDataProtectionKeychainTest() {
        for useDataProtection in [false, true] {
            let label = useDataProtection ? "dataprotection" : "legacy"
            let probe = KeychainStore(
                service: "com.yourname.AskAI.dptest",
                account: "probe",
                useDataProtection: useDataProtection)
            do {
                try probe.save("round-trip-value")
                let read = try probe.read()
                try probe.delete()
                Log.app.notice(
                    """
                    dptest[\(label, privacy: .public)] \
                    write+read=\(read == "round-trip-value", privacy: .public) OK
                    """)
            } catch let KeychainStore.KeychainError.unexpectedStatus(status) {
                Log.app.error(
                    """
                    dptest[\(label, privacy: .public)] FAILED status=\
                    \(status, privacy: .public)
                    """)
            } catch {
                Log.app.error(
                    """
                    dptest[\(label, privacy: .public)] FAILED \
                    \(String(describing: error), privacy: .public)
                    """)
            }
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

    /// The API key, once read. `nil` inner value means "read, and there isn't
    /// one" -- distinct from the outer nil, which means "not read yet".
    ///
    /// Main thread only.
    private var cachedKey: String??

    /// Reads the key. **Blocks**, sometimes for many seconds: the first
    /// `SecItemCopyMatching` in a sandboxed process can sit behind a Keychain
    /// authorization dialog, and this app's ad-hoc signature changes on every
    /// rebuild, so macOS treats each build as a new application and asks again.
    /// Never call this on the main thread. See NOTES.md.
    private func readKey() -> String? {
        // Distinguish "no key stored" from "keychain refused us". An
        // ad-hoc-signed sandboxed app can fail with errSecMissingEntitlement
        // (-34018), which would otherwise look identical to an empty
        // keychain and send the user hunting in Settings for nothing.
        do {
            let key = try keychain.read()
            Log.llm.notice("keychain read ok hasKey=\(key != nil, privacy: .public)")
            return key
        } catch {
            Log.llm.error(
                "keychain read FAILED: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Reads the key off the main thread at launch so the dialog, if there is
    /// one, appears while the user is not waiting on an answer.
    ///
    /// Without this the read happens inside the Services handler, on the main
    /// thread, and the panel cannot draw until it returns -- which is what made
    /// the first question after every launch look frozen for 10-35 seconds.
    private func warmKeychain() {
        guard !MockLLMClient.isEnabled() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let key = self.readKey()
            DispatchQueue.main.async { self.cachedKey = .some(key) }
        }
    }

    /// Built lazily so a key added in Settings takes effect without relaunching,
    /// and cached so a second invocation can cancel the first one's request.
    private func makeOrchestrator(apiKey: String?) -> AskOrchestrator {
        let client: LLMClient
        if MockLLMClient.isEnabled() {
            Log.llm.notice(
                "using MockLLMClient (\(MockLLMClient.environmentKey, privacy: .public)=1)")
            client = MockLLMClient()
        } else {
            Log.llm.notice(
                """
                client provider=\(self.settings.provider.rawValue, privacy: .public) \
                model=\(self.settings.model, privacy: .public)
                """)
            client = LLMClientFactory.make(
                configuration: settings.configuration(), apiKey: apiKey)
        }
        return AskOrchestrator(
            client: client,
            machine: resultPanel.machine,
            streaming: settings.isStreamingEnabled
        )
    }

    private func ask(selection: String, slot: Int) {
        lastSlot = slot
        let template = settings.template(for: slot)

        // Fast path: everything already resolved.
        if let orchestrator {
            Log.llm.notice(
                "asking slot=\(slot, privacy: .public) chars=\(selection.count, privacy: .public)")
            orchestrator.ask(selection: selection, template: template)
            return
        }
        if let cachedKey {
            let orchestrator = makeOrchestrator(apiKey: cachedKey)
            self.orchestrator = orchestrator
            Log.llm.notice(
                "asking slot=\(slot, privacy: .public) chars=\(selection.count, privacy: .public)")
            orchestrator.ask(selection: selection, template: template)
            return
        }

        // The warm-up has not finished (or has not been given a chance). Resolve
        // the key off the main thread so the panel keeps drawing its loading
        // state instead of freezing behind a Keychain dialog.
        Log.llm.notice("keychain not warm yet; resolving off-main")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let key = self.readKey()
            DispatchQueue.main.async {
                self.cachedKey = .some(key)
                let orchestrator = self.makeOrchestrator(apiKey: key)
                self.orchestrator = orchestrator
                Log.llm.notice(
                    """
                    asking slot=\(slot, privacy: .public) \
                    chars=\(selection.count, privacy: .public)
                    """)
                orchestrator.ask(selection: selection, template: template)
            }
        }
    }

    /// Discards the cached orchestrator so the next ask picks up new settings.
    ///
    /// Also drops the cached key and re-reads it: the most common reason to get
    /// here is the user having just pasted a new API key into Settings, and a
    /// stale cached key would keep the old one alive until relaunch.
    func invalidateOrchestrator() {
        orchestrator = nil
        cachedKey = nil
        warmKeychain()
    }

    // MARK: - Services

    private func installServicesProvider() {
        serviceProvider.onSelection = { [weak self] selection, slot in
            guard let self else { return }
            let anchor = self.pointerTracker.anchor
            Log.panel.debug(
                """
                anchor y=\(Int(anchor.y), privacy: .public) \
                pointer y=\(Int(NSEvent.mouseLocation.y), privacy: .public)
                """)
            self.resultPanel.show(at: anchor)
            self.ask(selection: selection.text, slot: slot)
        }
        serviceProvider.onEmptySelection = { [weak self] in
            guard let self else { return }
            self.resultPanel.machine.showEmptySelection()
            self.resultPanel.show(at: self.pointerTracker.anchor)
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

    // MARK: - Main menu

    /// Installs a minimal main menu.
    ///
    /// Without this, an `LSUIElement` app has no menu bar at all, so ⌘V / ⌘C /
    /// ⌘X / ⌘A are never dispatched — which is why pasting an API key into the
    /// Settings window silently did nothing. The items target `nil` so they
    /// travel the responder chain to whichever text field is focused.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit AskAI",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        // The title must be exactly "Edit" for AppKit to treat it as the
        // standard editing menu.
        let editMenu = NSMenu(title: "Edit")
        // String selectors rather than #selector: `copy` collides with
        // NSObject.copy() and will not compile cleanly.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
