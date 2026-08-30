# PLAN — user-generated sprites

Let users create their own character from a text prompt in Settings, the way
`~/Desktop/sprite-sheet-creator` does, instead of being stuck with the one
sheet vendored into the bundle.

Written 2026-08-30, against the state at `feat: move the character outside the
card into a speech bubble`.

---

## 0. Read this first

**RULE 1 — Stage 2 is a go/no-go gate.** Everything downstream assumes a
generated sheet can be sliced into usable frames *without* a human dragging grid
lines. The reference implementation has draggable dividers precisely because
image models do not reliably honour a grid. If fixed-grid slicing does not hold,
stop and re-plan: the honest alternative is a frame-editing UI, which is a much
larger feature than "type a prompt, get a character".

**RULE 2 — No network before Stage 3.** Stages 0–2 are refactors and local image
work. They are independently valuable: they make the sprite system data-driven
whether or not generation ever ships.

**RULE 3 — One stage, one commit**, matching PLAN.md.

**RULE 4 — Generation costs the user real money.** Every design decision that
can avoid an API call should. This is why Stage 1 exists.

### What the reference implementation does

`sprite-sheet-creator` (Next.js) runs a four-step pipeline:

1. `fal-ai/nano-banana-pro` — prompt → one character image, white background.
2. `fal-ai/nano-banana-pro/edit` — that image → a sprite sheet, one call per
   animation (walk 2x3, jump 2x2, attack 2x2). Passing the character image is
   what keeps identity stable across sheets; generating each sheet from the text
   prompt alone would produce a different-looking character each time.
3. `fal-ai/bria/background/remove` — white background → transparent PNG.
4. Client-side canvas slicing, with **user-adjustable grid dividers**.

Its `FAL_KEY` lives server-side in a Next.js API route. We have no server, so the
key has to be the user's own, in the Keychain, exactly like the LLM key.

### Three places this app must differ

- **Step 3 is probably unnecessary.** `scripts/make-sprites.swift` already does
  background removal locally by border flood fill, and it handled the reference
  sheets cleanly — including preserving white *inside* the character. That
  removes an API call, a cost, and a dependency. Bria is better on complex
  backgrounds, but our prompt asks for a white one.
- **The animations are wrong for us.** Walk/jump/attack is a platformer's
  vocabulary. This app needs the five `SpriteMood` cases. The existing vendored
  set already proves the mapping: a 6-frame walk for `.thinking`, and a 4-pose
  sheet (crouch / celebrate / kneel / stand) covering `.talking`, `.confused`,
  `.searching` and `.idle`.
- **Slicing must move into the app.** It is currently a build-time script run by
  a developer. It has to become runtime code, which means it has to become
  testable code.

---

## Stage 0 — Make sprite sets data-driven

No network, no new UI. Today `SpriteMood.animation` hardcodes frame names
(`walk-0`…`walk-5`, `pose-0`…`pose-3`) and `SpriteLoader` reads one fixed
directory inside the app bundle, which is read-only.

- Introduce a `SpriteSet` value type in `AskAICore`: an id, a display name, and
  a mood → (frame names, duration, loops) mapping. Codable, so it can be written
  as a small manifest beside the frames.
- `SpriteMood.animation` becomes a lookup on the active set rather than a
  `switch`. The current hardcoded values become the built-in set's manifest.
- `SpriteLoader` gains a second search path: user sets in
  `Application Support/<bundle-id>/Sprites/<set-id>/`, falling back to the
  bundled default. Note the app is sandboxed, so this resolves inside the
  container — that is fine and is the correct location.
- `SettingsStore` gains `activeSpriteSetID`, defaulting to the built-in.

**Verify.** `make test` green. `make snapshot` byte-identical to before. Copy a
hand-made set into Application Support, point the setting at it, and the panel
uses it with no code change and no relaunch.

**Why first.** It de-risks everything else, and it is the only stage that
touches the working panel. If generation is later abandoned, this still leaves
the app able to load a character an artist supplied by hand.

---

## Stage 1 — Move frame extraction into the app

Port `scripts/make-sprites.swift` into `AskAICore` as pure functions: border
flood fill, union bounding box across frames, nearest-neighbour downscale.

- Input: image data + grid (columns, rows). Output: per-frame image data.
- No AppKit — CoreGraphics/ImageIO only, so it stays in the core target and
  under test.
- Rewrite `scripts/make-sprites.swift` as a thin CLI over the same functions, so
  there is exactly one implementation and the script keeps working.

**Verify.** Unit tests over a synthetic sheet: a known grid of solid squares on
white, asserting frame count, transparency at the corners, opaque centres, and
that interior white survives the fill. Re-running `make sprites` produces frames
byte-identical to the committed ones — that is the real regression test.

**Note.** This is where the "no extra API call" bet gets paid off or lost. If
local flood fill turns out to be inadequate on real generated sheets in Stage 2,
Bria goes back on the table as Stage 3a.

---

## Stage 2 — GO/NO-GO: slice a real generated sheet

Take sheets generated by `sprite-sheet-creator` *today* — including at least one
generated fresh, not the three already vendored — and run Stage 1's extractor
over them with a fixed grid.

**Pass condition.** For at least 4 of 5 generated sheets: every cell contains
exactly one character, no character is clipped by a cell boundary, and the union
crop leaves frames aligned enough that playback does not jitter.

**If it passes**, generation can be a one-shot "type a prompt, get a character"
flow and the plan continues as written.

**If it fails**, stop. The options are, in order of preference:

1. Tighten the prompt (explicit grid, generous margins, "do not let the
   character touch the cell edges") and re-test. Cheapest fix.
2. Auto-detect cell boundaries by projecting alpha onto each axis and finding
   the gutters, rather than assuming an even grid. Moderate work, no UI.
3. Build the divider-dragging UI the reference implementation has. This roughly
   doubles the feature and should force a conversation about whether it is worth
   it.

**Verify.** Write the actual pass/fail counts into NOTES.md. Do not record a
verdict from three sheets and call it a rule.

---

## Stage 3 — fal.ai client

Mirror the shape the LLM layer already uses, because it works and is tested.

- `SpriteGeneratorClient` protocol + a `FalClient` conformer in `AskAICore`.
- fal is queue-based: submit returns a request id, then poll status, then fetch
  the result. That is different from the LLM clients' single request/response
  and needs its own tests for the polling loop, including timeout and failure.
- Key in the Keychain under a **new account** on the existing service —
  `KeychainStore` is already parameterised for exactly this. It must not collide
  with the LLM key.
- Two calls per generation: character, then one sheet per animation. Sheets
  reference the character image URL so identity holds.
- Everything through `URLSession`, tested with the existing `StubURLProtocol`.
  No live calls in the suite.

**Verify.** Stubbed tests for submit/poll/success, poll/failure, timeout,
malformed payload, and missing key. Then exactly one real generation, run by
hand, with the request and timing recorded in NOTES.md.

---

## Stage 4 — Settings: generate a character

A new **Sprites** tab in the existing Settings window.

- fal.ai key field, same treatment as the LLM key.
- Prompt field, with the fixed style suffix appended invisibly (pixel art,
  centred, white background) exactly as the reference implementation does.
- **A cost warning before the first call.** Each generation is several paid
  requests. Users should not discover this from a bill.
- Progress that names the step ("generating character", "generating walk cycle",
  2 of 3), because the whole thing takes tens of seconds.
- Cancel that actually cancels.
- Preview the extracted frames, animated, before committing.
- Save writes the set to Application Support and switches to it. Discard leaves
  everything untouched.

**Verify.** Generate a character from a cold start, preview it, save it, and see
it appear in a real Services invocation without relaunching. Cancel mid-flight
and confirm no partial set is written.

---

## Stage 5 — Manage sets

- List installed sets, switch active, rename, delete.
- The built-in set is undeletable and is the fallback if a user set is missing
  or corrupt.
- Regenerate a single animation without redoing the whole character.

**Verify.** Delete the active set while the panel is open; the app falls back to
the built-in rather than showing an empty character or crashing.

---

## Stage 6 — Robustness

- A set whose manifest references missing frames must degrade to the built-in,
  not trap. `SpriteLoader` already returns nil and logs rather than crashing;
  keep that property under the new loading path.
- Cap disk use; a runaway set count should not fill the container.
- Reduced Motion still honoured for generated sets — `restingFrame` must be
  meaningful, so the manifest has to record which frame is the resting one
  rather than assuming the last.
- Frames are user-supplied content now: validate dimensions and reject absurd
  sizes before decoding.

---

## Risks worth naming up front

- **Cost and rate limits.** Several paid calls per character, on the user's own
  key. Mitigated by a warning and by not calling Bria.
- **Identity drift between sheets.** Generating each sheet from the character
  *image* rather than the text prompt is what prevents it; if the edit model
  drifts anyway, the character will visibly change between moods.
- **Latency.** Tens of seconds. The whole flow must be async, cancellable, and
  must never touch the main thread — the Keychain incident in NOTES.md is the
  cautionary tale.
- **Quality is unbounded.** Users will generate bad characters and blame the
  app. Preview-before-save is the mitigation.
- **Scope.** Stage 2 failing turns this from a weekend feature into an image
  editor. That is the whole reason it is a gate.
