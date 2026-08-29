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
