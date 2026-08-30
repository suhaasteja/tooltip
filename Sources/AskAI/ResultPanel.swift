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
        let panel = existingOrNewPanel()
        resize(panel)
        position(panel, at: pointer)

        // `.accessory` apps have no active window to order against, so an
        // ordinary `orderFront` can be ignored. PLAN.md Stage 4.
        panel.orderFrontRegardless()
        // Safe with `.nonactivatingPanel`: the panel takes key status for
        // Escape/scrolling without activating AskAI, so the frontmost app keeps
        // its active title bar and, critically, its selection.
        panel.makeKey()

        installDismissMonitors()
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

    /// Re-measures the hosted SwiftUI content and grows/shrinks the panel,
    /// keeping its top-left corner anchored so the panel expands downward as an
    /// answer streams in rather than crawling up the screen.
    func resizeToFit() {
        guard let panel, panel.isVisible else { return }
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        resize(panel)
        var frame = panel.frame
        frame.origin = CGPoint(x: topLeft.x, y: topLeft.y - frame.height)
        // Re-clamp: growth may have pushed the bottom edge off-screen.
        frame.origin = PanelPlacement.origin(
            pointer: CGPoint(x: frame.minX, y: frame.maxY),
            panelSize: frame.size,
            screens: visibleFrames(),
            gap: 0
        )
        panel.setFrame(frame, display: true)
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

        // Vibrancy backdrop with rounded corners; the hosting view rides on top.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: ResultPanelView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    private var hostingView: NSHostingView<ResultPanelView>?

    private func resize(_ panel: NSPanel) {
        guard let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let height = max(fitting.height, 60)
        panel.setContentSize(NSSize(width: ResultPanelView.width, height: height))
    }

    private func position(_ panel: NSPanel, at pointer: CGPoint) {
        let origin = PanelPlacement.origin(
            pointer: pointer,
            panelSize: panel.frame.size,
            screens: visibleFrames()
        )
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    private func visibleFrames() -> [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }

        // Clicks in other applications. Mouse-only global monitors do NOT
        // require the Accessibility permission (keyboard ones would), so this
        // keeps the app sandbox-friendly and prompt-free.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }

        // Clicks inside our own process; dismiss only if outside the panel so
        // the user can still select text and press Retry.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
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
