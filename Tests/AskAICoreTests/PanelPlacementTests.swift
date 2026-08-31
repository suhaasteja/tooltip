import Testing
import CoreGraphics
@testable import AskAICore

// A 1440x900 main display with the menu bar excluded, bottom-left origin.
private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)
// A second display sitting to the right, taller, offset upward.
private let rightScreen = CGRect(x: 1440, y: 100, width: 1920, height: 1080)

private let panel = CGSize(width: 360, height: 240)

@Suite("Panel placement")
struct PanelPlacementTests {

    @Test("hangs below-right of the pointer when there is room")
    func belowRightWhenRoomy() {
        let o = PanelPlacement.origin(
            pointer: CGPoint(x: 400, y: 600), panelSize: panel, screens: [mainScreen]
        )
        #expect(o.x == 400 + PanelPlacement.pointerGap)
        #expect(o.y == 600 - PanelPlacement.pointerGap - panel.height)
    }

    @Test("clamps left near the right edge instead of running off-screen")
    func clampsNearRightEdge() {
        let o = PanelPlacement.origin(
            pointer: CGPoint(x: 1430, y: 600), panelSize: panel, screens: [mainScreen]
        )
        #expect(o.x + panel.width <= mainScreen.maxX - PanelPlacement.screenMargin)
        // Flipped to the pointer's left, not merely nudged back.
        #expect(o.x < 1430)
    }

    @Test("flips above the pointer near the bottom edge")
    func clampsNearBottomEdge() {
        let o = PanelPlacement.origin(
            pointer: CGPoint(x: 400, y: 10), panelSize: panel, screens: [mainScreen]
        )
        #expect(o.y >= mainScreen.minY + PanelPlacement.screenMargin)
        #expect(o.y > 10)
    }

    @Test("stays inside the visible frame in every corner")
    func neverExceedsVisibleFrame() {
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1440, y: 0),
            CGPoint(x: 0, y: 875), CGPoint(x: 1440, y: 875),
            CGPoint(x: 720, y: 437),
        ]
        for p in corners {
            let o = PanelPlacement.origin(pointer: p, panelSize: panel, screens: [mainScreen])
            let r = CGRect(origin: o, size: panel)
            #expect(mainScreen.insetBy(dx: -0.001, dy: -0.001).contains(r),
                    "panel \(r) escaped \(mainScreen) for pointer \(p)")
        }
    }

    @Test("picks the screen containing the pointer, not the first one")
    func picksContainingScreen() {
        let o = PanelPlacement.origin(
            pointer: CGPoint(x: 3300, y: 900), panelSize: panel,
            screens: [mainScreen, rightScreen]
        )
        let r = CGRect(origin: o, size: panel)
        #expect(rightScreen.contains(r))
        #expect(!mainScreen.contains(r))
    }

    @Test("a pointer in the gap between displays snaps to the nearest")
    func fallsBackToNearestScreen() {
        // Below rightScreen's bottom edge (y=100) and past mainScreen's right.
        let found = PanelPlacement.screen(containing: CGPoint(x: 3000, y: 50),
                                          in: [mainScreen, rightScreen])
        #expect(found == rightScreen)
    }

    @Test("no screens means no clamping rather than a crash")
    func toleratesNoScreens() {
        let o = PanelPlacement.origin(
            pointer: CGPoint(x: 400, y: 600), panelSize: panel, screens: []
        )
        #expect(o.x == 412)
    }

    @Test("a panel bigger than the screen pins to the top-left, no NaN")
    func toleratesOversizePanel() {
        let huge = CGSize(width: 2000, height: 1400)
        let o = PanelPlacement.origin(
            pointer: CGPoint(x: 700, y: 400), panelSize: huge, screens: [mainScreen]
        )
        #expect(o.x == mainScreen.minX + PanelPlacement.screenMargin)
        #expect(o.y == mainScreen.minY + PanelPlacement.screenMargin)
    }
}

@Suite("Panel anchoring")
struct PanelAnchorTests {
    private let text = CGPoint(x: 400, y: 700)     // where the user right-clicked
    private let menu = CGPoint(x: 460, y: 520)     // where the pointer ended up

    @Test("a recent context-click wins over the live pointer")
    func prefersRecentClick() {
        // The right-click → Services → Ask AI path: the pointer is down in the
        // menu, but the selection is where the click happened.
        let point = PanelAnchor.anchor(
            lastRightClick: (point: text, age: 2), pointer: menu)
        #expect(point == text)
    }

    @Test("with no click at all, the live pointer is used")
    func fallsBackToPointer() {
        #expect(PanelAnchor.anchor(lastRightClick: nil, pointer: menu) == menu)
    }

    @Test("a stale click is ignored")
    func ignoresStaleClick() {
        let point = PanelAnchor.anchor(
            lastRightClick: (point: text, age: PanelAnchor.clickRecencyWindow + 1),
            pointer: menu)
        #expect(point == menu)
    }

    @Test("a click exactly at the window edge still counts")
    func boundaryIsInclusive() {
        let point = PanelAnchor.anchor(
            lastRightClick: (point: text, age: PanelAnchor.clickRecencyWindow),
            pointer: menu)
        #expect(point == text)
    }

    @Test("a negative age (clock skew) is not trusted")
    func rejectsNegativeAge() {
        let point = PanelAnchor.anchor(
            lastRightClick: (point: text, age: -5), pointer: menu)
        #expect(point == menu)
    }
}

@Suite("Bubble side")
struct BubbleSideTests {

    private let character: CGFloat = 56
    private let bubble: CGFloat = 300
    private let tail: CGFloat = 11

    private func side(atX x: CGFloat, screens: [CGRect] = [mainScreen]) -> BubbleSide {
        PanelPlacement.bubbleSide(
            anchor: CGPoint(x: x, y: 500),
            characterWidth: character, bubbleWidth: bubble, tailWidth: tail,
            screens: screens)
    }

    @Test("prefers the right when there is room")
    func prefersRight() {
        #expect(side(atX: 100) == .right)
        #expect(side(atX: 700) == .right)
    }

    @Test("flips left near the right edge")
    func flipsLeft() {
        // 1440 wide: a character plus tail plus gap plus a 300pt bubble cannot
        // fit to the right of x=1200.
        #expect(side(atX: 1200) == .left)
        #expect(side(atX: 1400) == .left)
    }

    @Test("stays right when the left is even tighter")
    func staysRightWhenLeftIsWorse() {
        // Hard against the left edge: neither side fits, but the right has more
        // room, so it should not flip into the screen edge.
        #expect(side(atX: 10) == .right)
    }

    @Test("no screens means no flipping")
    func noScreens() {
        #expect(side(atX: 99999, screens: []) == .right)
    }

    @Test("uses the display the anchor is actually on")
    func usesContainingScreen() {
        // x=1500 is near the LEFT edge of the second display, not the right
        // edge of the first, so there is plenty of room to the right.
        #expect(side(atX: 1500, screens: [mainScreen, rightScreen]) == .right)
        // Near the second display's right edge it must flip.
        #expect(side(atX: 3200, screens: [mainScreen, rightScreen]) == .left)
    }

    @Test("the flip boundary respects the screen margin")
    func flipBoundary() {
        let arm = tail + PanelPlacement.pointerGap + bubble
        // Exactly fits.
        let fits = mainScreen.maxX - PanelPlacement.screenMargin - arm - character
        #expect(side(atX: fits) == .right)
        // One point further right does not.
        #expect(side(atX: fits + 1) == .left)
    }
}

@Suite("Panel window placement at screen edges")
struct WindowOriginTests {

    private let gap = PanelPlacement.pointerGap
    private let margin = PanelPlacement.screenMargin

    /// Real geometry rather than an invented rect: where the character sits
    /// inside the window is exactly what decides whether clamping drags it off
    /// the user's word, so inventing it would test the wrong thing.
    private func geometry(side: BubbleSide) -> BubbleGeometry {
        BubbleLayout.geometry(
            bubbleSize: CGSize(width: 300, height: 140),
            characterSize: CGSize(width: 84, height: 66),
            tailSize: CGSize(width: 11, height: 18),
            side: side, gap: 4, inset: 22, tailDropFromTop: 26)
    }

    private var windowSize: CGSize { geometry(side: .right).windowSize }
    private var character: CGRect { geometry(side: .right).characterRect }

    private func place(
        _ anchor: CGPoint, side: BubbleSide = .right, screens: [CGRect] = [mainScreen]
    ) -> CGRect {
        let g = geometry(side: side)
        return CGRect(origin: PanelPlacement.windowOrigin(
            anchor: anchor, windowSize: g.windowSize,
            characterRect: g.characterRect, screens: screens),
                      size: g.windowSize)
    }

    /// Where the character lands on screen, given a placed window.
    private func characterOnScreen(_ window: CGRect, side: BubbleSide = .right) -> CGRect {
        let c = geometry(side: side).characterRect
        return CGRect(x: window.minX + c.minX, y: window.minY + c.minY,
                      width: c.width, height: c.height)
    }

    @Test("with room, the character hangs just below-right of the anchor")
    func defaultPlacement() {
        let anchor = CGPoint(x: 400, y: 600)
        let onScreen = characterOnScreen(place(anchor))
        #expect(onScreen.minX == anchor.x + gap)
        #expect(onScreen.maxY == anchor.y - gap)
    }

    /// The regression this replaced: reusing `origin` as a clamp flipped the
    /// window a full width to the left near the right edge, so the character
    /// ended up hundreds of points from the word it was explaining.
    @Test("near the right edge the character stays beside the anchor")
    func rightEdgeDoesNotThrowTheCharacterAway() {
        let anchor = CGPoint(x: mainScreen.maxX - 30, y: 600)
        // Near the right edge the bubble flips left, which is what the app does
        // via `bubbleSide` — so the character is on the window's right.
        let side = PanelPlacement.bubbleSide(
            anchor: anchor, characterWidth: 84, bubbleWidth: 300, tailWidth: 11,
            screens: [mainScreen])
        #expect(side == .left, "the bubble should have flipped")
        let window = place(anchor, side: side)
        let onScreen = characterOnScreen(window, side: side)
        #expect(window.maxX <= mainScreen.maxX - margin, "window left the screen")
        // Nudged, not flipped: still within a window's width of the anchor.
        let drift = abs(onScreen.midX - anchor.x)
        #expect(drift < 200, "character drifted \(drift)pt from the anchor")
    }

    @Test("near the left edge the window stays on screen")
    func leftEdge() {
        let window = place(CGPoint(x: mainScreen.minX + 4, y: 600))
        #expect(window.minX >= mainScreen.minX + margin)
    }

    /// Sliding up from the bottom would park the panel over the very text it is
    /// explaining, so it flips above the anchor instead.
    @Test("near the bottom edge the panel flips above the anchor")
    func bottomEdgeFlipsAbove() {
        let anchor = CGPoint(x: 400, y: mainScreen.minY + 40)
        let window = place(anchor)
        #expect(window.minY >= mainScreen.minY + margin, "window left the screen")
        #expect(window.minY >= anchor.y, "the whole panel should clear the anchor")
    }

    /// The bubble legitimately reaches above the character, so a top-edge anchor
    /// does not mean the window must sit entirely below it — only that it stays
    /// on screen and does not flip.
    @Test("near the top edge the panel stays on screen without flipping")
    func topEdgeStaysBelow() {
        let anchor = CGPoint(x: 400, y: mainScreen.maxY - 20)
        let window = place(anchor)
        #expect(window.maxY <= mainScreen.maxY - margin)
        #expect(window.minY < anchor.y, "should not have flipped above")
    }

    @Test("a corner is handled in both axes at once")
    func bottomRightCorner() {
        let window = place(CGPoint(x: mainScreen.maxX - 20, y: mainScreen.minY + 20))
        #expect(window.maxX <= mainScreen.maxX - margin)
        #expect(window.minY >= mainScreen.minY + margin)
        #expect(window.minX >= mainScreen.minX + margin)
    }

    @Test("the window is placed on the display the anchor is on")
    func usesTheAnchorsScreen() {
        let anchor = CGPoint(x: 2000, y: 800)      // second display
        let window = place(anchor, screens: [mainScreen, rightScreen])
        #expect(window.minX >= rightScreen.minX)
        #expect(window.maxX <= rightScreen.maxX)
    }

    @Test("a window taller than the screen is pinned rather than lost")
    func tallerThanScreen() {
        let huge = CGSize(width: 420, height: mainScreen.height + 400)
        let origin = PanelPlacement.windowOrigin(
            anchor: CGPoint(x: 400, y: 500), windowSize: huge,
            characterRect: character, screens: [mainScreen])
        let window = CGRect(origin: origin, size: huge)
        // Cannot fit, so the top is what stays visible: the character and the
        // start of the answer matter more than the end.
        #expect(window.maxY <= mainScreen.maxY - margin + 0.01)
    }

    @Test("no screens means no clamping")
    func noScreens() {
        let anchor = CGPoint(x: 5000, y: 5000)
        let onScreen = characterOnScreen(place(anchor, screens: []))
        #expect(onScreen.minX == anchor.x + gap)
    }

    @Test("clamped moves a rect the minimum distance")
    func clampIsMinimal() {
        let rect = CGRect(x: mainScreen.maxX - 100, y: 400, width: 420, height: 220)
        let result = PanelPlacement.clamped(
            rect, toScreenContaining: CGPoint(x: 400, y: 400), screens: [mainScreen])
        #expect(result.maxX == mainScreen.maxX - margin)
        #expect(result.minY == rect.minY, "y should not have moved")
    }
}
