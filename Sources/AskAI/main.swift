import AppKit

// SwiftPM executables have no NSApplicationMain / @main storyboard path, so the
// app is bootstrapped by hand. Activation policy is set before `run()` so the
// Dock never sees us even briefly.
let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
