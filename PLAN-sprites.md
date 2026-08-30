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

**RULE 2 — Extract the character per cell, do not "remove the background".**
Slice first, then keep the largest connected component in each cell. Edge flood
fill and grid detection were both tried and both failed on real generated sheets;
the evidence is below and the rule exists so it is not re-litigated.

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

### Output format is a model choice, not a parameter

Two documentation sources each gave a field for requesting PNG. **Both are
wrong**, confirmed by 400s from the live API:

```
generationConfig.imageConfig.imageOutputOptions.mimeType
  -> 400 Unknown name "imageOutputOptions" at 'generation_config.image_config'
generationConfig.responseFormat.mimeType
  -> 400 Unknown name "mimeType" at 'generation_config.response_format'
```

The format follows the model:

```
gemini-2.5-flash-image      -> image/png
gemini-3-pro-image-preview  -> image/jpeg
```

**But chasing PNG turns out to be the wrong goal.** Measured on the top margin
of each sheet:

```
JPEG (pro)    pure-255 white = 77%   distinct near-white values = 7
PNG  (flash)  pure-255 white = 29%   distinct near-white values = 10
```

The PNG model's background is a faintly tinted off-white, so it is *less* pure
than the lossy JPEG. Format was never the problem. Any background removal has to
tolerate a non-white "white" regardless of which model is used, so pick the model
on image quality, not on mime type.

Quality note from the two samples: the pro model produced a genuinely varied walk
cycle (legs clearly change position); the flash model's six frames are nearly
identical, which makes for a poor animation. That is the real tradeoff.

### Both models draw cell borders, and asking them not to does not work

Asked for a 2x3 grid, both models rendered visible cell boxes — the flash sheet
did so even with "Do NOT draw any borders, grid lines, frame separators" in the
prompt. Prompt-based suppression is not reliable and must not be depended on.

Those borders **enclose each cell**, which defeats edge-based flood fill.
`scripts/make-sprites.swift` as written fills the whole sheet then slices:

```
whole-sheet fill: reached 427676 of 859201 white pixels (49%) -- BLOCKED
```

Slicing first and filling each cell from its own edges fixes the JPEG sheet but
**still fails on the PNG one**, where the drawn box sits inside the nominal cell:

```
cell(0,1) cleared=50%  FAIL      cell(1,1) cleared=50%  FAIL
```

Detecting the grid from the image instead of assuming it does not rescue this
either — projecting background-only rows/columns found 0 usable gutters on the
JPEG sheet (borders span the full height) and 5 false ones on the PNG sheet.
This is precisely why the reference implementation ships draggable dividers.

### The algorithm that does work: largest connected component

Per cell, label connected components of non-background pixels and **keep only
the largest**. A drawn border is its own component and gets discarded; so does
stray noise. Verified on both sheets with a plain even grid, no gutter detection:

```
JPEG (pro)    6/6 cells  bboxes 156-204 x 294-318
PNG  (flash)  6/6 cells  bboxes 141-161 x 212-214
>>> LARGEST-COMPONENT WORKS on both
```

Guard: a component spanning >92% of the cell in both axes is a border, not a
character, and should be rejected rather than kept.

This handles drawn borders, tinted backgrounds and JPEG ringing in one step, and
it removes the need for both edge flood fill and grid detection.

### Model choice: pro, and configurable

**Decision: default to `gemini-3-pro-image-preview`.** It produces a genuinely
varied walk cycle where the flash model's six frames were nearly identical, and
animation quality is the whole point of the character. The model id is
configurable, exactly as `LLMConfiguration.model` is — which matters more here
than for the LLM, because **output format follows the model**, so changing it
changes the bytes the pipeline receives.

### Getting a trustable PNG out of a JPEG source

The pro model returns JPEG; the frames we write are PNG regardless. The question
is how much of the JPEG's damage survives into them. Measured, downscaling one
cell to 70x79 and counting 5-bit colour buckets among non-background pixels —
real pixel art has few colours, ringing invents many:

```
box-average resize      : 242
naive nearest-neighbour : 202
block-centre sampling   : 197
```

Three conclusions, in order of how much they matter:

1. **Never smooth-resize.** Box-averaging is 20% worse than nearest-neighbour
   because it mixes ringing back into every output pixel. The existing script
   already uses nearest-neighbour with `interpolationQuality = .none`; keep it.
2. **Block-centre sampling is a real but small win** (197 vs 202, ~2.5%).
   Generated pixel art is a large image whose logical pixels are NxN blocks, and
   sampling block centres skips the ringing that lives at block edges. The pitch
   is recoverable from the image: a histogram of horizontal edge spacings peaked
   hard at 6px with multiples at 11-12 and 17-18, giving a fractional pitch of
   5.64. Worth doing, not worth contorting the pipeline for.
3. **Most of the remaining palette is the model's own shading, not JPEG.** ~200
   buckets is far more than hand-authored pixel art would use. If "trustable"
   means a small, crisp palette, that needs an explicit quantisation step
   (median-cut to 32-64 colours), which is separate work and should be judged on
   how the result looks rather than on the bucket count.

An earlier draft of this plan claimed block-centre sampling made the artefacts
vanish. It does not; it improves them slightly. The measurement is above so the
claim is not repeated.

### Grid fidelity — Stage 2's gate

Both sheets honoured the requested 2x3 grid: even cells, one character per cell,
none clipped, identity consistent across all six frames. Content bounds are
consistent within each sheet, which is what a shared union crop needs.

**Two sheets is not a rule**, and the first attempt at an extraction algorithm
already failed on the second sheet. Stage 2 still runs in full.

---

## Stage 0 — Make sprite sets data-driven — **DONE**

> Shipped. `SpriteSet` + `SpriteSetStore` in `AskAICore`, `SettingsStore
> .activeSpriteSetID`, and `SpriteLoader` resolving per set. 157 tests (was
> 138); `make snapshot` byte-identical; a hand-installed set was loaded, its
> fallback proved by breaking it, and restored. See NOTES.md.

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

## Stage 1 — Frame extraction into the app — **DONE**

> Shipped as `SpriteExtractor` in `AskAICore`, with the script replaced by the
> `SpriteTool` target so there is one implementation. 170 tests (was 157).
> Vendored frames and panel snapshots both byte-identical. See NOTES.md.

Port `scripts/make-sprites.swift` into `AskAICore` as pure functions, **and
replace the algorithm while porting**. Edge flood fill is kept only for the
vendored sheets' regression test; generated sheets need the component approach.

New pipeline, per sheet:

1. Slice into `columns x rows` cells on the nominal even grid.
2. Per cell, label connected components of non-background pixels and keep the
   **largest**. Reject it as a border if it spans >92% of the cell in both axes.
3. Union bounding box across all kept components, applied to every cell, so
   frames stay aligned and playback does not jitter.
4. Estimate the block pitch from a histogram of horizontal edge spacings, and
   resample at block centres. Falls back to plain nearest-neighbour when the
   histogram has no clear peak — the difference is small (197 vs 202 colour
   buckets), so this must never be allowed to fail loudly.
5. **Never box-average or otherwise smooth-resize.** It is measurably the worst
   option (242 buckets) because it mixes JPEG ringing into every output pixel.
   `interpolationQuality = .none` stays.

Background is "light" rather than "white": threshold around 200, not 250. The
PNG model's background is tinted and the JPEG model's rings around outlines, so
neither is pure. Do **not** rely on the prompt suppressing cell borders — both
models drew them anyway.

- CoreGraphics/ImageIO only, no AppKit, so it stays testable in the core target.
- `scripts/make-sprites.swift` becomes a thin CLI over the same functions — one
  implementation, and the script keeps working.

**Verify.** Unit tests on synthetic sheets: known grid of solid squares, **plus
a variant with drawn cell borders and a variant on a tinted background** — those
two are the regression guards for this whole stage, because they are exactly what
broke the first two attempts. Assert frame count, transparent corners, opaque
centres, interior light pixels preserved, and that a border-only cell is
rejected rather than returned as a character. Re-running `make sprites` on the
vendored sheets must still produce byte-identical committed frames.

---

## Stage 2 — GO/NO-GO: grid fidelity — **PASSED 5/5**

> **GO.** Five freshly generated sheets, three 2x3 walk cycles and two 2x2 pose
> sheets, all pass. No prompt tightening, no grid detection, and no
> divider-dragging UI needed. See NOTES.md.

One fresh sheet passed (above). Confirm it was not luck.

Generate **five** sheets — a mix of the 6-frame walk and the 4-pose set, with
different character prompts — and run Stage 1's extractor over each.

**Pass condition.** For at least 4 of 5: one character per cell, none clipped by
a cell boundary, background cleared >95% per cell, and union-cropped frames
aligned well enough that playback does not jitter.

**If it fails**, in order of preference:

1. Tighten the prompt — explicit grid, generous margins, "do not let the
   character touch the cell edges". Cheapest, but note that asking for no
   borders already failed once, so do not assume prompt fixes stick.
2. Detect cell boundaries from the image rather than assuming an even grid.
   **Already tried the obvious version** — projecting background-only rows and
   columns — and it found 0 usable gutters on one sheet and 5 false ones on the
   other. A smarter variant would have to detect the drawn border lines
   themselves. Moderate work, no UI, uncertain payoff.
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
- **Backgrounds are not white and borders get drawn.** Both are handled by the
  largest-component algorithm, but a character that is itself very light against
  a tinted background may be partly eaten by the threshold. A character split
  into two disconnected pieces (a detached accessory, a floating weapon) would
  lose the smaller piece — worth a test in Stage 2.
- **Quality is unbounded.** Users will generate bad characters and blame the
  app. Preview-before-save is the mitigation.
- **`gemini-3-pro-image-preview` is a preview model.** Preview endpoints get
  renamed and retired. The model id must be configurable, not hardcoded, exactly
  as `LLMConfiguration.model` already is — and since output format follows the
  model, changing it changes the bytes the pipeline receives.
