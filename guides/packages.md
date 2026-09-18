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

The core loop — screens, navigation, state, storage, the neutral theme,
distribution — is in mob itself. Everything below is opt-in.

### Device I/O

| Package | Gives you | Notes |
|---|---|---|
| [mob_camera](https://hexdocs.pm/mob_camera) | Photo/video capture, live preview session, ML-ready frame streaming | The `<CameraPreview>` view node is in core; pair it with `MobCamera.start_preview/2` |
| [mob_photos](https://hexdocs.pm/mob_photos) | The system photo/video picker | No runtime permission needed (out-of-process picker) |
| [mob_video](https://hexdocs.pm/mob_video) | On-device video clip / probe / thumbnail / extract-audio | No ffmpeg; uses AVFoundation on iOS and MediaCodec on Android |
| [mob_location](https://hexdocs.pm/mob_location) | GPS/network location — one-shot + continuous | |
| [mob_biometric](https://hexdocs.pm/mob_biometric) | Face ID / Touch ID / fingerprint auth | iOS + Android both green (Android now via platform BiometricPrompt on ComponentActivity) |
| [mob_scanner](https://hexdocs.pm/mob_scanner) | QR / barcode scanning (full-screen scanner) | Also activate `mob_camera` (it owns the `:camera` permission) |
| [mob_bluetooth](https://hexdocs.pm/mob_bluetooth) | Bluetooth discovery + SPP/HFP/HID + BLE (LE advertise/scan/connect) | Verified on both Moto G Power + iPhone |
| [mob_midi](https://hexdocs.pm/mob_midi) | MIDI in + out (over USB, Bluetooth LE MIDI, and app-to-app) | |
| [mob_touch](https://hexdocs.pm/mob_touch) | Raw touch stream, observe-without-consume | Useful for gesture prototyping / analytics without owning the UI event flow |
| [mob_screencast](https://hexdocs.pm/mob_screencast) | The device's own screen as an on-device-encoded H264 stream | For remote viewing / WebRTC; `max_size` is Android-only today |

### Messaging + wake

| Package | Gives you | Notes |
|---|---|---|
| [mob_sms](https://hexdocs.pm/mob_sms) | System SMS composer pre-filled with recipient + body | `MobSms.compose/2` on both platforms. iOS observes send / cancel via the MessageUI delegate; Android hands off to the user's SMS app (outcome unobservable — see the plugin's per-platform-delivery docs). No permissions on either platform. |
| [mob_notify](https://hexdocs.pm/mob_notify) | Local notification scheduling + push registration | Pairs with the server-side [mob_push](https://hexdocs.pm/mob_push) below; delivery into `handle_info` is core behaviour |
| [mob_background](https://hexdocs.pm/mob_background) | Keep-alive execution while backgrounded — iOS silent-audio session, Android foreground service | For long-running work (music, upload, walk tracker). Not to be confused with `mob_wake` (planned) — the OS-triggered opportunistic execution / silent-push receive plugin. See [Background execution](background_execution.md). |

### ML

| Package | Gives you | Notes |
|---|---|---|
| [mob_nx](https://hexdocs.pm/mob_nx) | Pluginised Nx ML backends — Eigen (CPU baseline) shipped, Vulkan compute + others under development | Spike; API surface still narrow |

## Style packages

| Package | Gives you |
|---|---|
| [mob_themes](https://hexdocs.pm/mob_themes) | Five preset looks — Obsidian (default), ObsidianGlass, Citrus, Birch, Material3. Switch live with `Mob.Theme.set(MobThemes.Citrus)` |

## Component kits

| Package | Gives you | Notes |
|---|---|---|
| [mob_mishka](https://hexdocs.pm/mob_mishka) | 73 Mishka Chelekom composites for Mob apps — dialogs, tabs, accordions, hue / alpha / range / angle sliders, semi-circle progress, JSON input, and more | Shipped as a proper Hex plugin (replaces the pre-`mob_new` 0.6 vendoring pattern). Reads Mob's theme tokens (see [Theming](theming.md)), so switching `Mob.Theme.set/1` re-skins every composite at once, identically on both platforms. `mix mob_mishka.gen <name>` ejects a specific composite into your `lib/<app>/components/` for editing with `config :mob_mishka, :override_namespace, MyApp.Components`. `mix mob_mishka.migrate` converts pre-plugin vendored apps in one pass. Design system upstream: [mishka-group/mishka_chelekom](https://github.com/mishka-group/mishka_chelekom) (Shahryar Tavakkoli / [@shahryarjb](https://github.com/shahryarjb)). |

## Framework integrations

| Package | Gives you |
|---|---|
| [mob_ash](https://hexdocs.pm/mob_ash) | Declare [Ash](https://hexdocs.pm/ash) resources, get generated list/detail/create screens per resource — Ash runs on-device |

## Server-side companions

| Package | Gives you |
|---|---|
| [mob_push](https://hexdocs.pm/mob_push) | APNs + FCM push sending from your Elixir server (no mob dependency — works for any app) |

## Choosing plugins for an app

The catalog is deliberately un-monolithic — you pay for what you activate.
Some pairing hints:

- **Verification / OTP flow.** `mob_sms` + the built-in text-field
  `text_content_type: :one_time_code` prop (mob 0.9.1+) covers iOS
  QuickType autofill; `mob_sms`'s `MobSms.OneTimeCode.arm/2` covers
  Android via Google Play Services' SMS Retriever. Same shape on both
  platforms, no `READ_SMS` permission on Android.
- **Camera-centric app.** `mob_camera` for capture + preview,
  `mob_scanner` if you want QR/barcode as its own screen (activates
  `:camera` under the hood), `mob_photos` for picking existing images
  from the library. `mob_video` for on-device editing.
- **Sensor / peripheral app.** `mob_bluetooth` for BLE + BR/EDR,
  `mob_midi` for musical instruments, `mob_location` for GPS,
  `mob_touch` if you need the raw touch stream.
- **Background sync.** `mob_notify` for local reminders, the planned
  `mob_wake` epic ([MOB-257](https://linear.app/mobframework/issue/MOB-257))
  for OS-triggered opportunistic execution + silent-push receive.
  `mob_background` (keep-alive) is a DIFFERENT plugin — it keeps a
  process alive while backgrounded, not opportunistically wakes you.
- **Design system.** `mob_mishka` gives you 73 composites; `mob_themes`
  gives you five preset visual looks that all composites read from.
- **Push notifications end-to-end.** `mob_notify` on the client
  (register for pushes, receive them) + `mob_push` on your server
  (send APNs / FCM).

## Building your own

- Pure-Elixir UI kits: function composites work with a plain Hex dep, and
  tag-name composites via [`Mob.Composite`](Mob.Composite.html) — see the
  [Components guide](components.md).
- Anything deeper: `mix mob.new_plugin --tier 0|1|2|3|4` scaffolds a plugin
  with tests; the [Plugins guide](plugins.md) and the
  [manifest reference](MOB_PLUGINS.md) cover the rest.
- If your plugin will fill an obvious gap in the first-party catalog above,
  reach out — happy to review, credit, and potentially adopt it into
  first-party status once it stabilises.
