import Testing
import CoreGraphics
@testable import AskAICore

@Suite("Bubble geometry")
struct BubbleGeometryTests {

    private let bubble = CGSize(width: 300, height: 120)
    private let character = CGSize(width: 56, height: 72)
    private let tail = CGSize(width: 11, height: 18)
    private let gap: CGFloat = 4
    private let inset: CGFloat = 22
    private let drop: CGFloat = 26

    private func geometry(
        side: BubbleSide, bubbleSize: CGSize? = nil
    ) -> BubbleGeometry {
        BubbleLayout.geometry(
            bubbleSize: bubbleSize ?? bubble, characterSize: character, tailSize: tail,
            side: side, gap: gap, inset: inset, tailDropFromTop: drop)
    }

    @Test("character is left of the bubble on the right side, and vice versa")
    func sidesSwap() {
        let right = geometry(side: .right)
        #expect(right.characterRect.maxX <= right.bubbleRect.minX)

        let left = geometry(side: .left)
        #expect(left.characterRect.minX >= left.bubbleRect.maxX)
    }

    /// The whole point of the tail. If it drifts off the bubble the join shows
    /// as a floating triangle, which a build will never complain about.
    @Test("the tail touches the bubble on both sides")
    func tailTouchesBubble() {
        for side in [BubbleSide.right, .left] {
            let g = geometry(side: side)
            let touches = abs(g.tailRect.maxX - g.bubbleRect.minX) <= 1
                || abs(g.tailRect.minX - g.bubbleRect.maxX) <= 1
            #expect(touches, "\(side): tail \(g.tailRect) detached from \(g.bubbleRect)")
        }
    }

    @Test("the tail sits between character and bubble, never overlapping the character")
    func tailIsBetween() {
        let right = geometry(side: .right)
        #expect(right.tailRect.minX >= right.characterRect.maxX - 1)

        let left = geometry(side: .left)
        #expect(left.tailRect.maxX <= left.characterRect.minX + 1)
    }

    @Test("the tail lines up with the character's vertical middle")
    func tailAlignsWithCharacter() {
        let g = geometry(side: .right)
        #expect(abs(g.tailRect.midY - g.characterRect.midY) < 0.01)
    }

    @Test("the tail hangs the requested distance below the bubble's top")
    func tailDrop() {
        let g = geometry(side: .right)
        #expect(abs((g.bubbleRect.maxY - g.tailRect.midY) - drop) < 0.01)
    }

    @Test("everything fits inside the window with the inset preserved")
    func everythingFits() {
        for side in [BubbleSide.right, .left] {
            for height in [CGFloat(44), 120, 420] {
                let g = geometry(side: side,
                                 bubbleSize: CGSize(width: 300, height: height))
                let bounds = CGRect(origin: .zero, size: g.windowSize)
                for (name, rect) in [("character", g.characterRect),
                                     ("bubble", g.bubbleRect),
                                     ("tail", g.tailRect)] {
                    #expect(bounds.contains(rect),
                            "\(side)/\(height): \(name) \(rect) escapes \(g.windowSize)")
                    #expect(rect.minX >= inset - 1, "\(name) breaks the left inset")
                    #expect(rect.minY >= inset - 1, "\(name) breaks the bottom inset")
                }
            }
        }
    }

    /// A short bubble is the case where the character is taller than the card,
    /// so its head pokes above the top and the window has to grow to hold it.
    @Test("a short bubble still leaves room for the character")
    func shortBubble() {
        let g = geometry(side: .right, bubbleSize: CGSize(width: 300, height: 44))
        #expect(g.windowSize.height >= character.height + inset * 2)
        #expect(CGRect(origin: .zero, size: g.windowSize).contains(g.characterRect))
    }

    /// Streaming grows the bubble on every delta. The character must not move
    /// relative to the window's bottom-left as it does, or it will jitter.
    @Test("growing the bubble does not move the character's offset from the top")
    func characterStableWhileBubbleGrows() {
        let small = geometry(side: .right, bubbleSize: CGSize(width: 300, height: 60))
        let large = geometry(side: .right, bubbleSize: CGSize(width: 300, height: 400))
        // Distance from the window's top edge is what the caller pins.
        let smallDrop = small.windowSize.height - small.characterRect.maxY
        let largeDrop = large.windowSize.height - large.characterRect.maxY
        #expect(abs(smallDrop - largeDrop) < 0.01)
    }

    @Test("window width covers character, gap, tail and bubble")
    func windowWidth() {
        let g = geometry(side: .right)
        let expected = character.width + gap + tail.width + bubble.width + inset * 2
        #expect(abs(g.windowSize.width - expected) < 0.01)
    }
}
