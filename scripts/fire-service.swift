import AppKit

// 1. Fire the service from a non-AskAI process, exactly as Stage 2 did.
// 2. Enumerate on-screen windows and report any owned by AskAI.
//    Owner name + bounds come from CGWindowListCopyWindowInfo without needing
//    the Screen Recording permission (only titles and pixels would).

let text = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Photosynthesis converts light energy into chemical energy."

let pb = NSPasteboard(name: .init(rawValue: "AskAIProbePasteboard"))
pb.clearContents()
pb.setString(text, forType: .string)

// The item name is the bare menu title as it appears in the Services menu.
// "AskAI/Ask AI: Explain" does NOT work; the app-name prefix must be omitted.
let slot = ProcessInfo.processInfo.environment["SLOT"] ?? "Explain"
let itemName = "Ask AI: \(slot)"

print("pointer at \(NSEvent.mouseLocation)")
let fired = NSPerformService(itemName, pb)
print("NSPerformService(\"\(itemName)\") -> \(fired)")

// Give the panel a beat to be ordered front.
Thread.sleep(forTimeInterval: 1.5)

let info = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] ?? []

let ours = info.filter { ($0[kCGWindowOwnerName as String] as? String) == "AskAI" }
if ours.isEmpty {
    print("NO ON-SCREEN AskAI WINDOW")
} else {
    for w in ours {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        print("AskAI window layer=\(layer) "
            + "x=\(b["X"] ?? -1) y=\(b["Y"] ?? -1) "
            + "w=\(b["Width"] ?? -1) h=\(b["Height"] ?? -1)")
    }
}

// Who is frontmost? Should NOT be AskAI -- the panel must not steal activation.
// NSWorkspace.frontmostApplication reports the owner of the frontmost WINDOW,
// which a .floating panel legitimately is -- it is NOT a measure of app
// activation. Ask the Accessibility layer which process is actually frontmost.
let script = "tell application \"System Events\" to name of first process whose frontmost is true"
let front = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue ?? "<none>"
print("frontmost app: \(front)")
