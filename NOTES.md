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
