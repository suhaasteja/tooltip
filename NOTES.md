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

---

## Stage 2 — GO/NO-GO: **PASSED**

`pbs -dump_pboard` shows the entry with the expected keys:

```
NSBundleIdentifier = "com.yourname.AskAI";
NSBundlePath = "/Applications/AskAI.app";
NSMenuItem = { default = "Ask AI"; };
NSMessage = askAI;
NSPortName = AskAI;
NSRequiredContext = { };
NSSendTypes = ( NSStringPboardType, "public.utf8-plain-text" );
```

And an invocation from a *different* process reached the provider selector:

```
AskAI: [com.yourname.AskAI:service] askAI fired userData= chars=47 \
  text=The mitochondria is the powerhouse of the cell.
```

So the bridged selector `askAI:userData:error:` is correct and the pasteboard
carries the selection. The load-bearing assumption of the whole app holds.

### How the gate was driven: `NSPerformService`, not UI automation

Clicking Services → Ask AI in another app's menu can only be scripted through
System Events, which needs the Accessibility (TCC) permission. PLAN.md Stage 9
explicitly warns that granting TCC to a frequently-re-signed, command-line-built
binary causes permission loops — so triggering that prompt during Stage 2 would
have risked the exact failure mode the plan says to avoid, to test something
Stage 2 does not require.

Instead the gate was driven with `NSPerformService(_:_:)` from a separate
throwaway process. That is the same dispatch path a menu click takes — `pbs`
registry lookup, port resolution, selector invocation — minus the menu-drawing
step. It proves the mechanism; it does not prove menu *presentation* in any
given app.

Quirk worth knowing: the item name is the bare menu title.
`NSPerformService("Ask AI", pb)` returns `true`;
`NSPerformService("AskAI/Ask AI", pb)` returns `false`.

### App coverage matrix — NOT yet established, needs a human

PLAN.md asks for a per-app baseline (TextEdit, Safari, Notes, Mail, Terminal).
That check is inherently manual: whether an app *offers* the item depends on its
first responder answering `validRequestorForSendType:returnType:`, which cannot
be inspected from outside the process. I am not recording a matrix I did not
observe.

**To fill this in**, with AskAI running from `/Applications`, in each app select
a sentence, then right-click → Services → "Ask AI", and watch:

```sh
make logs
```

A line tagged `[com.yourname.AskAI:service]` means that app works. Record the
results here and in the README before promising "system-wide". Expect gaps:
Electron apps and some terminal emulators either omit the Services menu or put
nothing usable on the pasteboard.

If the item is missing in an app that should have it, that app can be asked why:

```sh
defaults write <that-app-bundle-id> NSDebugServices com.yourname.AskAI
# relaunch it, reproduce, then check its log; unset with `defaults delete`
```

---

## Stage 5

### `_Testing_Foundation.framework` in CLT is incomplete — overlays disabled

Adding `import Foundation` next to `import Testing` broke the build:

```
error: no such module '_Testing_Foundation'
```

`Testing.framework/Modules/Testing.swiftcrossimport/Foundation.swiftoverlay`
declares a cross-import overlay that Swift auto-loads whenever both modules are
imported. The CLT copy of `_Testing_Foundation.framework` ships the **binary**
(`Versions/A/_Testing_Foundation`) but **no `Modules` directory**, so the
overlay's `.swiftmodule` does not exist and the import cannot be resolved. That
is a packaging gap in Command Line Tools, not something the project can fix.

`make test` therefore passes `-Xswiftc -Xfrontend -Xswiftc
-disable-cross-import-overlays`. Note it must go through `-Xfrontend`: SwiftPM's
argument parser rejects the bare driver spelling with

```
Fatal error: 'try!' expression unexpectedly raised an error: unknown argument
```

Nothing the suite uses lives in that overlay — `@Test`, `#expect`, `#require`
and `Issue` are all in `Testing` proper. 46 tests pass.

### Model configuration: adaptive thinking at `low` effort, not thinking disabled

The current Opus-tier model rejects `temperature`, `top_p`, `top_k`, and
`thinking.budget_tokens` with a 400, so the client sends none of them; depth is
controlled with `output_config.effort` instead. There is a test asserting their
absence, because reintroducing one would be a silent 400 in production.

Thinking is **on by default** on this model tier, and `max_tokens` caps thinking
*plus* answer — which is why `max_tokens` is 2048 rather than something tight,
despite tooltip answers being short.

Turning thinking off entirely would be faster, but is the documented-worse
option here: with thinking disabled this model tier can leak `<thinking>` tags
into the visible response. `effort: "low"` with thinking left on gets most of the
latency win without that failure mode. Both values are configurable.

### Keychain works from the test runner

`swift test` runs unsandboxed, so `SecItemAdd`/`SecItemCopyMatching` against the
login keychain succeed without a prompt. Tests use a per-run random service name
so they can never read or clobber a real stored key.

### Network entitlement is now signed in

`com.apple.security.network.client` added and verified present in the signature
(`make entitlements`). Editing the entitlements file invalidates the signature,
so `make bundle` re-signs on every build.

---

## Stage 7

### Changing `NSServices` needs a `pbs -flush`, not just a reinstall

After replacing the single `askAI` entry with four slots, rebuilding, re-signing
and re-installing, `pbs -dump_pboard` still reported the **old** single entry:

```
default = "Ask AI";
NSMessage = askAI;
```

`make bundle && make install && open` was not enough. Only

```sh
/System/Library/CoreServices/pbs -flush
```

picked up the new set. This is PLAN.md appendix #4 in practice — worth knowing
that the symptom is a *stale but plausible* dump rather than an empty one, which
is easy to misread as "my change didn't compile".

Renaming the slots also invalidated the probe script: `NSPerformService` takes
the bare menu title, so `"Ask AI"` stopped resolving and returned `false`.
`scripts/fire-service.swift` now takes `SLOT=Explain|Summarise|Translate|Custom`.

### Keychain works from the sandboxed, ad-hoc-signed app — verified, not assumed

This was the biggest unflagged risk in the plan. A sandboxed app normally gets
its Keychain access group from a provisioning profile; an **ad-hoc** signature
has no team identifier, so `SecItemAdd` can fail with `errSecMissingEntitlement`
(-34018). That would make the Settings API-key field silently useless — and
because `AppDelegate` originally used `try?`, it would have looked identical to
"no key stored".

Two changes:

1. The keychain read now logs failure distinctly from "no key found".
2. A launch-time self-test behind `ASKAI_KEYCHAIN_SELFTEST=1` round-trips a
   throwaway secret.

Result, from inside the installed sandboxed bundle:

```
keychain selftest: write+read=true delete=true
```

So `KeychainStore` is sound here and the Cloudflare-Worker fallback in PLAN.md
Stage 5 is not needed on this machine. It remains the right answer if this app
is ever distributed — an embedded key is still extractable.

### Four slots verified end to end

All four appear in `pbs` and each dispatches to its own selector:

```
Ask AI: Explain   -> true    slot=1
Ask AI: Summarise -> true    slot=2
Ask AI: Translate -> true    slot=3
Ask AI: Custom    -> true    slot=4
```

---

## Stage 8

### Streaming added without disturbing the non-streaming path

`stream(system:prompt:onDelta:)` was added to the `LLMClient` protocol **with a
default implementation** that calls `complete` and emits a single delta. So
`MockLLMClient` and every existing test keep working untouched, and only
`AnthropicClient` overrides it. Streaming is a user setting (default on) and the
orchestrator picks the path.

SSE parsing is a pure static function (`AnthropicClient.textDelta(fromSSELine:)`)
rather than being buried in the byte loop, so the wire format is unit-tested
without a network: `[DONE]`, ping, comment, event-name and blank lines, missing
space after `data:`, malformed JSON, and whitespace preservation.

`thinking_delta` events are explicitly ignored. This model tier thinks by
default, so without that filter the panel would render the model's reasoning as
the answer.

A mid-stream transport drop with text already received returns the partial answer
rather than throwing — a truncated answer beats losing a half-written one.

### Not verified against the live endpoint

Streaming is tested against the documented SSE shape and through the orchestrator
with a fake streaming client, but no real API key was used in this session, so
the live stream is unexercised. Flagged in README "Known gaps" and step 7 of
MANUAL-QA.md rather than being quietly claimed.

### Temporary test-panel menu entry removed

The Stage 3 "Show test panel" item is gone, as the plan required. `make probe`
covers the same ground better, from outside the app.

---

## Provider support: LiteLLM / Gemini / local models

Added `OpenAICompatibleClient` alongside `AnthropicClient`, both behind the
existing `LLMClient` protocol. One client covers LiteLLM proxy, Ollama, LM
Studio, vLLM, OpenRouter, Gemini's compatibility endpoint and OpenAI itself,
because they all speak `/chat/completions`. "Support Gemini" is a base-URL
change, not a new client.

Wire differences from Anthropic that the code has to get right:

| | Anthropic | OpenAI-compatible |
|---|---|---|
| Auth | `x-api-key` + `anthropic-version` | `Authorization: Bearer` |
| System prompt | top-level `system` | `role: "system"` in `messages` |
| Reply | `content[]` typed blocks | `choices[0].message.content` |
| Stream delta | `content_block_delta` | `choices[0].delta.content` |
| Effort | `output_config.effort` | not supported (hidden in Settings) |
| API key | required | **optional** — local servers accept none |

`reasoning_content` deltas (DeepSeek-R1 style, passed through by LiteLLM) are
filtered out for the same reason Anthropic's `thinking_delta` is.

### Two things local servers needed that hosted APIs did not

1. **ATS.** Local servers are plain HTTP on localhost, which App Transport
   Security blocks by default. Added `NSAllowsLocalNetworking` — this permits
   cleartext to loopback and `.local` only, and unlike `NSAllowsArbitraryLoads`
   does not weaken ATS for the public internet.
2. **An optional API key.** `AnthropicClient` throws `.missingAPIKey` on an
   empty key; doing that here would make Ollama unusable. The header is simply
   omitted when there is no key.

Error mapping also reads three different envelope shapes seen in the wild:
OpenAI/LiteLLM `{"error":{"message":…}}`, Ollama `{"error":"…"}`, and
FastAPI/LiteLLM-proxy `{"detail":…}`. A 404 says "check the base URL and that
the model is available" rather than "HTTP 404", and a refused connection says
"Is it running?" — both are the overwhelmingly likely causes locally.

**Verified against a real local server**, not just stubs: a fake
OpenAI-compatible server on `127.0.0.1:4000`, the installed sandboxed bundle
pointed at it, and a genuine Services invocation produced a request at the
server. Sandbox + ATS + streaming all confirmed working over loopback.

### Test suite is now `--no-parallel`

`StubURLProtocol` is process-global mutable state. swift-testing's `.serialized`
only orders tests *within* a suite, so once a second client suite existed, the
two suites raced and stubs bled across them (a 401 test seeing a 503 response).
`make test` now passes `--no-parallel`. 107 tests, still under a second.

---

## Panel anchoring, and paste in an LSUIElement app

Two defects found in real use, both stemming from the app having no normal
window/menu presence.

### The panel appeared over the Services menu, not the selection

`NSEvent.mouseLocation` read inside the service handler is the *menu item* the
user just clicked — right-click → Services → Ask AI moves the cursor a long way
down from the selected text. Anchoring there put the panel in the wrong place
every time on the most common invocation path.

Fix: a global monitor records where the user last opened a context menu, and
`PanelAnchor` prefers that over the live pointer when it is recent (30s).
Keyboard-shortcut invocations have no recent click and fall back to the pointer.
Mouse-only global monitors need no Accessibility permission, so this stays
sandbox-friendly.

Verified with logs from the installed bundle — right-click at y=700, pointer
moved to y=450, result `anchor y=700 pointer y=450` and the panel drawn at
y≈688.

Anchoring to the *text* itself would need the Accessibility API to read the
focused element's frame. Not worth a TCC prompt for this improvement.

### ⌘V did nothing in Settings

An `LSUIElement` app has **no main menu**, and AppKit dispatches the standard
editing key equivalents through menu items. With no Edit menu, `cut:`/`copy:`/
`paste:`/`selectAll:` were never sent, so the API-key field could not be pasted
into — the single most important field in the app.

Fix: `installMainMenu()` builds a minimal App + Edit menu with `target: nil`
items so they travel the responder chain to the focused field. Note the menu
title must be exactly `"Edit"`, and the actions must be string selectors —
`#selector(NSText.copy(_:))` collides with `NSObject.copy()`.

---

## Sprite character (BACKLOG.md §2), first pass

### `Bundle.module` cannot work in a hand-assembled .app

The obvious way to ship the sprite frames — declare them as SwiftPM
`resources:` and read them through `Bundle.module` — fails at launch:

```
AskAI/resource_bundle_accessor.swift:12: Fatal error: could not load resource
bundle: from /…/dist/AskAI.app/AskAI_AskAI.bundle or /…/.build/…/AskAI_AskAI.bundle
```

SwiftPM's generated accessor for an **executable** target searches
`Bundle.main.bundleURL`, which for an app bundle is the `.app` **root**, not
`Contents/Resources`. `bundle.sh` puts the generated `.bundle` in
`Contents/Resources` (where it belongs, and where `codesign` expects it), so the
accessor looks in a place nothing will ever be. Worse, it calls `fatalError`
rather than returning nil, so the app dies on launch instead of degrading.

Fix: don't use SwiftPM resources at all. `Sources/AskAI/Sprites` is `exclude:`d
from the target, `bundle.sh` copies it to `Contents/Resources/Sprites`, and
`SpriteLoader` uses plain `Bundle.main`. `exclude:` (rather than just leaving the
files there) is what silences SwiftPM's "unhandled files" warning.

This only bites because the app is hand-bundled; an Xcode target would not hit
it. It is the same family as appendix #10 — a loose SwiftPM build is not the
thing that ships.

### Screenshots need TCC; rendering our own view does not

Verifying how the panel looks by `screencapture` fails without the Screen
Recording permission (`could not create image from display`), and granting TCC to
a frequently re-signed ad-hoc binary is the loop PLAN.md Stage 9 warns about.

`ASKAI_SPRITE_SNAPSHOT=<dir>` instead renders `ResultPanelView` into an
`NSBitmapImageRep` via `cacheDisplay(in:to:)` and writes PNGs. No permission, and
deterministic across runs. `make snapshot` wraps it.

Two caveats worth knowing:

1. **The app is sandboxed, so it can only write inside its container.** Passing an
   arbitrary output path silently produces `NSPOSIXErrorDomain Code=2` for every
   file. `make snapshot` writes to
   `~/Library/Containers/com.yourname.AskAI/Data/tmp/shots` and copies out.
2. **`NSVisualEffectView` vibrancy does not render offscreen** — it samples what
   is behind the window, and offscreen there is nothing. The snapshots draw on a
   flat grey instead. They are honest about layout, sizing and the character;
   they are not a preview of the real material.

### Source art needed background removal and a shared crop

The sheets in `~/Desktop/sprite-sheet-creator/assets` are opaque white-background
PNGs (`hasAlpha: no`) — that project removes backgrounds at runtime via Bria, but
the saved assets never went through it. Two non-obvious requirements in
`scripts/make-sprites.swift`:

- **Flood fill from the border, not a white threshold.** The character contains
  white (eyes, the guitar pickguard); a plain "near-white is transparent" pass
  punches holes through it. Only white *connected to the edge* is background.
- **One union bounding box for every frame of a sheet.** Trimming each frame to
  its own content re-centres the character per frame, which reads as jitter
  during playback.

`walk-sprite-sheet.png` in that directory is Goku — a copyrighted character, not
usable here. The guitarist in `sprite_1/2/3.png` is consistent across all three
sheets and is what got vendored.

### Only the thinking mood loops

`SpriteMood.animation` marks every mood except `.thinking` as non-looping, and
`restingFrame` is the **last** frame rather than the first. The panel is
something the user reads; a character still moving under a paragraph competes
with the text, and at ~30 invocations a day that stops being charming fast. The
`.talking` sequence is therefore celebrate-then-settle, so Reduce Motion (and the
settled state) shows a calm character rather than a frozen mid-leap.

Playback is a `Timer` on `.common`, not `TimelineView(.animation)`, which would
redraw at display rate for as long as the view exists — unacceptable in a process
that stays resident for weeks. Single-frame moods never start a timer at all
(`needsAnimation`), and `ResultPanel.hide()` calls `animator.stop()`.

### Not done in this pass

The character is *inside* the existing card, beside the text. The BACKLOG idea of
a character standing outside the panel with a speech bubble needs the vibrancy
backdrop moved from the window's `contentView` into SwiftUI, and needs
`PanelPlacement` to report which side it flipped to so a bubble tail can point
back. `resizeToFit` would also have to invert: it currently pins the top-left and
grows down, whereas a character-anchored panel must pin the character.

### First live hosted-API verification (with the sprite in place)

Installed to `/Applications`, `pbs -flush`ed, and driven with `make probe`. Real
Services dispatch, real network:

```
slot=2 selection chars=127 truncated=false
asking slot=2 chars=127
CFNetwork Summary: response_status=200, response_bytes=2129
AskAI window w=380.0 h=111.0   (loading)
AskAI window w=380.0 h=131.0   (answer rendered, then stable)
```

This closes two gaps the README and BACKLOG §3 had both carried since the build:
"no live-API verification" and "streaming unverified against a live endpoint" —
but **only for the path actually configured on this machine**, which was:

```
llm.provider = openai        llm.streaming = 1
llm.presetID = gemini        llm.model = gemini-3.5-flash
llm.baseURL  = https://generativelanguage.googleapis.com/v1beta/openai/chat/completions
```

So what is now verified live is `OpenAICompatibleClient`, streaming, against
Gemini's OpenAI-compatible endpoint. **`AnthropicClient` against the real
Anthropic API is still unexercised** — different auth header, different request
body, different SSE event shape, and the `output_config.effort` field that only
that client sends. Do not read this as "the LLM layer is verified".

Caveat on the streaming evidence: window height was sampled once a second while
the response took ~2s, so the panel was observed growing 111 -> 131 but the
individual delta-by-delta growth was not. The stream produced a rendered answer;
that is the claim.

One transient worth recording: the very first probe after launch returned
`NSPerformService -> true` and logged the service handler reaching the provider,
but no `asking slot=` line and no on-screen window. Every subsequent invocation
behaved. Most likely the global mouse-down dismiss monitor catching a stray
click during app warm-up. Not reproduced since; noted rather than explained.

---

## Character outside the panel (BACKLOG.md §2, second pass)

Three unknowns were probed before any panel code was touched, because two of
them would have invalidated the design.

### Transparent window regions swallow clicks — this was the blocker

Once the window spans character *and* bubble, most of it is empty. A plain
`NSView` claims every point in its bounds, so `hitTest` returned
`NSHostingView` even at the far corner. Two consequences, both bad: clicks meant
for the app the user is reading get eaten, and `ResultPanel`'s dismiss rule
(`event.window !== panel`) reports "inside the panel" for a click on empty air,
so the panel stops closing.

`ShapedContainer` overrides `hitTest` and returns nil outside registered rects.
Verified: bubble/tail/character accept clicks, everything else passes through.
The dismissal fix falls out for free — a click in the gap reaches the window
below, and the app's existing global mouse monitor sees it and hides the panel.

### SwiftUI's `.regularMaterial` is NOT a substitute for `NSVisualEffectView`

The plan had been to move the vibrancy into SwiftUI as
`.background(.regularMaterial)` so the bubble could carry its own backdrop.
Walking the view tree shows this builds **no `NSVisualEffectView` at all** — the
result is a flat translucent fill with no behind-window blur.

So the effect view stays, just sized to the bubble instead of being the
`contentView`. Confirmed working as a sub-region: `material=6` (`.popover`),
`blendingMode=0` (`.behindWindow`).

The tail is still filled with `.regularMaterial`, which is a deliberate
compromise: at 11x18pt a flat fill matches the card closely enough, and the
alternative is a second effect view with a triangular mask.

### The shadow does trace irregular content

`hasShadow` + `isOpaque=false` derives the shadow from content alpha, and it
handles a detached character correctly — bubble and character get their own
shadows rather than one rectangular smear. It must be recomputed whenever the
silhouette changes, so `layout()` ends with `invalidateShadow()`; that is every
streamed delta.

### Anchoring inverted, and verified empirically

The old panel pinned its top-left and grew downward. This one pins the
**character** and grows the bubble away from it. Measured across state changes
in preview mode:

```
x=760.0 topY=1677.0 w=415.0 h=149.0
x=760.0 topY=1677.0 w=415.0 h=185.0
x=760.0 topY=1677.0 w=415.0 h=124.0
```

Constant x and top edge while the height moves — so the character does not
drift while an answer streams in.

The arrangement itself is `BubbleLayout.geometry` in `AskAICore`, not in the
panel: a tail one point off its bubble, or a character that shifts a pixel
between frames, are invisible in a passing build and glaring in use. They are
now assertions instead.

`PanelPlacement.bubbleSide` picks the flank, chosen **once per presentation**
rather than per layout pass — a bubble that flipped sides mid-answer because it
grew a line would throw the character across the text.

### Snapshot tool now composes the real layout

`SpriteSnapshot` renders through the same `BubbleLayout.geometry` the panel
uses, and emits both sides for every state, since the tail direction only gets
exercised near a screen edge in normal use. Same caveats as before: no vibrancy
offscreen, and the backdrop is drawn opaque so the transparent regions are
visible as a rectangle.

### The slow first invocation is the Keychain, not the panel

Worth writing down because it looks exactly like a panel bug and is not one. On
the first Services invocation after launch, the answer took 10-35 seconds to
start. Instrumenting `show()` settled it:

```
15:13:53.239664  service fires
15:13:53.269907  show build=11.3ms layout=16.0ms order=2.6ms key=0.2ms
15:14:02.917696  keychain read ok            <- 9.65s gap
15:14:02.920631  asking slot=1
```

All of it is the first `SecItemCopyMatching` in the sandboxed process, inside
`AppDelegate.makeOrchestrator()`. Building the panel -- four hosting views,
geometry, framing, shadow -- is 30ms cold and 0.6ms warm.

This predates the sprite work entirely and is visible in this session's earlier
logs on the previous build. It is also what the "first probe after launch did
nothing" note further up was actually seeing; that entry's guess about a stray
click was wrong.

**Still unfixed.** The first question after launch appears frozen. The read
happens on the main thread from the service handler, so nothing can draw. The
obvious fix is to warm it on a background queue at launch -- the orchestrator is
already built lazily and cached, so only the very first call pays -- but that is
a change to the LLM wiring, not to the panel, and has been left alone here.

The `show build=/layout=/order=/key=` line was kept rather than removed. In a
hand-bundled app with no debugger attached, one notice per panel presentation is
cheap and it is what turned a 35-second mystery into a one-line answer.

### The data protection keychain needs a provisioning profile — tested, not assumed

`kSecUseDataProtectionKeychain` is Apple's recommended replacement for the
legacy ACL model, and would remove the "enter your login password" dialog
entirely: access is decided by the app's access group rather than by a per-item
list of trusted binaries. Tested from the signed, sandboxed bundle
(`ASKAI_DPKEYCHAIN_TEST=1`):

```
dptest[legacy]         write+read=true OK
dptest[dataprotection] FAILED status=-34018
```

-34018 is `errSecMissingEntitlement`. The data protection keychain requires an
`application-identifier` (or `keychain-access-groups`) entitlement, and those
are only granted by an **embedded provisioning profile** — a Development
certificate on its own does not carry one. So this is not available to a
hand-bundled app signed with a bare identity, and `KeychainStore.useDataProtection`
stays off by default.

It becomes available if the app ever ships with a provisioning profile (App
Store, or Developer ID with a profile for the entitlement). The flag is in place
for that day.

### The prompt is a developer problem, not a user problem

Worth being clear, because it changes how much it matters: the login-password
dialog appears when an app tries to read a keychain item **created under a
different code identity**. Re-signing ad-hoc on every build creates a new
identity every time, so the developer sees it constantly.

An end user installing a properly signed build never hits it. Their app creates
the item itself when they paste their key in Settings, and the creating
application is automatically on the item's ACL. Nothing to authorize.

So the fix for the dev loop (a stable `ASKAI_SIGN_ID`) is not something users
need, and the data protection keychain is a nice-to-have rather than a blocker
for distribution.

### fal.ai is not needed — Google's image model answers over plain REST

`~/Desktop/sprite-sheet-creator` calls `fal-ai/nano-banana-pro`. That is Google's
model with fal as a paid middleman; the same repo's
`scripts/generate-resume-sprites.mjs` already prefers Google directly when
`GEMINI_API_KEY` is set. Confirmed with a direct call, no SDK:

```
POST .../v1beta/models/gemini-3-pro-image-preview:generateContent
     header x-goog-api-key
-> HTTP 200, one part, inlineData, 371 KB
   usage promptTokenCount=125 candidatesTokenCount=1400 (IMAGE 1120)
```

Single synchronous request returning bytes inline — no queue, no polling, no
third-party image host. And this app already talks to that host for the Gemini
preset, so when the active provider is Gemini the existing key covers both.

Two things the pipeline has to survive:

1. **The response is JPEG, not PNG.** Lossy, so the "white" background is not
   pure and there is ringing around dark outlines. Thresholds must be tolerant
   (225-235, not 250).
2. **The model draws grid lines.** Asked for a 2x3 grid it rendered visible cell
   borders, and those borders *enclose* each cell, so a flood fill from the image
   border cannot get inside: it reached 427676 of 859201 white pixels (49%).

That second one breaks `scripts/make-sprites.swift` as written, which fills the
whole sheet and slices afterwards.

**Fix, verified: slice first, then fill each cell from its own edges**, insetting
a few pixels past any border line.

```
cell(0,0) cleared=100%  cell(0,1) cleared=99%   cell(0,2) cleared=100%
cell(1,0) cleared=99%   cell(1,1) cleared=100%  cell(1,2) cleared=99%
```

Robust whether or not borders are drawn, so it is the right order regardless of
prompt tweaks. Grid fidelity itself was good: even cells, one character each,
none clipped, identity consistent across all six frames.

### PNG vs JPEG was the wrong question

Two documentation sources each named a field for requesting PNG from the image
API. Both are wrong; the live API rejects them:

```
generationConfig.imageConfig.imageOutputOptions.mimeType
  -> 400 Unknown name "imageOutputOptions" at 'generation_config.image_config'
generationConfig.responseFormat.mimeType
  -> 400 Unknown name "mimeType" at 'generation_config.response_format'
```

Format follows the model: `gemini-2.5-flash-image` returns PNG,
`gemini-3-pro-image-preview` returns JPEG.

But PNG does not give a cleaner background. Measured on the top margin:

```
JPEG (pro)    pure-255 white = 77%   distinct near-white values = 7
PNG  (flash)  pure-255 white = 29%   distinct near-white values = 10
```

The PNG model tints its background, so it is *less* pure than the lossy one.
Whatever the format, "white" cannot be assumed. Pick the model on image quality
instead — and on that, the pro model produced a genuinely varied walk cycle while
the flash model's six frames were nearly identical.

### Extraction: two approaches failed before one worked

Both models draw cell borders, and the flash model did so even when the prompt
explicitly forbade it. Those borders enclose each cell:

1. **Whole-sheet edge flood fill** (what `make-sprites.swift` does today):
   reached 427676 of 859201 white pixels, 49%. Blocked by the borders.
2. **Slice first, then fill each cell from its own edges**: fixed the JPEG sheet
   (99-100% per cell) but failed 2 of 6 cells on the PNG sheet at 50%, where the
   drawn box sits inside the nominal cell boundary.
3. **Grid detection by background-only row/column projection**: 0 usable gutters
   on the JPEG sheet (borders span the full height), 5 false ones on the PNG.

What works is **largest connected component per cell**: label non-background
components, keep the biggest, discard the rest. Borders and stray marks are
separate components and fall away. Verified on both sheets with a plain even
grid and no gutter detection:

```
JPEG (pro)    6/6 cells  bboxes 156-204 x 294-318
PNG  (flash)  6/6 cells  bboxes 141-161 x 212-214
```

Needs one guard: a component spanning >92% of the cell in both axes is a border,
not a character.

### How much of the JPEG survives into the PNG frames

The pro model is the quality choice but returns JPEG; the frames written are PNG
either way. Measured on one cell downscaled to 70x79, counting 5-bit colour
buckets among non-background pixels (real pixel art has few colours, ringing
invents many):

```
box-average resize      : 242
naive nearest-neighbour : 202
block-centre sampling   : 197
```

- **Smooth resizing is the actual mistake**, 20% worse than nearest-neighbour.
  It mixes ringing into every output pixel. `interpolationQuality = .none` in
  `make-sprites.swift` was already right.
- **Block-centre sampling helps, but only slightly.** Generated pixel art is a
  large image whose logical pixels are NxN blocks; sampling centres skips the
  ringing at block edges. The pitch is recoverable — a histogram of horizontal
  edge spacings peaked at 6px with multiples at 11-12 and 17-18, giving 5.64.
- **Most of the residual palette is the model's shading, not JPEG.** ~200 buckets
  is far more than hand-authored pixel art. Getting to a genuinely small palette
  needs explicit quantisation, which is separate work.

Recorded because the intuition "sample block centres and the JPEG artefacts
vanish" is appealing and wrong: it is a 2.5% improvement, not a fix.

## Sprite sets (PLAN-sprites.md Stage 0)

The character is no longer welded to the bundle. `SpriteSet` describes one
character as data — an animation per mood, each naming frames by basename — and
`SpriteSetStore` reads sets from Application Support, which inside the sandbox
resolves to the app's own container. `SpriteSet.builtIn` describes the vendored
character in code, so the fallback needs nothing on disk.

Three properties this stage exists to guarantee, all asserted:

- **A set missing a mood** falls back to the built-in animation *for that mood*,
  rather than leaving the panel with nothing to draw. Half-generated characters
  will be common in Stage 4.
- **A manifest is validated on decode.** Empty `frames` and a non-positive
  duration are rejected (an empty array would trap on the next subscript); an
  out-of-range `restingIndex` is clamped instead, because a bad resting frame is
  cosmetic and not worth discarding a usable character over.
- **A set whose frames are missing on disk is not "complete"** and is not used.
  That is the interrupted-generation case: the manifest lands but the PNGs did
  not. `save` writes the manifest *last* for the same reason.

`restingIndex` is now stored rather than derived. The shipped sequences are
authored to settle into their resting pose, so "last frame" was right for them,
but a generated animation may rest anywhere.

### Verification

`make snapshot` output was byte-identical to the pre-refactor baseline, which is
the check that matters: this stage was supposed to change no rendering at all.

The disk path was exercised end to end rather than assumed. A hand-built set was
installed into the container, and all three directions confirmed from logs:

```
1. installed  -> sprite set inverted "Inverted Guitarist" frames=10
2. one frame removed
              -> sprite set inverted unavailable; falling back to builtin
                 sprite set builtin "Guitarist" frames=10
3. restored   -> sprite set inverted "Inverted Guitarist" frames=10
```

The load is logged unconditionally, not just on failure. An absent warning is
much weaker evidence than a present confirmation, and "which character is
loaded" is the first thing worth knowing when one looks wrong.

## Frame extraction moved into the app (PLAN-sprites.md Stage 1)

`SpriteExtractor` in `AskAICore` replaces the script's whole-sheet flood fill.
`scripts/make-sprites.swift` is gone; `Sources/SpriteTool` is a thin CLI over the
same code, because a loose `swift scripts/…` script cannot import the package and
duplicating the logic was the thing to avoid.

The rule is **subtractive**, which is the part worth remembering: rather than
"find the character", it drops what is definitely *not* character — the drawn
cell border (a component spanning >92% of the cell in both axes) and specks below
2% of the main mass — and keeps the rest. Then it fills enclosed holes, so
background-coloured pixels *inside* the outline (the guitarist's eyes, the light
face of his guitar) survive.

Keeping only the single largest component would amputate a detached limb or a
held object. There is a synthetic test for that case; no real sheet has needed it
yet, so it is a guard rather than a fix.

### A misdiagnosis worth recording

A generated robot's legs looked missing in the extracted frame, and the
multi-component change above was made in response. Measuring afterwards showed
the frame's opaque rows ran 24...130 of 0...131 — transparent margin at the
bottom, so nothing was clipped, and the output was byte-identical before and
after the change. The legs were always there and were never a separate
component; the frames just looked truncated at contact-sheet size.

The lesson is the cheap one: check the pixel extents before changing an
algorithm on the strength of a thumbnail.

### Regression guards

Both held, and both are the point of the stage:

- `make sprites` reproduces the committed vendored frames **byte-identically**,
  using `Options.vendored` (threshold 235, no pixel-grid snapping) to match how
  they were originally cut.
- `make snapshot` output is byte-identical, so nothing about the panel changed.

Generated sheets, which the old algorithm could not handle at all, now extract
6/6 cells cleanly on both the JPEG and the PNG sample.

## Stage 2 GO/NO-GO: grid fidelity — passed 5/5

Five sheets generated fresh from `gemini-3-pro-image-preview`, deliberately
varied: three 2x3 walk cycles (robot, wizard, cat-in-a-suit) and two 2x2 pose
sheets (wizard, knight). Scored mechanically by `SpriteTool evaluate`, not by
eye — the pass bar was one character per cell, none clipped by a cell boundary,
and >95% of each cell's background cleared.

```
PASS  01-robot-walk    6/6   cleared 99/99/100/99/99/99%   bounds 126-174 x 264-270
PASS  02-wizard-walk   6/6   cleared 99/99/99/99/99/99%    bounds 167-230 x 338-342
PASS  03-cat-walk      6/6   cleared 99/99/99/99/99/99%    bounds 198-241 x 372-378
PASS  04-wizard-pose   4/4   cleared 99/99/99/99%          bounds 262-354 x 436-467
PASS  05-knight-pose   4/4   cleared 97/97/97/97%          bounds 261-410 x 441-447
==> 5/5 sheets pass
```

Then checked visually as well, because Stage 1's misdiagnosis came from trusting
a thumbnail: all 26 frames extract cleanly with fully transparent backgrounds.

**The detached-component guard earned itself.** The wizard pose sheet was prompted
with "a glowing magic orb floating in the air beside him, clearly separated from
his body and not touching him". The orb survives in all four frames. The
"keep only the largest component" version this replaced would have deleted it —
so the guard added speculatively in Stage 1 is now confirmed against real output,
not just a synthetic test.

**Consequence for the plan:** the expensive fallbacks are not needed. No prompt
tightening, no image-derived grid detection, and in particular no
divider-dragging UI — which was the outcome that would have roughly doubled the
feature. Fixed even-grid slicing plus subtractive extraction is enough.

Caveat worth keeping: five sheets from one model with one prompt family. A user
typing an arbitrary character description will find cases these did not. The
built-in set remains the fallback, and Stage 4's preview-before-save is what
stops a bad generation reaching the panel.

## Sprite generation client (PLAN-sprites.md Stage 3)

`GeminiImageClient` talks to `generateContent` directly — no SDK, no fal.ai, no
job queue. `SpriteGenerationJob` drives a one-line description through the model
and out as an installable `SpriteSet` plus its frames, and lives in `AskAICore`
so the whole flow is testable against a fake client with no network.

Two things the client must not get wrong, both covered by tests:

- **Auth is `x-goog-api-key`, not `Authorization: Bearer`.** The
  OpenAI-compatible client talks to the *same host* with the other scheme, so
  mixing them up would produce a confusing 401.
- **The response mime type is carried, never assumed.** Format follows the
  model, so anything writing bytes to disk must read it rather than guess `.png`.

A 200 carrying no image is a safety refusal, and the model explains itself in a
text part. That text is surfaced to the user, because "the model returned no
image" is useless next to what it actually said, and the error is marked
non-retryable — a refusal will not succeed on a second attempt.

### Verified live, including the path stubs cannot reach

One real run, `"a small round owl wearing tiny round spectacles"`:

```
[  0.0s] Designing the character…
[ 16.8s] Generating walk (1 of 2)…
[ 36.0s] Cutting out frames…
[ 36.4s] Generating pose (2 of 2)…
[ 52.6s] Cutting out frames…
==> 10 frames, 2 sheets, 53.1s
==> moods: confused, idle, searching, talking, thinking
```

The point of doing this live was the **reference-image path**: every sheet is
generated from the character image rather than the text, which is what holds
identity, and sending a generated image back as `inline_data` is a body shape no
stub can validate. It works, and identity held — the same owl, palette and
spectacles across both sheets. There is visible drift in proportion and detail
between sheets, which is the documented risk rather than a defect.

~53 seconds for a full character. That is why Stage 4 needs step-named progress
and a working cancel.

### Known limitation: the character changes size between moods

Each sheet is union-cropped independently, so the character fills a different
share of its frame depending on which sheet it came from:

```
walk-0  131px of 132  (99%)      pose-0  117px of 132  (88%)
walk-3  120px of 132  (90%)      pose-1  132px of 132  (100%)
```

Rendered at a fixed height, that is a ~12% size jump when the mood changes.
The fix is to normalise scale *across* sheets instead of within each one, which
needs both sheets in hand before either is cut. Deferred to Stage 6.

## Sprites tab (PLAN-sprites.md Stage 4)

`SpriteStudioModel` + `SpriteStudioView`, a third tab beside General and Prompts.
Describe a character, generate, look at the frames, keep or discard.

Four decisions worth keeping:

- **Nothing is written until the user keeps a preview.** That makes "cancel"
  trivially correct — there is no partial set to clean up, because a set is only
  ever saved by an explicit keep. It also means a bad generation costs money but
  never pollutes the character list.
- **Named progress steps, not a spinner.** The run takes ~53 seconds; a minute of
  undifferentiated spinning reads as a hang.
- **A cost warning before the first paid run.** Three image requests billed to
  the user's own key. They should not learn that from a bill.
- **The key field only appears when the key cannot be reused.**
  `SettingsStore.llmKeyWorksForImages` checks the configured base URL's *host*,
  not the preset id, because the URL is user-editable and the preset is only a UI
  hint. A lookalike host is rejected; there is a test for that.

`SpriteSet.makeID(from:)` moved into `AskAICore` rather than staying in the app
target. The id becomes a directory name and the description is whatever the user
typed, so traversal safety must be asserted against the real implementation, not
a copy in the test file that can drift. `"../../etc/passwd"` collapses to
`etc-passwd`.

Concurrency follows the rest of the AppKit layer: explicit main-thread hops, not
`@MainActor`. Adding the attribute pulled isolation checking into `AppDelegate`
and `SettingsWindowController`, which this package deliberately opts out of (see
Package.swift). The Keychain read runs on a detached task for the reason recorded
above.

### Verified

- `make snapshot` byte-identical: the panel itself is untouched.
- A character generated live by `SpriteTool generate` was installed into the
  app's real container, selected, and driven through a genuine Services
  invocation: `sprite set generated "a small round owl…" frames=10`, panel drawn
  at 415x165 growing to 239 as the answer streamed, no missing frames.

**Not verified: the buttons.** Generate / cancel / keep / discard need a human
clicking them. The logic behind each is tested, and the end-to-end path is
proven, but the wiring from button to model has only been read, not exercised.

## The character now thinks instead of walking

The first draft inherited walk/jump/attack from `~/Desktop/sprite-sheet-creator`.
That is a **platformer's** vocabulary, and this app explains highlighted words: a
character walking on the spot while an explanation loads reads as filler, and
celebrating when the answer arrives is the wrong gesture entirely.

The two sheets are now:

- **thinking** (6 frames, looping) — a ponder cycle: hand rising to the chin,
  resting there with eyes glancing up, head tilting, a finger tapping, returning.
  The prompt explicitly says "Do not show walking", because the model will
  otherwise reach for a walk cycle when asked for six frames of a character.
  Frame duration went 0.11s -> 0.18s; pondering at walking speed reads as
  agitation, and this is the one loop the user watches for several seconds.
- **poses** (4 frames) — attentive idle, explaining with a teaching gesture,
  puzzled shrug, searching. Position maps to mood, so the order is load-bearing.

Frame basenames stay `walk-N`. They are only filenames, and renaming them would
orphan every character already generated.

Both templates are now editable in Settings, with the same rules as the Services
prompt slots: `{{character}}` is substituted, and blanking the field restores the
default. A template that has lost its placeholder gets the description appended
rather than silently generating a character nobody asked for.

### The bug this uncovered: aspect ratio never reached the request

`SpriteSheetSpec.aspectRatio` was dead data. The job never passed it to the
client, so every sheet was generated at the client's default 4:3 — including the
pose sheet, which asks for a 2x2 grid. The model obliged the aspect ratio rather
than the prompt and returned **3x2**, which the extractor then sliced as 2x2,
cutting across frame boundaries and producing halves of two owls stitched
together.

Stage 2 did not catch this because its generation script passed the aspect ratio
explicitly; only the in-app path had the gap. The fix moves `aspectRatio` onto
the `generate` call — per request, not per client — and there is now a test
asserting each sheet's ratio reaches the request.

Worth remembering as a shape of bug: the extractor was fine, the prompt was fine,
and the two disagreed about the grid because a parameter silently went nowhere.
It was only visible by **looking at the frames**.

### Still open: the size jump is worse than measured

The ~12% mood-to-mood size difference recorded earlier is more noticeable with
these sheets — the pose frames carry more empty width than the thinking frames,
so the character reads as smaller when it starts explaining. Same cause: each
sheet is union-cropped independently. Stage 6.

## Animated character preview in Settings

The Sprites tab now shows the selected character animated, with a mood picker, so
choosing between characters is a matter of looking rather than remembering what a
name refers to. The same view animates a freshly generated character while the
user decides whether to keep it — the flat frame strip stays underneath, because
the animation shows whether it *reads* as thinking while the strip shows whether
any single frame came out mangled.

`FramePlayer` is deliberately separate from `SpriteAnimator`. The panel's
animator resolves frames from disk; Settings has to animate two things the panel
never does — a character that exists only in memory because it has not been kept
yet, and an arbitrary mood of an installed character. Both reduce to "these
images, in this order", which is a much smaller job.

Two things it inherits from the panel on purpose:

- **Reduce Motion is honoured.** A preview arguably exists to show motion, so
  this is the one place ignoring it could be defended — but an app that respects
  the setting everywhere except where it matters is just inconsistent. The view
  says why the character is holding still instead of leaving it looking broken.
- **The timer stops when the window closes.** `windowWillClose` calls
  `stopPreview()`, and `show()` restarts it. A character animating in a window
  nobody can see is exactly the battery cost the panel is careful to avoid.

Mood labels in the picker describe what the user would see happen ("Thinking
about an answer") rather than the enum case, which is named for the panel state
it comes from.

## Managing characters (PLAN-sprites.md Stage 5)

Rename, delete and regenerate, plus size on disk. The built-in character is
protected from all three: it ships read-only inside the bundle and is the
fallback for everything else.

Three things were more delicate than "add three buttons" suggests:

- **Deleting the character the panel is currently showing.** Order matters:
  the selection moves to the built-in *first*, so the panel is already looking
  elsewhere, and only then are the files removed and the frame cache dropped.
  Doing it the other way leaves the panel pointed at a directory that no longer
  exists. There is belt-and-braces here too — `activeSpriteSet` already refuses
  to return a set whose frames are missing, and a test asserts the fallback holds
  even if the UI never moved the selection.
- **Rename is not `save`.** `save` requires the frames in memory, and re-reading
  several megabytes of PNG to change one string would be absurd, so `rename`
  rewrites only the manifest. The **id does not change**: it is the directory
  name, and moving it would orphan the selection stored in settings. So a
  character can be called anything without its identity moving.
- **Regenerate reuses the id**, which is what makes it replace rather than
  accumulate a near-duplicate — and is exactly why `SpriteLoader.forget` has to
  run, or cached frames from the previous version keep winning.

An empty rename restores the old name silently rather than raising an error: it
is a slip, not a decision worth a banner.

### Characters made under the old prompts cannot be fixed in place

The mole, the owl and anything else generated before the thinking/explaining
redesign have walk-cycle **art**. No manifest edit turns a walk cycle into
pondering — the frames are the actions. Regenerate is the only fix, and it costs
a paid run per character, so it is a button rather than something the app does on
anyone's behalf.

## Robustness and one shared scale (PLAN-sprites.md Stage 6)

### The character no longer changes size between moods

Each sheet used to be scaled to `targetHeight` from **its own** union crop. So a
character the model happened to draw at 213px in one sheet and 240px in another
came out the same height in both — which means the *same pose* ended up at two
different sizes, and the character visibly grew when it started thinking. The
side-by-side mood preview in Settings made it obvious; a minute apart in the
panel, it was easy to miss.

Extraction is now two phases. `measure` finds each sheet's crop and masks;
`render` draws onto a canvas that is the union across **all** sheets, at one
scale. Relative sizes the model drew are preserved, which is what makes the
moods look like one character. Frames are bottom-aligned on the canvas rather
than centred: characters stand on the ground, so a shorter pose should read as
crouching, not floating.

Measured on a regenerated character — every frame now shares a 168x132 canvas:

```
walk-0  content  93x109      pose-0 (idle)       91x114
walk-3  content  93x119      pose-1 (explaining)139x121
                             pose-2 (puzzled)   168x124
```

`pose-0` at 91x114 against `walk-0` at 93x109 is the point: the resting body is
now the same size in both sheets. The wider poses are wider because the character
genuinely spreads its wings, which is correct rather than a scale artefact.

The single-sheet path is unchanged and the vendored frames are still
byte-identical, because one sheet's canvas is its own crop.

### Limits on user-supplied content

Frames can be hand-installed, not only generated, so `save` now validates before
writing anything: an empty frame is rejected, a frame over 1 MB is rejected (a
132px PNG is tens of kilobytes), and the total across all characters is capped at
100 MB. Validation happens **before** the first write, so a refusal leaves nothing
behind — the manifest-last ordering only protects against interrupted writes, not
invalid ones. Replacing a character does not count against the budget twice, or
regenerating would eventually be refused for no reason.

### A tooling mistake worth recording

Two contact sheets in this session rendered **stale data**. They were made by
`sed`-ing a path into a copy of an earlier script, and the pattern did not match,
so the copy silently kept reading the original directory while writing to a
new-looking filename. One of them was used to claim the aspect-ratio fix worked.

The numbers were right throughout — the measurement scripts used a substitution
that did match — but the pictures were of the wrong thing. The contact sheet now
takes its directory as an argument and prints how many frames it found, so it
cannot quietly render nothing or something else.

Two conclusions in this session have now been reached by looking at an image;
both times the image needed checking as carefully as the code.
