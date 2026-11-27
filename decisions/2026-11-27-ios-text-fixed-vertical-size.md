# iOS Text keeps the height its wrapped lines need

- Date: 2026-11-27
- Status: accepted
- Linear: MOB-562

## Context

On iOS, a plain `:text` that should wrap was sometimes cut to one line ending
in "…" inside a Column, with a blank strip of about the lost height lower in
the same card. `max_lines` was not set. The mob_mishka gallery showed it on
the accordion "Multiple open" and "Always one open" bodies, toast, toggle and
field captions, menu, preview_card, number_field, empty_state and floating
window bodies, and on many code blocks. The same kind of Text wrapped
elsewhere on the same page.

The cause is how SwiftUI places a stack, not the width. A vertical ScrollView
sizes its content with no height limit, so every Column reports the height
its wrapped children need. The content is then placed at exactly that height,
and each Column (a `VStack`) places its children inside the concrete height it
was given. A `VStack` shares that height out by flexibility: least flexible
child first, each offered an equal share of what is left. A Text with no
`.lineLimit` and no `.fixedSize` counts as flexible, because it can drop lines
and end in "…". Take a card `[title, description, accordion, code block]`.
The accordion (tall, a little flexible) is placed before the code block (more
flexible). It is offered an equal share that is smaller than its ideal
height, and the cut lands on its Text bodies. The code block is then offered
more than it can use, and the difference is the blank strip after it. So
whether a Text was squeezed depended on its siblings.

On the iPhone 18 Pro simulator the unfixed build matched the baseline
captures. Adding `.fixedSize(horizontal: false, vertical: true)` to the
vertical ScrollView's own `VStack` (the content-detent sheet already does
this) left the accordion page unchanged. That only affects the scroll's
direct children, and the squeeze happens in Columns nested below them.

The 2026-09-14 record (`2026-09-14-ios-stack-gap-and-row-text-priority.md`)
rejected forcing Text to its fixed ideal size, because a Text that never
narrows could overflow a constrained Row. That concern is about width.

## Decision

- The `.label` case applies `.fixedSize(horizontal: false, vertical: true)` to
  every Text. Its width still comes from the parent, so it wraps, and the Row
  text priority and `weight` still decide how wide it is. Its height is always
  what those lines need, so no stack can count it as flexible or give it less.
  Containers built only from such Text are then inflexible too, so the fix
  holds at any depth.
- This applies with and without `max_lines`. `.lineLimit` caps the ideal
  height, so a capped Text is held at `min(lines needed, max_lines)` lines
  instead of being squeezed below its cap in the same way.
- The vertical ScrollView's `VStack` is not changed. It does not fix this bug
  (see above). Once every Text is fixed vertically, the only effect would be
  on how the scroll's direct children that are genuinely flexible (Spacers,
  `fill_height`, `weight`) share space, and that is not this issue.
- Horizontal `fixedSize` stays rejected, as in the 2026-09-14 record. The Row
  text priority (`.layoutPriority(1)` for a direct Row label beside a flexible
  Spacer) is unchanged. It acts on width, and this change acts on height.

## Consequences

- Text in a scrolling page, a hugging Column, a Row or a Box shows all its
  lines, as on Android, where a Column in a vertical scroll measures each
  child with unlimited height.
- The blank strips and some of the over-tall horizontal Scrolls and text
  fields in the gallery go away too (MOB-565 tracks those). That slack was
  height taken from squeezed Text and handed to the most flexible sibling.
- A Text whose height is genuinely bounded now draws all its lines past the
  bound instead of being cut to fewer lines with "…". The bound can be a
  fixed `height` on a Row, Column or Box ancestor, a `weight` share smaller
  than the Text, or a screen that does not scroll and whose content is taller
  than the screen. iOS already does this for any other child taller than its
  frame. Android instead clips the Text at the height it was given: the
  bridge uses `TextOverflow.Clip` when `max_lines` is unset (mob_new
  `MobBridge.kt.eex`, the `:text` renderer). In the gallery, the
  floating-window "Layers" example is a 140pt window whose own moduledoc says
  it is too short for its body, and it now runs its second line over the
  window edge. To keep a Text short in a bounded frame, set `max_lines`.
  There is no clean clip-to-bounds prop: `clip_height: 1` is a no-op
  (`MobDrawClip` only clips below 1), and something like 0.999 works only by
  accident.
- A Text whose width is squeezed by an unrelated bug now shows it by
  wrapping taller instead of ending in "…" on one line. This is a regression
  until MOB-564 lands, and the next mob release is gated on MOB-564.
  MishkaTabs labels get an even split of the strip's width, because every
  trigger is a Column and a Column always fills on iOS (MOB-564). A long label
  wraps to two lines, but the strip's horizontal Scroll stays one line tall.
  So the labels are cut off mid-glyph, and the active tab's underline (the
  wrapper's 2dp bottom gap under the label) is pushed below the strip and
  clipped away entirely. Fixing the Column fill removes the wrap, and both
  come back.
- Buttons are a separate case (`.lineLimit(1)` in their label) and do not
  change.

## Verification

iPhone 18 Pro simulator, mishka_ios_demo built against this branch. All 66
gallery pages were toured with `scripts/ios_tour.exs`. 43 pages are
pixel-identical to the unfixed baseline. The other 23 were compared by eye:
the squeezed bodies, captions, hints and code blocks show every line, the
blank strips are gone, and Row labels beside flexible Spacers, buttons and
`max_lines: 1` labels look the same as before. The two regressions are the
fixed-height and tab cases described above.
`test/mob/native_text_max_lines_test.exs` fails if the modifier is removed or
made horizontal.
