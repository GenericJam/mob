# A glass theme marks surfaces, not every box with a background

- Date: 2026-08-09
- Status: accepted

## Context

`Mob.Renderer.inject_theme_flags/3` set `glass: true` on every `:box` that had a
`background:`. On iOS each of those becomes an independent `glassEffect`
surface, and each surface samples and blurs its own backdrop every frame. A
card gallery therefore rendered dozens of live sampling surfaces — visibly
chunky scrolling on an A15 under `MobThemes.ObsidianGlass`, and fine under every
non-glass theme.

"Has a background" was never the definition of a surface; it was the cheapest
thing to test for. Boxes carry backgrounds for lots of reasons that have nothing
to do with floating above content.

## Decision

The theme default now applies to a `:box` that

1. has a `background:`,
2. **has children**, and
3. is **not already inside a glass surface**.

(1) is unchanged — no fill, nothing to swap.

(2) Childless boxes are decoration: a status dot, a colour swatch, a bar, a
rule. They read as a solid shape at their size, so a backdrop sample buys
nothing visible and costs a pass.

(3) Glass inside glass samples glass. The inner surface blurs an
already-blurred backdrop, which costs a second pass and muddies the surface the
outer one just established. The outermost surface on a branch wins.

Nesting is tracked by threading `in_glass` through the recursive `prepare/4`
context, set from the node's *final* `glass` value — so a box made glassy by an
explicit prop suppresses its descendants too, and `glass: false` on a card hands
glass to the first box below it.

The rule deliberately does **not** key off corner radius or off which colour
token the background resolves to. Radius would silently strip glass from
square-edged sheets; keying off `:surface`-family tokens would undo
`2026-08-08-glass-tint-and-per-node-glass-opt-in`, whose point is that a
`background: :primary` chip must stay visibly primary *through* the glass.

`Map.put_new/3` is retained, so the escape hatch is untouched in both
directions: `glass: false` keeps a solid fill where translucency costs
legibility, and `glass: true` opts a box in where this rule says no (a childless
badge, a nested chip). Covered in `test/mob/renderer_test.exs`.

## Consequences

- **Visible change under existing glass themes.** Childless decorative boxes and
  nested chips go solid. That is the intent — they were sampling backdrops to
  look like solid shapes — but an app that liked a glassy nested chip has to ask
  for it with `glass: true`.
- One existing test fixture (`a glassy Box still ships its background colour`)
  was a childless box; it grew a child so it still describes a surface. Its
  assertion — the flag must not displace `background` on the wire — is unchanged.
- `inject_theme_flags/3` becomes `/4` (it needs the node's children). Private.
- Android still ignores the flag entirely, so nothing changes there.
- The remaining surfaces batch into one render pass via the root
  `GlassEffectContainer` (`2026-08-09-one-glass-effect-container-at-the-root`),
  and only near-viewport ones are realized at all
  (`2026-08-09-lazy-scroll-children`). The three compound; this one is the only
  part testable on the host.
