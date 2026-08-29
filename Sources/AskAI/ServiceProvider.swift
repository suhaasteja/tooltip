import AppKit

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
    @objc func askAI(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        // Stage 2 is a mechanism proof only: read the string and log it.
        // Extraction, the panel, and the LLM arrive in stages 3-6.
        let raw = pboard.string(forType: .string)
        Log.service.notice(
            """
            askAI fired \
            userData=\(userData ?? "<nil>", privacy: .public) \
            chars=\(raw?.count ?? -1, privacy: .public) \
            text=\(raw ?? "<nil>", privacy: .public)
            """
        )
    }
}
