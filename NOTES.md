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
