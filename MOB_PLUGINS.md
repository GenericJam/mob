# Mob plugins — manifest schema

Mob plugins are regular Hex packages with a `priv/mob_plugin.exs` data
file. The data file declares what the plugin contributes (NIFs, UI
components, screens, permissions, etc.) and mob_dev's compile step
autolinks those contributions into the host app's build.

This doc covers:

- The five plugin tiers and what each one ships
- The manifest schema, annotated with concrete examples
- Install + activation flow
- Validation + compatibility rules

For the surrounding ecosystem questions (why Hex, why a manifest,
plugin authoring via `mix mob.new_plugin`), see `RELEASE.md` and the
relevant guides.

## Plugin tiers

Plugins range from "10 lines of helper code" to "embedded chat app."
The manifest scales — small plugins use 3 fields, big plugins use a
dozen. Every section below the required header is optional; you only
write what you need.

| Tier | Example | What it ships | Hot-pushable? |
|--|--|--|--|
| 0 | `mob_color_palette` | Pure Elixir module, no native, no manifest | Yes (regular Hex pkg) |
| 1 | `mob_haptic_extras` | NIF + Elixir wrapper | No (native rebuild) |
| 2 | `mob_signature_pad` | + new `<SignaturePad>` component | No |
| 3 | `mob_in_app_purchase` | + `Mob.Screen` modules, migrations, assets | No |
| 4 | `mob_chat_kit` | + lifecycle hooks, settings, notification handlers | No |

A tier-0 plugin doesn't need this spec at all — it's just a Hex
package depending on `:mob`. The manifest matters from tier 1
upward.

## Minimum viable manifest (tier 1)

```elixir
# priv/mob_plugin.exs
%{
  name: :mob_haptic_extras,
  mob_version: "~> 0.6",
  plugin_spec_version: 1
}
```

Three required fields, that's it. A manifest this small means "this
plugin's contributions are entirely in the lib/ folder, no native
code, no permissions." Functionally equivalent to a tier-0 plugin
but allows mob_dev to print it in `mix mob.plugins` output and
enforce the `mob_version` constraint at compile time.

Add fields below as you need them. Every section is independently
optional.

## Tier 1 — functional plugin

A NIF + Elixir wrapper + per-platform helper code that doesn't touch
the render tree. The canonical example is the `mob_bluetooth` plugin
(extracted from core in Wave 1):

```elixir
%{
  name: :mob_bluetooth,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Bluetooth Classic peripheral (HFP / SPP / HID)",

  # Static-linked NIFs. `:module` is the NIF's Erlang module name (a valid
  # C token: `[a-z][a-z0-9_]*`), NOT an Elixir module — ERL_NIF_INIT uses
  # it as BOTH the registered module name AND the static-init symbol prefix
  # (`<module>_nif_init`), so an Elixir module like `MobBluetooth.Nif`
  # would yield an invalid C symbol. The plugin ships a small Erlang stub
  # (e.g. `src/mob_bluetooth_nif.erl`) that calls `erlang:load_nif/2`; an
  # Elixir wrapper can then `defdelegate` into it.
  #
  # `:native_dir` is the per-NIF native source directory. mob_dev's build
  # appends these entries to the existing :static_nifs list (the generated
  # driver table references `<module>_nif_init` over C ABI regardless of
  # source language).
  #
  # `:lang` selects the compile path (default `:c`):
  #   - `:c`   → `<native_dir>/<module>.c`, compiled with
  #              `-DSTATIC_ERLANG_NIF_LIBNAME=<module>` (the ERL_NIF_INIT macro
  #              emits the init symbol). Fed to build.zig via `-Dplugin_c_nifs`.
  #   - `:zig` → `<native_dir>/<module>.zig`, compiled via `addZigObject` and
  #              fed via `-Dplugin_zig_nifs`. The source names its own
  #              `export fn <module>_nif_init()` (no libname flag) and reaches
  #              mob-core bindings through the named imports `@import("erts")`
  #              / `@import("jni")` that build.zig wires for plugin zig objects.
  #              See mob_dev `decisions/2026-05-28-zig-plugin-nifs.md`.
  nifs: [
    %{module: :mob_bluetooth_nif, native_dir: "priv/native/jni", lang: :zig}
  ],

  android: %{
    # Merged into android/app/build.gradle's dependencies block.
    gradle_deps: [],

    # Merged into AndroidManifest.xml. REQUIRES explicit user opt-in
    # via `config :mob, :plugins` — mob_dev refuses to merge these
    # silently for plugins that haven't been activated.
    permissions: [
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.BLUETOOTH_SCAN"
    ],

    # The plugin's own Kotlin bridge class, in its OWN package (NOT the app's
    # MobBridge). mob_dev copies it into the app source tree before
    # `gradle assembleDebug` so the app's Kotlin sourceSet compiles it.
    bridge_kt: "priv/native/android/MobBluetoothBridge.kt",

    # Fully-qualified name of that Kotlin class. mob_dev generates a
    # `MobPluginBootstrap.registerAll/0` (called from MainActivity.onCreate)
    # that invokes `<bridge_class>.register()` at startup; the plugin's
    # `nativeRegister(env, cls)` JNI thunk caches its own jclass + method IDs
    # from the `cls` arg (no FindClass / classloader problem). This is how a
    # plugin-owned Kotlin class becomes callable from its NIF.
    bridge_class: "io.mob.bluetooth.MobBluetoothBridge",

    # Plain JNI-thunk C (Java_<pkg>_<Class>_*) compiled alongside beam_jni.c
    # via `-Dplugin_jni_sources` (no NIF-init libname — these aren't NIFs).
    # Holds nativeRegister + the nativeDeliver* thunks that call the plugin
    # NIF's `mob_deliver_*` exports.
    jni_source: "priv/native/jni/mob_bluetooth_jni.c"
  },

  ios: %{
    # Swift files compiled with the project's existing swiftc invocation.
    swift_files: ["priv/native/ios/MobBluetooth.swift"],

    # Info.plist keys to merge. iOS rejects builds without these for
    # the matching permission categories — same opt-in gate as Android.
    plist_keys: %{
      "NSBluetoothAlwaysUsageDescription" =>
        "Required by mob_bluetooth — replace this string in your Info.plist"
    },

    # System frameworks linked at the static-link step.
    frameworks: ["CoreBluetooth"]
  }
}
```

Notes:

- `:gradle_deps` accept any string Gradle would understand (`group:artifact:version`).
- `:plist_keys` strings are placeholders — the user must replace them
  in their `ios/Info.plist`. App Store review rejects apps with the
  default text; this is intentional friction so the user provides a
  real explanation.
- iOS or Android can be omitted. iOS-only and Android-only plugins
  are valid. The validator warns (does not error) when one is missing
  so users discover the gap.

## Tier 2 — visual plugin

Adds new render-tree node types. Same shape as tier 1 plus a
`:ui_components` section:

```elixir
%{
  name: :mob_charts,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Line / bar / pie chart components",

  android: %{
    gradle_deps: ["com.github.PhilJay:MPAndroidChart:v3.1.0"]
  },

  ui_components: [
    %{
      # PascalCase tag for the ~MOB sigil:  <Chart data={@series} />
      tag: "Chart",

      # Snake-case atom for the render tree:  %{type: :chart, ...}
      atom: :chart,

      # Props the component accepts. Documentation + (eventually)
      # compile-time validation. Optional today; required if you
      # want `mix mob.routes` and similar tools to know the shape.
      props: [:data, :type, :color, :width, :height],

      ios: %{
        # SwiftUI View struct in priv/native/ios/. mob's renderer
        # dispatches `case .chart:` → `MobChartView(node: node)`.
        view_module: "MobChartView"
      },

      android: %{
        # @Composable function in priv/native/android/. mob's
        # renderer dispatches `"chart" -> MobChart(node, m)`.
        composable: "MobChart"
      }
    },

    %{
      tag: "Sparkline",
      atom: :sparkline,
      props: [:data, :color],
      ios: %{view_module: "MobSparklineView"},
      android: %{composable: "MobSparkline"}
    }
  ]
}
```

A visual plugin can omit one platform if the component is genuinely
platform-specific (e.g., an iOS-only Live Activity widget). The
validator warns when a `ui_components` entry has only one platform —
silent UX bugs on the missing side are the #1 React Native plugin
pain point.

**Visual plugins are NOT hot-pushable.** Adding a new node type
requires recompiling the native shell. The dev loop is "edit Elixir
→ rebuild app → reinstall," not "edit Elixir → `mix mob.push`."
The manifest validator surfaces this distinction.

## Tier 3 — multi-screen plugin

Plugins that ship entire screens (effectively mini-applications
embedded in the host). Adds `:screens`, `:migrations`, `:assets`:

```elixir
%{
  name: :mob_in_app_purchase,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "StoreKit / Play Billing IAP flow",

  # ── tier-1 capability bits ──
  nifs: [%{module: :mob_iap_nif, native_dir: "priv/native/jni"}],
  android: %{
    gradle_deps: ["com.android.billingclient:billing:6.1.0"],
    bridge_kt: "priv/native/android/MobIapBridge.kt",
    jni_source: "priv/native/android/jni/iap.c"
  },
  ios: %{
    swift_files: ["priv/native/ios/MobIap.swift"],
    frameworks: ["StoreKit"]
  },

  # ── tier-3 additions ──

  # Mob.Screen modules the plugin contributes. Host can push them
  # via `Mob.UI.push_screen(MobIap.CatalogScreen)`. The plugin's
  # README explains the intended navigation patterns.
  screens: [
    %{module: MobIap.CatalogScreen, default_route: "/iap/catalog"},
    %{module: MobIap.CartScreen, default_route: "/iap/cart"},
    %{module: MobIap.ConfirmationScreen, default_route: "/iap/confirm"}
  ],

  # Ecto migrations the plugin ships. The repo_namespace prefixes
  # table names so plugins from different vendors don't collide.
  # Host app's migrator picks them up at boot.
  migrations: %{
    repo_namespace: "mob_iap_",
    migrations_dir: "priv/repo/migrations"
  },

  # Asset bundles to merge into the host app's bundle.
  # Fonts get registered automatically on iOS (UIAppFonts) and
  # Android (assets/fonts/). Images are addressable from Mob.UI
  # via "plugin://mob_iap/<filename>" path syntax.
  assets: %{
    fonts: ["priv/assets/iap-icons.ttf"],
    images: ["priv/assets/store-badge.png"]
  }
}
```

The `screens:` section is declarative — it tells the host these
modules exist and provides suggested routes. The host app *chooses*
whether and where to wire them into its navigation. This avoids the
React-Native problem of plugins silently grabbing routes.

## Tier 4 — embedded sub-app

Tier 3 plus lifecycle hooks, settings, background workers, push
notifications. The line between "plugin" and "embedded application"
gets thin here — but as long as the plugin lives under the host's
supervisor (no independent OTP app), it's still a plugin.

```elixir
%{
  name: :mob_chat_kit,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Embeddable chat (channels, messages, attachments)",

  # ... tier 1/2/3 fields ...

  lifecycle: %{
    # Called from Mob.App.on_start/0 after the host's own setup.
    # Returns :ok or {:error, reason} — error bubbles to host.
    on_start: {MobChatKit, :start, []},

    # Children added to the host's supervisor tree. Same shape as
    # Supervisor.child_spec. Started after on_start succeeds.
    supervised: [
      MobChatKit.MessageSync,
      {MobChatKit.PresenceTracker, []}
    ],

    # Optional OS-level callbacks. Called when the app foregrounds
    # or backgrounds. Plugin can flush pending state, pause workers, etc.
    on_resume: {MobChatKit, :on_resume, []},
    on_background: {MobChatKit, :on_background, []}
  },

  settings: %{
    # User-facing settings the plugin exposes. Persisted via
    # Mob.State, namespaced per plugin. Defaults are
    # used until the user opens the editor_screen and saves.
    schema: [
      %{key: :sound_on_message, type: :boolean, default: true},
      %{key: :default_channel, type: :string, default: "#general"},
      %{key: :sync_interval_seconds, type: :integer, default: 30}
    ],

    # Mob.Screen module the host can push to let users edit. The
    # plugin owns the screen's UX; the host just provides the
    # entry point.
    editor_screen: MobChatKit.SettingsScreen
  },

  notifications: %{
    # Push notification handler. The host's notification dispatcher
    # checks each plugin's handler in registration order; first
    # match wins. `match` is either a function or a map prefix.
    handlers: [
      %{
        match: %{type: "chat_message"},
        handler: {MobChatKit.Notifications, :handle_message, 1}
      }
    ]
  }
}
```

`:settings.schema` typed entries get free runtime validation via
`Mob.State`. The plugin reads its own settings with
`Mob.Plugins.get_setting(:mob_chat_kit, :default_channel)`.

> **Status (2026-06-06):** tiers 3 and 4 are **built and device-verified**
> (iPhone + Android). The wiring is pure-Elixir off a generated runtime
> manifest read by `Mob.Plugins` at boot; see
> `decisions/2026-06-06-plugin-tiers-3-4.md`. Device-verified: static +
> generated screens, migrations (table created on device), `plugin://` images,
> notification routing, tier-4 lifecycle/settings/supervised workers, and
> **custom fonts** — `assets.fonts` are build-bundled (iOS `.app` + `UIAppFonts`,
> Android `res/font` uncompressed) and used via the `font:` prop, visually
> confirmed on Android (a plugin-shipped serif font rendered distinct from the
> system font). This also makes app-level `priv/fonts/` custom fonts (documented
> above) actually work for the first time. Merged to masters; `mix mob.new_plugin`
> scaffolds all five tiers (0–4), cross-plugin conflict detection + a runtime-
> manifest auto-regen guard the multi-plugin case (see "Cross-plugin conflict
> detection" below), and a second plugin migration is device-verified composing
> alongside the first.

## Code-generated plugins (spec version 2+)

Some plugins need to derive their contributions from the *host app's*
configuration at compile time, not declare them statically. The
canonical case is an Ash integration: define `N` Ash resources in
the host app, and a `mob_ash` plugin generates `N × 3` screens (list,
detail, form) plus any matching UI components — all baked into the
build, not runtime.

For these plugins the static `:screens` list isn't enough. Spec
version 2 adds the `:screens_generator` field that returns the same
shape at compile time:

```elixir
%{
  name: :mob_ash,
  mob_version: "~> 0.6",
  plugin_spec_version: 2,   # bumped — requires v2
  description: "Generate Mob screens from Ash resources",

  # Either static (tier 3) or generated (this section), not both.
  # Generator is {Module, :function, args}; mob_dev calls it during
  # the compile step and uses the returned list as if it had been
  # declared statically.
  screens_generator: {MobAsh.ScreenGenerator, :generate, []},

  ui_components: [
    %{tag: "AshForm",  atom: :ash_form,  props: [:resource, :action, :record]},
    %{tag: "AshList",  atom: :ash_list,  props: [:resource, :filter, :sort]},
    %{tag: "AshField", atom: :ash_field, props: [:attribute, :record]}
  ],

  ios: %{swift_files: ["priv/native/ios/MobAshForm.swift", ...]},
  android: %{composable_files: [...]}
}
```

The generator function returns a list with the same shape as
`:screens`:

```elixir
defmodule MobAsh.ScreenGenerator do
  def generate do
    # Read host app's Ash domain registration.
    domains = MobDev.Plugin.host_config(:my_app, :ash_domains, [])

    for domain <- domains,
        resource <- domain.resources(),
        screen <- [:list, :detail, :form] do
      module = generated_module_name(resource, screen)
      route  = generated_route(resource, screen)

      # Actually create the module at compile time via Module.create/3.
      create_screen_module(module, resource, screen)

      %{module: module, default_route: route}
    end
  end
end
```

`MobDev.Plugin.host_config/3` is the explicit, audited API for
generators to read the host's `config :my_app, ...` during compile.
Calls outside this surface (e.g. reading `mob.exs` directly,
introspecting other plugins) require `:host_config_keys` declared
in the manifest so the audit can verify what the generator touches.

### Other generator fields

Spec version 2 adds matching generator forms for any section that
benefits from dynamic computation:

- `:nifs_generator` — useful when the NIF set depends on host config
  (e.g., conditionally include a feature)
- `:ui_components_generator` — for plugins that synthesize components
  from a schema (form-builders, data-bound widgets)

A plugin can mix static and generator forms across different
sections — static `:nifs` + generated `:screens` is fine.

### Why generators at compile time, not runtime

Mob plugins are statically merged for App Store / Play Store
compatibility. Runtime plugin registration would require dynamic
module loading which our build posture forbids. Compile-time
generators produce real modules that ship in the binary the same as
hand-written ones. Hot-push works for any pure-Elixir generated
modules (same rule as static screens); native-touching generators
require a rebuild.

### What a host app looks like

The Ash integration story for an end user:

```elixir
# mix.exs
{:mob_ash, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_ash]

# my_app.ex (the host's Ash domain)
config :my_app, :ash_domains, [MyApp.Blog, MyApp.Auth]

# That's it. Compile produces:
#   MobAsh.Generated.Blog.Post.ListScreen
#   MobAsh.Generated.Blog.Post.DetailScreen
#   MobAsh.Generated.Blog.Post.FormScreen
#   MobAsh.Generated.Auth.User.ListScreen
#   ... etc, all baked into the build.
```

Adding a resource to the Ash domain regenerates its screen set on
next compile. Removing one removes the screens. The host's
`App.navigation/1` can either wire them up by convention or pick a
subset.

### The contract is generic — Ash is one example

The `:screens_generator` + `host_config/3` API doesn't know about
Ash. Any host-side registry of resource-like things can drive
screen generation. A `mob_ecto` sketch shows the same pattern
without Ash as a dependency:

```elixir
%{
  name: :mob_ecto,
  mob_version: "~> 0.6",
  plugin_spec_version: 2,
  description: "Generate Mob screens from Ecto schemas",

  screens_generator: {MobEcto.ScreenGenerator, :generate, []},

  ui_components: [
    %{tag: "EctoForm",  atom: :ecto_form,  props: [:schema, :changeset]},
    %{tag: "EctoList",  atom: :ecto_list,  props: [:schema, :query]},
    %{tag: "EctoField", atom: :ecto_field, props: [:field, :record]}
  ]
}
```

The host registers its schemas the same way Ash domains are
registered:

```elixir
# my_app.ex
config :my_app, :ecto_schemas, [MyApp.Blog.Post, MyApp.Auth.User]
```

And the generator iterates schemas instead of resources:

```elixir
defmodule MobEcto.ScreenGenerator do
  def generate do
    schemas = MobDev.Plugin.host_config(:my_app, :ecto_schemas, [])

    for schema <- schemas,
        screen <- [:list, :detail, :form] do
      module = generated_module_name(schema, screen)
      route  = generated_route(schema, screen)
      create_screen_module(module, schema, screen)
      %{module: module, default_route: route}
    end
  end
end
```

mob_ash and mob_ecto have identical contracts with mob_dev — they
differ only in how they introspect the host's resource definitions.
The same pattern fits Phoenix schemas, Memento tables, or any
custom host-side registry.

### Working with Ash beyond the basics

If a host app wants to share resource code between the Phoenix
server and the mob_ash generator — the same `User` attributes,
validations, or calculations on both sides — the recommended path
is **Spark Fragments**, the existing Ash mechanism for composable
DSL fragments:

```elixir
defmodule Shared.User.Attributes do
  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    attribute :email, :string
    attribute :name, :string
  end
end

# server-side resource
defmodule MyApp.Auth.User do
  use Ash.Resource, fragments: [Shared.User.Attributes]
  # + server-only actions, policies, data layer
end

# mobile-side resource (read by mob_ash's generator)
defmodule MyApp.Mobile.User do
  use Ash.Resource, fragments: [Shared.User.Attributes]
  # + mobile-safe action subset
end
```

Per-action exposure granularity ("expose only `:read` and `:create`
to mobile") is a host-app concern, expressed by which actions live
on the mobile-side resource module. mob_dev does not need a DSL
for this — the generator sees whatever resources the host registers
in `config :my_app, :ash_domains` and generates screens for their
declared actions.

This keeps mob_dev's contract Ash-agnostic while giving Ash users
a clean path for the server/mobile code-sharing question without
mob_dev needing to know anything about it.

## Install + activation flow

Two-step opt-in by design.

### Step 1 — install (`deps + mix deps.get`)

Standard Hex flow. The plugin is now resolvable; mob_dev sees it on
the next compile.

```elixir
# mix.exs
defp deps do
  [
    {:mob, "~> 0.6"},
    {:mob_haptic_extras, "~> 0.1"}
  ]
end
```

```bash
mix deps.get
```

After this, `mix mob.plugins` lists the plugin as **installed but not
activated**. Its native code is NOT merged into the build. Its
permissions are NOT added to your manifest. This is deliberate — a
silent `mix deps.get` should never modify your app's permission set.

### Step 2 — activation (explicit consent in `mob.exs`)

```elixir
# mob.exs
config :mob, :plugins, [
  :mob_haptic_extras,
  :mob_bluetooth
]
```

Now mob_dev's compile step merges contributions. If `mob_bluetooth`
declares `BLUETOOTH_CONNECT` + `BLUETOOTH_SCAN`, those permissions
get added to `AndroidManifest.xml` only after the plugin is in this
list. mob_dev prints the diff at compile time so you see exactly
what's being added.

If you've added a plugin to `deps` but not to `config :mob,
:plugins`, the next compile prints:

```
[mob] :mob_bluetooth is installed but not activated. Add it to
      `config :mob, :plugins` in mob.exs to enable its contributions
      (NIFs, permissions, native code).
```

### Convenience — `mix mob.add_plugin <name>`

Wraps both steps + runs the plugin's interactive setup (if any):

```bash
mix mob.add_plugin mob_chat_kit
```

Does: add to `deps`, run `mix deps.get`, add to `config :mob,
:plugins`, walk the plugin's `setup:` prompts (e.g., "Register
MobChatKit.MessageListScreen in your App.navigation/1? [Y/n]"). For
tier 1-2 plugins the prompts are usually empty. For tier 3-4 plugins
they're where the plugin author guides integration.

Standard flow always works — `mix mob.add_plugin` is convenience,
not a required entry point.

## Schema reference

Top-level required:

- `:name` — atom matching the package name. Convention: `mob_` prefix.
- `:mob_version` — string, semver requirement (`"~> 0.6"`).
- `:plugin_spec_version` — integer. Current: `1`. Bumped when this
  schema makes breaking changes; old plugins keep working against
  old spec versions.

Top-level optional:

- `:description` — short string for `mix mob.plugins` output.

Capability sections (any combination):

- `:nifs` — list of NIF declarations. See tier 1 example.
- `:android` — map of Android-specific contributions:
  - `:gradle_deps` (list of strings)
  - `:permissions` (list of strings — opt-in via activation)
  - `:bridge_kt` (path to Kotlin file)
  - `:jni_source` (path to C/Zig file)
  - `:min_sdk` (integer, optional override)
- `:ios` — map of iOS-specific contributions:
  - `:swift_files` (list of paths)
  - `:plist_keys` (map — opt-in via activation)
  - `:frameworks` (list of strings)
  - `:min_version` (string, optional override)

Visual sections:

- `:ui_components` — list of component maps. Each entry:
  - `:tag` (PascalCase string for the sigil)
  - `:atom` (snake_case atom for the render tree)
  - `:props` (list of atom keys, optional)
  - `:ios` (map: `:view_module` SwiftUI struct name)
  - `:android` (map: `:composable` function name)

Multi-screen sections:

- `:screens` — list of `%{module, default_route}` maps
- `:migrations` — `%{repo_namespace, migrations_dir}` map
- `:assets` — `%{fonts, images}` map

Sub-app sections:

- `:lifecycle` — `%{on_start, supervised, on_resume, on_background}` map
- `:settings` — `%{schema, editor_screen}` map
- `:notifications` — `%{handlers}` map

Setup section (tier 3+):

- `:setup` — list of interactive prompts that `mix mob.add_plugin`
  walks through. Optional; mostly for tier-3/4 plugins.

## Validation rules

`mix mob.validate_plugin` (run from a plugin project) checks:

- Required top-level fields present
- `mob_version` is a valid version requirement
- Every path in the manifest exists on disk
- Files declared as `bridge_kt` / `jni_source` / `swift_files` /
  `view_module` / `composable` exist and parse
- `ui_components` entries with only one platform (warning, not error)
- `permissions` and `plist_keys` declared (warning + manual review
  recommended before publishing)
- `mob_version` satisfied by the version of `:mob` in deps

Compile-time validation (run by mob_dev when activating plugins):

- Plugin's `mob_version` requirement satisfied by the installed mob
- All plugins in `config :mob, :plugins` are present in `deps`
- **Cross-plugin conflict detection** (see below)

Both stages fail loud — never silent.

### Cross-plugin conflict detection

Anyone can ship a plugin, and a host can activate any combination — so when two
plugins both contribute into the same shared namespace, mob_dev must catch it at
build time rather than let one silently win on device. `cross_validate` (in
`MobDev.Plugin.Validator`) runs over the activated set and **fails the build**
when two plugins clash on any of:

| Shared resource | Manifest field |
|--|--|
| Screen route | `screens.default_route` |
| Component atom | `ui_components.atom` |
| iOS native view key | `ui_components.ios.view_module` |
| Android native view key | `ui_components.android.composable` |
| Migration namespace | `migrations.repo_namespace` |
| NIF module | `nifs.module` |
| iOS Swift source basename | `ios.swift_files` |
| Android JNI source basename | `android.jni_source` |
| Android bridge class | `android.bridge_class` |
| iOS Info.plist key | `ios.plist_keys` |
| Supervised worker | `lifecycle.supervised` |
| Notification match | `notifications.handlers[].match` |

A clash on any of these is a build error naming the resource, the value, and how
many plugins declared it. Resources that are *inherently* safe — settings (keyed
per-plugin), `plugin://` images (namespaced per-plugin), Android permissions /
iOS frameworks (set-unioned) — compose without a check.

A note on what counts as a clash: the check is **cross-plugin**, so a single
plugin legitimately declaring the same value twice is fine — e.g. a
cross-platform NIF that ships one iOS (`lang: :objc`) and one Android
(`lang: :zig`) entry for the same `:module` is *not* a collision; two *different*
plugins claiming that module is. Detection only flags identical values, not
semantic overlap (two notification predicates that could both match the same
payload aren't comparable in general — keep matches disjoint).

**Completeness guarantee.** Every field that lands in a shared namespace is
classified in `Validator.conflict_surface/0`, and a test (`conflict_surface_test`)
asserts that classification covers *every* merge gatherer. Adding a new
shared-resource field to the schema without classifying its conflict behavior
fails CI — so the guarantee that multiples compose can't silently rot as the
schema grows. A property-based fuzzer (`merge_fuzz_test`) additionally checks the
detection is sound and complete across random N-plugin combinations.

### Runtime plugin manifest

Tiers 3 and 4 are pure-Elixir and **runtime-wired**: the host needs to know,
while running, which screens / lifecycle hooks / settings / notification handlers
the activated plugins declared. mob_dev bakes that into a generated terms file,
`priv/generated/mob_plugins.exs`, which the core `Mob.Plugins` module reads once
at boot. It is **derived state, not hand-maintained** — `mix mob.deploy --native`
regenerates it from the activated plugins' current manifests on every build (you
can also run `mix mob.regen_plugin_manifest` directly, or `--check` it in CI).
Because it regenerates unconditionally, changing a plugin's tier-3/4 sections
can't ship a stale manifest. Tier-0/1/2 plugins contribute nothing to it.

## Versioning and forward compatibility

`:plugin_spec_version` is the escape hatch for evolving the schema
without breaking existing plugins.

- Today: spec version 1. All examples above target spec 1.
- If the schema needs a breaking change (e.g., renaming `:ui_components`
  to `:components`), bump to spec 2 and have mob_dev support both.
- Plugins declare which spec they target; mob_dev validates against
  that spec; old plugins keep compiling unchanged.

Bumping spec version means giving plugin authors a migration window
before deprecating the old spec.

## Hot-push compatibility

| Plugin tier | Hot-pushable? | Why |
|--|--|--|
| 0 (regular Hex pkg) | Yes | Pure Elixir; `.beam` ships via `mix mob.push` |
| 1 (NIFs) | No | Native code requires APK/IPA rebuild |
| 2 (visual component) | No | Same |
| 3 (multi-screen) | Partial — Elixir code in screens IS hot-pushable; native code IS NOT |
| 4 (sub-app) | Partial — same |

The manifest validator computes `hot_pushable` automatically from
which sections are populated. Plugin docs should make this explicit
so users understand why some changes need a rebuild.

## Why this design

A few choices to flag:

- **Manifest is data, not code.** The plugin doesn't `register_plugin`
  at runtime; mob_dev reads the data at compile time. Static,
  inspectable, validatable. Closer to `mix.exs`'s `project/0` than
  to Phoenix's runtime route registration.
- **Two-step activation (deps + config).** Borrowed from how iOS
  entitlements work — a framework supporting capability X doesn't
  mean your app uses X; that requires explicit declaration. Mitigates
  the supply-chain risk of silent permission merges.
- **Schema scales with tier, not exhaustive everywhere.** A tier-1
  plugin doesn't fill out `:lifecycle` or `:settings`. The schema
  doesn't make small plugins look big.
- **Hex is the substrate.** Versioning, dep resolution, security
  posture, hexdocs publication — all free. Local `path:` deps work
  the same way for development.
- **Static-link required, no dlopen.** Mob's App-Store-compatible
  build pins this. Plugins follow the same rule; the build embeds
  plugin NIFs into the host's `libpigeon.so`. Restrictive vs. React
  Native; necessary for App Store shipping.

## Requirements raised by third-party UI-kit evaluation

Evaluating whether an established web component library (Mishka
Chelekom — shadcn-style Phoenix/Tailwind generator) could be brought
to Mob surfaced two gaps in the current spec. Both are now resolved
(2026-05-27) — see `decisions/2026-05-27-pure-elixir-composite-tier.md`
and `decisions/2026-05-27-ui-kit-distribution-model.md`. The resolution
for each is noted inline below.

### 1. Pure-Elixir composite components have no tier

`:ui_components` (tier 2) assumes **native backing** — every entry
maps `tag`/`atom` → a SwiftUI `view_module` and an Android
`composable`. There is currently no slot for a **pure-Elixir
composite**: a tag that expands to a *built-in widget tree* with no
native code (e.g. `<MishkaCombobox/>` → `Column` + `TextField` +
`List`). This is the headline ask from any UI-kit author who doesn't
write Swift/Kotlin.

What exists today:

- **Tier 0** already gives function-call composites —
  `def combobox(opts), do: ~MOB"..."` invoked via the sigil's
  `{combobox(...)}` child slot. Pure Elixir, hot-pushable, ships as a
  plain Hex package with no manifest. A UI kit can ship its
  presentational + simple-interactive components this way **now**.
- What's missing is **tag syntax** (`<MishkaCombobox/>`) and a
  manifest declaration for it.

Reserved shape — a third form alongside the native one:

```elixir
ui_components: [
  %{tag: "MishkaCombobox", atom: :mishka_combobox,
    expand: {Mishka.Combobox, :expand}}   # pure-Elixir, no :ios/:android — RESERVED, not yet honored
]
```

This implies a **third expansion pass in core**, run before
`Mob.List.expand` / `Mob.Component.expand` in `Mob.Screen.do_render/3`
(so a composite can itself emit `<List>` / `native_view` for the later
passes), recursing to a fixpoint with a depth guard. Because the pass
runs in the screen process and is handed the screen pid (like
`Mob.List.expand` is), it can **auto-inject event targets** — the
author writes `on_select="combo_select"` and the pass wires
`{screen_pid, :combo_select}`, removing the need to thread `self()`
through every component. Hot-pushable (pure Elixir; same rule as
tier 0).

**Resolution:** the `expand:` field is **reserved in the spec but not
yet honored** — declaring it later is not a breaking change.
Tier-0 function composites (`{combobox(...)}`) are the **v1 answer**
for pure-Elixir UI kits; authors ship today. The third expansion pass
(and the auto-inject-event-targets ergonomics) is a renderer feature
that benefits all components, so it's carved into a **separate
core-runtime track** — out of scope for the plugin epic, whose Phase 1
is explicitly "no core churn." It should be designed against a concrete
consumer.

### 2. Generator vs. dependency — distribution model

Mishka-class kits are **shadcn-style generators**: a dev-only tool
(`mix mishka.ui.gen.component`, built on Igniter) that emits component
**source the user owns and edits** into their project; components are
free, the paid tier is templates + support, not components. The plugin
system here is **dependency-shaped** (Hex dep + two-step activation).

These are different products. A faithful UI kit for Mob may be a
**generator** (`mix mob.gen.component`) rather than a plugin at all —
or the two coexist (a generator scaffolds owned source *from* a plugin
package). Decide which model a UI kit targets before committing a
vendor to it; it determines whether a kit is a plugin in the first
place, and it's the vendor's entire identity as a tool author.
(Igniter is shared ground — Mishka is built on it and Mob's build
migration is heading there — so the generator path is not foreign
territory.)

**Resolution:** two lanes, kept separate. The **plugin (dependency)
lane** — Hex dep + two-step activation — is what this spec covers and
is in scope for the plugin epic; it's for native-backed,
capability-bearing, or centrally-maintained components. The
**generator lane** — `mix mob.gen.component`, Igniter-based, emitting
owned-source presentational components — is a separate tool tracked
with the Igniter build-migration work, **not** part of the plugin
epic. The two can coexist. For Mishka specifically, the faithful port
is the generator lane.

## Future: full-language plugins

This section parks an idea that's coherent but explicitly out of
scope for the current spec. Mob's lane is Elixir-first / BEAM-native
(see `plugin_extraction_plan.md` "Scope"). A determined plugin author
who wants to write entire screens in Python, Lua, JS, or any other
language-with-an-embedded-interpreter could in principle build that
on top of the plugin system — but the framework doesn't ship the
glue.

### What would be needed

A new manifest concept — a **screen dispatcher**:

```elixir
%{
  name: :mob_python_app,
  mob_version: "~> 0.6",
  plugin_spec_version: 3,   # speculative — not part of v2

  requires: [:mob_pythonx],

  screen_dispatcher: %{
    kind: :python,
    module: MobPythonApp.Dispatcher,
    callbacks: [
      mount: 3,
      render: 1,
      handle_event: 3
    ]
  }
}
```

A screen registered with `kind: :python` would route its lifecycle
callbacks through the dispatcher instead of expecting an Elixir
module. The dispatcher resolves them however it wants — calling
into the embedded Python interpreter, in this case.

The user's authoring story would then look like:

```python
# app/screens/home.py
import mob

@mob.screen("home")
class HomeScreen:
    def mount(self, params, session):
        return {"count": 0}

    def render(self, assigns):
        return mob.ui.column([
            mob.ui.text(f"Count: {assigns['count']}"),
            mob.ui.button("Tap", on_tap=("incr", None))
        ])

    def handle_event(self, name, _, assigns):
        if name == "incr":
            return {"count": assigns["count"] + 1}
```

### Why it's parked

- **Lane discipline.** Mob's value rests on Elixir + BEAM
  ergonomics. Diverting design effort into "Python frontends are
  equally first-class" weakens the core lane without obviously
  reaching parity with React Native / Flutter / native SDKs in their
  own lanes.
- **The hooks are conceptually clear; the implementation is
  bottomless.** Sketching the screen-dispatcher takes a paragraph.
  Making it actually pleasant (debugging, hot-reload across the
  language seam, error attribution, asset bundling, IDE support) is
  multi-month framework work. Worth doing only if the demand is
  clear.
- **The hybrid model captures the win without the cost.** Apps that
  use Mob screens in Elixir but call into Rust (via `mob_rustler`)
  or Python (via `mob_pythonx`) for specific concerns — ML, perf-
  sensitive paths, scripting layers — get most of the benefit
  without forcing the entire screen surface through an interpreter.
  See `plugin_extraction_plan.md` "Scope" for the recommended
  hybrid pattern.

### What stays open

- The plugin spec versioning leaves room. If a plugin author builds
  a full Python (or Lua, JS, etc.) frontend on top of the current
  spec, the framework can codify the screen-dispatcher concept in a
  later spec bump without breaking anyone.
- The BEAM-native path is unaffected. Gleam, LFE, Hamler, or any
  BEAM language can already author Mob screens today — Mob's API is
  just BEAM modules, the sigil is the only Elixir-flavoured part. A
  `mob_gleam` ergonomic-wrappers plugin is a perfectly reasonable
  community project that needs no framework changes.

The door stays open. Walking through it is on the ambitious
plugin author, not the framework.
