import AppKit
import SwiftUI
import AskAICore

/// Hosts `SettingsView` in a standard window.
///
/// Unlike the result panel, this window *should* activate: the user chose it
/// from the menu bar and needs to type into it. An `.accessory` app can't
/// normally take focus, so activation is requested explicitly.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let model: SettingsModel
    private let sprites: SpriteStudioModel

    init(model: SettingsModel, sprites: SpriteStudioModel) {
        self.model = model
        self.sprites = sprites
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AskAI Settings"
            window.contentView = NSHostingView(
                rootView: SettingsView(model: model, sprites: sprites))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        // Pick up characters installed since the window was last opened, and
        // restart the preview that windowWillClose stopped.
        sprites.refreshSets()
        sprites.refreshPreview()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drop back to accessory behaviour once the window closes so the app does
    /// not linger as the active application with nothing on screen.
    func windowWillClose(_ notification: Notification) {
        // Stop the preview timer: a character animating in a window nobody can
        // see is exactly the battery cost the panel is careful to avoid.
        sprites.stopPreview()
        NSApp.hide(nil)
    }
}
