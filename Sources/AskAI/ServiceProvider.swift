import AppKit
import AskAICore

/// Receives Services-menu invocations from other applications.
///
/// The bridged shape is load-bearing and easy to get subtly wrong. AppKit
/// derives the Objective-C selector from `NSMessage` in Info.plist by appending
/// `:userData:error:`, so `NSMessage = askAI` must resolve to the selector
/// `askAI:userData:error:`. A mismatch fails *silently*: the menu item appears
/// and does nothing. See PLAN.md appendix #2.
///
/// AppKit allows exactly one services provider object per application, so every
/// prompt slot added in Stage 7 becomes another `@objc` method on this class
/// rather than another provider.
final class ServiceProvider: NSObject {

    /// Invoked with the cleaned selection and the slot that fired.
    var onSelection: ((Selection, Int) -> Void)?
    /// Invoked when the pasteboard carried nothing usable.
    var onEmptySelection: (() -> Void)?

    // One method per Info.plist slot. AppKit permits a single provider object
    // per app, so slots are methods here rather than separate providers, and
    // each name must match its NSMessage exactly.

    @objc func askAI1(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) { handle(pboard: pboard, slot: 1) }

    @objc func askAI2(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) { handle(pboard: pboard, slot: 2) }

    @objc func askAI3(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) { handle(pboard: pboard, slot: 3) }

    @objc func askAI4(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) { handle(pboard: pboard, slot: 4) }

    /// Shared body for every prompt slot.
    ///
    /// Returns immediately: the service handler must not block, so the LLM call
    /// it eventually triggers is dispatched asynchronously (Stage 6). The
    /// pointer position is sampled *here*, before any hop, because by the time
    /// an async continuation runs the cursor may have moved.
    private func handle(pboard: NSPasteboard, slot: Int) {
        let raw = pboard.string(forType: .string)
        guard let selection = SelectionExtractor.extract(from: raw) else {
            Log.service.notice("slot=\(slot, privacy: .public) empty selection")
            dispatchToMain { self.onEmptySelection?() }
            return
        }

        Log.service.notice(
            """
            slot=\(slot, privacy: .public) selection \
            chars=\(selection.text.count, privacy: .public) \
            truncated=\(selection.wasTruncated, privacy: .public)
            """
        )
        dispatchToMain { self.onSelection?(selection, slot) }
    }

    /// Services invocations arrive on a non-main thread; all UI work must hop.
    private func dispatchToMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
