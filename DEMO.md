# DEMO — text to exercise the tool on

Open this in any app with a Services menu (TextEdit, Xcode, Safari via a
`file://` URL, most editors) and highlight things. It is written to be the kind
of thing this tool is *for*: dense technical prose where a term you half-know
stops you, and asking your agent about it would cost a turn, some context, and
your place in what you were reading.

The layout is deliberate. Terms sit at the start of lines, at the far right of
long ones, on the first line, and on the last — so highlighting your way through
also exercises the panel's edge placement. There is a long paragraph for
Summarise, a non-English sentence for Translate, and enough length to scroll.

---

## 1. The one-word lookups

`errSecMissingEntitlement` is the first term in this document on purpose: it sits
at the top-left, which is where the panel has the least room to hang above.

Read the next few lines and stop at anything you would otherwise have asked
about. Each is a real term from this project's own build logs.

- A **designated requirement** is the rule a signature says future versions must satisfy.
- **Ad-hoc signing** produces a signature with no team identifier and no stable identity.
- The **hardened runtime** is the opt-in set of protections notarisation insists on.
- **`LSUIElement`** is the Info.plist key that makes an app run without a Dock icon.
- **`pbs`** is the pasteboard server, which caches the Services menu aggressively.
- **`NSRequiredContext`** must be present even when empty, or the service silently vanishes.
- A **keychain ACL** is the list of applications allowed to read one stored item.
- **`kSecUseDataProtectionKeychain`** opts into the keychain that has no ACLs at all.
- A **sandbox container** is the private directory a sandboxed app may actually write to.
- **Server-sent events** are the newline-delimited stream format the answer arrives in.

## 2. Terms that live at the right margin

These lines are long on purpose: the term you want sits near the right edge, where the panel has to flip its bubble to the other flank.

Rendering pixel art correctly means avoiding any resampling that blends neighbouring pixels, which is why the extractor uses **nearest-neighbour**.

Finding the character in a generated sheet means labelling every run of adjacent non-background pixels, a technique called **connected-component labelling**.

The bitmap format the whole pipeline passes around stores colour already multiplied by opacity, which is known as **premultiplied alpha**.

Accessibility settings exist for real medical reasons; the one that suppresses animation is aimed at people with **vestibular** disorders.

## 3. A paragraph for Summarise

Highlight this whole paragraph and use *Ask AI: Summarise*. It is deliberately
overstuffed, in the way a design document or a model's own explanation often is,
and the useful test is whether the summary keeps the causal chain rather than
just the nouns. The panel is anchored to a point in screen coordinates rather
than to the selected text, because tracking the text itself would require the
Accessibility API, and granting that permission to a frequently re-signed
ad-hoc binary causes a permission loop that is worse than the problem it solves.
Anchoring to a point has a consequence: once the page scrolls, the panel is
pointing at whatever slid underneath it, so it dismisses on scroll instead of
following. That is not a workaround but a convention — the system's own Look Up
popover behaves identically, for the same underlying reason. The anchor itself is
not the live pointer either, because opening a context menu and travelling down
to Services drags the cursor well below the word; a right-click within the last
thirty seconds is a much better guess at where you were looking, and the
keyboard-shortcut path, which has no click, falls back to the pointer.

## 4. A sentence for Translate

Highlight the line below and use *Ask AI: Translate*.

> Der Bildschirmrand ist genau die Stelle, an der die meisten Tooltips versagen.

And one more, in a different script:

> 選択したテキストの近くに表示されることが最も重要です。

## 5. Custom slot

*Ask AI: Custom* sends the selection with no added instruction, so it is the slot
to point at something that already contains its own question:

> In one sentence: why would a flood fill starting at the border of an image fail
> to remove the background from a grid of cells that have been drawn with visible
> borders?

## 6. Scroll behaviour

Highlight anything above, get an answer, then scroll this document. The panel
should close rather than drift. Then get another answer and scroll **inside** the
panel itself, if the answer is long enough to need it — that should not close it.

## 7. Deliberately awkward selections

- A single character: `x`
- A selection with a lot of leading whitespace and internal line breaks:

        one
        two

- A term containing a URL, which models like to reformat: https://developer.apple.com/documentation/appkit/nspasteboard
- An emoji run that is not text at all: 🦉📎🔍
- Something with no meaningful content, to see the empty-selection character: `   `

## 8. The bottom edge

Everything from here down exists so there is text near the bottom of a maximised
window. The panel should flip above the word rather than hanging off the screen,
and the character should sit just above your selection, not float far over it.

Scroll so this line is at the very bottom of your window, then highlight the last
term in the document, which is **idempotent**.
