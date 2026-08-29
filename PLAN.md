# AskAI — Build Plan

A background macOS app that adds **"Ask AI"** to the system Services menu. Select
text in *any* app, invoke the service (right-click → Services, or a global keyboard
shortcut), and the selection is sent to an LLM with a user-configurable prompt. The
response appears in a floating panel at the pointer.

No Dock icon. No main window. A menu bar item and a Settings window.

---

## 0. Read this first (instructions to the executing agent)

You are executing this plan end-to-end in one session. Follow these rules:

**RULE 1 — Stage 2 is a go/no-go gate.** Services registration is the load-bearing
assumption of this entire app. It is verified in isolation, with a trivial hardcoded
service, before a single line of LLM or UI code is written. If Stage 2 cannot be made
to pass, **stop and report** — do not build stages 3+ on an unproven foundation.

**RULE 2 — Never assume an API signature.** Check the SDK or the linked docs. The
Services method signature in particular is bridged from an Objective-C selector shape
and is easy to get subtly wrong; a mismatch fails *silently* (the menu item appears
and does nothing). Confirm it against the Services Implementation Guide.

**RULE 3 — One stage, one commit.** Do not start stage N+1 until stage N's Verify
block passes. Each commit must build cleanly.

**RULE 4 — Re-sign after every `Info.plist` change.** This app is hand-bundled and
ad-hoc signed. Editing `Info.plist` invalidates the signature, and an invalidly
signed bundle will be ignored or misbehave. `make bundle` must always run before
testing anything Services-related.

**RULE 5 — Stop and report, don't improvise around blockers.** Write problems to
`NOTES.md` and continue with the next independent stage if one exists.

### Prerequisites

**Full Xcode is NOT required.** SwiftPM plus Command Line Tools (~2 GB).

```bash
sw_vers                    # macOS 13+ is fine; 14+ recommended
xcode-select -p            # if missing: xcode-select --install
swift --version            # need Swift 5.9+
git --version
```

### Reference documentation

| Topic | URL |
|---|---|
| Services Implementation Guide — providing a service | https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html |
| Services properties (`NSServices` plist keys) | https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html |
| `NSApplication.servicesProvider` | https://developer.apple.com/documentation/appkit/nsapplication/servicesprovider |
| `NSUpdateDynamicServices()` | https://developer.apple.com/documentation/appkit/nsupdatedynamicservices() |
| `NSPasteboard` | https://developer.apple.com/documentation/appkit/nspasteboard |
| `NSPanel` | https://developer.apple.com/documentation/appkit/nspanel |
| `NSWindow.StyleMask` (`.nonactivatingPanel`) | https://developer.apple.com/documentation/appkit/nswindow/stylemask |
| `NSWindow.Level` | https://developer.apple.com/documentation/appkit/nswindow/level |
| `NSStatusItem` (menu bar) | https://developer.apple.com/documentation/appkit/nsstatusitem |
| `NSApplication.ActivationPolicy.accessory` | https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy |
| `LSUIElement` | https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement |
| `Info.plist` key reference | https://developer.apple.com/documentation/bundleresources/information-property-list |
| App Sandbox | https://developer.apple.com/documentation/security/app-sandbox |
| `com.apple.security.network.client` | https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_network_client |
| Keychain Services | https://developer.apple.com/documentation/security/keychain-services |
| `SMAppService` (launch at login) | https://developer.apple.com/documentation/servicemanagement/smappservice |
| `pbs` tool (Services debugging) | https://ss64.com/mac/pbs.html |
| SwiftPM manifest | https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html |
| Anthropic Messages API | https://docs.claude.com/en/api/messages |
| Anthropic model IDs (fetch current — do not hardcode from memory) | https://docs.claude.com/en/docs/about-claude/models |
| Anthropic streaming | https://docs.claude.com/en/docs/build-with-claude/streaming |

### Prior art worth reading (not forking)

Two MIT-licensed repos build a *different* product — a voice-driven, screen-aware AI
companion — but share this app's shell architecture. Neither implements text selection
or Services, so there is nothing to fork wholesale. Read them for specific files:

| Repo | Read for |
|---|---|
| https://github.com/farzaa/clicky | `leanring-buddy/ClaudeAPI.swift` — a working Swift streaming-SSE client for the Messages API (Stage 5/8). `OverlayWindow.swift` and `CompanionPanelView.swift` — menu-bar app with `NSPanel` overlays, no Dock icon (Stage 1/3). `worker/src/index.ts` — the key-proxy pattern below. |
| https://github.com/jasonkneen/openclicky | A more heavily developed fork of the same base. `CLAUDE.md`, `AGENTS.md`, `docs/` — worth skimming for how a Swift macOS repo is structured for agent execution. Its secrets handling (`~/.config/<app>/secrets.env`, `chmod 600`) is a simpler alternative to Keychain if that stage stalls. |

Both are MIT and the upstream author explicitly invites reuse. Both require full Xcode
and use a `.xcodeproj`, so their build setup does **not** transfer to this plan's
SwiftPM approach — read their Swift sources, ignore their build tooling.

**Take their key-handling pattern seriously.** Clicky ships no API keys in the app.
The app talks to a small Cloudflare Worker that holds the secrets and forwards to the
provider. That is a materially better answer than an embedded key, and it is maybe an
hour of work: `wrangler secret put ANTHROPIC_API_KEY`, one `/chat` route that proxies
to the Messages API, `wrangler deploy`. If this app is ever going to leave your own
machine, do this instead of Keychain. See Stage 5.

---

## Stage 1 — Menu bar app that launches and signs

**Goal.** A signed, sandboxed, Dock-less app with a status bar item. No Services yet.

**Architecture note — this split matters for every later stage.** Two SwiftPM targets:

- `AskAICore` — **library**. All pure logic: prompt templating, LLM client, error
  mapping, panel view-model state machine, pasteboard text extraction, panel
  placement math. This is what `swift test` exercises.
- `AskAI` — thin **executable**. AppKit shell only.

If a stage's logic is hard to test, it is in the wrong target. Move it.

**Do.**
- `git init`. `.gitignore`: `.build/`, `dist/`, `.DS_Store`.
- `Package.swift`: `platforms: [.macOS(.v13)]`, the two targets plus `AskAICoreTests`.
  No external dependencies.
- `AppDelegate` setting `NSApp.setActivationPolicy(.accessory)` and creating an
  `NSStatusItem` with a menu: Settings…, Quit.
- `Resources/Info.plist`: `CFBundleExecutable`, `CFBundleIdentifier`
  (`com.yourname.AskAI`), `CFBundleName` (`AskAI`), `CFBundlePackageType` (`APPL`),
  `CFBundleShortVersionString`, `LSMinimumSystemVersion`, `NSPrincipalClass`
  (`NSApplication`), and `LSUIElement` = `true`.
- `Resources/AskAI.entitlements`: `com.apple.security.app-sandbox` = true. Network
  client is deliberately withheld until Stage 5.
- `scripts/bundle.sh`: `swift build -c release` → assemble
  `dist/AskAI.app/Contents/{MacOS,Resources}` → copy binary and `Info.plist` →
  `codesign --force --sign - --entitlements Resources/AskAI.entitlements dist/AskAI.app`
- `Makefile`: `build`, `test`, `bundle`, `run`, `install`, `clean`.
  `install` copies the bundle to `/Applications` (see Stage 2 for why this matters).

**Verify.**
```bash
make build && make test && make run
# menu bar icon appears; NO Dock icon; Quit works
codesign -d --entitlements - dist/AskAI.app   # sandbox present
codesign -v dist/AskAI.app                    # signature valid
```

**Commit.** `chore: scaffold sandboxed menu bar app with ad-hoc signing`

---

## Stage 2 — GO/NO-GO: register a Service system-wide

**Goal.** "Ask AI" appears in the Services menu of apps you did not write, and firing
it demonstrably reaches your code. The handler does nothing but log. This stage exists
to prove the mechanism before anything is built on it.

**Do.**
- Add `NSServices` to `Info.plist` as an array with one dictionary:
  - `NSMessage` — the method name, e.g. `askAI` (no colon, no arguments).
  - `NSPortName` — the application name, `AskAI`.
  - `NSMenuItem` — a dictionary with a single `default` key, e.g. `Ask AI`.
  - `NSSendTypes` — array containing `NSStringPboardType`.
  - `NSRequiredContext` — an **empty dictionary**. This key must be present even when
    empty, or the service will not appear at all. This is the single most common
    silent failure.
  - Optionally `NSKeyEquivalent` with a `default` key.
- `ServiceProvider: NSObject` with the bridged handler. Confirm the exact shape
  against the Services Implementation Guide; it derives from the Objective-C selector
  `message:userData:error:` and looks like:
  ```swift
  @objc func askAI(_ pboard: NSPasteboard,
                   userData: String?,
                   error: AutoreleasingUnsafeMutablePointer<NSString?>) { ... }
  ```
  The `NSMessage` value must match the method's Objective-C selector name exactly.
- In `applicationDidFinishLaunching`: `NSApp.servicesProvider = provider`, then call
  `NSUpdateDynamicServices()`.
- Handler body for now: read the string off the pasteboard and `NSLog` it. Nothing else.

**Verify — do these in order and do not skip.**
```bash
make bundle && make install         # bundle must be in /Applications
open /Applications/AskAI.app        # launch once so Launch Services registers it
/System/Library/CoreServices/pbs -dump_pboard | grep -A12 AskAI
```
The dump must show your entry with the right `NSMessage`, `NSPortName`, and
`NSSendTypes`. If absent:
```bash
/System/Library/CoreServices/pbs -flush     # full rescan; slow but thorough
```
Then, in **TextEdit** (not your app): type a sentence, select it, right-click →
Services → "Ask AI". Watch for your log line:
```bash
log stream --predicate 'process == "AskAI"' --info
```
Also confirm it is listed in System Settings → Keyboard → Keyboard Shortcuts →
Services, where a shortcut can be bound.

If the entry appears in `pbs` but not in a given app's menu, diagnose with the
`NSDebugServices` user default, passing your bundle identifier — the target app then
logs *why* the service was or wasn't offered.

**Record in `NOTES.md`:** which apps offered the service and which didn't. Test at
minimum TextEdit, Safari, Notes, Mail, and Terminal. Coverage is not universal and
you need to know your real baseline before promising system-wide behaviour.

**Commit.** `feat: register Ask AI as a system Service provider`

---

## Stage 3 — Floating result panel

**Goal.** A panel that appears at the pointer, over any app, without stealing focus.

**Why not `NSPopover`:** popovers anchor to a view in your own window hierarchy. This
app has no window on screen when the service fires, and the selection lives in
another process. A borderless panel positioned in screen coordinates is the right
primitive.

**Do.**
- `ResultPanel` wrapping an `NSPanel`:
  - `styleMask`: `[.nonactivatingPanel, .borderless]` (non-activating so the user's
    app keeps focus and their selection is not lost)
  - `level = .floating`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it works in
    Spaces and over full-screen apps
  - `isFloatingPanel = true`, `hidesOnDeactivate = false`
  - rounded corners, vibrancy via `NSVisualEffectView`, content is an
    `NSHostingView` over SwiftUI
- Position at `NSEvent.mouseLocation`. Two things to handle: screen coordinates are
  bottom-left origin, and the panel must be clamped to the visible frame of whichever
  `NSScreen` contains the pointer so it doesn't render off-screen or on the wrong
  monitor. Put this math in `AskAICore` as a pure function.
- Dismiss on Escape and on click-outside (a local + global `NSEvent` monitor).
- Three states: `.loading`, `.success(String)`, `.failure(String)` with Retry.

**Verify.**
- Unit test the placement function in `AskAICore`: pointer near right edge clamps
  left; near bottom clamps up; multi-screen picks the screen containing the point;
  panel never exceeds `visibleFrame`. Feed it synthetic screen rects — no UI needed.
- Unit test the state machine: `idle → loading → success`, `idle → loading → failure`.
- Manual: add a temporary status-item menu entry "Show test panel" → panel appears at
  the pointer with placeholder text, Escape dismisses, focus stays in the other app
  (verify the other app's title bar stays active).

**Commit.** `feat: floating non-activating result panel with screen clamping`

---

## Stage 4 — Wire the Service to the panel

**Goal.** Select text anywhere → Services → Ask AI → panel shows the selected text
verbatim. Still no LLM.

**Do.**
- Pasteboard extraction into `AskAICore`: read `.string`, handle nil, trim, collapse
  runs of whitespace, and impose a sane length cap (say 8,000 characters) with a
  marker when truncated.
- Handler: extract → if empty, show a "no text selected" panel state; otherwise show
  the panel with the text.
- Because the app is `.accessory` and the panel is non-activating, the panel must be
  ordered front explicitly (`orderFrontRegardless()`).

**Verify.**
- Unit tests on extraction: nil pasteboard, empty string, whitespace-only, text with
  mixed newlines, text over the cap (truncated + marked), unicode and emoji intact.
- Manual: select a paragraph in Safari → Services → Ask AI → panel shows exactly that
  text at the pointer. Repeat in Notes and TextEdit.

**Commit.** `feat: route service invocation to result panel`

---

## Stage 5 — LLM client

**Goal.** Tested networking layer, fully exercised offline.

**Do.**
- `protocol LLMClient { func complete(system: String?, prompt: String) async throws -> String }`
- `AnthropicClient`: POST `https://api.anthropic.com/v1/messages`, headers
  `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`.
  Body: `model`, `max_tokens`, `messages`, optional `system`. Response: concatenate
  `content[]` blocks where `type == "text"`. **Fetch the current model ID from the
  models doc — do not hardcode from memory.**
- Inject `URLSession` so tests use a stubbed `URLProtocol`.
- Typed `LLMError`: `missingAPIKey`, `unauthorized`, `rateLimited`, `server(Int)`,
  `decoding`, `network(Error)`, `cancelled`. Each maps to a human-readable panel message.
- `MockLLMClient` behind `ASKAI_MOCK_LLM=1` so the app demos with no key.
- `KeychainStore` via `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` with
  `kSecClassGenericPassword`. Never `UserDefaults`.
- **Optional but recommended if this will ever leave your machine:** point
  `AnthropicClient` at your own Cloudflare Worker instead of `api.anthropic.com`, with
  the key held as a Worker secret. See `worker/src/index.ts` in farzaa/clicky for a
  minimal working version. This makes `KeychainStore` unnecessary and removes the
  extractable-key problem entirely. Keep the base URL configurable so both modes work.
- **Now** add `com.apple.security.network.client` to entitlements, then re-bundle and
  confirm it is actually signed in:
  `make bundle && codesign -d --entitlements - dist/AskAI.app | grep network`

**Verify.**
```bash
make test
```
Offline via stubbed `URLProtocol`: multi-block response parses and concatenates;
401 → `.unauthorized`; 429 → `.rateLimited`; 500 → `.server(500)`; malformed JSON →
`.decoding`; request builder sets all three headers and the correct URL; Keychain
round-trip save → read → delete → nil.

**Commit.** `feat: LLM client with keychain credentials and offline tests`

---

## Stage 6 — End to end

**Goal.** The actual product.

**Do.**
- Prompt template with an explicit `{{selection}}` placeholder. Default:
  `Explain the following concisely, in plain language:\n\n{{selection}}`
- Handler: extract → show panel in `.loading` → substitute template → call client →
  render `.success` or `.failure`.
- Cancel in-flight `Task` if the panel closes or a new invocation starts.
- The service handler returns immediately; the work is async. Do not block it.

**Verify.**
- Unit test the orchestrator against `MockLLMClient`: success path, error path,
  second invocation cancels the first.
- Manual, with a real key: select a sentence in Safari → Services → Ask AI → spinner →
  answer at the pointer. Then bind a shortcut in System Settings and confirm the
  keyboard path works identically.

**Commit.** `feat: end-to-end selection to LLM to panel`

---

## Stage 7 — Settings and multiple prompts

**Goal.** The customisation payoff.

**Do.**
- Settings window (opened from the status item): API key (`SecureField` → Keychain),
  model picker, prompt template editor, max-tokens.
- **Multiple prompts.** Each distinct Services menu entry needs its own `NSServices`
  dictionary and its own `@objc` method — the plist is static and read at
  registration, so prompts cannot be added at runtime without editing and re-signing
  the bundle. Ship a fixed set of **four** slots (`askAI1`…`askAI4`) whose *titles are
  fixed* in the plist ("Ask AI: Explain", "Ask AI: Summarise", "Ask AI: Translate",
  "Ask AI: Custom") but whose *prompt bodies* are user-editable in Settings and stored
  in `UserDefaults`. This is the honest way to get near-dynamic prompts; document the
  constraint in the README rather than pretending it's unlimited.
- Each slot gets its own bindable shortcut in System Settings.

**Verify.**
- Unit tests on templating: substitution works; a template with no placeholder appends
  the selection rather than dropping it; multiple occurrences all substitute; braces
  inside the selection are not re-expanded; empty template falls back to a default.
- Manual: edit slot 2's prompt, re-invoke, confirm behaviour changed without a rebuild.
- Manual: `pbs -dump_pboard` shows all four entries; all four appear in System Settings.

**Commit.** `feat: settings window and four configurable prompt slots`

---

## Stage 8 — Streaming and polish

**Do.**
- SSE streaming (`"stream": true`) via `URLSession.bytes(for:)`, appending
  `content_block_delta` text deltas into the panel as they arrive. Keep the
  non-streaming path behind the protocol so existing tests still pass.
- Copy button; text selectable in the panel.
- Status item menu: Settings, "Open Services shortcuts…" (deep-link to System
  Settings), Quit.
- Launch at login via `SMAppService`.
- README: what it is, the Command Line Tools requirement, `make install`, the
  first-launch registration step, how to bind shortcuts, the four-slot constraint,
  and the app-coverage findings from Stage 2.
- `MANUAL-QA.md` as one ordered checklist. `NOTES.md` for every SDK/plan divergence.

**Commit.** `feat: streaming responses, launch at login, docs`

---

## Stage 9 (OPTIONAL — read the fork carefully before starting)

Services do not work everywhere. Terminal emulators, many Electron apps, and some
games either don't offer the Services menu or don't put a usable string on the
pasteboard. The universal fallback is a global hotkey that synthesises ⌘C, reads the
pasteboard, and restores the previous contents — roughly how commercial tools in this
category achieve true universality.

**The catch, and it is a real one:** that approach requires the Accessibility
permission and posting synthetic events, which conflicts with the App Sandbox. Taking
this path most likely means **dropping `com.apple.security.app-sandbox`**, which in
turn rules out Mac App Store distribution.

**A second hazard, learned from openclicky's README:** macOS TCC permissions
(Accessibility, Screen Recording, Microphone) are bound to a signed app *identity and
install path*. Repeatedly rebuilding and re-signing from the command line changes that
identity and can put you in a permission loop where the grant appears to exist but
doesn't apply. openclicky's maintainers explicitly warn against using terminal
`xcodebuild` for permission testing for exactly this reason.

This does **not** affect Stages 1–8 — Services and the sandbox involve no TCC prompts —
but it directly threatens this stage's ad-hoc-signed, frequently-rebuilt workflow. If
you take the Accessibility path, expect to either install to a stable path and re-grant
deliberately, or accept that this is the point where full Xcode with a stable signing
identity starts paying for itself.

**Do not start this stage without deciding that explicitly.** If you do:
- Verify first whether a sandboxed app can obtain Accessibility trust on the current
  macOS version (`AXIsProcessTrustedWithOptions`) before restructuring anything.
  Record the finding in `NOTES.md`.
- Reset a confused permission state with
  `tccutil reset Accessibility com.yourname.AskAI` rather than fighting it.
- Global hotkey registration, pasteboard save/restore around the synthetic copy, and a
  clear first-run permission prompt explaining why the app needs it.
- Keep Services working as the sandbox-friendly default path; the hotkey is additive.

---

## Appendix — gotchas that will bite

1. **`NSRequiredContext` must exist even when empty.** Omit it and the service simply
   never appears, with no error anywhere.
2. **`NSMessage` must match the Objective-C selector exactly.** A mismatch means the
   menu item appears and silently does nothing — the worst failure mode in the project.
3. **Editing `Info.plist` breaks the code signature.** Always `make bundle` (which
   re-signs) before testing. A stale or invalid signature causes confusing behaviour.
4. **Services are cached by `pbs`.** After any plist change: re-bundle, re-install,
   relaunch, and if the change doesn't take, `/System/Library/CoreServices/pbs -flush`.
   The cache is why "I changed it and nothing happened" is usually not a code bug.
5. **The app must be somewhere Launch Services scans.** `/Applications` is reliable;
   a build directory often is not. Launch it once so it registers.
6. **`.nonactivatingPanel` is essential.** An activating window steals focus, which in
   several apps clears the user's selection out from under you.
7. **`NSEvent.mouseLocation` is bottom-left origin** and spans all displays. Clamp to
   the containing screen's `visibleFrame` or the panel lands off-screen on multi-monitor.
8. **Service coverage is not universal.** Establish your real baseline in Stage 2 and
   put it in the README instead of over-promising.
9. **Sandbox blocks network silently-ish.** Verify with
   `codesign -d --entitlements - dist/AskAI.app`. Editing the file is not enough — re-sign.
10. **`swift run` is not a valid way to test this app.** A loose binary has no
    `Info.plist`, no signature, and therefore no Services registration and no
    entitlements. Always go through `make bundle`.
11. **An embedded API key is extractable.** Fine for personal use. For anything
    shared, use the Cloudflare Worker proxy pattern from farzaa/clicky (Stage 5).
13. **TCC permissions bind to signing identity and install path.** Only relevant if
    you take Stage 9. Frequent ad-hoc re-signing can cause permission loops.
12. **Debugging without Xcode:** `log stream --predicate 'process == "AskAI"' --info`,
    `pbs -dump_pboard`, the `NSDebugServices` default, and Console.app for sandbox
    violations.

---

## What changed from the VisionKit plan, and why

The earlier plan (kept as `PLAN-visionkit-superseded.md`) built Live Text integration:
text *inside images*, with a custom item merged into the native Look Up context menu.
That achieves genuine menu integration but only inside a single app's own window — no
public API lets a third-party app inject items into another app's Live Text menu.

Services invert the tradeoff: system-wide reach across nearly every app, but plain
selected text only, arriving via the pasteboard, with no image context and no Look Up
integration.

The two are complementary, not competing. The `AskAICore` library here — LLM client,
Keychain, templating, panel state — is exactly what the VisionKit app needed too. If
image text later matters, the VisionKit overlay work becomes an additional feature on
top of this core rather than a separate project.
