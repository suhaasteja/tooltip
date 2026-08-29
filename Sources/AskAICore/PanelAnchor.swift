import Foundation
import CoreGraphics

/// Chooses the screen point the panel should be anchored to.
///
/// The naive answer — "wherever the pointer is when the service fires" — is
/// wrong for the most common invocation path. Going
/// right-click → Services → Ask AI drags the pointer well below the selected
/// text, so the panel lands over the menu instead of over what the user
/// selected.
///
/// The right-click that *opened* that menu, however, was on the text. So a
/// recent right-click is a much better anchor than the live pointer, and the
/// keyboard-shortcut path (where no click happened) falls back to the pointer.
///
/// Pure so the heuristic is testable without an event stream.
public enum PanelAnchor {

    /// How long a right-click stays a plausible anchor.
    ///
    /// Generous enough to cover browsing into a nested Services submenu, short
    /// enough that an unrelated right-click from minutes ago is not reused.
    public static let clickRecencyWindow: TimeInterval = 30

    /// - Parameters:
    ///   - lastRightClick: Where the user last opened a context menu, and how
    ///     long ago in seconds. `nil` if they never have.
    ///   - pointer: The live pointer location.
    public static func anchor(
        lastRightClick: (point: CGPoint, age: TimeInterval)?,
        pointer: CGPoint,
        window: TimeInterval = clickRecencyWindow
    ) -> CGPoint {
        guard let click = lastRightClick, click.age >= 0, click.age <= window else {
            return pointer
        }
        return click.point
    }
}
