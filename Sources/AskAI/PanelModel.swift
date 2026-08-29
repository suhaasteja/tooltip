import Foundation
import AppKit
import Combine
import AskAICore

/// SwiftUI-observable façade over `AskAICore.PanelViewModel`.
///
/// The state machine itself stays in the core library (UI-free, and therefore
/// testable without a running app); this class exists only to republish it as
/// `@Published` for the view.
final class PanelModel: ObservableObject {
    @Published private(set) var state: PanelState = .idle

    let machine = PanelViewModel()

    /// Invoked when the user asks to retry, carrying the failed selection.
    var onRetry: ((String) -> Void)?
    /// Invoked when the user dismisses the panel.
    var onDismiss: (() -> Void)?

    init() {
        machine.onChange = { [weak self] newState in
            // The state machine is driven from the main thread everywhere in
            // this app, but async LLM completions land off it -- hop
            // defensively rather than trusting every future call site.
            if Thread.isMainThread {
                self?.state = newState
            } else {
                DispatchQueue.main.async { self?.state = newState }
            }
        }
    }

    /// Briefly true after a copy, to swap the button label for feedback.
    @Published private(set) var didCopy = false
    private var copyResetWork: DispatchWorkItem?

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        didCopy = true
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.didCopy = false }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func retry() {
        guard let selection = state.selection else { return }
        onRetry?(selection)
    }

    func dismiss() {
        onDismiss?()
    }
}
