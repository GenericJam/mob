# Mob fonts

Status (2026-08-24): **implemented, compile-verified, not yet
device-verified.** All five design points below shipped — named font
tokens, app-wide default injection, plugin-declared defaults with
conflict detection, an explicit fallback chain, and the cross-platform
name-resolution fix. What's *not* done yet:

- **Native fallback-chain behavior hasn't been confirmed on a physical
  device** — only that the iOS (Swift/ObjC) and Android (Kotlin template)
  changes compile and the app builds successfully on both platforms. A
  real "this font is missing, does it visibly fall through to the next
  name" check is still open.
- `mob_dev`'s new dependency on `mob` (needed so `RuntimeManifest` and the
  asset planner can call `Mob.Font.android_resource_name/1`) is currently
  a path dependency in `mob_dev/mix.exs`, pending `mob` publishing a
  version with `Mob.Font` — see the `TEMP` comment there.

This doc is the living reference (same convention `MOB_STYLES.md` and
`MOB_PLUGINS.md` follow: one doc, kept current, mixing "what's real" and
"what's next" under an explicit status header) — it was written as a
design doc first (see git history / `decisions/` for the process), then
updated in place as each piece shipped, rather than kept as a separate
frozen proposal.

## Goals

1. An app can set a **custom font** once and have it apply everywhere,
   instead of repeating `font: "…"` on every `<Text>`/`<Button>`.
2. A **plugin** can declare its own default font — a component-kit
   plugin (e.g. a Mishka-Chelekom-style port) ships a font and says
   "use this unless the host picked something else."
3. An explicit **fallback font** — when the chosen font can't be
   resolved on-device, fall back to something declared, not to
   whatever `Font.custom`/`ResourcesCompat.getFont` silently does today.
4. **Named font tokens**, app-wide, resolved the same way color tokens
   already are — set up once, referenced by name (`font: :heading`)
   everywhere, exactly like `text_color: :primary` today.
5. Docs (`guides/styling.md`, `MOB_STYLES.md`, `MOB_PLUGINS.md`) end up
   accurate — including fixing one existing false claim (see below).

## Current state

| Capability | Status | Where |
|---|---|---|
| Per-node `font:` prop | ✅ shipped | `ios/mob_nif.m:688-693` → `MobNode.h:199` → `MobRootView.swift` (`resolvedFont`); Android `MobBridge.kt.eex` (`fontFamilyProp`) |
| App-level font bundling (`priv/fonts/*.ttf`) | ✅ shipped | `mob_dev/lib/mob_dev/native_build.ex` |
| Plugin font bundling (`assets: %{fonts: [...]}`) | ✅ shipped | `mob_dev/lib/mob_dev/plugin/assets.ex`, merged in `plugin/merge.ex` |
| iOS `UIAppFonts` registration | ✅ shipped (build-time plist patch) | `assets.ex` |
| Android `res/font/` + runtime lookup | ✅ shipped | `Mob.Font.android_resource_name/1` (mob core) — one implementation, called both at build time (bundling) and to compute a theme token's Android name |
| Cross-plugin font *file* collision detection | ✅ shipped | `assets.ex` (raises on basename collision) |
| App-wide default font | ✅ shipped | `Mob.Theme.fonts[:default]` + `Mob.Renderer.inject_font_default/2` |
| Plugin-declared default font | ✅ shipped | `default_font: %{family:, file:}` manifest field, `Mob.Plugins.apply_default_font/0` |
| Declared fallback font/chain | ✅ shipped, compile-verified only | `Mob.Theme.font_fallback` pushed via `notify_native/1`; iOS `MobNode.resolveFontName` / Android `fontFamilyProp` walk it — **not yet confirmed on a physical device** |
| Named font tokens (`font: :heading`) | ✅ shipped | `Mob.Renderer.resolve_font/3` |
| Cross-platform font-name consistency | ✅ fixed | see below |

### The bug this closed

`guides/styling.md` used to claim: *"Mob normalises the name before
sending it to the NIF so you can use the same string on both
platforms."* **That was false** — there was no such normalization in
`lib/mob/renderer.ex`. What actually happened:

- iOS used whatever string you gave it, as-is, as the PostScript name
  (`Font.custom(family, size:)`).
- Android's build step (`mob_dev`, at bundle time) normalized the font
  **file's name** to compute the `res/font/` resource filename.
- Android's runtime (Kotlin, on-device) independently re-normalized
  whatever string you put in the `font:` **prop** to *guess* that same
  resource name.

Two separate implementations of "normalize a string," running on two
different inputs (file name vs. prop value), in two different
languages, kept in sync only by convention — agreeing when the
PostScript name and the filename happened to be similar enough, and
silently diverging otherwise.

**The fix:** `Mob.Font.android_resource_name/1` now lives in `mob` core
(not `mob_dev`, which is dev-only and can't be depended on by code that
ships on-device) and is the single implementation both sides call —
`mob_dev`'s asset planner when bundling the file, and `Mob.Theme.font/2`
when building a theme token. Android's runtime Kotlin no longer
re-derives anything; it looks up the value the theme token already
carries.

## How it works

### 1. Named font tokens on `Mob.Theme`

`%Mob.Theme{}` has a `fonts` field, structurally identical to how
colors already work — a semantic-name → spec map:

```elixir
%Mob.Theme{
  # ...existing fields...
  fonts: %{
    default: %{ios: "Inter-Regular", android: "inter_regular"},
    heading: %{ios: "Inter-Bold",    android: "inter_bold"},
    mono:    %{ios: "JetBrainsMono-Regular", android: "jetbrains_mono_regular"}
  },
  font_fallback: ["Helvetica Neue"]   # ordered; last resort is the OS default
}
```

`font` props reference tokens by atom, exactly like `text_color:
:primary` does today:

```elixir
%{type: :text, props: %{text: "Section", font: :heading}, children: []}
%{type: :text, props: %{text: "Body copy"}, children: []}  # no font: -> app-wide default applies
```

**Resolution** joins the existing `resolve_token/3` dispatcher in
`renderer.ex` (`@color_props`, `@spacing_props`, `@size_props`,
`@radius_props` already worked this way — this is a 5th category, not a
new mechanism):

```elixir
@font_props ~w(font)a

defp resolve_token(key, value, ctx) when is_atom(value) and key in @font_props do
  resolve_font(value, ctx.fonts, ctx.platform)
end

# Theme fonts map -> the value for the CURRENT platform only. Unlike colors
# (one ARGB int used by both platforms), a font value carries a name PER
# platform, so the split happens here; native only ever sees one string.
# A map value missing the requested platform key falls back to whichever
# platform key IS present (still a usable name) rather than the raw token
# atom (which would ask the OS for a font literally named e.g. "heading").
# An atom not found in the map passes through unresolved (mirrors
# resolve_color/2's unknown-atom behavior).
defp resolve_font(value, theme_fonts, platform) do
  case Map.get(theme_fonts, value) do
    %{} = spec -> Map.get(spec, platform) || spec[:ios] || spec[:android]
    string when is_binary(string) -> string
    nil -> value
  end
end
```

A raw string (`font: "Custom-Family"`) still passes straight through
unresolved, same escape hatch colors already have for one-off values —
and so does a bare-string `fonts` map *value* (used as-is on both
platforms, for a name that's already identical on both, e.g. a built-in
system font).

### 2. App-wide default font

Rather than adding `font: :default` to every text-bearing entry in
`@component_defaults` (which needs remembering for every future
text-bearing node type too), this is a cross-cutting injection pass —
the same shape as `inject_theme_flags/3` (which stamps `glass: true`
onto `:box` nodes with a `background:`): walk the tree once, and for
any node without its own `font:` prop, set `font: :default` — but
**only when the active theme actually declares one** (`fonts[:default]`
present), so an app that never touches this feature sees zero behavior
change:

```elixir
defp inject_font_default(props, %{fonts: %{default: _}}) when is_map_key(props, :font),
  do: props

defp inject_font_default(props, %{fonts: %{default: _}}), do: Map.put(props, :font, :default)
defp inject_font_default(props, _ctx), do: props
```

Not type-restricted (unlike the glass flag) — native already treats
`font` as a generic pass-through prop on any node type, not just
`:text`, so the injection applies uniformly.

**Explicit `font:` on a node always wins** — same "explicit props
always win" invariant `Map.merge(defaults, props)` already guarantees
everywhere else.

### 3. Plugin-declared default font

Two plugin-facing mechanisms carry this, meaning different things:

- **Full style packages** (`priv/mob_style.exs`, the `MOB_STYLES.md`
  mechanism) replace the *entire* active theme via
  `Mob.Plugins.apply_default_style/0` → `Mob.Theme.set(theme_mod)` —
  note this is **`set/1` with a bare module**, i.e. `mod.theme()`
  wholesale, not the `{module, overrides}` partial-merge form
  (`plugins.ex`, `theme.ex`). A style package's `fonts` map rides along
  for free — no separate infra needed for that case.
- A plugin that ONLY wants to suggest a default font (e.g. a capability
  plugin, not a full visual-identity package) has a narrow manifest
  field for exactly that, so it doesn't need to author colors/spacing/
  radii just to suggest one font:

```elixir
%{
  name: :mob_some_plugin,
  # ...
  assets: %{fonts: ["priv/fonts/PluginFont-Regular.ttf"]},
  # :file must be one of assets.fonts above. :family can't be derived from
  # the filename — it's the iOS PostScript name, embedded in the font
  # file's own metadata, so the plugin author supplies it explicitly.
  default_font: %{family: "PluginFont-Regular", file: "priv/fonts/PluginFont-Regular.ttf"}
}
```

This sets **only** `Mob.Theme.fonts[:default]`
(`Mob.Plugins.apply_default_font/0`, called at boot right after
`apply_default_style/0`), layered onto whichever theme is already
active via `Theme.set(%{theme | fonts: Map.put(theme.fonts, :default, spec)})`
— it does not touch colors/spacing/radii, and does not use
`Mob.Theme.set/1`'s whole-struct-replace path the way a style package
does.

**Precedence when more than one thing wants to set the default font**
(enforced by boot order — `use Mob.App, theme:` runs first, then
`Mob.Plugins.boot/1` — `apply_default_style/0` then
`apply_default_font/0` — then the host's own `on_start/0`):

1. An explicit `font:` prop on a node — always wins (existing
   invariant, unchanged).
2. The host app's own explicit choice — a `Mob.Theme.set(fonts: %{...})`
   call in `on_start/0` runs last, so it always wins over anything
   below.
3. A style package activated via `config :mob, :default_style` — an
   explicit host *activation* decision, so it outranks passive/incidental
   plugin defaults, same reasoning `MOB_STYLES.md` already documents for
   `:default_style` generally.
4. A single capability plugin's `default_font:` — applied only if
   nothing above already set `fonts[:default]`.
5. **Conflict:** two or more active capability plugins declare a
   `default_font:`, and nothing above resolved it — this is a **build-time
   error** (`Validator.conflict_surface/0`'s `default_font` entry,
   checked by `cross_validate/1`), not a runtime pick. Silently choosing
   one plugin's font over another's is exactly the kind of surprise
   mob's plugin system already refuses to allow for every other
   single-valued manifest field.
6. Mob's own built-in neutral default (`%Mob.Theme{}`'s `fonts: %{}`)
   guarantees text always renders even with zero configuration — no
   `:default` key means the injection pass in §2 is simply a no-op, and
   native's own font APIs already resolve to the OS system font when
   given no name.

### 4. Fallback chain

Before: if a font name couldn't be resolved, iOS's `Font.custom`
silently substituted the system font (no signal), and Android's
`fontFamilyProp` swallowed the exception in an empty `catch` block and
returned `null` (same silent result). No logging either side.

`Mob.Theme.font_fallback` is an ordered list of font names, theme-level
(not per-token — see "Non-goals"). It's pushed to native as part of the
existing theme-push channel: `Theme.notify_native/1` resolves it to the
current platform's names and sends it as `_font_fallback` alongside the
palette (the same JSON blob `Mob.Theme.set/1` already sends via
`:mob_nif.set_theme/1` — previously iOS's half of that was a no-op and
Android only kept `Number` values; both now also parse
`_font_fallback`).

Native tries the resolved primary name first; if unavailable, walks the
fallback list in order; the OS system font is always the implicit last
resort:

- **iOS**: `nif_set_theme` (`ios/mob_nif.m`) parses the JSON and caches
  `_font_fallback` in a static `NSArray`, exposed to Swift via
  `mob_font_fallback()` (declared in the bridging header). `MobNode`'s
  new `resolveFontName(primary:)` walks `[primary] + mob_font_fallback()`,
  checking `UIFont(name:size:) != nil` before using each candidate
  (`Font.custom` itself has no "did this resolve" signal the way
  `UIFont` does) — `resolvedFont` calls it instead of going straight to
  `Font.custom`. Logs via `NSLog(@"[mob/font] ...")` when the primary
  choice misses, so a missing font is diagnosable instead of silently
  "just looks like the wrong font."
- **Android**: `MobBridge.setTheme` now also parses `_font_fallback`
  into `MobBridge.fontFallback`. `fontFamilyProp` (in the `mob_new`
  Kotlin template, `MobBridge.kt.eex`) walks
  `[primary] + MobBridge.fontFallback` via `resolveOneFontName`,
  replacing the old empty `catch` blocks with `Log.w("MobBridge", ...)`
  on every failed candidate and a final "none resolved" log if the
  whole chain misses.

**Not yet done:** confirming this on a physical device — verified so
far only via a real `xcodebuild`/`gradlew assembleDebug` compile on both
platforms (see status header). The behavioral check (point a `font:` at
a name that doesn't exist, confirm the fallback list's next name
visibly renders instead) is still open.

**Non-goal:** per-token fallback chains (e.g. `:heading` falling back
to `:default` before falling back to the theme-level list). One global
fallback list is enough to make failures deterministic and debuggable;
a richer cascade can be added later if it's ever actually needed.

### 5. Cross-platform resolution (closed the bug)

The fragility was that Android's runtime *re-derived* a resource name
from a string it couldn't be sure matched what was computed at build
time. The fix: **stop re-deriving it at runtime.** The Android resource
name is computed once — `Mob.Font.android_resource_name/1` — and
carried as an exact string in the theme token; Kotlin just looks it up,
it never normalizes anything.

**The constraint this ran into:** the normalization logic used to live
in `mob_dev` (`lib/mob_dev/plugin/assets.ex`) — a **dev-only**
dependency (`only: [:dev, :test]` in every generated app's `mix.exs`).
`Mob.Theme` lives in `mob` core and ships **on-device**; core can't
depend on a dev-only package's function. So the function moved *into*
`mob` core (`Mob.Font.android_resource_name/1`), and `mob_dev` added a
regular (non-dev-only, since `mob_dev` itself never ships on-device —
only the files it produces do) dependency on `mob` so its asset planner
can call the same function. This is the one piece of this feature that
touched `mob_dev` as well as `mob` core.

Authoring ergonomics, so nobody hand-types a resource name and risks
the mismatch:

```elixir
Mob.Theme.font("Inter-Bold", from_file: "priv/fonts/Inter-Bold.ttf")
# => %{ios: "Inter-Bold", android: "inter_bold"}   (android computed via Mob.Font)

# used when building a fonts map:
fonts: %{heading: Mob.Theme.font("Inter-Bold", from_file: "priv/fonts/Inter-Bold.ttf")}
```

A plugin's `default_font: %{family:, file:}` manifest field goes
through the equivalent conversion in `mob_dev` — `RuntimeManifest`
builds the exact same `%{ios:, android:}` shape from the plugin's
declared family + file before it ever reaches `Mob.Plugins`.

## Precedence summary (single source of truth)

```
explicit font: prop on a node
  > host app's explicit Mob.Theme.set(fonts: ...) in on_start/0
    > activated style package's theme.fonts (:default_style)
      > a single capability plugin's default_font: manifest field
        > mob's built-in neutral default (fonts: %{} — no injection, system font)
```

Font *resolution failure* (chosen font missing/corrupt on-device) is a
separate axis, handled by `font_fallback`, independent of which default
"won" above.

## Manifest / schema

- `Mob.Theme` struct: `fonts` (map), `font_fallback` (list) fields;
  `Mob.Theme.font/2` builder; `fonts_map/1` / `font_fallback_list/1`
  accessors (mirroring `color_map/1` / `radius_map/1`).
- `Mob.Font.android_resource_name/1` (mob core) — the single
  file-name-to-Android-resource-name implementation.
- `priv/mob_plugin.exs` (capability plugins): `default_font:` optional
  `%{family:, file:}` field. `MobDev.Plugin.Manifest.check_default_font/2`
  validates `file` is one of `assets.fonts`. `MobDev.Plugin.Merge.default_font/1`
  gathers it; `MobDev.Plugin.Validator.conflict_surface/0`'s `default_font`
  entry (checked by `cross_validate/1`) makes two plugins declaring one a
  build error. `MobDev.Plugin.RuntimeManifest.build/1` converts the
  survivor to the on-device `%{ios:, android:}` spec, read at boot by
  `Mob.Plugins.default_font/0` / `apply_default_font/0`.
- `priv/mob_style.exs` (style packages): no schema change — `fonts`
  rides in the existing `theme:` module's struct.
- `mob_dev/mix.exs`: new dependency on `mob` (currently a `path: "../mob"`
  dep pending a published `mob` version with `Mob.Font` — see the `TEMP`
  comment there), so the asset planner and `RuntimeManifest` can call
  `Mob.Font.android_resource_name/1`.

## Documentation

- `guides/styling.md` — "Custom fonts" section rewritten: named tokens,
  app-wide default, plugin defaults, fallback, escape hatch for a raw
  string. False normalization claim removed.
- `MOB_STYLES.md` — notes `fonts`/`font_fallback` are theme fields like
  any other token category; style packages get them for free.
- `MOB_PLUGINS.md` — documents the `default_font:` manifest field
  (example + compact schema reference), links back here for the
  precedence ladder rather than duplicating it.
- This doc — status header updated to reflect shipped state (this pass).

## Known gaps

- **Fallback-chain behavior is compile-verified only, not
  device-verified.** A real device check (point `font:` at a name that
  doesn't exist, confirm the fallback list's next name visibly renders)
  is still open.
- `mob_dev`'s dependency on `mob` is a temporary path dependency —
  needs to become a real version constraint once `mob` publishes a
  version containing `Mob.Font`.
