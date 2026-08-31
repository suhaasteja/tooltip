import CoreGraphics

/// Which side of the character the speech bubble hangs on.
///
/// The tail has to point back at the character, so this is not a private
/// rendering detail -- placement decides it and the view has to follow.
public enum BubbleSide: String, Equatable, Sendable {
    case right
    case left
}

/// Screen-coordinate math for positioning the result panel at the pointer.
///
/// Pure and screen-agnostic so it can be unit tested with synthetic rects — the
/// caller supplies `NSScreen.screens.map(\.visibleFrame)`.
///
/// Coordinates are AppKit's: **bottom-left origin**, y growing upward, with all
/// displays in one continuous space (so a second monitor above or left of the
/// main one yields negative coordinates). PLAN.md appendix #7.
public enum PanelPlacement {

    /// Gap between the pointer and the panel's nearest corner.
    public static let pointerGap: CGFloat = 12
    /// Minimum breathing room between the panel and the screen edge.
    public static let screenMargin: CGFloat = 8

    /// Returns the bottom-left origin for a panel of `panelSize` shown at `pointer`.
    ///
    /// The panel is preferentially hung below-right of the pointer (matching the
    /// direction a cursor "points"), then clamped so it never leaves the visible
    /// frame of whichever screen contains the pointer.
    ///
    /// - Parameters:
    ///   - pointer: Pointer location, e.g. `NSEvent.mouseLocation`.
    ///   - panelSize: The panel's size.
    ///   - screens: Visible frames of all screens. Empty means "no clamping".
    /// - Returns: The origin to assign to the panel's frame.
    public static func origin(
        pointer: CGPoint,
        panelSize: CGSize,
        screens: [CGRect],
        gap: CGFloat = pointerGap,
        margin: CGFloat = screenMargin
    ) -> CGPoint {
        // Preferred placement: below and to the right of the pointer.
        var x = pointer.x + gap
        var y = pointer.y - gap - panelSize.height

        guard let frame = screen(containing: pointer, in: screens) else {
            return CGPoint(x: x, y: y)
        }

        // If the panel would overflow the right edge, flip it to the pointer's
        // left rather than merely sliding it back — sliding would park the panel
        // on top of the cursor and the text under it.
        if x + panelSize.width > frame.maxX - margin {
            x = pointer.x - gap - panelSize.width
        }
        // Same idea vertically: flip above the pointer before clamping.
        if y < frame.minY + margin {
            y = pointer.y + gap
        }

        // Final hard clamp. Also handles a panel larger than the screen, where
        // the flips above cannot help: pin to the top-left of the visible frame
        // rather than letting it drift off-screen.
        x = clamp(x, lower: frame.minX + margin, upper: frame.maxX - margin - panelSize.width)
        y = clamp(y, lower: frame.minY + margin, upper: frame.maxY - margin - panelSize.height)

        return CGPoint(x: x, y: y)
    }

    /// Which side of the character the bubble should hang on.
    ///
    /// Prefers the right, matching reading direction and the way the panel has
    /// always hung below-right of the pointer. Flips left when the bubble would
    /// overflow the screen's right edge. When neither side fits -- a bubble
    /// wider than the room on either flank -- it picks the roomier one, because
    /// the final clamp will slide the window back on-screen and the side with
    /// more space is the one that ends up covering less of the selection.
    ///
    /// Pure and screen-agnostic for the same reason as `origin`: the flip rule
    /// is the part worth testing, and it should not need a second display to
    /// exercise.
    ///
    /// - Parameters:
    ///   - anchor: Where the character will sit (the user's context click).
    ///   - characterWidth: Width of the character.
    ///   - bubbleWidth: Width of the bubble.
    ///   - tailWidth: Width of the tail between them.
    public static func bubbleSide(
        anchor: CGPoint,
        characterWidth: CGFloat,
        bubbleWidth: CGFloat,
        tailWidth: CGFloat,
        screens: [CGRect],
        gap: CGFloat = pointerGap,
        margin: CGFloat = screenMargin
    ) -> BubbleSide {
        guard let frame = screen(containing: anchor, in: screens) else { return .right }

        let arm = tailWidth + gap + bubbleWidth
        let rightEdge = anchor.x + characterWidth + arm
        let leftEdge = anchor.x - arm

        let fitsRight = rightEdge <= frame.maxX - margin
        if fitsRight { return .right }

        let fitsLeft = leftEdge >= frame.minX + margin
        if fitsLeft { return .left }

        // Neither fits: take the flank with more room.
        let roomRight = (frame.maxX - margin) - (anchor.x + characterWidth)
        let roomLeft = anchor.x - (frame.minX + margin)
        return roomRight >= roomLeft ? .right : .left
    }

    /// The visible frame containing `point`, or the nearest one if the pointer
    /// sits in a gap between mismatched displays.
    public static func screen(containing point: CGPoint, in screens: [CGRect]) -> CGRect? {
        if let hit = screens.first(where: { $0.contains(point) }) { return hit }
        return screens.min { a, b in
            squaredDistance(from: point, to: a) < squaredDistance(from: point, to: b)
        }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Clamps `value` into `lower...upper`, tolerating an inverted range.
    ///
    /// The range inverts when the panel is wider or taller than the visible
    /// frame; `min(max())` would then return the wrong bound, so prefer `lower`
    /// (top-left pinned, overflow off the far edge where content is less likely
    /// to be missed).
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}

// MARK: - Placing the whole panel around its character

public extension PanelPlacement {

    /// Moves a rect the **minimum** distance needed to sit inside a screen.
    ///
    /// Distinct from `origin`, which flips the panel to the other side of the
    /// pointer when it would overflow. That is right when the panel is placed
    /// relative to a cursor, and wrong here: this panel is anchored to a
    /// character that must stay next to the user's text, so overflow should
    /// nudge it, not throw it a full window's width away.
    static func clamped(
        _ rect: CGRect, toScreenContaining anchor: CGPoint,
        screens: [CGRect], margin: CGFloat = screenMargin
    ) -> CGRect {
        guard let frame = screen(containing: anchor, in: screens) else { return rect }
        var result = rect

        // Push in from whichever edge overflows. If the panel is wider or taller
        // than the screen, prefer showing its top-left: the character and the
        // start of the answer matter more than the end.
        if result.maxX > frame.maxX - margin {
            result.origin.x = frame.maxX - margin - result.width
        }
        if result.minX < frame.minX + margin {
            result.origin.x = frame.minX + margin
        }
        if result.minY < frame.minY + margin {
            result.origin.y = frame.minY + margin
        }
        if result.maxY > frame.maxY - margin {
            result.origin.y = frame.maxY - margin - result.height
        }
        return result
    }

    /// Where to put a panel window so its character sits beside `anchor`.
    ///
    /// The character hangs below the anchor, matching the direction a cursor
    /// points. When the window will not fit below — the selection is near the
    /// bottom of the screen — it flips *above* instead, which is a deliberate
    /// choice rather than the accidental one `origin` used to make: sliding a
    /// panel up from the bottom edge would park it over the very text it is
    /// explaining.
    ///
    /// - Parameters:
    ///   - characterRect: the character's rect **in window coordinates**.
    static func windowOrigin(
        anchor: CGPoint,
        windowSize: CGSize,
        characterRect: CGRect,
        screens: [CGRect],
        gap: CGFloat = pointerGap,
        margin: CGFloat = screenMargin
    ) -> CGPoint {

        let x = anchor.x + gap - characterRect.minX

        // Below: the character's top sits `gap` under the anchor. The bubble may
        // reach higher than the character, which is fine — it is off to the side,
        // not over the text.
        let below = CGRect(
            x: x,
            y: (anchor.y - gap - characterRect.height) - characterRect.minY,
            width: windowSize.width, height: windowSize.height)

        // Above: the whole *window* clears the anchor, not just the character.
        // Anchoring the character instead would leave the bubble hanging back
        // down over the selection, which is the thing this flip exists to avoid.
        let above = CGRect(
            x: x, y: anchor.y + gap,
            width: windowSize.width, height: windowSize.height)

        guard let frame = screen(containing: anchor, in: screens) else {
            return below.origin
        }

        func fitsVertically(_ rect: CGRect) -> Bool {
            rect.minY >= frame.minY + margin && rect.maxY <= frame.maxY - margin
        }

        let chosen: CGRect
        if fitsVertically(below) {
            chosen = below
        } else if fitsVertically(above) {
            chosen = above
        } else {
            // Neither fits, so the window is taller than the room either side of
            // the anchor. Take the side with more space and let the clamp trim.
            let roomBelow = anchor.y - (frame.minY + margin)
            let roomAbove = (frame.maxY - margin) - anchor.y
            chosen = roomBelow >= roomAbove ? below : above
        }

        return clamped(chosen, toScreenContaining: anchor,
                       screens: screens, margin: margin).origin
    }
}
