# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AskAI is a background macOS app (`LSUIElement`, no Dock icon) that adds four
"Ask AI" entries to the system Services menu. Selected text in any app arrives
via the pasteboard, is templated into a prompt, sent to an LLM, and the answer
is drawn in a floating non-activating panel near where the user right-clicked.

Hand-bundled and ad-hoc signed with SwiftPM — there is no Xcode project.

## Commands

```sh
make build      # debug build
make test       # test suite — see "Testing" below; do NOT use bare `swift test`
make bundle     # release build -> dist/AskAI.app, ad-hoc signed with entitlements
make run        # bundle + launch from dist/
make install    # bundle + copy to /Applications (required for Services to register)
make probe TEXT="..."   # fire a service from another process, report the resulting panel
make logs       # live log stream for subsystem com.yourname.AskAI
make services   # dump this app's entries from the pbs Services registry
make entitlements       # show what is actually signed into the bundle
make clean

make sprites    # re-slice the sprite sheets into Sources/AskAI/Sprites
make preview    # cycle the panel through every state on a timer
make snapshot   # render each panel state to dist/snapshots/*.png
```

`SLOT=Explain|Summarise|Translate|Custom make probe` selects which slot to fire
(default Explain). This is the verification path of choice — it exercises the
real dispatch (`NSPerformService` → pbs lookup → selector) without needing UI
automation or the Accessibility permission.

### Testing

`XCTest` ships only with full Xcode, so the suite is swift-testing
(`import Testing` / `@Test` / `#expect`). On a Command Line Tools-only install
SwiftPM cannot locate `Testing.framework`, and CLT's `_Testing_Foundation.framework`
is missing its `Modules` directory. `make test` supplies the framework search
path and passes `-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays` to
work around both.

**A bare `swift test` fails with `no such module 'Testing'`. That is expected,
not a broken checkout.** The suite is also `--no-parallel`: `StubURLProtocol` is
process-global mutable state and the client suites race without it.

To run a single suite or test, pass `--filter` alongside the same flags —
filters match the **Swift type name**, not the `@Suite` display string
(`PromptTemplateTests`, not `"Prompt templating"`):

```sh
DF="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --no-parallel --filter PromptTemplateTests \
  -Xswiftc -F -Xswiftc "$DF" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$DF" -Xlinker -rpath -Xlinker "$DF"
```

All tests are offline; networking goes through a stubbed `URLProtocol`.

## Architecture

Two targets, and the split is the main design rule:

| Target | Contents |
|---|---|
| `AskAICore` | Everything pure and testable — selection normalization, panel placement/anchoring math, panel state machine, prompt templating, LLM clients + SSE parsing, Keychain, settings, sprite mood/animation data. No AppKit. |
| `AskAI` | Thin AppKit shell — app delegate, services provider, panel window, settings window. |

**If logic is hard to test, it is in the wrong target.** New behaviour belongs in
`AskAICore` with the AppKit target reduced to wiring.

### Request flow

`ServiceProvider.askAIN:userData:error:` (invoked off the main thread by AppKit)
→ `SelectionExtractor.extract` → hop to main → `AppDelegate` reads
`PointerTracker.anchor` and shows the panel → `AskOrchestrator.ask` →
`PromptTemplate.render` → `LLMClient.complete`/`stream` → `PanelViewModel`
transitions → SwiftUI panel redraws.

Two invariants worth preserving:

- **The service handler must never block.** It returns immediately and the LLM
  call runs in a detached `Task`.
- **Every result is gated on a request id.** `PanelViewModel.startLoading` bumps
  a monotonic counter; `finish`/`fail`/`appendDelta` no-op if superseded. This is
  what stops a slow first answer from overwriting a fast second one, and what
  stops a late reply from resurrecting a dismissed panel. Cancellation alone is
  not relied on — it can lose the race.

### Providers

`LLMClient` is a two-method protocol (`complete`, `stream`). `stream` has a
default implementation that calls `complete` and emits one delta, so mocks and
non-streaming clients need not implement it. Two conformers:
`AnthropicClient` (native Messages API) and `OpenAICompatibleClient`
(`/chat/completions` — covers LiteLLM, Ollama, LM Studio, vLLM, OpenRouter,
Gemini's compatibility endpoint, OpenAI). `LLMClientFactory.make` picks one from
`LLMConfiguration.provider`.

Adding "support for Gemini" or "for local models" is a base-URL change in
`ProviderPreset.all`, not a new client.

Model config details that are load-bearing (see NOTES.md for the full reasoning):
the Anthropic client sends **no** `temperature`, `top_p`, `top_k`, or
`thinking.budget_tokens` — the current model tier 400s on them — and uses
`output_config.effort` instead. There is a test asserting their absence.
Thinking is on by default and shares the `max_tokens` budget, which is why it is
2048 rather than something tight. `thinking_delta` (Anthropic) and
`reasoning_content` (DeepSeek-R1 via LiteLLM) deltas are filtered out, or the
panel renders reasoning as the answer.

## Constraints that will bite

**Four slots, frozen titles.** `NSServices` is read from `Info.plist` at
registration; there is no API to add entries at runtime. Menu titles are fixed at
build time; only prompt *bodies* are user-editable (`UserDefaults`). Adding or
renaming a slot means editing `Resources/Info.plist`, adding the matching
`@objc askAIN` method in `ServiceProvider.swift`, updating `PromptSlot.all` in
`Settings.swift` so the title matches, then `make install && pbs -flush`. Do not
build UI that pretends a fifth slot is possible.

**`NSMessage` must match the Objective-C selector exactly** — AppKit appends
`:userData:error:`. A mismatch fails *silently*: the menu item appears and does
nothing.

**`NSRequiredContext` must be present even when empty**, or the service never
appears anywhere, with no error logged.

**Info.plist changes invalidate the code signature.** `make bundle` always
rebuilds and re-signs; never test a Services change without it.

**Services are cached by `pbs`.** After any `NSServices` change, a rebuild and
reinstall is not enough — the dump keeps showing the *old but plausible* entry,
which reads like "my change didn't compile". Run:

```sh
/System/Library/CoreServices/pbs -flush
```

**The app must run from `/Applications`.** Launch Services does not reliably
scan build directories, and it must be launched once to register.

**`swift run` is not a valid way to test this app.** A loose binary has no
Info.plist, no signature, hence no Services and no entitlements.

**Do not use SwiftPM `resources:` / `Bundle.module`.** The generated accessor for
an executable target searches `Bundle.main.bundleURL` — the `.app` root, not
`Contents/Resources` — so it can never find its bundle in a hand-assembled app,
and it `fatalError`s instead of returning nil. Asset directories are `exclude:`d
from the target, copied by `scripts/bundle.sh`, and read via `Bundle.main`.

**The app is sandboxed and can only write inside its container.** Any debug
affordance that writes files must target
`~/Library/Containers/com.yourname.AskAI/Data/` or it fails with POSIX error 2 on
every write, `try?`-swallowed and easy to misread as "the code never ran".

**`log` is a zsh builtin.** Always write `/usr/bin/log` explicitly, or you get
silent empty output that looks exactly like "the app logged nothing". Also,
`NSLog` from this bundle is not reliably queryable — the app uses `os.Logger`
under subsystem `com.yourname.AskAI` (`Sources/AskAI/Log.swift`), queried by
subsystem rather than process name.

**`LSUIElement` apps have no main menu**, so AppKit never dispatches ⌘C/⌘V/⌘X/⌘A
(they travel through menu items). `AppDelegate.installMainMenu()` builds a
minimal App + Edit menu to restore them — the Edit menu title must be exactly
`"Edit"`, and the actions must be string selectors (`Selector(("copy:"))`);
`#selector(NSText.copy(_:))` collides with `NSObject.copy()`.

**Accessibility (TCC) is deliberately not requested.** It is incompatible with
the App Sandbox and causes permission loops for a frequently re-signed ad-hoc
binary. This rules out a universal global hotkey (PLAN.md Stage 9, not taken) and
anchoring the panel to the selected text's frame. Mouse-only global monitors need
no permission, which is why `PointerTracker` works.

**Changing `CFBundleIdentifier` orphans the Keychain item, the sandbox container
and the pbs registration.** See BACKLOG.md §1 before any rename.

## Environment flags

- `ASKAI_MOCK_LLM=1` — canned client, runs end-to-end with no API key.
- `ASKAI_KEYCHAIN_SELFTEST=1` — round-trips a throwaway secret at launch and
  logs the result. Diagnostic for `errSecMissingEntitlement` (-34018), which a
  sandboxed ad-hoc-signed app can hit and which otherwise looks identical to
  "no key stored".
- `ASKAI_SPRITE_PREVIEW=1` — cycles the panel through every state on a timer.
- `ASKAI_SPRITE_SNAPSHOT=<dir>` — renders each state to a PNG and exits.
  Deliberately draws into its own bitmap rather than screenshotting, because
  `screencapture` needs the Screen Recording permission this project avoids.

## Repo conventions

- **NOTES.md is a running log of divergences from PLAN.md and things that bit.**
  When reality differs from the plan, or a non-obvious failure mode is found,
  append to it — newest stage last. Most of the constraints above were learned
  there first.
- **PLAN.md is the original build plan**, including a numbered appendix of
  gotchas that other files cite by number ("PLAN.md appendix #4").
- **BACKLOG.md is parked work with its reasoning**, so it need not be re-derived.
- **MANUAL-QA.md is the human checklist**, including the per-app Services
  coverage table.
- Do not claim per-app Services coverage or live-API verification that has not
  been observed — both are open gaps recorded in the README, and the repo has
  deliberately avoided writing tables it did not measure.
