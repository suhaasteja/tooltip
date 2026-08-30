# BACKLOG

Parked work, with the reasoning behind it so it does not have to be
re-derived. Nothing here is started.

---

## 1. Rename the app

**Why:** "AskAI" is generic — the whole category is named this way
(AI Popover, AI Text Assistant), and "AI" in a product name dates badly.

**Do it before real use, not after.** Changing `CFBundleIdentifier` orphans:

- the Keychain item → stored API key is lost
- the sandbox container → all settings are lost
- the `pbs` registration → needs `pbs -flush` + reinstall

Cheap now. Expensive once someone has been using it for a month.

### Candidates, with availability checked (2026-08-28)

| Name | Status |
|---|---|
| **Gloss** | ✅ No macOS app found. A gloss *is* a brief explanation of a passage — semantically exact. |
| **Aside** | ✅ No macOS app found. Describes the UX: a quiet remark off to the side. |
| **Wisp** | ⚠️ Unchecked. Best if the character direction wins (see below). |
| **Pip** | ⚠️ Unchecked. 3 letters. Collides with Python's `pip` in dev contexts. |
| **Blip** / **Mote** | ⚠️ Unchecked. |
| **Loupe** | ❌ Taken — colour picker on the Mac App Store. |
| **Glean** | ❌ Taken — Glean, enterprise search, ships Mac + Safari apps. |
| **Gist** | ❌ Conceptual collision with GitHub Gist. |
| **Nib** | ❌ `.nib` is an Interface Builder file — confusing for a Mac dev tool. |

**Constraint that drove the shortlist:** the name renders in every context menu
as `<Name>: Explain`, so past ~6 characters it crowds. `Sidenote: Summarise`
is right at the limit.

**Competitors are all literal compounds** (PopClip, Contexter, WordWand,
ActionClip, OnText), so a short evocative single word would stand out.

### Files a rename touches

- `Resources/Info.plist` — `CFBundleIdentifier`, `CFBundleName`,
  `CFBundleExecutable`, `NSPortName`, and all four `NSMenuItem` titles
- `Package.swift` — target and product names
- `Sources/AskAI/Log.swift` — log subsystem
- `Sources/AskAICore/KeychainStore.swift` — default service name
- `Makefile` — `APP_NAME`
- `scripts/fire-service.swift` — the `"Ask AI: "` item-name prefix
- `skills/askai-setup/SKILL.md`, `README.md`, `MANUAL-QA.md`, this file

Then: `make install && pbs -flush`, relaunch, re-bind shortcuts.

---

## 2. Sprite character

> **Built.** The character stands outside the card with a speech bubble and a
> tail, driven by `SpriteMood` off `PanelState`. Geometry is
> `BubbleLayout.geometry` in `AskAICore` (tested), the flank comes from
> `PanelPlacement.bubbleSide`, and `ShapedContainer` keeps the window's
> transparent regions click-through. See NOTES.md.
>
> Note for anyone reading the original plan below: moving the vibrancy into
> SwiftUI as `.background(.regularMaterial)` does **not** work — it builds no
> `NSVisualEffectView` and produces a flat fill with no blur. The effect view
> stayed, sized to the bubble.
>
> Still open: the bubble has no scroll affordance of its own beyond the
> inherited 420pt cap, and the character does not persist between invocations.
>
> **Next:** letting users generate their own character from a prompt, the way
> `~/Desktop/sprite-sheet-creator` does. Staged plan in `PLAN-sprites.md`.

**Idea:** instead of a text card, a small animated character appears at the
selected text and delivers the answer in a speech bubble.

**Why it is cheap from here:** `PanelState` already carries exactly the states a
character needs moods for, and the panel is already borderless, transparent,
non-activating and floating. The AppKit work is done.

| `PanelState` | Character |
|---|---|
| `.loading` | thinking — bobbing, blinking |
| `.success` | talking — speech bubble with the answer |
| `.failure` | confused — shrug |
| `.emptySelection` | looking around |

The Stage-8 anchoring fix matters here: the character appears at the user's
text, not down in the Services menu where the pointer ended up.

### Two asset routes

- **Vector, in SwiftUI shapes.** No assets to ship, scales freely, looks
  Mac-native. Limited to simple designs — a floating blob with eyes that
  squash, blink and bob. A *wisp* suits this well (soft glow, floaty motion).
  Buildable without an artist.
- **Sprite sheet.** PNG frames supplied by a human or an image generator, with
  a frame player built around it. Higher art ceiling, but the asset must be
  owned and licensed.

### Open questions

- Does the speech bubble scroll for long answers, or does the character stay
  small and the bubble become the existing panel?
- Does the character persist between invocations, or appear and vanish?
- Reduced-motion accessibility setting should disable the bobbing.

---

## 3. Known gaps carried over from the build

- **Per-app Services coverage is unmeasured.** `MANUAL-QA.md` §6 has the table;
  it needs a human clicking through real apps. Do this before making any
  "works everywhere" claim.
- **Live-API verification: done for one path only.** `OpenAICompatibleClient`
  with streaming, against Gemini's compatibility endpoint, through a real
  Services invocation — HTTP 200, answer rendered. See NOTES.md.
  **`AnthropicClient` against the real Anthropic API remains unexercised**, and
  it differs in auth header, body shape, SSE events and `output_config.effort`.
- **Stage 9 (universal hotkey) not started**, deliberately. See NOTES.md — it
  requires Accessibility, which is incompatible with the App Sandbox. A
  middle path exists: global hotkey that reads the *existing* clipboard
  (user presses ⌘C first), which needs no permissions and keeps the sandbox.
- **macOS 27 reportedly ships a built-in AI popover** for selected text. Does
  not make this redundant — bring-your-own-model, local LLMs and editable
  prompts are all things it will not do — but worth knowing before investing
  in branding.

---

## 4. Distribution

Investigated 2026-08-30. The app is already sandboxed, which is the expensive
prerequisite most projects fail on, so the remaining work is signing and
packaging rather than architecture.

**The Keychain password prompt is a developer problem, not a user problem.** It
fires when an app reads an item created under a *different* code identity, and
ad-hoc signing mints a new identity every build. A user installing a signed
build never sees it: their app creates the item itself and is automatically on
its ACL. This does not block shipping. See NOTES.md.

| Option | Cost | User experience | What this codebase still needs |
|---|---|---|---|
| **A. Source + `make install`** | free | needs CLT (~2 GB) and a terminal | nothing — works today, `skills/askai-setup` covers it |
| **B. Unsigned .zip** | free | Gatekeeper blocks; right-click → Open, or strip the quarantine xattr | nothing, but a bad first impression |
| **C. Developer ID + notarised** | $99/yr | double-click, opens clean | hardened runtime, notarise step, icon, real bundle id |
| **D. Homebrew Cask** | free, on top of C | `brew install --cask` | a tap plus a GitHub release |
| **E. Mac App Store** | $99/yr | best trust, worst iteration | C's work plus review and an App ID — **and it is the only route that unlocks the data protection keychain** |

### Four things that must happen before anything public

1. **`CFBundleIdentifier` is still the placeholder `com.yourname.AskAI`.** This
   puts §1 (rename) on the critical path: changing it after release orphans
   every user's stored key, settings container and `pbs` registration. Cheap
   now, breaking later.
2. **No hardened runtime.** `scripts/bundle.sh` does not pass
   `--options runtime`, and notarisation rejects builds without it. One flag,
   but it interacts with the sandbox and needs testing.
3. **No app icon.** `Info.plist` has no `CFBundleIconFile`.
4. **Per-app Services coverage is still unmeasured.** README deliberately
   refuses to claim "works everywhere"; in public that gap becomes support load.

### Recommendation

Ship **A** properly first — the audience for a bring-your-own-key Services tool
is technical, it costs nothing, and it surfaces the real app-coverage picture
before any money is spent. Then **C + D** for reach. **E** only for the data
protection keychain or App Store trust; the review friction is real for an app
whose core feature is "bring your own LLM key".

Caveat on C and E: both bind releases to a paid Apple account, and certificates
expire (Developer ID ~5 years, Development ~1). That is a renewal obligation on
anything already shipped.
