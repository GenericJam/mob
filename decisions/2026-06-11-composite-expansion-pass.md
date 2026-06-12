# Composite expansion pass (the ui_components `expand:` form, honored)

- Date: 2026-06-11
- Status: accepted

## Context

The 2026-05-27 pure-elixir-composite-tier ADR reserved `expand:` in
`ui_components` and deferred the renderer pass: Phase 1 forbade core
churn, and the feature deserved a concrete consumer. Both conditions
flipped — the plugin epic's phases are done, and a UI-kit author
(porting Mishka Chelekom, no Swift/Kotlin) asked for exactly this:
`<MishkaCombobox>` tags expanding to built-in widget trees, and relief
from threading `self()` through every event prop.

## Decision

`Mob.Composite`: a persistent_term registry (tag atom → `{Module,
:function}` expander) and an expansion pass that runs FIRST in
`Mob.Screen.do_render/3` — before `Mob.List.expand` and
`Mob.Component.expand`, so composites may emit `<List>` nodes and
`Mob.UI.native_view` components. Output is re-expanded to a fixpoint
with a depth guard (20); circular composites and crashing expanders log
and render an empty node rather than taking the screen down. The
expander contract is `expand(props, children, ctx)`.

Event-target auto-injection: `on_*` props written as bare strings/atoms
arrive at expanders as `{screen_pid, tag}`. Composed tap tags
(`{pid, {tag, term}}`) carry per-row identity through the existing
event bridge.

Registration: boot, from the runtime manifest (`composites:` — emitted
by mob_dev from `expand:` ui_components entries, validated native-XOR-
expand; expand-only plugins classify tier 2 but hot-push as pure
Elixir), or `Mob.Composite.register/2` for manifest-less Hex kits.

## Consequences

- UI kits ship tag-syntax components with zero native code; tier-0
  function composites remain the simpler form underneath.
- Composites are stateless; state stays in the screen (or a
  `Mob.Component` for native-backed islands). Decoupling
  `Mob.Component`'s stateful lifecycle from native backing is the
  natural follow-on if kits need isolated component state.
- The `~MOB` whitelist warns once per call site for composite tags
  (compile-time list inside mob) — follow-up: app-extendable tags.
- Worked example: `mob_plugin_demo/plugins/mob_demo_kit`,
  Moto-G-verified (nested expansion, filtered combobox, selection).
