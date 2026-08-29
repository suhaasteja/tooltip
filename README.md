# AskAI

A background macOS app that adds **"Ask AI"** entries to the system Services
menu. Select text in almost any app, invoke the service (right-click → Services,
or a keyboard shortcut you bind yourself), and the selection is sent to Claude
with a prompt you control. The answer appears in a floating panel at the pointer
without taking focus away from what you were reading.

No Dock icon. No main window. A menu bar item and a Settings window.

---

## Requirements

- macOS 13 or later (developed and verified on macOS 26).
- **Command Line Tools only — full Xcode is not required.**
  ```sh
  xcode-select --install
  ```
  Swift 5.9+ (verified on 6.2). No external package dependencies.
- An Anthropic API key, unless you only want to try the mock (see below).

## Install

```sh
make install     # builds, ad-hoc signs, and copies to /Applications
open /Applications/AskAI.app
```

Two steps that are easy to skip and both matter:

1. **It must live in `/Applications`.** Launch Services does not reliably scan
   build directories, and a service it cannot see is a service that does not
   appear.
2. **Launch it once** so it registers. If the entries still do not show up:
   ```sh
   /System/Library/CoreServices/pbs -flush
   ```
   This is also required any time the Services entries themselves change — the
   cache will otherwise keep serving the previous set (see NOTES.md).

Confirm registration at any time:

```sh
make services    # dumps this app's entries from the Services registry
```

## Set your API key

Menu bar → **Settings…** → paste the key → **Save key**. It is stored in the
login Keychain, never in preferences. Verified working from the sandboxed,
ad-hoc-signed bundle.

To try the app with no key at all:

```sh
ASKAI_MOCK_LLM=1 /Applications/AskAI.app/Contents/MacOS/AskAI
```

## Use it

Select text anywhere, then right-click → **Services** → one of:

| Entry | Default behaviour |
|---|---|
| Ask AI: Explain | Explains the selection in plain language |
| Ask AI: Summarise | Summarises it in a few sentences |
| Ask AI: Translate | Translates to English, or to Spanish if already English |
| Ask AI: Custom | Sends the selection with no added instruction |

Escape or a click outside dismisses the panel. The answer is selectable and
there is a Copy button.

### Keyboard shortcuts

System Settings → Keyboard → Keyboard Shortcuts → Services, or use the menu bar
item's **Open Services Shortcuts…** entry. Each of the four slots can be bound
separately.

---

## The four-slot constraint — read this before being disappointed

**You can edit what the four prompts say. You cannot add a fifth.**

`NSServices` is read from the app bundle's `Info.plist` when the app registers,
and there is no API to add entries at runtime. So the app ships four slots whose
**menu titles are frozen at build time** and whose **prompt bodies are editable**
in Settings → Prompts and stored in `UserDefaults`.

Adding or renaming a slot means editing `Resources/Info.plist`, adding the
matching `@objc askAIN` method in `ServiceProvider.swift`, then
`make install && pbs -flush`. That is the real ceiling for a Services-based app,
and pretending otherwise would just produce a confusing UI.

Use `{{selection}}` in a prompt to mark where the selected text goes. If the
placeholder is missing, the selection is appended rather than dropped.

## App coverage is not universal

Services availability depends on each app answering
`validRequestorForSendType:returnType:` — it is not something this app controls.
Text-heavy AppKit apps generally work; some Electron apps and terminal emulators
either omit the Services menu or put nothing usable on the pasteboard.

**The per-app baseline for this machine has not been filled in yet** — it needs a
human clicking through real apps. See `MANUAL-QA.md` for the checklist and
NOTES.md for how to record results. I have deliberately not written a coverage
table I did not observe.

---

## Development

```sh
make build      # debug build
make test       # run the test suite (see the note below)
make bundle     # release build -> dist/AskAI.app, ad-hoc signed
make run        # bundle + launch from dist/
make install    # bundle + copy to /Applications
make probe      # fire a service from another process and report what happened
make logs       # live log stream
make entitlements  # show what is actually signed into the bundle
make clean
```

### `make test`, not `swift test`

XCTest ships with Xcode, not the Command Line Tools, so the suite uses
swift-testing. SwiftPM cannot locate `Testing.framework` on a CLT-only install
(`xcrun --show-sdk-platform-path` fails there), and CLT's
`_Testing_Foundation.framework` is missing its `Modules` directory. `make test`
supplies the framework search path and disables cross-import overlays to work
around both. A bare `swift test` will fail with `no such module 'Testing'` —
that is expected, not a broken checkout. Full detail in NOTES.md.

### Layout

| Target | Contents |
|---|---|
| `AskAICore` | Everything pure and testable: pasteboard normalization, panel placement math, panel state machine, prompt templating, LLM client + SSE parsing, Keychain, settings. |
| `AskAI` | Thin AppKit shell: app delegate, services provider, panel window, settings window. |

If logic is hard to test, it is in the wrong target.

**88 tests, all offline.** Networking is exercised through a stubbed
`URLProtocol`; nothing in the suite makes a real request.

### Debugging

```sh
make logs
/System/Library/CoreServices/pbs -dump_pboard | grep -A12 AskAI
```

`log` is a zsh **builtin** — always write `/usr/bin/log` explicitly, or you get
silent empty output that looks exactly like "the app logged nothing".

---

## Security note

The API key is held in the login Keychain, which is appropriate for personal
use. It is still extractable by anything running as you. If this app is ever
distributed, point `LLMConfiguration.baseURL` at a small proxy that holds the
key server-side instead of shipping one; the base URL is configurable precisely
so both modes work.

## Known gaps

- Per-app Services coverage is unmeasured (see above).
- The end-to-end path has been verified with the mock client and with real
  Services dispatch; a run against a live API key is still a manual step.
- Streaming is implemented and unit-tested against the SSE wire format, but has
  not been exercised against the live endpoint.
