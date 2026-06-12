# Mob styles — manifest schema

Mob styles are Hex packages that ship a coherent visual identity — a
palette of theme tokens plus per-component native renderers that
implement that look. They're packaged like plugins (Hex, manifest,
compile-time merge) but operate on a different axis: instead of
**adding** capabilities to an app, they **substitute** the look of the
built-in primitives.

Examples: `mob_m3` (Material Design 3), `mob_cupertino` (Apple HIG),
`mob_liquid_glass` (the depth-and-blur look), `mob_rn_compat` (React
Native default look). Any number of these can be installed
simultaneously, and the app picks which to use — per app, per screen,
or per element.

This doc covers:

- The relationship to `MOB_PLUGINS.md` (sibling, separate API surface)
- The cascade model — how the active style is resolved at render time
- The manifest schema, annotated with concrete examples
- The native dispatch table — how iOS/Android route to the right view
- The prop contract — what each baseline primitive exposes that styles
  must support
- Validation + compatibility rules

For the surrounding ecosystem (Hex packaging, mob_dev compile-step
internals, hot-push compatibility), see `MOB_PLUGINS.md` — the
infrastructure is shared.

## Implementation status (2026-06-11)

The **tokens-only tier is IMPLEMENTED and device-verified**: the
four-field `priv/mob_style.exs` manifest (loaded + validated by
`MobDev.Style`), activation via `config :mob, :styles` +
`config :mob, :default_style` in `mob.exs`, the styles riding the plugin
runtime manifest, and core applying the default style's theme at boot
(`Mob.Plugins.apply_default_style/0`; a misconfigured style fails the
BUILD, a broken theme module logs and renders baseline). First package:
`mob_themes` (Obsidian/ObsidianGlass/Citrus/Birch/Material3).

**NOT yet implemented** (the mob_m3 tier): the cascade, per-element
`style:` props, the `_style` node field, and the namespaced native
dispatch table — everything from "The cascade" onward describes design,
not shipped behavior. Precedence note learned in practice:
`:default_style` is a DEFAULT — app code calling `Mob.Theme.set/1`
(e.g. restoring a persisted user choice) outranks it, so hosts should
only override when the user explicitly chose.

## Why a separate surface from `MOB_PLUGINS.md`

Plugins **add**. Styles **substitute**. The two have different
activation semantics, validation rules, and override mechanics:

| | Plugins (`MOB_PLUGINS.md`) | Styles (this doc) |
|--|--|--|
| Operates on | App capabilities | Visual identity |
| Activation | `config :mob, :plugins, [:a, :b]` (list, additive) | `config :mob, :styles, [:a, :b]` + `:default_style` |
| Naming | Adds new tags like `<Chart>` | Overrides built-in tags like `<Toggle>` |
| Multiple active | Independent — stack freely | Coexist — disambiguated by package name |
| Per-element use | N/A | `<Toggle style={:mob_m3} />` |
| Manifest file | `priv/mob_plugin.exs` | `priv/mob_style.exs` |

The infrastructure underneath (Hex resolution, native-code merge,
`mob_version` constraint, hot-push computation, validator) is shared.
A single package can ship both manifests if it wants to (e.g., a
"Material 3 + Material Icons" package contributing both a style and an
icon-set capability).

## The cascade

At render time, each node resolves to **one active style** (or to the
neutral baseline if none applies). The resolution order, highest
precedence first:

1. **Per-element prop** — `<Toggle style={:mob_cupertino} />` wins for
   that node only.
2. **Nearest ancestor's `style:` prop** — `<Screen style={:mob_m3}> …
   </Screen>` applies to all descendants that don't override.
3. **`config :mob, :default_style`** — the app-wide default, set in
   `mob.exs`.
4. **Built-in neutral baseline** — when no style is active. Generic
   prop-driven primitives with neutral defaults.

The cascade is computed in Elixir before the render tree ships to the
native side, so each node arrives at the renderer with its effective
style already attached (a `_style` field on the serialized node). The
native dispatch table is a flat lookup: `(style_name, atom) → view`.

## Multiple installed + cherry-pick

The motivating tension: if styles were exclusive (one slot), installing
`mob_m3` would force every component to use M3's choices — including
M3's `<Picker>`, even if the developer prefers the Cupertino picker
shipped by a different style.

The fix is namespacing the native registry by package name. With both
`mob_m3` and `mob_cupertino` installed:

```elixir
# mob.exs
config :mob, :styles, [:mob_m3, :mob_cupertino]
config :mob, :default_style, :mob_m3
```

The app-wide look is M3, but a developer can opt into Cupertino at any
scope:

```elixir
~MOB"""
<Column>
  <Button text="M3 button" />                    {/* uses :mob_m3 */}
  <Toggle style={:mob_cupertino} checked={...}/> {/* opts into :mob_cupertino */}

  <Section style={:mob_cupertino}>
    <Picker .../>     {/* picks up Cupertino picker */}
    <Slider .../>     {/* Cupertino slider — inherited from Section */}
  </Section>
</Column>
"""
```

Cherry-picking is per-prop, not per-package — you can mix freely. The
package-name namespace prevents "piggy-backed component" conflicts
because both styles can coexist in the native dispatch table without
shadowing each other.

## The neutral baseline (no style activated)

If `config :mob, :default_style` is nil/unset and no node uses a
`style:` prop, the renderer falls through to the built-in neutral
baseline. This path:

- Uses `Mob.Theme.default()` — neutral grays, sane spacing, no
  Material/Cupertino opinion.
- Renders each component via its baseline native view (`MobToggle`,
  `MobTextField`, `MobButton` etc.) which is prop-driven enough that a
  developer can hand-style anything via per-component props:

```elixir
~MOB"""
<Button background={0xFF336699} text_color={0xFFFFFFFF}
        corner_radius={8} padding={:space_md} text="Custom">
"""
```

The neutral baseline is the no-dependencies starting point. A
developer who wants total control bypasses styles entirely and
hand-encodes each surface — the per-component prop surface is the
escape hatch.

## Minimum viable manifest

```elixir
# priv/mob_style.exs
%{
  name: :mob_m3,
  mob_version: "~> 0.6",
  style_spec_version: 1,
  description: "Material Design 3 (Material You)",

  # Theme struct module. Provides color / spacing / radius / type-scale
  # tokens consumed by every component when this style is active.
  theme: Mob.Theme.Material3
}
```

Four required fields. A style this small means "tokens only, no
per-component native overrides" — useful for repalette-only styles
(e.g., a brand pack that swaps colors but keeps shapes). The baseline
native primitives are used for rendering.

## Tier — tokens + native overrides

The canonical case: a style ships its theme struct **and** custom
native views for each primitive it wants to restyle visually.

```elixir
%{
  name: :mob_m3,
  mob_version: "~> 0.6",
  style_spec_version: 1,
  description: "Material Design 3 (Material You)",

  theme: Mob.Theme.Material3,

  # Per-component native overrides. Each entry maps a built-in
  # primitive atom to a platform-specific view. mob_dev's compile
  # step adds them to the renderer's dispatch table under the key
  # `<style_name>:<atom>` — so :mob_m3's toggle is registered as
  # "mob_m3:toggle", not "toggle".
  component_views: [
    %{
      atom: :toggle,
      ios: %{view_module: "MobM3Toggle"},
      android: %{composable: "MobM3Toggle"}
    },
    %{
      atom: :text_field,
      ios: %{view_module: "MobM3TextField"},
      android: %{composable: "MobM3TextField"}
    },
    %{
      atom: :button,
      ios: %{view_module: "MobM3Button"},
      android: %{composable: "MobM3Button"}
    }
  ],

  # Native sources to compile and link. Same shape as the plugin
  # manifest's :ios / :android sections.
  ios: %{
    swift_files: [
      "priv/native/ios/MobM3Toggle.swift",
      "priv/native/ios/MobM3TextField.swift",
      "priv/native/ios/MobM3Button.swift"
    ]
  },
  android: %{
    composable_files: [
      "priv/native/android/MobM3Toggle.kt",
      "priv/native/android/MobM3TextField.kt",
      "priv/native/android/MobM3Button.kt"
    ]
  }
}
```

A style can override any subset of primitives — `mob_m3` might
override `Toggle` and `TextField` but use the baseline `Button` if it's
visually close enough. The renderer falls through to the baseline view
for any primitive the active style doesn't declare.

## Install + activation flow

Two-step opt-in, mirroring plugins.

### Step 1 — install

```elixir
# mix.exs
defp deps do
  [
    {:mob, "~> 0.6"},
    {:mob_m3, "~> 0.1"},
    {:mob_cupertino, "~> 0.1"}
  ]
end
```

```bash
mix deps.get
```

After this, `mix mob.styles` lists both as **installed but not
activated**. The native code is NOT merged. The renderer doesn't know
about them.

### Step 2 — activation in `mob.exs`

```elixir
# mob.exs
config :mob, :styles, [:mob_m3, :mob_cupertino]
config :mob, :default_style, :mob_m3
```

Now mob_dev's compile step:
- Adds each style's native sources to the iOS/Android build
- Registers each style's `component_views` in the renderer dispatch
  table under `<style_name>:<atom>`
- Makes `:default_style` the fallback when a node has no `style:` prop
  and no styled ancestor

If a style is in `deps` but not in `config :mob, :styles`, compile
warns:

```
[mob] :mob_cupertino is installed but not activated. Add it to
      `config :mob, :styles` in mob.exs to enable, then set
      `config :mob, :default_style` to make it the app-wide default.
```

### Convenience — `mix mob.add_style <name>`

```bash
mix mob.add_style mob_m3              # adds to deps + :styles
mix mob.set_default_style mob_m3      # sets :default_style
```

Standard flow always works; the convenience tasks are not required.

## Native dispatch

The renderer keeps a flat dispatch table keyed by `(style_name, atom)`:

```
("mob_m3",        :toggle)     -> MobM3Toggle
("mob_m3",        :text_field) -> MobM3TextField
("mob_cupertino", :toggle)     -> MobCupertinoToggle
(<baseline>,      :toggle)     -> MobToggle           # always present
(<baseline>,      :text_field) -> MobTextField        # always present
```

`<baseline>` is the framework's built-in fallback row, populated at
compile time regardless of which styles are active. Every primitive
has a baseline row, so the renderer always has somewhere to dispatch
when no style applies.

At render time:

1. Elixir-side `Mob.Renderer.prepare/4` computes the effective style
   for each node (per-element prop → ancestor → default).
2. The node serializes with an effective `_style` field
   (string — `"mob_m3"` or `nil` for baseline).
3. The native code reads `_style` + `atom` and dispatches:

```swift
// iOS pseudocode
let key = (node.styleName, node.nodeType)
let view = componentViews[key] ?? baselineViews[node.nodeType]!
```

```kotlin
// Android pseudocode
val view = componentViews[node.styleName to node.atom]
  ?: baselineViews[node.atom]!!
```

The fallback to baseline handles two cases cleanly: (a) a style that
doesn't override the primitive in question, (b) a node with no style
attached.

## The prop contract

Every primitive — baseline and style-provided — implements the same
**prop contract** for that component. The contract is the framework's
API surface; bumping it is breaking-change territory.

For `Toggle`, the v1 prop contract is roughly:

```
checked          : bool       — current on/off state
on_change        : handle     — fired on toggle
text             : string?    — optional embedded label
track_on_color   : color      — track fill when on
track_off_color  : color      — track fill when off
thumb_color      : color      — thumb fill (both states by default)
thumb_size       : dp         — thumb diameter
track_width      : dp         — overall track width (auto if nil)
animation_ms     : int        — transition duration
accessibility_id : string?    — for Mob.Test
```

A baseline `MobToggle` consumes these with neutral defaults (gray
track, white thumb, 250ms animation). A `MobM3Toggle` consumes the
same props with M3 defaults (primary-colored track, specific thumb
size from M3 spec, 200ms animation curve from M3 motion spec). The
contract is identical; only the visual defaults differ.

**This is what makes per-component overrides work without escape
hatches.** The user can write:

```elixir
~MOB"""
<Toggle checked={@val} thumb_color={:tertiary} animation_ms={400} />
"""
```

…and it works whether `:default_style` is `nil`, `:mob_m3`, or
`:mob_cupertino`. Every style-provided primitive accepts the full
contract; the user can hand-tune any prop on top of any style.

Each component's contract lives in `lib/mob/ui.ex` as the component's
`@props` attribute and is enforced by `mix mob.validate_style` against
the manifest's declared overrides. New props are additive;
removed/renamed props bump `style_spec_version`.

## User-app inline overrides

A user can ship their own component view without authoring a Hex
package. Drop the Swift/Kotlin file in the app's `ios/` or
`android/app/src/main/java/.../` directory and register it in
`mob.exs`:

```elixir
# mob.exs
config :mob, :component_views, %{
  toggle: %{ios: "MyApp.CustomToggle", android: "MyApp.CustomToggle"}
}
```

Mob treats this as an unnamed inline style — the user's overrides
take precedence over both `:default_style` and any inherited
`style:` prop, but per-element `style:` props still win. Think of it
as a `style: :user` slot that's always implicit and always last.

Same mechanism handles "I activated `:mob_m3` but want one specific
behavior different" — override the relevant slot in
`:component_views` and your app keeps M3 everywhere else.

## Schema reference

Top-level required:

- `:name` — atom matching the package name. Convention: `mob_` prefix.
- `:mob_version` — string, semver requirement (`"~> 0.6"`).
- `:style_spec_version` — integer. Current: `1`. Independent of
  `:plugin_spec_version`.

Top-level optional:

- `:description` — short string for `mix mob.styles` output.
- `:theme` — module name. Required if the style provides tokens (almost
  always true). Module must export `theme/0` returning a `%Mob.Theme{}`
  struct.

Component overrides (any combination):

- `:component_views` — list of override maps. Each entry:
  - `:atom` — built-in primitive atom (`:toggle`, `:text_field`, etc.)
  - `:ios` — `%{view_module: "ClassName"}` (SwiftUI View struct)
  - `:android` — `%{composable: "FunctionName"}` (@Composable Kotlin function)

Native sections (mirroring plugin manifest):

- `:ios` — `%{swift_files, frameworks, min_version}`
- `:android` — `%{composable_files, gradle_deps, min_sdk}`

A style can omit `:ios` or `:android` if it's platform-specific (warns,
doesn't error — same UX as plugins).

## Validation rules

`mix mob.validate_style` (run from a style project) checks:

- Required top-level fields present
- `theme:` module exports `theme/0` returning a `%Mob.Theme{}`
- Every `component_views` `:atom` is a known baseline primitive
- Every file path referenced exists and parses
- Native views consume the full prop contract for their primitive

Compile-time validation (run by mob_dev when activating styles):

- Every style in `config :mob, :styles` is present in `deps`
- `:default_style` (if set) is in `:styles`
- `mob_version` requirement satisfied by installed mob
- No two styles with the same `:name` (Hex prevents this anyway)

Conflicts between styles are **not** validation errors — that's the
point of the namespace. Two styles can both override `:toggle`; the
renderer disambiguates at dispatch time.

## Versioning and forward compatibility

`:style_spec_version` is independent of `:plugin_spec_version`. The
prop contract per primitive is also versioned — bumping a
component's prop contract version is a breaking change for every
style that overrides it.

`mix mob.styles` shows the spec version + per-component contract
versions a style targets and which it would be incompatible with.

## Hot-push compatibility

Styles override native code, so adding or changing a style requires a
native rebuild. They are **not hot-pushable**. Style swaps via the
`style:` prop at runtime ARE possible (the renderer respects the prop
on every render), so an app can dynamically theme itself across
already-compiled styles without rebuilding.

## Why this design

Choices worth flagging:

- **Plural + namespaced, not exclusive.** Earlier draft assumed one
  active style; that traps developers when one style ships a great
  toggle and another ships a great picker. Namespacing by package
  name + cherry-picking per element is what makes both available.
- **Cascade in Elixir, dispatch in native.** Style resolution
  (per-element → ancestor → default) is centralised in
  `Mob.Renderer.prepare/4`. The native side just looks up
  `(style_name, atom)` in a flat table. Keeps native code dumb.
- **Prop contract is the framework's API.** Every style implements the
  same contract per primitive, so per-element prop overrides work
  uniformly across styles. New props are additive; removals are
  breaking.
- **User-app inline overrides via `config :mob, :component_views`.**
  Same mechanism as plugins, lower barrier — drop a Swift file in your
  app, point at it, done. Style packages and inline overrides share
  one code path; styles are just the published, versioned form.
- **Separate manifest from plugins.** Same Hex/build infrastructure,
  different conceptual axis. Readers of a `mob_style.exs` shouldn't
  have to mentally filter out plugin fields and vice versa.
