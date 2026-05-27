# Pure-Elixir composite components: reserve the `expand:` field, defer the expansion pass

- Date: 2026-05-27
- Status: accepted

## Context
Evaluating a third-party UI kit (Mishka Chelekom, shadcn-style Phoenix/Tailwind
generator) surfaced a gap: `:ui_components` (tier 2) assumes **native backing** —
every entry maps `tag`/`atom` to a SwiftUI `view_module` and an Android
`composable`. There is no slot for a **pure-Elixir composite**: a `<Tag/>` that
expands to a built-in widget tree (e.g. `<MishkaCombobox/>` → `Column` +
`TextField` + `List`) with no native code. This is the headline ask from any
UI-kit author who doesn't write Swift/Kotlin.

The capability already exists at **tier 0**: `def combobox(opts), do: ~MOB"..."`
invoked via the sigil's `{combobox(...)}` child slot — pure Elixir, hot-pushable,
ships as a plain Hex package with no manifest. What's missing is (a) `<Tag/>`
syntax and (b) auto-injected event targets so authors don't thread `self()`
through every component.

Closing (a)+(b) requires a **third expansion pass** in `Mob.Screen.do_render/3`,
run before `Mob.List.expand` / `Mob.Component.expand`, recursing to a fixpoint
with a depth guard. All four of those modules are in the plugin epic's "stays in
core, finalised" set, and Phase 1 of the epic is explicitly **"No core churn."**
This is a renderer feature that benefits all components, not a plugin-extraction
feature.

## Decision
Reserve the third manifest form in the spec now, without implementing it:

```elixir
ui_components: [
  %{tag: "MishkaCombobox", atom: :mishka_combobox,
    expand: {Mishka.Combobox, :expand}}   # pure-Elixir, no :ios/:android — RESERVED
]
```

- Document tier-0 function composites (`{combobox(...)}`) as the **v1 answer** for
  pure-Elixir UI kits. Authors can ship today.
- The `expand:` field is **reserved/planned** in the spec — declared but not yet
  honored by mob_dev — so adopting it later is not a breaking change.
- The third expansion pass (and the auto-inject-event-targets ergonomics) is
  carved into a **separate core-runtime track**, not gated by and not gating the
  plugin epic. Its API should be designed against a concrete consumer.

## Consequences
- Phase 1's "no core churn" invariant holds; the epic doesn't grow a renderer
  rewrite.
- UI-kit authors have a working path now (tier 0) and a documented future path
  (`expand:`), so the spec doesn't have to break to accommodate them later.
- The ergonomic prize (tag syntax + auto event-target wiring) waits for a real
  consumer to drive the design — deliberately, to avoid speculative core API.
- Follow-up: when the core-runtime track picks up the expansion pass, supersede
  this decision with one that records the implemented pass + depth-guard
  semantics.
