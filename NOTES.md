# NOTES — divergences from PLAN.md, and things that bit

Running log of every place reality differed from the plan. Newest stage last.

---

## Stage 1

### XCTest is not available without full Xcode — the suite uses swift-testing

PLAN.md's prerequisites say "Full Xcode is NOT required. SwiftPM plus Command
Line Tools." That is true for *building*, but not for the plan's testing story:
`XCTest` is part of the Xcode installation, not the Command Line Tools. With CLT
only, `import XCTest` fails with `no such module 'XCTest'`.

`Testing.framework` (swift-testing) **is** bundled with CLT, at
`$(xcode-select -p)/Library/Developer/Frameworks/Testing.framework`. So the
entire test suite uses `import Testing` / `@Test` / `#expect` instead of
`XCTestCase`. No capability is lost — everything the plan asks to unit-test is
pure-function work that swift-testing covers fine.

Two knock-on changes:

1. **`swift-tools-version` had to go from 5.9 to 6.0.** SwiftPM only wires up
   swift-testing for tools-version 6.0+. To avoid dragging in Swift 6 strict
   concurrency (which fights AppKit's implicitly-main-thread API surface for no
   benefit here), every target pins `swiftSettings: [.swiftLanguageMode(.v5)]`.
   The language the code is written in is unchanged; only the manifest version moved.

2. **`swift test` alone does not work — use `make test`.** SwiftPM locates
   `Testing.framework` by asking `xcrun --show-sdk-platform-path`, which errors
   out on a CLT-only install:
   ```
   xcrun: error: unable to lookup item 'PlatformPath' from command line tools installation
   ```
   So the framework search path is supplied explicitly. `make test` passes
   `-Xswiftc -F <dev frameworks>` plus matching `-Xlinker -F` / `-rpath`.
   A bare `swift test` still fails with `no such module 'Testing'`; that is
   expected, not a broken checkout.

Harmless linker warning on every test build (`Testing` requires macOS 14, the
package targets 13). It affects the test bundle only, never the shipped app.

### `log` in zsh is a shell builtin — always write `/usr/bin/log`

PLAN.md's debugging section says to run
`log stream --predicate 'process == "AskAI"' --info`. In zsh (the default shell
here) `log` is a **builtin** that prints watched users. It swallows the command,
prints nothing, and exits 0 — so it looks exactly like "the app produced no log
output". That is a trap in Stage 2, where absence of a log line is the signal
that the service did not reach your code.

Always invoke `/usr/bin/log` explicitly. The `make logs` target does.

### `NSLog` did not surface; the app uses `os.Logger` instead

Even via `/usr/bin/log`, `NSLog` output from this bundle was not reliably
queryable. Replaced with `os.Logger` under an explicit subsystem
(`com.yourname.AskAI`, see `Sources/AskAI/Log.swift`) and queried by subsystem
rather than process name. `.notice` and above persist by default. Verified:

```
AskAI: [com.yourname.AskAI:app] AskAI launched (core 0.1.0)
```

### Info.plist `CFBundleIdentifier`

Left as the plan's placeholder `com.yourname.AskAI`. This string is load-bearing
for `pbs`, `tccutil`, and Launch Services — changing it later means re-installing
and flushing the Services cache.
