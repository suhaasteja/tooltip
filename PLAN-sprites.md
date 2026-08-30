# PLAN — user-generated sprites

Let users create their own character from a text prompt in Settings, instead of
being stuck with the one sheet vendored into the bundle.

Written 2026-08-30. **Revised the same day** after verifying that Google's image
model can be called directly, which removed fal.ai from the design entirely.

---

## 0. Read this first

**RULE 1 — No queue, no polling, no third-party image host.** Verified below:
`generativelanguage.googleapis.com` returns the image bytes inline from a single
`generateContent` POST. Anything reintroducing a job queue is a step backwards.

**RULE 2 — Slice before removing the background.** Not the other way round. This
is load-bearing and counter-intuitive; the reasoning is in Stage 1.

**RULE 3 — One stage, one commit**, matching PLAN.md.

**RULE 4 — Generation costs the user real money.** Every design decision that
can avoid a call should.

---

## What was verified, 2026-08-30

### Google's image model works over plain REST — fal.ai is unnecessary

The reference implementation (`~/Desktop/sprite-sheet-creator`) calls
`fal-ai/nano-banana-pro`. That *is* Google's model; fal is a paid middleman.
Its own `scripts/generate-resume-sprites.mjs` already auto-selects Google
directly when `GEMINI_API_KEY` is set, falling back to fal only otherwise.

Confirmed by direct call, no SDK:

```
POST https://generativelanguage.googleapis.com/v1beta/models/
     gemini-3-pro-image-preview:generateContent
header  x-goog-api-key: <key>
body    {"contents":[{"parts":[{"text": ...}]}],
         "generationConfig":{"imageConfig":{"aspectRatio":"4:3","imageSize":"1K"}}}

-> HTTP 200, one part, inlineData, 371 KB
   usage: promptTokenCount=125 candidatesTokenCount=1400 (IMAGE 1120)
```

Consequences, all simplifications:

- **No second vendor, and possibly no second API key.** This app already talks
  to `generativelanguage.googleapis.com` — the current configuration on this
  machine is the Gemini preset. A Google AI Studio key works for both the LLM
  and image generation, so when the active provider is Gemini the existing key
  can be reused. Only non-Gemini users need to supply a separate one.
- **One synchronous request per sheet.** fal is submit → poll → fetch; this is a
  single POST returning bytes. Stage 3 loses an entire class of complexity, and
  `URLSession` + `StubURLProtocol` cover it exactly like the LLM clients.
- **Billed as tokens**, which is the same mental model as the rest of the app.

### Two things the API does that the pipeline has to survive

**It returns JPEG, not PNG.** `mimeType=image/jpeg`. No alpha channel (expected
— we add it), but also lossy: the "white" background is not pure white, and
there is ringing around the character's dark outline. Background removal cannot
threshold at 250 and hope. 225–235 held up in testing.

**It draws grid lines.** Asked for a 2x3 grid, the model helpfully rendered
visible black cell borders. Those borders **enclose each cell**, so a flood fill
starting at the image border cannot get inside:

```
white pixels total    = 859201
reached by flood fill = 427676  (49%)
>>> flood fill BLOCKED — grid lines enclose the cells
```

This breaks `scripts/make-sprites.swift` as currently written, which fills the
whole sheet first and slices afterwards.

### The fix, verified

Reverse the order: **slice into cells first, inset past any border line, then
flood fill each cell from its own edges.**

```
cell(0,0) background cleared=100%  content=204x294  OK
cell(0,1) background cleared=99%   content=157x307  OK
cell(0,2) background cleared=100%  content=199x300  OK
cell(1,0) background cleared=99%   content=162x318  OK
cell(1,1) background cleared=100%  content=205x307  OK
cell(1,2) background cleared=99%   content=163x318  OK
>>> SLICE-THEN-FILL WORKS
```

Robust whether or not the model draws borders, so it is the right approach even
if a prompt tweak suppresses them.

### Grid fidelity — the Stage 2 gate, largely answered

The generated sheet honoured the requested 2x3 grid exactly: even cells, one
character per cell, none clipped, identity consistent across all six frames.
Content bounds vary 157–205 x 294–318, which is normal for a walk cycle and well
within what a shared union crop handles.

**One sheet is not a rule.** Stage 2 still runs, but the risk it was written to
catch now looks low, and the expensive fallback (a divider-dragging UI) is
unlikely to be needed.

---

## Stage 0 — Make sprite sets data-driven

No network, no new UI. Today `SpriteMood.animation` hardcodes frame names and
`SpriteLoader` reads one fixed directory inside the read-only app bundle.

- `SpriteSet` value type in `AskAICore`: id, display name, and a mood →
  (frames, duration, loops, resting frame) mapping. Codable, written as a small
  manifest beside the frames.
- `SpriteMood.animation` becomes a lookup on the active set instead of a
  `switch`; today's hardcoded values become the built-in set's manifest.
- `SpriteLoader` gains a second search path:
  `Application Support/<bundle-id>/Sprites/<set-id>/`, falling back to the
  bundled default. The app is sandboxed, so this resolves inside the container —
  correct, and writable.
- `SettingsStore` gains `activeSpriteSetID`.

**Verify.** `make test` green, `make snapshot` byte-identical. A hand-made set
dropped into Application Support is picked up with no code change or relaunch.

**Why first.** It de-risks everything else, is the only stage touching the
working panel, and stands alone: even if generation is abandoned, an artist can
hand you a character.

---

## Stage 1 — Frame extraction into the app, slice-then-fill

Port `scripts/make-sprites.swift` into `AskAICore` as pure functions, **and fix
the ordering while porting**.

New pipeline, per sheet:

1. Slice into `columns x rows` cells on the nominal grid.
2. Inset each cell by a few pixels to skip a drawn border line.
3. Flood fill **that cell** from **its own** edges — this is the change.
4. Union bounding box across all cells, applied to all of them, so frames stay
   aligned and playback does not jitter.
5. Nearest-neighbour downscale.

Keep the alpha threshold tolerant of JPEG ringing (225–235, not 250), and keep
the flood fill rather than a plain threshold so white *inside* the character
survives.

- CoreGraphics/ImageIO only, no AppKit, so it stays testable in the core target.
- `scripts/make-sprites.swift` becomes a thin CLI over the same functions — one
  implementation, and the script keeps working.

**Verify.** Unit tests on a synthetic sheet: known grid, solid squares on white,
**plus a variant with drawn grid lines** — that case is the regression guard for
this whole stage. Assert frame count, transparent corners, opaque centres, and
interior white preserved. Re-running `make sprites` on the vendored sheets must
still produce byte-identical committed frames.

---

## Stage 2 — GO/NO-GO: grid fidelity across several generations

One fresh sheet passed (above). Confirm it was not luck.

Generate **five** sheets — a mix of the 6-frame walk and the 4-pose set, with
different character prompts — and run Stage 1's extractor over each.

**Pass condition.** For at least 4 of 5: one character per cell, none clipped by
a cell boundary, background cleared >95% per cell, and union-cropped frames
aligned well enough that playback does not jitter.

**If it fails**, in order of preference:

1. Tighten the prompt — explicit grid, generous margins, "do not let the
   character touch the cell edges", and "no borders or grid lines". Cheapest.
2. Detect cell boundaries by projecting alpha onto each axis to find gutters,
   instead of assuming an even grid. Moderate, no UI.
3. Build the divider-dragging UI the reference implementation has. Roughly
   doubles the feature; should trigger a conversation about whether it is worth
   it rather than being done silently.

**Verify.** Record actual pass/fail counts in NOTES.md. Do not generalise from
three sheets.

---

## Stage 3 — Gemini image client

- `SpriteGeneratorClient` protocol + `GeminiImageClient` in `AskAICore`,
  mirroring the LLM layer's shape because it already works and is tested.
- Single POST per sheet. Decode `candidates[0].content.parts[].inlineData`,
  base64, `mimeType` — do not assume PNG.
- Two calls per character: one for the base character, then one **per sheet**
  passing the character image back as an input part. Generating each sheet from
  the text prompt alone produces a different-looking character each time;
  passing the image is what holds identity.
- Key resolution: reuse the configured LLM key when the provider is Gemini,
  otherwise a separate Google key under a **new account** on the existing
  Keychain service. `KeychainStore` is already parameterised for this.
- Reuse the existing error-envelope mapping where possible — this is the same
  host the OpenAI-compatible client already talks to.

**Verify.** `StubURLProtocol` tests for success, 400, 429, malformed payload,
missing key, and a response whose part carries no `inlineData`. Then one real
generation by hand, with timing recorded in NOTES.md. No live calls in the suite.

---

## Stage 4 — Settings: generate a character

A new **Sprites** tab in the existing Settings window.

- Prompt field, with the pixel-art/white-background style suffix appended
  invisibly, as the reference implementation does.
- Key field **only when the active provider is not Gemini**; otherwise say the
  existing key is being reused.
- **A cost warning before the first call.** Several paid requests per character.
- Step-named progress ("character", then "walk cycle", "poses") — the whole
  thing takes tens of seconds.
- Cancel that actually cancels.
- Animated preview of extracted frames before committing.
- Save writes the set and switches to it; discard leaves everything untouched.

**Verify.** Generate from cold, preview, save, and see it in a real Services
invocation without relaunching. Cancel mid-flight; confirm no partial set is
written.

---

## Stage 5 — Manage sets

- List, switch, rename, delete.
- The built-in set is undeletable and is the fallback.
- Regenerate one animation without redoing the character.

**Verify.** Delete the active set while the panel is open — falls back to the
built-in rather than showing an empty character or crashing.

---

## Stage 6 — Robustness

- A manifest referencing missing frames degrades to the built-in, never traps.
  `SpriteLoader` already returns nil and logs; keep that under the new path.
- Cap disk use; runaway sets must not fill the container.
- Reduced Motion honoured for generated sets — the manifest records the resting
  frame rather than assuming the last one.
- Frames are user-supplied content now: validate dimensions and reject absurd
  sizes before decoding.

---

## Risks worth naming

- **Cost.** A few paid calls per character on the user's own key. Mitigated by a
  warning, by dropping fal's middleman, and by not needing a background-removal
  API at all.
- **Identity drift between sheets.** Passing the character *image* into each
  sheet call is the mitigation; if the model drifts anyway the character visibly
  changes between moods.
- **Latency.** Tens of seconds. Async, cancellable, never on the main thread —
  the Keychain incident in NOTES.md is the cautionary tale.
- **JPEG artefacts.** Lossy edges make background removal fuzzier than it was
  with the vendored PNGs. Tolerant thresholds and per-cell fill handle it; very
  low-contrast characters against white may still smear.
- **Quality is unbounded.** Users will generate bad characters and blame the
  app. Preview-before-save is the mitigation.
- **`gemini-3-pro-image-preview` is a preview model.** Preview endpoints get
  renamed and retired. The model id must be configurable, not hardcoded, exactly
  as `LLMConfiguration.model` already is.
