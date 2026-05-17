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
the render tree. The canonical example is what `Mob.Bt` would look
like if it lived outside core:

```elixir
%{
  name: :mob_bluetooth,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Bluetooth Classic peripheral (HFP / SPP / HID)",

  # Static-linked NIFs. Each entry is the Elixir module that calls
  # `Mob.StaticNif.load/1` plus the directory of native sources.
  # mob_dev's build appends these to the existing :static_nifs list.
  nifs: [
    %{module: MobBluetooth.Nif, native_dir: "priv/native/jni"}
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

    # Kotlin file injected into MobBridge.kt's plugin extension slot.
    # The plugin's Kotlin code declares its own BroadcastReceivers,
    # external function bindings, etc.
    bridge_kt: "priv/native/android/MobBluetoothBridge.kt",

    # C/Zig source compiled alongside beam_jni.c. Provides the JNI
    # thunks that route into the plugin's NIFs.
    jni_source: "priv/native/android/jni/bluetooth.c"
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
  nifs: [%{module: MobIap.Nif, native_dir: "priv/native/jni"}],
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
    # Mob.Storage in the namespace `:mob_chat_kit`. Defaults are
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
Mob.Storage. The plugin reads its own settings with
`Mob.Plugin.get_setting(:mob_chat_kit, :default_channel)`.

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
- No two activated plugins declare the same `ui_components.atom`
- No two activated plugins claim the same `screens.default_route`
- Migration `repo_namespace` doesn't collide with host or other plugins
- All plugins in `config :mob, :plugins` are present in `deps`

Both stages fail loud — never silent.

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
