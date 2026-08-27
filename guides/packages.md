# First-Party Packages

Mob is fully featured — but since 0.7.0 the capabilities live in focused
packages rather than one monolithic core. Core ships the kernel every app
needs (screens, navigation, rendering, state, storage, permissions,
distribution, the test harness, and the neutral light/dark/adaptive
themes); everything else is one dep + one config line away.

Activating any capability plugin is the same two steps:

```elixir
# mix.exs
{:mob_camera, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_camera]
```

Style packages use the styles lane instead:

```elixir
config :mob, :styles, [:mob_themes]
config :mob, :default_style, :mob_themes
```

## Capability plugins

| Package | Gives you | Notes |
|---|---|---|
| [mob_camera](https://hexdocs.pm/mob_camera) | Photo/video capture, live preview session, ML-ready frame streaming | The `<CameraPreview>` view node is in core; pair it with `MobCamera.start_preview/2` |
| [mob_photos](https://hexdocs.pm/mob_photos) | The system photo/video picker | No runtime permission needed (out-of-process picker) |
| [mob_location](https://hexdocs.pm/mob_location) | GPS/network location — one-shot + continuous | |
| [mob_biometric](https://hexdocs.pm/mob_biometric) | Face ID / Touch ID / fingerprint auth | iOS fully working; Android currently reports `:not_available` (fix tracked) |
| [mob_notify](https://hexdocs.pm/mob_notify) | Local notification scheduling + push registration | Pairs with the server-side [mob_push](https://hexdocs.pm/mob_push); delivery into `handle_info` is core behavior |
| [mob_scanner](https://hexdocs.pm/mob_scanner) | QR / barcode scanning (full-screen scanner) | Also activate `mob_camera` (it owns the `:camera` permission) |
| [mob_bluetooth](https://hexdocs.pm/mob_bluetooth) | Bluetooth discovery + SPP/HFP/HID | |
| [mob_screencast](https://hexdocs.pm/mob_screencast) | The device's own screen as an on-device-encoded H264 stream | For remote viewing/WebRTC; `max_size` is Android-only today |

## Style packages

| Package | Gives you |
|---|---|
| [mob_themes](https://hexdocs.pm/mob_themes) | Five preset looks — Obsidian (default), ObsidianGlass, Citrus, Birch, Material3. Switch live with `Mob.Theme.set(MobThemes.Citrus)` |

## Component kits

| Package | Gives you | Notes |
|---|---|---|
| [Mishka Chelekom](https://mishka.tools/chelekom) | 70+ pre-styled components on the web, with a growing set already ported natively — sliders, dialogs, avatars, menus, pickers, and more — to real SwiftUI and Compose | Reads Mob's theme tokens (see [Theming](theming.md)), so switching `Mob.Theme.set/1` re-skins every ported component at once, identically on both platforms. Not yet its own Hex package — the port lives in the [mishka_chelekom monorepo](https://github.com/mishka-group/mishka_chelekom/tree/master/development/mob) alongside the web version. Register only the components a screen actually uses; the demo app's showcase eagerly registers all 60 of its catalog pages at boot for its own gallery purposes, which is fine there but adds measurable startup cost on lower-end Android hardware if copied wholesale. |

## Framework integrations

| Package | Gives you |
|---|---|
| [mob_ash](https://hexdocs.pm/mob_ash) | Declare [Ash](https://hexdocs.pm/ash) resources, get generated list/detail/create screens per resource — Ash runs on-device |

## Server-side companions

| Package | Gives you |
|---|---|
| [mob_push](https://hexdocs.pm/mob_push) | APNs + FCM push sending from your Elixir server (no mob dependency — works for any app) |

## Building your own

- Pure-Elixir UI kits: function composites work with a plain Hex dep, and
  tag-name composites via [`Mob.Composite`](Mob.Composite.html) — see the
  [Components guide](components.md).
- Anything deeper: `mix mob.new_plugin --tier 0|1|2|3|4` scaffolds a plugin
  with tests; the [Plugins guide](plugins.md) and the
  [manifest reference](MOB_PLUGINS.md) cover the rest.
