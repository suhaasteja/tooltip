import AppKit
import AskAICore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let serviceProvider = ServiceProvider()

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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
