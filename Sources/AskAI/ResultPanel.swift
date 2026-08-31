import AppKit
import SwiftUI
import Combine
import AskAICore

/// Borderless, non-activating floating panel shown at the pointer.
///
/// Not an `NSPopover`: popovers anchor to a view in your own window hierarchy,
/// and this app has no window on screen when the service fires — the selection
/// lives in another process entirely. A panel positioned in screen coordinates
/// is the right primitive.
final class ResultPanel: NSObject {

    private let model = PanelModel()
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var onRetry: ((String) -> Void)? {
        get { model.onRetry }
        set { model.onRetry = newValue }
    }

    /// The state machine driving the panel. Callers mutate this.
    var machine: PanelViewModel { model.machine }

    /// Swaps the character. Safe while the panel is visible.
    func use(spriteSet: SpriteSet) {
        model.animator.use(spriteSet)
        if panel != nil { layout() }
    }

    /// The character's slot, taken from its own frames.
    ///
    /// Sized to the art rather than to a constant, so nothing is letterboxed.
    /// A fixed slot put ~14pt of dead space above the character, which reads as
    /// the panel hovering further from the selected text than it does.
    private var characterSize: CGSize {
        SpriteLoader.frameSize(
            for: model.animator.set,
            fallback: CGSize(width: PanelChrome.characterWidth,
                             height: PanelChrome.characterHeight))
    }

    private var stateObserver: AnyCancellable?

    override init() {
        super.init()
        model.onDismiss = { [weak self] in self?.hide() }

        // Grow/shrink with the content: loading -> answer changes the height,
        // and later streaming changes it on every delta. Deferred by one
        // runloop turn so SwiftUI has laid out the new content before the
        // fitting size is measured.
        stateObserver = model.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeToFit() }
    }

    // MARK: - Presentation

    /// Shows the panel at the current pointer location, or repositions it if
    /// already visible.
    func show(at pointer: CGPoint = NSEvent.mouseLocation) {
        let t0 = DispatchTime.now()
        let panel = existingOrNewPanel()
        let tPanel = DispatchTime.now()

        // The side is chosen once per presentation, not per layout pass: a
        // bubble that flipped sides mid-answer because it grew a line would be
        // jarring, and the character would appear to jump across the text.
        let characterSize = self.characterSize
        side = PanelPlacement.bubbleSide(
            anchor: pointer,
            characterWidth: characterSize.width,
            bubbleWidth: ResultPanelView.width,
            tailWidth: PanelChrome.tailWidth,
            screens: visibleFrames())

        // Where the character should sit, in screen coordinates. Everything
        // else is laid out around it, and it stays put for the whole
        // presentation -- see `layout()`.
        characterOrigin = CGPoint(
            x: pointer.x + PanelPlacement.pointerGap,
            y: pointer.y - PanelPlacement.pointerGap - characterSize.height)

        layout()
        let tLayout = DispatchTime.now()

        // `.accessory` apps have no active window to order against, so an
        // ordinary `orderFront` can be ignored. PLAN.md Stage 4.
        panel.orderFrontRegardless()
        let tOrder = DispatchTime.now()
        // Safe with `.nonactivatingPanel`: the panel takes key status for
        // Escape/scrolling without activating AskAI, so the frontmost app keeps
        // its active title bar and, critically, its selection.
        panel.makeKey()
        let tKey = DispatchTime.now()

        installDismissMonitors()

        func ms(_ a: DispatchTime, _ b: DispatchTime) -> Double {
            Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000
        }
        Log.panel.notice(
            """
            show build=\(ms(t0, tPanel), format: .fixed(precision: 1), privacy: .public)ms \
            layout=\(ms(tPanel, tLayout), format: .fixed(precision: 1), privacy: .public)ms \
            order=\(ms(tLayout, tOrder), format: .fixed(precision: 1), privacy: .public)ms \
            key=\(ms(tOrder, tKey), format: .fixed(precision: 1), privacy: .public)ms
            """)
    }

    func hide() {
        removeDismissMonitors()
        panel?.orderOut(nil)
        // Before `reset()`, which would otherwise set the mood to `.idle` and
        // start a fresh (invisible) animation on the way out.
        model.animator.stop()
        machine.reset()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Re-measures the bubble and re-lays-out around the character.
    ///
    /// The character is the fixed point, which is the inversion this layout
    /// required: the old card pinned its top-left corner and grew downward,
    /// but here the character must not move while the bubble grows next to it
    /// on every streamed delta.
    func resizeToFit() {
        guard let panel, panel.isVisible else { return }
        layout()
    }

    // MARK: - Panel construction

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: ResultPanelView.width, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        // Follow the user across Spaces and sit above full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { [weak self] in self?.hide() }

        // The window now spans character + bubble, so most of it is empty. A
        // shaped container is what stops that empty space from swallowing
        // clicks meant for the app underneath. See PanelChrome.
        let container = ShapedContainer()

        // Vibrancy sized to the BUBBLE, not the window.
        //
        // It used to be the contentView, which is why it came for free. SwiftUI's
        // `.regularMaterial` is not a substitute -- it builds no
        // NSVisualEffectView at all (verified; NOTES.md), so the blur has to
        // stay a real effect view, just a smaller one.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        container.addSubview(effect)

        // Tail below the bubble in z-order; it only overlaps by a point.
        let tail = NSHostingView(rootView: TailView(side: .right))
        container.addSubview(tail)

        let bubble = NSHostingView(rootView: ResultPanelView(model: model))
        container.addSubview(bubble)

        // The character rides on transparency, outside the card entirely.
        // No explicit height: the character fills the rect `layout()` gives it,
        // which is already its frames' own size.
        let character = NSHostingView(rootView: SpriteView(animator: model.animator))
        container.addSubview(character)

        panel.contentView = container
        self.panel = panel
        self.container = container
        self.effectView = effect
        self.bubbleView = bubble
        self.tailView = tail
        self.characterView = character
        return panel
    }

    private var container: ShapedContainer?
    private var effectView: NSVisualEffectView?
    private var bubbleView: NSHostingView<ResultPanelView>?
    private var tailView: NSHostingView<TailView>?
    private var characterView: NSHostingView<SpriteView>?

    /// Which flank the bubble is on. Fixed for the duration of a presentation.
    private var side: BubbleSide = .right
    /// The character's bottom-left in screen coordinates. The layout's fixed
    /// point: everything else is positioned relative to it.
    private var characterOrigin: CGPoint = .zero

    // MARK: - Layout

    /// Positions character, tail and bubble, then sizes the window around them.
    ///
    /// The arrangement itself is `BubbleLayout.geometry` in the core library, so
    /// it is testable without a window; this method measures the SwiftUI bubble,
    /// asks for the geometry, and applies it.
    private func layout() {
        guard let panel, let container, let effectView,
              let bubbleView, let tailView, let characterView else { return }

        bubbleView.layoutSubtreeIfNeeded()
        let bubbleSize = NSSize(width: ResultPanelView.width,
                                height: max(bubbleView.fittingSize.height, 44))

        let geometry = BubbleLayout.geometry(
            bubbleSize: bubbleSize,
            characterSize: characterSize,
            tailSize: CGSize(width: PanelChrome.tailWidth,
                             height: PanelChrome.tailHeight),
            side: side,
            gap: PanelChrome.gap,
            inset: PanelChrome.shadowInset,
            tailDropFromTop: PanelChrome.tailDropFromTop)

        let characterRect = geometry.characterRect
        let bubbleRect = geometry.bubbleRect
        let tailRect = geometry.tailRect
        let windowSize = geometry.windowSize

        // Keep the character pinned to its screen position, then clamp the whole
        // window on-screen. Clamping can still shift the character -- an answer
        // that grows past the screen edge has to move something -- but it is the
        // last resort rather than the default.
        var origin = CGPoint(x: characterOrigin.x - characterRect.minX,
                             y: characterOrigin.y - characterRect.minY)
        // gap:0 makes `origin` an identity placement, so this is purely a clamp.
        origin = PanelPlacement.origin(
            pointer: CGPoint(x: origin.x, y: origin.y + windowSize.height),
            panelSize: windowSize,
            screens: visibleFrames(),
            gap: 0)

        panel.setFrame(NSRect(origin: origin, size: windowSize), display: true)
        container.frame = NSRect(origin: .zero, size: windowSize)
        effectView.frame = bubbleRect
        bubbleView.frame = bubbleRect
        tailView.frame = tailRect
        tailView.rootView = TailView(side: side)
        characterView.frame = characterRect

        // Only these accept clicks; the rest of the window passes them through.
        // The tail is included so there is no dead notch between the two.
        container.interactiveRects = [bubbleRect, tailRect, characterRect]

        // The shadow is derived from content alpha, so it has to be recomputed
        // whenever the silhouette changes -- which is every streamed delta.
        panel.invalidateShadow()
    }

    private func visibleFrames() -> [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }

        // Clicks and scrolls in other applications. Mouse-only global monitors
        // do NOT require the Accessibility permission (keyboard ones would), so
        // this keeps the app sandbox-friendly and prompt-free.
        //
        // Scrolling dismisses because the panel is anchored to a point on
        // screen, not to the text — once the page moves, it is pointing at
        // whatever slid under it. macOS's own Look Up popover behaves the same
        // way, so this is the convention rather than a workaround.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            self?.hide()
        }

        // The same events inside our own process; dismiss only if they landed
        // outside the panel, so the user can still select text, press Retry, and
        // scroll a long answer without it vanishing.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel { self.hide() }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

/// A borderless panel refuses key status by default, which would swallow Escape.
private final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    // Deliberately false: becoming *main* is what would activate the app and
    // clear the user's selection in the app they were reading.
    override var canBecomeMain: Bool { false }

    /// AppKit routes Escape here.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
