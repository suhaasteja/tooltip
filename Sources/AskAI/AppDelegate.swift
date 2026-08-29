import AppKit
import AskAICore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let serviceProvider = ServiceProvider()
    let resultPanel = ResultPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        installServicesProvider()
        Log.app.notice("AskAI launched (core \(AskAICore.version, privacy: .public))")
    }

    private func installServicesProvider() {
        // Held as a stored property: `servicesProvider` is an unowned reference,
        // so a temporary here would be deallocated and invocations would go
        // nowhere.
        NSApp.servicesProvider = serviceProvider
        // Forces an immediate rescan so a freshly installed/re-signed bundle is
        // picked up without logging out.
        NSUpdateDynamicServices()
        Log.app.notice("services provider registered")
    }

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
        // Temporary, for Stage 3 manual verification. Removed in Stage 8.
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
        let sample = "Placeholder selection — the quick brown fox jumps over the lazy dog."
        let id = resultPanel.machine.startLoading(selection: sample)
        resultPanel.show()
        // Fake a reply so the loading -> success transition is observable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.resultPanel.machine.finish(
                requestID: id,
                answer: """
                    This is placeholder panel content. It should appear at the \
                    pointer, float above other apps, leave the frontmost app \
                    active, and dismiss on Escape or a click outside.
                    """
            )
            self.resultPanel.resizeToFit()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
