import CoreGraphics

/// Where the character, tail and bubble sit inside the panel window.
///
/// All rects are in the window's own coordinate space, AppKit style: bottom-left
/// origin, y growing upward.
public struct BubbleGeometry: Equatable, Sendable {
    public let windowSize: CGSize
    public let characterRect: CGRect
    public let bubbleRect: CGRect
    public let tailRect: CGRect

    public init(windowSize: CGSize, characterRect: CGRect,
                bubbleRect: CGRect, tailRect: CGRect) {
        self.windowSize = windowSize
        self.characterRect = characterRect
        self.bubbleRect = bubbleRect
        self.tailRect = tailRect
    }
}

/// Lays out a speech bubble beside a character.
///
/// Pure, so the arrangement can be tested by asserting on rectangles instead of
/// by looking at a window --- which matters here because the failure modes are
/// quiet: a tail one point off its bubble, or a character that drifts by a pixel
/// between frames, are invisible in a passing build and obvious in use.
///
/// Internally the arrangement is described top-down, because that is how the
/// pieces actually relate: the bubble's top edge is the datum and the tail hangs
/// a fixed distance below it. The whole thing is flipped into AppKit's
/// bottom-left space exactly once, at the end.
/// Whether the panel sits below the anchor or above it.
public enum BubbleVerticalSide: String, Equatable, Sendable {
    case below
    case above
}

public enum BubbleLayout {

    /// - Parameter verticalSide: which way the bubble grows away from the
    ///   character. `.below` hangs it under the anchor, with the tail near the
    ///   bubble's top; `.above` mirrors that so the bubble grows upward, which
    ///   is what a selection near the bottom of the screen needs. Without the
    ///   mirror the bubble still reaches down past the character, there is no
    ///   room for it, and the clamp shoves the whole panel up — leaving the
    ///   character floating far above the word.
    public static func geometry(
        bubbleSize: CGSize,
        characterSize: CGSize,
        tailSize: CGSize,
        side: BubbleSide,
        gap: CGFloat,
        inset: CGFloat,
        tailDropFromTop: CGFloat,
        verticalSide: BubbleVerticalSide = .below
    ) -> BubbleGeometry {

        let arm = gap + tailSize.width

        // The character straddles the tail so it reads as the speaker: its
        // vertical middle lines up with where the tail meets the bubble. For a
        // short drop this puts its head above the bubble's top edge, which is
        // why the union below can start at a negative y.
        //
        // Flipped, the tail attaches the same distance from the bubble's BOTTOM,
        // so the bubble extends upward and the character still sits at the end
        // nearest the anchor.
        let tailCentre = verticalSide == .below
            ? tailDropFromTop
            : bubbleSize.height - tailDropFromTop
        let characterY = tailCentre - characterSize.height / 2

        let top = min(0, characterY)
        let bottom = max(bubbleSize.height, characterY + characterSize.height)
        let contentHeight = bottom - top
        let contentWidth = characterSize.width + arm + bubbleSize.width

        let characterX: CGFloat = side == .right ? 0 : bubbleSize.width + arm
        let bubbleX: CGFloat = side == .right ? characterSize.width + arm : 0
        // One point of overlap so no seam shows between tail and bubble.
        let tailX: CGFloat = side == .right
            ? bubbleX - tailSize.width + 1
            : bubbleX + bubbleSize.width - 1

        func flip(_ y: CGFloat, _ height: CGFloat) -> CGFloat {
            inset + contentHeight - (y - top) - height
        }

        return BubbleGeometry(
            windowSize: CGSize(width: contentWidth + inset * 2,
                               height: contentHeight + inset * 2),
            characterRect: CGRect(
                x: inset + characterX, y: flip(characterY, characterSize.height),
                width: characterSize.width, height: characterSize.height),
            bubbleRect: CGRect(
                x: inset + bubbleX, y: flip(0, bubbleSize.height),
                width: bubbleSize.width, height: bubbleSize.height),
            tailRect: CGRect(
                x: inset + tailX,
                y: flip(tailCentre - tailSize.height / 2, tailSize.height),
                width: tailSize.width, height: tailSize.height))
    }
}
