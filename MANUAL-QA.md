# MANUAL-QA

Everything here needs a human. Automated coverage (88 tests + scripted Services
dispatch) is in the test suite and `make probe`; this file is only the residue
that genuinely cannot be automated without granting Accessibility/Screen
Recording permissions to a frequently re-signed binary — which PLAN.md Stage 9
warns leads to TCC permission loops.

Work top to bottom. Stop and record anything that fails.

## 0. Clean install

```sh
make clean && make install
open /Applications/AskAI.app
/System/Library/CoreServices/pbs -flush     # required after any NSServices change
make services                                # should list all four slots
```

- [ ] Menu bar shows the sparkle icon
- [ ] **No** Dock icon appears
- [ ] `make services` lists `askAI1`–`askAI4` with the four titles

## 1. Basic round trip

In TextEdit, type and select a sentence, then right-click → Services →
**Ask AI: Explain**.

- [ ] Panel appears **at the pointer**, not centred or at a screen corner
- [ ] TextEdit's title bar stays active (the panel must not steal focus)
- [ ] The selection stays selected in TextEdit
- [ ] Spinner shows, then an answer replaces it
- [ ] Panel grows to fit the answer without covering the pointer

## 2. Dismissal

- [ ] Escape closes the panel
- [ ] A click outside closes the panel
- [ ] The × button closes the panel
- [ ] Clicking *inside* the panel does **not** close it
- [ ] Selecting text inside the answer works, and Copy puts it on the clipboard

## 3. All four slots

For each of Explain / Summarise / Translate / Custom:

- [ ] Appears in the Services menu
- [ ] Produces a visibly *different* style of answer for the same selection

## 4. Prompt editing without a rebuild

Settings → Prompts → slot **Summarise** → replace the body with
`Rewrite the following as a single haiku:\n\n{{selection}}` → close Settings.

- [ ] Re-invoking **Ask AI: Summarise** returns a haiku
- [ ] No rebuild, reinstall, or relaunch was needed
- [ ] "Restore default" puts the original prompt back

## 5. Keyboard shortcut path

Menu bar → **Open Services Shortcuts…** (or System Settings → Keyboard →
Keyboard Shortcuts → Services).

- [ ] All four AskAI entries are listed there
- [ ] A shortcut can be bound to one of them
- [ ] Selecting text and pressing that shortcut behaves identically to the menu

## 6. App coverage baseline — **the table README.md is waiting on**

For each app: select a sentence, right-click → Services, and note whether the
AskAI entries appear and whether firing one produces an answer. Keep
`make logs` running in a terminal; a line tagged
`[com.yourname.AskAI:service]` proves the invocation reached the app.

| App | Entries appear? | Fires correctly? | Notes |
|---|---|---|---|
| TextEdit | | | |
| Safari | | | |
| Notes | | | |
| Mail | | | |
| Terminal | | | |
| *(add any others you care about)* | | | |

Copy the finished table into `NOTES.md` and summarise it in `README.md`.

If an app shows no entries, ask it why:

```sh
defaults write <that-app-bundle-id> NSDebugServices com.yourname.AskAI
# relaunch that app, reproduce, check Console, then:
defaults delete <that-app-bundle-id> NSDebugServices
```

## 7. Live API key

Settings → paste a real key → Save key.

- [ ] Status line reads "A key is stored."
- [ ] An invocation returns a real answer
- [ ] **Streaming on** (default): text appears progressively, not all at once
- [ ] **Streaming off**: answer appears in one go; both paths work
- [ ] "Remove" deletes the key and the next invocation shows
      "No API key set. Add one in Settings." with **no** Retry button

## 8. Failure handling

- [ ] With no key: friendly message, no Retry (it is not retryable)
- [ ] With a deliberately wrong key: "API key rejected", no Retry
- [ ] With Wi-Fi off: network message **with** a Retry button, and Retry works
      once the network is back
- [ ] Invoke with nothing selected (or only whitespace): "No text selected."

## 9. Superseding

- [ ] Invoke on a long selection, then immediately invoke on a different one
- [ ] Only the second answer ever appears; the first never overwrites it

## 10. Multi-display / edges

- [ ] Pointer near the right screen edge: panel flips left, stays fully on screen
- [ ] Pointer near the bottom edge: panel flips above the pointer
- [ ] On a second display: panel appears on *that* display
- [ ] Over a full-screen app: panel is visible above it
- [ ] After switching Spaces: panel still appears on the current Space

## 11. Launch at login

Settings → General → Launch at login.

- [ ] Toggling on reports no warning (app must be in `/Applications`)
- [ ] After a logout/login cycle, AskAI is running
- [ ] Toggling off stops that happening

## 13. Demo pass — `DEMO.md`

`DEMO.md` is a single document written to exercise everything at once, and is
the fastest way to check a build by hand. Open it in TextEdit (or any app with a
Services menu) and work down it.

It is arranged so that highlighting your way through hits the awkward cases
without having to remember them: terms at the top-left, terms at the right
margin where the bubble must flip flanks, a paragraph for Summarise, sentences
in German and Japanese for Translate, a self-contained question for the Custom
slot, deliberately awkward selections, and a bottom section for the flip-above
case.

What to watch for, in the order the document raises it:

| Section | Should happen |
|---|---|
| 1 | Panel appears beside the word, character adjacent to it |
| 2 | Near the right edge the bubble flips to the character's left |
| 3 | Summarise keeps the causal chain, not just the nouns |
| 4 | Translate handles both Latin and non-Latin script |
| 5 | Custom sends the selection with no added instruction |
| 6 | Scrolling the page closes the panel; scrolling *inside* it does not |
| 7 | Whitespace-only selection shows the searching character, not an error |
| 8 | At the bottom of a window the panel flips above, character just above the word |

---

## 12. Long and awkward input

- [ ] A selection over 8,000 characters is truncated with a visible marker
- [ ] Emoji and non-Latin scripts survive intact in the panel
- [ ] A code block with `{` `}` and a literal `{{selection}}` is not mangled
