# Plugin tiers 3 (multi-screen) and 4 (sub-app)

- Date: 2026-06-06
- Status: accepted

## Context

The plugin system shipped tiers 0-2 (pure-Elixir helper, NIF, native component).
Tiers 3 (multi-screen) and 4 (embedded sub-app) were specified in `MOB_PLUGINS.md`
and classified by the manifest engine, but nothing wired them. Unlike tiers 1-2
(native symbols merged at link time), tiers 3-4 are **pure-Elixir and
runtime-wired**: a plugin's screens / lifecycle modules / settings / notification
handlers are ordinary Elixir compiled into the host release. The only missing
piece was on-device awareness of what each activated plugin declares —
`MobDev.Plugin.activated/0` is compile-time only.

## Decision

A **generated runtime manifest** is the linchpin. mob_dev gathers each activated
plugin's tier-3/4 sections (running spec-v2 `screens_generator`s under the
host-config audit) and emits `priv/generated/mob_plugins.exs`; the core
`Mob.Plugins` module reads it at boot and feeds the existing primitives:

- **Screens** register into `Mob.Nav.Registry` by route at boot; the host still
  chooses where to surface them (no silent route-grabbing).
- **Lifecycle**: `Mob.Plugins.Supervisor` runs each `on_start`, supervises the
  declared children, and `Mob.Plugins.Lifecycle` dispatches `Mob.Device` app
  events to `on_resume`/`on_background`.
- **Settings**: `Mob.State` (the persistent K/V store) namespaced per plugin,
  schema-default on read, type-validated on write. (The spec said `Mob.Storage`;
  the actual K/V store is `Mob.State`.)
- **Notifications**: `dispatch_notification/1` routes a payload to the first
  matching handler (map prefix-match or `{M,F,arity}` predicate).
- **Migrations / images**: build-time file copies into the host bundle
  (`native_build`), since their build-machine paths are meaningless on device.

Two non-obvious calls the device runs forced:

1. **Host app name at compile time.** `Mob.Plugins.boot` needs the host OTP app
   to find the manifest, but `Application.get_application/1` returns nil on a mob
   release (custom BEAM entry, not `Application.start`). The `use Mob.App` macro
   captures `Mix.Project.config[:app]` at compile time instead.
2. **Plugin lifecycle starts before the host `on_start`.** A host `on_start` may
   never return (iOS blocks in `Mob.Dist.ensure_started`); starting plugin
   lifecycle after it would starve plugins. It runs before — framework services
   a plugin needs are already up. Tradeoff: a plugin `on_start` can't depend on
   the host's own `on_start` side-effects.

Tier-3/4 manifest sections must be fully serializable (they feed the terms
file), so notification `match` is a map or `{M,F,arity}` predicate, never a
closure; notification `handler` is `{M,F,arity}` (invoked with the payload),
distinct from the `{M,F,args}` MFAs that generators/lifecycle use.

## Consequences

- New generated artifact `priv/generated/mob_plugins.exs`, regenerated when
  `config :mob, :plugins` changes (`mix mob.regen_plugin_manifest`).
- Device-verified on iPhone + Moto G: tier-3 static screens, tier-3 spec-v2
  generated screens, tier-3 migrations (table created on device), and tier-4
  on_start / supervised worker / settings / notification routing.
- Remaining native frontier (planners + resolver already built/tested): font
  bundling (iOS `UIAppFonts` + platform bundle resources, Android assets), the
  renderer `plugin://` image hookup, and notification central delivery (a native
  reroute so real OS notifications reach `dispatch_notification`).
