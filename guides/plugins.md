# Writing a Plugin

A mob plugin is a Hex package (or local path dep) that extends a host app —
from a few lines of pure-Elixir helpers to an embedded sub-app with its own
screens, database tables, background workers, and settings. This guide walks the
full authoring loop: **scaffold → implement → sign → activate → deploy**. For the
exhaustive manifest schema, see [`MOB_PLUGINS.md`](MOB_PLUGINS.md); for the trust
model, [`MOB_PLUGIN_SECURITY.md`](MOB_PLUGIN_SECURITY.md).

## The five tiers

A plugin declares only what it needs. The tier is just *how much* it ships:

| Tier | Ships | Native rebuild? |
|--|--|--|
| 0 | Pure-Elixir helpers (no manifest) | No — plain Hex pkg, hot-pushable |
| 1 | A NIF + Elixir wrapper | Yes |
| 2 | A native UI component (`<MyView>`) | Yes |
| 3 | Whole `Mob.Screen`s + Ecto migrations + assets (fonts/images) | Yes |
| 4 | Lifecycle hooks + supervised workers + settings + notifications | Yes |

Tiers are cumulative in spirit but independent in the manifest — a tier-4 plugin
can also ship NIFs and screens. The *tier* reported by `mix mob.plugins` is just
the highest section present.

## 1. Scaffold

`mix mob.new_plugin` generates a working skeleton for any tier into
`plugins/<name>/`:

```bash
mix mob.new_plugin my_widget --tier 3
```

What you get per tier:

- **0** — `mix.exs` + `lib/my_widget.ex` (a `hello/0` to replace).
- **1** — adds an Erlang NIF stub (`src/my_widget_nif.erl`), the C source
  (`priv/native/jni/my_widget_nif.c`), and a `:nifs` manifest.
- **2** — adds a `Mob.Component` module + its Kotlin Composable + Swift View, and
  a `:ui_components` manifest.
- **3** — adds two `Mob.Screen` modules (list + detail), a `:screens` +
  `:migrations` manifest, and a namespaced Ecto migration.
- **4** — adds a lifecycle module, a supervised `Worker`, a `Notifications`
  handler, a settings editor screen, and a `:lifecycle` + `:settings` +
  `:notifications` manifest.

The generated manifest validates and the generated modules compile as-is — they
are stubs to fill in, not pseudocode. Every tier also ships a starter test
suite (`test/<name>_test.exs`): stdlib-only structural checks of the manifest
and stubs that run with plain `mix test` — grow it alongside your plugin's
pure logic.

## 2. Implement

Replace the stub bodies with your plugin's real logic. A few rules the manifest
comments also remind you of:

- **NIF `:module`** is a C/Erlang token (not an Elixir module) — `ERL_NIF_INIT`
  uses it as the registered name + the static-init symbol prefix.
- **Screen routes** (`screens.default_route`) and **migration `repo_namespace`**
  must be unique across *every* activated plugin (see Conflicts, below). The
  scaffold defaults the namespace to `"<name>_"`, which is unique by construction.
- **Migrations** are the plugin author's raw files; mob_dev namespaces the copied
  filename at build so two plugins' migrations never collide. Rename the
  scaffolded migration with a real timestamp before publishing.
- **Settings** are typed and per-plugin-namespaced; read/write them with
  `Mob.Plugins.get_setting/2` and `Mob.Plugins.put_setting/3` (values are
  validated against the declared `:type`).
- **Pure-Elixir composite components** (UI kits, no Swift/Kotlin): a
  `ui_components` entry may declare `expand: {Module, :function}` instead of
  native backing — your expander turns `<MyTag …/>` into a built-in widget
  tree at render time, with `on_*` event props auto-wired to the screen
  process. See the [Components guide](components.md) and `Mob.Composite`;
  the worked example is `mob_demo_kit`.
- **`host_requirements`**: if your plugin needs something the build can't
  automate — typically an `AndroidManifest.xml` fragment like a `<service>`,
  `<activity>`, or `<provider>` — declare each step as a string in the
  manifest's `host_requirements` list. Every `mix mob.deploy --native` of the
  host prints them, so a missing manual step can't fail silently at first
  feature use. (Examples: `mob_screencast`'s mediaProjection service,
  `mob_scanner`'s scanner activity, `mob_notify`'s FCM wiring.)

Validate as you go, from the plugin directory:

```bash
mix mob.validate_plugin
```

## 3. Sign

Plugins are cryptographically signed so a host can pin trust to a public key
(see [`MOB_PLUGIN_SECURITY.md`](MOB_PLUGIN_SECURITY.md)). One-time, generate a
keypair (the private key stays on your machine, under `~/.mob/keys/`):

```bash
mix mob.plugin.keygen --plugin plugins/my_widget
```

Then sign (re-run after any manifest or source change):

```bash
mix mob.plugin.sign --plugin plugins/my_widget
```

This writes `priv/mob_plugin.pub` + `priv/mob_plugin.sig` and prints a
fingerprint. The fingerprint is the public key — it does **not** change when you
re-sign new content, so a host's trust record stays valid across releases.

## 4. Activate (in the host)

Activation is two deliberate steps in the host app — a plugin in `deps` does
nothing until it's listed in `mob.exs`:

```elixir
# mix.exs
defp deps, do: [{:my_widget, path: "plugins/my_widget"} | _]

# mob.exs
config :mob, :plugins, [:my_widget]
config :mob, :trusted_plugins, %{my_widget: "ed25519:<fingerprint>"}
```

`mix mob.plugin.trust my_widget` records the fingerprint for you. An unsigned
prototype can instead be acknowledged explicitly via
`config :mob, :acknowledge_unsafe_plugins, [:my_widget]` (a banner prints).

Verify the host sees it:

```bash
mix mob.plugins   # lists tier, hot-push status, vetting, activation; flags conflicts
```

## 5. Deploy + verify

```bash
mix mob.deploy --native    # tiers 1-4 need a native rebuild
mix mob.connect            # drive the running app over dist
```

`--native` runs the build-time plugin wiring: NIF/component compilation, asset
bundling, migration copying, and a regeneration of the runtime plugin manifest
(`priv/generated/mob_plugins.exs`) so the device's tier-3/4 wiring always matches
what the plugins declare.

## Multiple plugins and conflicts

A host can activate any combination of plugins, so mob_dev checks at build time
that they compose: two plugins may not claim the same screen route, NIF module,
native view key, migration namespace, supervised worker name, plist key, or
notification match. A clash is a loud build error, not a silent last-write-wins.
See [`MOB_PLUGINS.md` → Cross-plugin conflict detection](MOB_PLUGINS.md) for the
full list and the completeness guarantee. Keep your routes/namespaces/worker
names specific to your plugin (the scaffold's `"<name>_"` defaults do this).

## Style packages (a sibling lane)

A package that ships a *look* rather than a capability uses the styles lane:
a four-field `priv/mob_style.exs` (`name`, `mob_version`,
`style_spec_version`, `theme:` — a module exporting `theme/0`) instead of a
plugin manifest, activated via `config :mob, :styles` +
`config :mob, :default_style`. Core applies the default style's theme at
boot. See [`MOB_STYLES.md`](MOB_STYLES.md) for the schema and current
implementation status; `mob_themes` is the worked example. A single package
may ship both manifests.

## Worked examples

The `mob_plugin_demo` project carries a device-verified plugin per tier — read
them as canonical patterns:

| Plugin | Tier | Demonstrates |
|--|--|--|
| `mob_palette_demo` | 0 | Pure-Elixir, activated via `mob.exs` only |
| `mob_demo_haptic_extras` | 1 | C NIF + iOS framework (`CoreHaptics`) |
| `mob_demo_zig_extras` | 1 | Zig NIF + Android Kotlin bridge |
| `mob_demo_perm` | 1 | Extending the permission registry |
| `mob_demo_signature_pad` | 2 | Native SwiftUI / Compose component |
| `mob_demo_kv_browser` | 3 | Two screens + a migration + a bundled font + a `plugin://` image |
| `mob_demo_gen_screens` | 3+4 | Spec-v2 `screens_generator` *and* tier-4 lifecycle/settings/notifications in one plugin |
| `mob_demo_subapp` | 4 | Lifecycle hooks, supervised worker, settings, notification handler |
| `mob_demo_kit` | 2 (expand) | Pure-Elixir composite components (`<DemoCard>`, `<DemoCombobox>`) — no native code |

Beyond the demo, the shipped first-party packages are full-size references:
`mob_camera` (the heaviest extraction — ObjC + Zig + Kotlin + permission
registry), `mob_scanner` (depends on `mob_camera`; an Activity
host-requirement), `mob_notify` (delivery-stays-in-core seam +
`host_requirements`), `mob_ash` (spec-v2 `screens_generator` against host
config), and `mob_themes` (a style package). See the
[First-Party Packages catalog](packages.md).

`mob_demo_gen_screens` is the clearest example of a single plugin spanning
multiple tiers, and (with `mob_demo_kv_browser` + `mob_demo_subapp`) of multiple
plugins stacking the same tier — two namespaced migrations, two supervised
workers, two settings owners, and two notification handlers all active at once.
