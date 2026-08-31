import AppKit
import SwiftUI
import AskAICore

/// The panel's content view once the character moved outside the card.
///
/// Load-bearing, and the reason this layout is possible at all. The window now
/// spans the character *and* the bubble, so most of its rect is empty --- and a
/// plain `NSView` claims every point in its bounds. Without this the panel would
/// swallow clicks meant for the app the user is reading, and the dismiss rule in
/// `ResultPanel` (`event.window !== panel`) would report "inside the panel" for
/// a click on empty air.
///
/// Returning nil hands the click to the window underneath. The app's existing
/// global mouse monitor still sees it, so "click outside dismisses" keeps
/// working with no extra code --- the correct behaviour falls out.
final class ShapedContainer: NSView {

    /// Rects, in this view's coordinates, that should accept clicks. Everything
    /// outside them is transparent to the mouse.
    var interactiveRects: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space.
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
}

/// The little triangle joining bubble to character.
///
/// Drawn as its own hosting view rather than as part of the bubble so the
/// bubble can keep a plain rounded-rect `NSVisualEffectView` behind it with
/// `masksToBounds`, which would otherwise clip the tail off.
struct TailShape: Shape {
    let side: BubbleSide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch side {
        case .right:
            // Bubble is to the right, so the tail points left at the character.
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .left:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Fills the tail with the same material as the bubble.
///
/// `.regularMaterial` here is not the vibrancy --- SwiftUI's materials build no
/// `NSVisualEffectView` at all (verified; see NOTES.md), so the bubble's blur
/// comes from a real effect view behind it. For a shape this small a material
/// fill is a close enough match at the join, and avoids a second effect view
/// with a triangular mask.
struct TailView: View {
    let side: BubbleSide

    var body: some View {
        TailShape(side: side)
            .fill(.regularMaterial)
            .accessibilityHidden(true)
    }
}

/// Fixed geometry for the character-and-bubble layout.
enum PanelChrome {
    /// Bubble text column. Narrower than the old 380pt card because the
    /// character now sits beside it rather than inside it.
    static let bubbleWidth: CGFloat = 300
    /// Fallback only. The real slot comes from the active character's frames —
    /// see `SpriteLoader.frameSize(for:fallback:)`. Frames differ in shape from
    /// one generated character to the next, and a fixed slot letterboxes them.
    static let characterHeight: CGFloat = 66
    static let characterWidth: CGFloat = 84
    static let tailWidth: CGFloat = 11
    static let tailHeight: CGFloat = 18
    /// Space between the character and the tail.
    static let gap: CGFloat = 4
    /// Transparent margin around everything, so the window's alpha-derived
    /// shadow has somewhere to draw instead of being clipped at the frame.
    static let shadowInset: CGFloat = 22
    /// How far below the bubble's top edge the tail sits, so it points at the
    /// character's head rather than its feet.
    static let tailDropFromTop: CGFloat = 26
}
