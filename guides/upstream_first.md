# Upstream First: Native Code in Mob or a Plugin

Mob apps grow native code: a NIF in `c_src/`, a `:static_nifs` entry in
`mob.exs`, a Kotlin or Swift view, a bridge class. Each time, one app solves a
platform problem for one platform, and the next app solves it again. FMutate,
Humdinger, Magpie and Choir Coach each carry their own audio engine, and all
four load AAudio by hand with `dlopen`. Only two of the four have an iOS side,
each written separately.

This guide is for app authors and the agents working for them. It covers where
native code belongs, and what a capability must wire up when it moves into Mob
or a plugin, so agents can see and drive it the way they see and drive the
rest of Mob.

## The rule: check upstream before writing app-side native code

Before you add a NIF, a native view, a bridge or a platform permission to an
app, decide where it belongs.

**Mob core** (`mob`) is for what most apps need, or what the framework itself
needs: rendering, input, navigation, lifecycle, and the platform services in
`Mob.Audio`, `Mob.Share`, `Mob.Haptic`, `Mob.Permissions` and their
neighbours. Anything the agent harness needs in order to see the app also goes
here.

**A Mob plugin** (a `mob_*` package, see [Writing a Plugin](plugins.md)) is
for a capability that meets all three of these:

- **More than one app needs it**, or it is obviously generic: MIDI, sensors,
  low-latency audio streams, Bluetooth, background execution.
- **It wraps a platform API.** CoreMIDI and `android.media.midi`, AAudio and
  a RemoteIO audio unit, `CMMotionManager` and `SensorManager`.
- **It has no app semantics.** It knows about devices, streams, buffers and
  permissions, not about cartridges, choir parts or drum kits.

**App-local** native code is right when:

- the code is the app's domain: FMutate's firmware engines and their shared
  memory ring protocol, a synth voice, an app-specific DSP chain;
- you are spiking to learn what the API should be. Then upstream it when a
  second app wants it, not after a third copy exists;
- a vendor SDK or licence ties it to one app.

A capability often splits. The generic I/O goes in a plugin, and the app's DSP
stays in the app and links against the plugin's C ABI. `mob_midi` works this
way on Android: it exposes `priv/include/mob_midi.h`, and Magpie's audio
engine sends and receives MIDI through that ABI.

If you're not sure, ask in Linear (team `MOB`) before you write the second
copy. An issue that names the apps that need the capability is enough.

## When you upstream: one API, honest platforms

- **One Elixir API for both platforms.** The same functions, return shapes and
  messages on iOS and Android, so app code doesn't branch on platform. Choir
  Coach shows the shape: `plugins/choir_audio_ios` is a separate iOS NIF with
  the same Erlang module, functions and events as the Android `c_src/choir_audio.c`,
  so `ChoirCoach.Audio.Native` runs unchanged on both.
- **Declare architectures honestly.** `:archs` on a `:static_nifs` entry and
  the per-platform sections of a plugin manifest say where the real
  implementation is. A platform without one answers
  `{:error, :unsupported}` from a stub, and the moduledoc has a support table
  that says so. `mob_midi`'s C ABI is Android-only, and its iOS stubs answer
  `:unsupported`. `mob_audio_capture` shows how to document a stub that is
  permanent because the platform forbids the capability; it predates the
  convention and answers `{:error, :unsupported_on_platform}`.
- **The host is a platform too.** On the host (`mix test`, dev) the NIF isn't
  loaded. Answer `{:error, :unsupported}` there instead of raising
  `:nif_not_loaded` (`MobMidi.Platform` does this), and ship a fake (below).
- **Errors are values.** A failed open, a lost device or a stalled stream
  comes back as a tagged tuple or a message to the owner process, never as a
  silent no-op. `mob_midi` answers `{:error, :queue_full}` and
  `{:error, :not_open}`; `mob_sensors` answers `{:error, :unavailable}` when the
  device has no such sensor.

## The feedback mechanisms a capability must reach

Agents verify Mob apps by asking the running BEAM, not by reading
screenshots (see [Agentic Coding](agentic_coding.md)). An upstreamed
capability is done when the agent can see it through the same channels as the
rest of Mob. This is what exists, and what a NIF, view or plugin has to do to
show up in each. Sloppy Joe, the on-device agent app, exposes several of these
as MCP tools; its tool names are in the table next to the `Mob.Test` call
each one corresponds to.

| Mechanism | Where it lives | What the agent gets | How a capability opts in |
|--|--|--|--|
| Render tree / `ui_tree` | `Mob.Test.find/2`, `inspect/1`, `ui_tree/1`, `view_tree/1`; Sloppy Joe `render_tree` | The nodes the screen rendered, with props and tap tags | Put state the user can see into assigns and render it. Props on a native view (`Mob.UI.native_view/2`) appear in the tree; state held only inside Swift or Kotlin does not |
| Assigns | `Mob.Test.assigns/1`, `Mob.Test.screen/1` | The screen's live state | Deliver results to the screen process as messages, so `handle_info/2` puts them in assigns |
| Element frames and tap by id | `Mob.Test.element_frames/1`, `frame/2`, `tap_id/2`; Sloppy Joe `element_frames` | On-screen position of every node with an `:id` | Give the node an `:id` (`Mob.UI.native_view/2` already requires one). On iOS a native view registered with `MobNativeViewRegistry` gets a frame like a built-in node. On Android it gets none yet (MOB-534), so `tap_id/2` answers `{:error, :not_found}` there |
| Synthetic input and message injection | `Mob.Test.tap/2`, `send_message/2`, `settle/2`; Sloppy Joe `tap` | Drive the screen without hardware | Results arrive at the screen as documented message tuples (`{:mob_sensors, :reading, type, map}`, `{:mob_sensors, :error, type, reason}`), so `send_message/2` can stand in for the hardware. Document each tuple in the moduledoc |
| Probe discovery | `Mob.Test.capabilities/1` (`mob_nif:capabilities/0`) | Which harness probes this build actually has | Core harness only. A plugin readback that may be missing on a platform answers `{:error, :unsupported}`, never raises |
| Action receipts | `Mob.Agent.Receipts`, `[:mob, :action, :stop]` telemetry | Which stage an action reached: dispatched, handled, assigns changed | Free for `Mob.Screen.dispatch/3` and the discrete native input in `Mob.Event.NativeInput`. Plugin-defined messages get no receipt, and neither do native view events, which go to the component process (`{:component_event, …}`), not the screen. Their effect must show in the owning screen's assigns or a readback |
| Event trace | `Mob.Event.Trace.subscribe/2` | Every event reaching a handler, payload included | What receipts cover, plus display-rate streams (scroll, drag, slider). Plugin-defined messages and native view events are not traced |
| Logger | `Mob.NativeLogger` → logcat / unified log; Sloppy Joe `logs` (an OTP `:logger` ring buffer) | What happened, with a timestamp, on and off the device | Log from Elixir with a bracketed prefix: `Logger.info("[mob_midi] opened …")`. Lines printed from C, Kotlin or Swift reach logcat or the unified log but **not** Sloppy Joe's `logs`; send native errors up to Elixir and log them there |
| Dist / RPC | `mix mob.connect`, `:rpc.call/4`; Sloppy Joe `eval` | Call any function on the device | Public functions are reachable already. Add a readback: a `status/0` or `info/0` that returns a plain map (open streams, sample rate, underruns, last error). FMutate's `FMutate.Audio.stats/0` and Humdinger's `info/0` are the shape |
| Self-test | `Mob.Plugin.SelfTest`, `selftest:` in the manifest; `mix mob.selftest`; mob_ci nightly | Proof that the native side linked and answers on this device | Implement `run/1`. It must get a real answer from native code; loading a module is not a pass |
| Defect bus | `Mob.Defect.Bus` (`emit/1`, `recent/0`, `subscribe/1`) | Fingerprinted, deduplicated defects across devices | Framework-level defects. A plugin MAY emit a `Mob.Defect.Capsule` for a fault the app can't see, such as a stream the OS killed |
| Diagnostics health | `Mob.Diag.health/0`, `Mob.Invariant.violations/0` | Whether the diagnostic stores themselves can be trusted | Core only |
| Post-mortems | `Mob.PostMortem.sweep/0` | Native crashes, ANRs, OOM kills, `erl_crash.dump`, MetricKit | Free: a crash in a NIF or a native view is captured with the rest of the app's |
| Render timing | `Mob.RenderStats` | Time per frame stage, BEAM and native | Core only |
| Push attestation | `mix mob.attest`, `mix mob.deploy --json` | Whether the device runs the code you pushed | Free for the Elixir half. Native code needs `mix mob.deploy --native` |
| Manifest checks | `mix mob.validate_plugin`, cross-plugin conflict checks at build time | Missing files, one-platform components, name clashes, a missing `selftest` | Use the manifest for everything native. Code in an app's `c_src/` gets none of these checks |
| Plugin audit | `mix mob.audit_plugins` | Risky calls in plugin Elixir and NIF C source (`Code.eval_string`, `binary_to_term/1`, `system(3)`, sockets) | Free for manifest plugins; app-local code isn't audited |
| Cross-platform agreement | `Mob.Differential.compare/3`, `MobDev.Differential.run/3` | The first divergence between the iOS and Android `view_tree/1`; `run/3` also puts it on the defect bus | Free for anything in the render tree. State held inside Swift or Kotlin can't be compared |
| Docs | Mob's `guides/` (Sloppy Joe `read_guide`, served at the device's mob version), moduledocs (`h/1`, hexdocs, Sloppy Joe `read_doc`) | The API and its rules | `@moduledoc` with the support table, the message tuples and the error atoms. `read_guide` serves only Mob's own `guides/`; a plugin's guide reaches agents through hexdocs and `deps/<plugin>/` |
| Host tests | `mix test`, `Mob.ScreenCase` | The Elixir half, without a device | A behaviour with a native and a fake implementation |

### Test-only native code and releases

Mob's own test harness is compiled out of iOS release builds by
`#if !MOB_RELEASE` in `ios/mob_nif.m`. It uses private UIKit selectors, which
App Store validation rejects. That flag does not reach plugins: mob_dev
compiles plugin and app NIF sources without `-DMOB_RELEASE`, and Android
release builds don't set it at all (MOB-510). So a plugin can't strip a
test-only entry point today. Until it can:

- put test hooks in Elixir (the fake, `send_message/2`), not in native code;
- keep native readbacks to public APIs that are safe to ship, such as
  counters and device lists;
- if a native entry point is test-only anyway, make it harmless in a shipped
  app and say so in its doc.

## Checklist

Work through it when you move native code into Mob or a plugin, or write a
new capability there. Each line names the mechanism above it feeds.

- [ ] One Elixir module is the API on iOS, Android and the host. No platform
      branches in app code.
- [ ] Each platform is real or answers `{:error, :unsupported}`. `:archs` and
      the manifest match, and the moduledoc has a support table.
- [ ] Results reach the screen as documented message tuples, and the screen
      can keep them in assigns. *(assigns, render tree, `send_message/2`)*
- [ ] Native views take an `:id` and report their state to the owning
      screen, so it shows in assigns or props, not only inside Swift or
      Kotlin. *(element frames, render tree, differential)*
- [ ] Every failure is a tagged tuple or an error message to the owner, and
      is logged from Elixir with a `[plugin_name]` prefix. *(Logger, Sloppy
      Joe `logs`)*
- [ ] A `status/0` or `info/0` readback returns a plain map an agent can read
      over RPC. *(dist)*
- [ ] `selftest:` names a `Mob.Plugin.SelfTest` that gets a real answer from
      native code. `mix mob.selftest` passes on both platforms.
- [ ] A behaviour plus a fake implementation lets `mix test` run without a
      device, and the plugin's host tests cover the Elixir half.
- [ ] No test-only native code, or test-only code that is harmless in a
      release (see above).
- [ ] The moduledoc covers the API, the messages, the error atoms and the
      support table. Rules every app must follow go in Mob's `guides/`, which
      Sloppy Joe's `read_guide` serves.
- [ ] `mix mob.validate_plugin` is clean.
- [ ] Verified on a device for each supported platform, by RPC and
      `Mob.Test`, not by a screenshot alone.

If a mechanism doesn't fit (the agent needs state that none of the above can
show), add a readback and file it, as described in
[Mob's `AGENTS.md`](https://github.com/GenericJam/mob/blob/master/AGENTS.md)
under "When the ladder can't be climbed, propose the missing readback".

## Examples

Plugins to copy:

| Plugin | Shows |
|--|--|
| `mob_midi` | One API on both platforms; `{:error, :unsupported}` on the host (`MobMidi.Platform`); tagged errors (`:queue_full`, `:not_open`); a C ABI (`priv/include/mob_midi.h`, Android today) other native code links against; `MobMidi.SelfTest` |
| `mob_sensors` | `{:error, :unavailable}` per sensor, a per-platform support table in the moduledoc, `MobSensors.SelfTest` |
| `mob_background` | A platform service (a foreground service on Android, an `AVAudioSession` keep-alive on iOS) behind one module, with `host_requirements` for the manifest fragment. It ships no `selftest` yet |
| `mob_audio_capture` | An honest one-platform plugin: the iOS stub is permanent and the README says why |

App-local native code that should move:

| App | Code | Platforms | Overlap |
|--|--|--|--|
| FMutate | `c_src/fm1audio.c` (`:static_nifs`, `archs: [:all]`) | AAudio output, RemoteIO output | Output stream, with a `stats/0` readback |
| Choir Coach | `c_src/choir_audio.c` (Android) and `plugins/choir_audio_ios` (iOS) | AAudio in and out; RemoteIO out and AudioQueue in | Playback, listening and pitch detection, one Erlang API on both |
| Humdinger | `c_src/hum_audio.c` (`archs: [:android]`) | AAudio in and out | Microphone pitch, level and spectrum, piano playback; `Humdinger.Audio` behaviour with `Native` and `Fake` |
| Magpie | `c_src/magpie_audio.c` (`archs: [:android]`) | AAudio in and out | Sampler output, recorder input, `Magpie.Audio` with `Native` and `Fake` |

All four open low-latency audio streams through AAudio on Android, loaded with
`dlopen`, and both iOS sides open their own RemoteIO unit. A shared audio I/O
plugin (streams, devices, sample rate, underrun counters, permission
handling) would let each app keep only its DSP, and give Humdinger and Magpie
an iOS side without writing one each. The apps' existing behaviour + fake
split and their `info/0` and `stats/0` readbacks should carry over into the
plugin.
