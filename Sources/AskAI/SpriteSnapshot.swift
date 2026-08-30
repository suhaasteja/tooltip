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

        for (name, state) in states {
            let model = PanelModel()
            drive(model, to: state)
            if let png = render(model: model) {
                write(png, to: "\(directory)/state-\(name).png")
            }
        }

        // Every frame of the thinking loop, to check the cycle reads as motion
        // and that no frame is misaligned.
        for index in 0..<SpriteMood.thinking.animation.frames.count {
            let model = PanelModel()
            drive(model, to: .loading(selection: "Checking the walk cycle."))
            model.animator.showFrame(at: index)
            if let png = render(model: model) {
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

    /// Draws the SwiftUI content into a bitmap.
    ///
    /// On an opaque backdrop rather than transparency: `NSVisualEffectView`
    /// samples what is behind the window, which offscreen is nothing, so the
    /// real panel's vibrancy cannot be captured this way. A flat panel-ish grey
    /// is an honest stand-in for checking layout and the character, and is not
    /// a claim about the final material.
    private static func render(model: PanelModel) -> Data? {
        let view = NSHostingView(rootView: ResultPanelView(model: model))
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }

        // Fill the backdrop first; cacheDisplay draws the view over it.
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
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
