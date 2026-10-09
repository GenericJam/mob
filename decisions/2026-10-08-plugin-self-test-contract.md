# Plugins carry their own on-device proof: `Mob.Plugin.SelfTest`

- Date: 2026-10-08
- Status: accepted
- Linear: MOB-411 (MOB-410 epic; MOB-418 for the remaining plugins)

## Context

Every first-party plugin has ubuntu-only CI that never compiles its native
code. mob_ci (the nightly device CI, `~/code/mob_ci`) proves a NIF
initialised with a "safe probe" per plugin that it keeps in its own
`priv/device_caps.exs`: `{:location_stop, []}` for mob_location,
`{:video_probe, ["/nonexistent"]}` for mob_video, `nil` for plugins whose
only exports open UI. That table is knowledge about plugin internals held
by a repo that does not own them, it went stale as soon as it was written
(26 plugins, 10 rows), and `nil` rows mean "we checked the module loaded",
which MOB-372/373/376 showed says nothing: those were "dev build works,
release doesn't" bugs that only a real native call sees.

## Decision

The proof moves into the plugin. `mob` gains a behaviour with one callback:

```elixir
@callback run(%{platform: :ios | :android, device: :simulator | :emulator | :physical}) ::
            :pass | {:fail, String.t()} | {:skip, :needs_hardware | :needs_user | String.t()}
```

declared in the manifest as `selftest: Module`. The rule for `:pass` is
that the test got a real answer back from native code (or, for a
pure-Elixir plugin, from its real API path); loading a module is not a
pass. `{:skip, _}` is for a resource the device lacks, after the test has
proved what it can without it. The runner (mob_dev's
`MobDev.Plugin.SelfTest.run_all/3`, `mix mob.selftest`; mob_ci's P12)
treats a raise, exit, timeout or off-contract return as a failure, so
tests assert with pattern matches instead of rescuing.

`mob` owns only the contract: the behaviour, its types, `result?/1` and the
documentation in `MOB_PLUGINS.md`. mob_dev owns validation (the manifest
key, a warning when missing that becomes an error one release later) and
the runner; mob_ci owns attribution (failing alone is `plugin:<p>`, failing
only in company is `conflict:<set>`). The runner passes the context rather
than the plugin detecting it, so a plugin cannot mistake a simulator for a
phone and skip where it should prove.

## Consequences

- `Mob.Plugin.*` is a new namespace for behaviours a plugin implements;
  `Mob.Plugins` (plural) stays the on-device registry.
- mob_ci's `device_caps.exs` shrinks to what the plugin cannot know (which
  fixture host can build it) once every plugin has a self-test (MOB-418).
- A plugin without a self-test is a warning from mob_dev 0.7.17 and an
  error from a later release; pilots are mob_location, mob_whisper and
  mob_deliver.

## Alternatives considered

- **Keep the probe table in mob_ci.** Rejected: it is knowledge about
  plugin internals held outside the plugin, and it cannot express "call
  this and expect that" without becoming a second test framework.
- **A lifecycle hook (`lifecycle.selftest`) instead of a behaviour.**
  Rejected: lifecycle MFAs are tier-4 and run at boot; a self-test runs on
  demand from the host, with a context, and wants a typed result.
- **Detect the context on the device (`Mob.Device`).** Rejected: the
  runner already knows the device it attached to, and a plugin deciding
  for itself that it is "on an emulator" is how a skip hides a real hole.
