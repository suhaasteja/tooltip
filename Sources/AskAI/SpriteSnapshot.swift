import AppKit
import SwiftUI
import AskAICore

/// Renders the panel's contents to PNGs, offscreen.
///
/// Exists because the obvious way to check how the panel looks -- take a
/// screenshot -- needs the Screen Recording permission, and this project
/// deliberately avoids TCC prompts (PLAN.md Stage 9). Drawing our own view into
/// our own bitmap needs no permission at all, and unlike a screenshot it is
/// deterministic: same states, same frames, every run.
///
/// `ASKAI_SPRITE_SNAPSHOT=<directory> dist/AskAI.app/Contents/MacOS/AskAI`
enum SpriteSnapshot {

    /// Renders one image per panel state, plus the walk cycle frame by frame,
    /// then exits.
    static func run(into directory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let states: [(String, PanelState)] = [
            ("loading", .loading(selection: "The mitochondria is the powerhouse of the cell.")),
            ("success", .success(
                selection: "The mitochondria is the powerhouse of the cell.",
                answer: "Mitochondria generate most of the chemical energy a cell needs, "
                    + "which is why they get called its powerhouse.")),
            ("failure", .failure(
                selection: "x", message: "Rate limited. Try again in a moment.",
                retryable: true)),
            ("empty", .emptySelection),
        ]

        // Both sides for every state: the tail direction is the thing most
        // likely to be wrong, and it is only exercised near a screen edge in
        // real use.
        for (name, state) in states {
            for side in [BubbleSide.right, .left] {
                let model = PanelModel()
                drive(model, to: state)
                if let png = render(model: model, side: side) {
                    write(png, to: "\(directory)/state-\(name)-\(side.rawValue).png")
                }
            }
        }

        // Every frame of the thinking loop, to check the cycle reads as motion
        // and that no frame is misaligned.
        for index in 0..<SpriteSet.builtIn.animation(for: .thinking).frames.count {
            let model = PanelModel()
            drive(model, to: .loading(selection: "Checking the walk cycle."))
            model.animator.showFrame(at: index)
            if let png = render(model: model, side: .right) {
                write(png, to: "\(directory)/walk-\(index).png")
            }
        }

        print("==> snapshots written to \(directory)")
        NSApp.terminate(nil)
    }

    private static func drive(_ model: PanelModel, to state: PanelState) {
        switch state {
        case .loading(let selection):
            model.machine.startLoading(selection: selection)
        case .success(let selection, let answer):
            let id = model.machine.startLoading(selection: selection)
            model.machine.finish(requestID: id, answer: answer)
        case .failure(let selection, let message, let retryable):
            let id = model.machine.startLoading(selection: selection)
            model.machine.fail(requestID: id, message: message, retryable: retryable)
        case .emptySelection:
            model.machine.showEmptySelection()
        case .idle:
            model.machine.reset()
        }
    }

    /// Composes character, tail and bubble exactly as `ResultPanel` does, and
    /// draws the result into a bitmap.
    ///
    /// Shares `BubbleLayout.geometry` with the real panel rather than
    /// re-deriving the arrangement, so a snapshot that looks right is evidence
    /// about the shipping layout and not about a copy of it.
    ///
    /// Two honest limitations:
    ///
    /// * `NSVisualEffectView` samples what is behind the *window*, and offscreen
    ///   there is nothing, so the bubble is filled flat here. These images say
    ///   nothing about the real material.
    /// * The window backdrop is drawn opaque so the transparent regions are
    ///   visible as a rectangle. In use those regions are see-through and pass
    ///   clicks through (`ShapedContainer`).
    private static func render(model: PanelModel, side: BubbleSide) -> Data? {
        let bubbleHost = NSHostingView(rootView: ResultPanelView(model: model))
        bubbleHost.layoutSubtreeIfNeeded()
        let bubbleSize = NSSize(width: ResultPanelView.width,
                                height: max(bubbleHost.fittingSize.height, 44))

        let geometry = BubbleLayout.geometry(
            bubbleSize: bubbleSize,
            characterSize: CGSize(width: PanelChrome.characterWidth,
                                  height: PanelChrome.characterHeight),
            tailSize: CGSize(width: PanelChrome.tailWidth,
                             height: PanelChrome.tailHeight),
            side: side,
            gap: PanelChrome.gap,
            inset: PanelChrome.shadowInset,
            tailDropFromTop: PanelChrome.tailDropFromTop)

        let container = NSView(frame: NSRect(origin: .zero, size: geometry.windowSize))

        // Stand-in for the vibrancy, which cannot render offscreen.
        let card = NSView(frame: geometry.bubbleRect)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        container.addSubview(card)

        let tail = NSHostingView(rootView: TailView(side: side))
        tail.frame = geometry.tailRect
        container.addSubview(tail)

        bubbleHost.frame = geometry.bubbleRect
        container.addSubview(bubbleHost)

        let character = NSHostingView(
            rootView: SpriteView(animator: model.animator,
                                 height: PanelChrome.characterHeight))
        character.frame = geometry.characterRect
        container.addSubview(character)

        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)
        else { return nil }

        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor(calibratedWhite: 0.32, alpha: 1).setFill()
            container.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func write(_ data: Data, to path: String) {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("   \(URL(fileURLWithPath: path).lastPathComponent)")
        } catch {
            print("!! failed to write \(path): \(error)")
        }
    }
}
