# Load plugin NIF modules at boot

- Date: 2026-06-10
- Status: accepted

## Context

On iOS a plugin's permission handler self-registers in its NIF's `load`
callback (`mob_register_permission_handler`), which only fires when the Erlang
NIF module is first loaded. Elixir loads modules lazily, so a screen that calls
`Mob.Permissions.request(socket, :camera)` in `mount/3` — before anything touches
the plugin's NIF module — runs before the handler is registered. Core's
`nif_request_permission` falls through to the registry, finds no `"camera"`
handler, and raises `:badarg`; the screen crashes on mount.

Android has no such gap: plugin permission providers register eagerly at boot via
the generated `MobPluginBootstrap.registerAll()`. The asymmetry surfaced while
device-verifying the `mob_camera` extraction (camera worked on a Moto G, badarg'd
on the iOS simulator). A per-plugin `lifecycle.on_start` that force-loaded the NIF
module worked but is a workaround every iOS permission plugin would have to copy.

## Decision

The runtime manifest now carries `nifs` — the activated plugins' NIF module atoms
(emitted by `MobDev.Plugin.RuntimeManifest.build/1`, deduped and platform-agnostic
since the same module name backs both the iOS and Android NIF). `Mob.Plugins.boot/1`
calls `ensure_nif_modules_loaded/0`, which `Code.ensure_loaded/1`s each one at boot
— firing every plugin NIF's `load` callback eagerly, the iOS counterpart to
Android's bootstrap. `load_nif` failure is tolerated by each NIF module's
`on_load`, so a host build with no native linked is a no-op.

## Consequences

- Any iOS plugin that registers a permission (or any other `load`-callback side
  effect) works without a per-plugin lifecycle workaround. The `mob_camera`
  `lifecycle.on_start` + `__ensure_native_loaded__` shim were removed.
- All activated plugin NIF modules load at boot on both platforms (cheap; also
  fail-fast if a NIF is mislinked). Loading on Android is redundant for permissions
  but harmless.
- The runtime manifest gained a key; `@empty` in `Mob.Plugins` carries `nifs: []`
  so older manifests without the key stay backward-compatible via `Map.merge`.
- Verified end-to-end on the iOS simulator: after removing the workaround and with
  the camera privacy permission reset, the native permission dialog fires on the
  camera screen (no badarg, no crash).
