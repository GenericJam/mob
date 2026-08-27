# Glass carries the node's background colour; `glass:` is a per-node override

- Date: 2026-08-08
- Status: accepted

## Context

`mobBoxBackground(node:)` had two branches: `useGlass` → `glassEffect(.clear, …)`,
otherwise → `background(colour, …)`. The glass branch never read
`node.backgroundColor`. Under any theme with `glass: true` (e.g.
`MobThemes.ObsidianGlass`) that discarded *every* Box background on iOS 26+.
Verified on an iPhone (iOS 26.5.2) and an iPhone 17 simulator: a
`background: :primary` chip rendered identically to a `:surface_raised` one, so
selected/active state disappeared, and semantic fills (warning, accent, avatar
variants) all collapsed to the same grey. Android ignores `glass:` and keeps its
solid fill, so the same app was legible there and not on iOS.

Two separate mechanisms for glass had also accumulated. Master has a
theme-driven `BOOL useGlass` set by `Mob.Renderer.inject_theme_flags/3`. A stale
branch (`material-liquid-glass`, May 2026) added an independent per-node
`material: :glass` NSString on `MobNode` plus a `MobMaterialModifier`.

## Decision

1. Tint the glass with the node's background: `glassEffect(.clear.tint(fill), …)`.
   `Glass.tint/1` takes an `Optional<Color>`, so a box with no resolvable
   background still gets plain clear glass — one expression, no extra branch.
   The pre-iOS-26 `.ultraThinMaterial` path puts the fill *behind* the material
   so it reads as frosted colour rather than being painted over.
   `Glass.clear` is kept as the base (the existing deliberate aesthetic);
   `.regular` is the single-token knob if a tint reads too weakly.

2. `inject_theme_flags/3` uses `Map.put_new/3` instead of `Map.put/3`. The theme
   flag is a *default*; an explicit `glass:` prop on a Box wins in either
   direction. `glass: false` is the escape hatch a glass theme needs for the one
   surface where translucency costs legibility; `glass: true` opts a single Box
   in without a glass theme. No new native surface — `mob_nif.m` already decodes
   the `glass` prop into `useGlass`, and props are not whitelisted, so the
   per-node value has always reached the device. Only the theme's unconditional
   `put` prevented the override.

3. `material-liquid-glass` is superseded, not merged. Its per-node opt-in is
   delivered by (2) with zero added surface area, and its implementation had
   since diverged from master: it branches from before `mobBoxBackground`
   existed, calls `.glassEffect()` with no `in: shape` (so glass would ignore
   `corner_radius`), applies glass *over* an already-painted solid background,
   and uses `.regular` / `.regularMaterial` where master uses `.clear` /
   `.ultraThinMaterial` — two conflicting glass aesthetics in one file. It also
   introduces a second, stringly-typed vocabulary (`material:`) alongside the
   existing typed flag, and its Android counterpart never landed.

## Consequences

- `Glass.tint/1` requires the iOS 26 SDK. That does not change the build floor:
  `glassEffect` already did (issue #55 — `glassEffect` fails to compile under
  Xcode 16.2, since `#available` gates runtime, not the SDK). Worth a follow-up:
  a `#if compiler(>=6.2)` guard so older Xcode compiles instead of erroring.
- Swift rendering is not host-testable. The Elixir side is covered in
  `test/mob/renderer_test.exs`: the glass flag must not displace `background`
  on the wire, and `glass:` must override the theme in both directions.
  The tint itself needs device/simulator verification.
- `MobNode.material` is not added; nothing in `mob` or `mob_new` references it.
