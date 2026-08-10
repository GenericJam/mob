# One `GlassEffectContainer`, at the root of the node tree

- Date: 2026-08-09
- Status: accepted

## Context

`MobRootView.swift` has a single `.glassEffect()` call site (`mobBoxBackground`)
and used none of iOS 26's batching APIs. Every glassy Box was therefore an
independent surface doing its own backdrop sample + blur every frame. On a
61-card gallery under `MobThemes.ObsidianGlass` that is dozens of samples per
frame on an A15 — visibly chunky scrolling under glass themes only.

The SDK surface (iPhoneOS26.4.sdk, `SwiftUICore.swiftinterface`) is:

    GlassEffectContainer<Content>(spacing: CGFloat? = nil, content: () -> Content)   // 9045
    func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID)  // 9880
    func glassEffectID(_ id: (some Hashable & Sendable)?, in: Namespace.ID)          // 17315

## Decision

**Exactly one container, wrapping the whole node tree**, applied in
`MobRootView.body` via `MobGlassBatch`.

Placement is the whole decision. Mob renders a recursive node tree, so the
tempting spot — next to the `glassEffect` call in `MobBox` — is the one that
cannot work: batching happens *within* a container, so a container per glass
node batches one surface each, and nesting containers re-splits the batch. The
container has to sit above every glass node that could share a pass, which in a
tree with no fixed depth means the root. Fix A (lazy `:scroll`) is what keeps
that batch small: only near-viewport cards are realized, so the root container
merges ~6 live surfaces, not 61.

`spacing: 0`, not the `nil` default: spacing is the distance at which sibling
glass shapes merge into one shape. We want the shared render pass, not the
morphing — a card grid must keep its card edges.

`glassEffectID` / `glassEffectUnion` are deliberately **not** used. They are for
morph transitions and for fusing shapes into one surface; both would change how
the theme looks, and neither is needed for the batching win.

The container is applied only when the current tree actually contains a glassy
node (`mobTreeHasGlass`, one walk per root push — the tree was just decoded from
JSON anyway). A container wrapping a tree with no glass in it is overhead
charged to every non-glass theme, i.e. every theme that scrolls fine today.

## Consequences

- iOS 26+ only; `#available` keeps iOS 17–25 on the untouched
  `.ultraThinMaterial` path, which has no container to join.
- The container wraps the node view *outside* its `.frame(maxWidth:
  .infinity, maxHeight: .infinity)`, so its single child already fills the
  screen and the container's own layout cannot move anything.
- During a nav transition the outgoing and incoming trees are separate views and
  so get a container each — transient, one extra pass for the duration of a
  push/pop.
- Not verifiable from the host: that SwiftUI actually collapses the passes, and
  the frame-time delta. Checked with `swiftc -typecheck` against
  iPhoneOS26.4.sdk (including the `if active, #available(iOS 26.0, *)` form) and
  `swiftlint`. Needs an on-device before/after — Instruments' Animation Hitches
  / SwiftUI template on the 61-card gallery under ObsidianGlass.
