---
name: askai-setup
description: Build, install and configure AskAI — a macOS Services-menu tool that sends selected text to an LLM and shows the answer in a floating panel. Use when the user wants to set up AskAI, change its LLM provider (Anthropic, Gemini, LiteLLM, Ollama, LM Studio), bind a keyboard shortcut to it, or when AskAI's Services entries are missing or not firing.
---

# Setting up AskAI

AskAI adds four **Ask AI:** entries to the macOS Services menu. The user selects
text in any app, invokes one, and the selection goes to an LLM with a
configurable prompt; the answer appears in a floating panel at the pointer.

Work through the steps in order. Several have non-obvious failure modes that are
called out — do not skip the verification commands, because the common failures
are all *silent*.

## Before you start

Confirm you are in the AskAI repository (`Package.swift` names `AskAI`, and
`Sources/AskAI/ServiceProvider.swift` exists). Requirements: macOS 13+, Command
Line Tools (`xcode-select -p`). **Full Xcode is not needed.**

## Step 1 — Build and install

```sh
make install
```

This builds a release binary, assembles `dist/AskAI.app`, ad-hoc signs it with
the sandbox entitlements, and copies it to `/Applications`.

**It must be in `/Applications`.** Launch Services does not reliably scan build
directories, and a service it cannot see never appears. Do not substitute
`make run`.

## Step 2 — Launch once so it registers

```sh
open /Applications/AskAI.app
```

## Step 3 — Verify registration before going further

```sh
make services
```

Expect all four entries with `NSMessage = askAI1` … `askAI4`. If you see fewer,
or the wrong titles, the Services cache is stale:

```sh
/System/Library/CoreServices/pbs -flush
```

then quit and relaunch the app and re-run `make services`. A stale cache returns
a *plausible but outdated* list rather than an empty one, so read the output
rather than just checking the command succeeded.

## Step 4 — Choose the LLM provider

Ask the user which they want, then apply it. **Quit the app first** — preferences
are cached, and a running app will overwrite your changes on exit.

Note the path: this app is sandboxed, so its preferences live in its container,
**not** `~/Library/Preferences`.

```sh
pkill -x AskAI
PREFS="$HOME/Library/Containers/com.yourname.AskAI/Data/Library/Preferences/com.yourname.AskAI"
```

| Provider | Commands |
|---|---|
| Anthropic (default) | `defaults delete "$PREFS" llm.provider 2>/dev/null; defaults delete "$PREFS" llm.baseURL 2>/dev/null; defaults delete "$PREFS" llm.model 2>/dev/null` |
| Gemini (direct) | `defaults write "$PREFS" llm.provider -string openai`<br>`defaults write "$PREFS" llm.baseURL -string "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"`<br>`defaults write "$PREFS" llm.model -string "gemini-2.5-flash"` |
| LiteLLM proxy | `defaults write "$PREFS" llm.provider -string openai`<br>`defaults write "$PREFS" llm.baseURL -string "http://localhost:4000/v1/chat/completions"`<br>`defaults write "$PREFS" llm.model -string "gemini/gemini-2.5-flash"` |
| Ollama | `defaults write "$PREFS" llm.provider -string openai`<br>`defaults write "$PREFS" llm.baseURL -string "http://localhost:11434/v1/chat/completions"`<br>`defaults write "$PREFS" llm.model -string "llama3.2"` |
| LM Studio | `defaults write "$PREFS" llm.provider -string openai`<br>`defaults write "$PREFS" llm.baseURL -string "http://localhost:1234/v1/chat/completions"`<br>`defaults write "$PREFS" llm.model -string "local-model"` |

Then `open /Applications/AskAI.app`.

The same choices exist in the app's own Settings window (menu bar ✨ → Settings…
→ General → Provider), which is friendlier — prefer directing the user there
unless they explicitly asked you to script it.

Local providers need no API key. Skip Step 5 for Ollama and LM Studio, and for
LiteLLM unless their proxy requires one.

## Step 5 — API key (hand this to the user)

**Do not try to script this.** The key belongs in the login Keychain, and
writing it from the command line does not reliably grant the sandboxed app
access to the item. Tell the user:

> Menu bar ✨ → **Settings…** → paste the key into **API key** → **Save key**.
> The status line should change to "A key is stored."

⌘V works there. (An earlier version had no Edit menu, so paste silently did
nothing; if the user reports that, they are on a stale build — re-run `make install`.)

To demo with no key at all:

```sh
pkill -x AskAI; ASKAI_MOCK_LLM=1 /Applications/AskAI.app/Contents/MacOS/AskAI &
```

## Step 6 — Bind a keyboard shortcut

This is GUI-only in practice; walk the user through it. The `pbs`
`NSServicesStatus` preference can in principle be written directly, but that is
**unverified** — do not script it without testing.

1. Menu bar ✨ → **Open Services Shortcuts…**
   (System Settings → Keyboard → Keyboard Shortcuts…)
2. The sheet may open on whatever category was last used — click **Services** in
   the left sidebar. There is no public URL anchor that goes deeper.
3. Expand the collapsed categories (`>` arrow) and find the four `Ask AI:`
   entries — most likely under **Text**.
4. **Tick the checkbox** for the entry. An unticked service cannot take a
   shortcut, and this is the step people miss.
5. Double-click the right-hand column of that row, then press the combination.
6. **Done**.

Recommend **⌥⌘E** for Explain; **⌃⌥⌘E** if that conflicts. Warn them:

- **`fn` cannot be used.** Cocoa key equivalents encode only ⌘ ⌥ ⌃ ⇧ — there is
  no representation for fn/Globe, and fn+E is the system emoji picker.
- Avoid bare ⌥+letter (dead keys for accents).
- The frontmost app wins any conflict, so a two-modifier combo can work in one
  app and silently do nothing in another.

## Step 7 — Verify end to end

Ask the user to select a sentence in TextEdit and invoke
right-click → Services → **Ask AI: Explain**.

To check without touching the UI, fire a real Services dispatch from a separate
process:

```sh
SLOT=Explain swift scripts/fire-service.swift "Photosynthesis in one sentence."
```

Expected: `NSPerformService(...) -> true`, an `AskAI window ...` line, and
`frontmost app:` naming something *other* than AskAI (the panel must not steal
focus).

Watch what the app itself did:

```sh
make logs     # then reproduce
```

A line tagged `[com.yourname.AskAI:service]` proves the invocation arrived.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `Ask AI` in the Services menu | Not in `/Applications`, never launched, or stale cache | `make install`, launch it, `pbs -flush` |
| Wrong/old entries in `make services` | Stale `pbs` cache | `pbs -flush`, relaunch, re-check |
| Entries present, nothing happens | Check `make logs` — no service line means it never reached the app | Confirm the checkbox in Step 6.4 is ticked |
| "No API key set" | Key not saved, or a local provider is selected that needs one | Step 5 |
| "Could not reach the server. Is it running?" | Local LLM server is down or wrong port | Start it; check `llm.baseURL` |
| Panel shows nothing / empty selection | The app published no usable text | Expected in some Electron apps and terminals — not fixable from here |
| Shortcut works in one app only | Modifier collision | Use three modifiers |
| `swift test` fails with `no such module 'Testing'` | XCTest is Xcode-only; the suite uses swift-testing with CLT workarounds | Use `make test`, never bare `swift test` |

## Things you cannot automate

Be honest with the user about these rather than pretending:

- **The API key** — Keychain + GUI (Step 5).
- **The keyboard shortcut** — System Settings only, in practice.
- **Per-app coverage** — whether a given app offers the service depends on that
  app answering `validRequestorForSendType:`, which cannot be inspected from
  outside it. `MANUAL-QA.md` §6 has the checklist; only a human clicking through
  real apps can fill it in.
