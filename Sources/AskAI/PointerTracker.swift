import AppKit
import AskAICore

/// Remembers where the user last opened a context menu.
///
/// Needed because by the time a Services invocation reaches us, the pointer has
/// moved off the selected text and into the menu. See `PanelAnchor`.
///
/// Mouse-only global monitors do **not** require the Accessibility permission
/// (keyboard ones would), so this stays sandbox-friendly and prompts for
/// nothing.
final class PointerTracker {

    private var lastRightClick: (point: CGPoint, at: Date)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            // Control-click is the other way to open a context menu, and
            // arrives as a left-click with the modifier set.
            let isContextClick = event.type == .rightMouseDown
                || event.modifierFlags.contains(.control)
            guard isContextClick else { return }
            let point = NSEvent.mouseLocation
            self?.lastRightClick = (point, Date())
            Log.panel.debug("context click at y=\(Int(point.y), privacy: .public)")
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Best guess at where the user's attention is.
    var anchor: CGPoint {
        let recent = lastRightClick.map {
            (point: $0.point, age: Date().timeIntervalSince($0.at))
        }
        return PanelAnchor.anchor(lastRightClick: recent, pointer: NSEvent.mouseLocation)
    }
}
