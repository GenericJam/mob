# Extensible permission registry for plugins (Option A, runtime)

- Date: 2026-06-04
- Status: accepted

## Context

Wave 2 of the plugin-extraction epic moves the runtime-permission capabilities
(`:camera`, `:microphone`, `:photo_library`, `:location`, `:notifications`) out
of core and into plugins. The static *declarations* (iOS `Info.plist` keys,
Android `<uses-permission>`) already merge from plugin manifests at build time
(see the Wave-1 plist/manifest merge). What stayed core-bound is the **runtime
request**: `Mob.Permissions.request/2` had a hardcoded capability enum, and
`:mob_nif.request_permission(cap)` dispatched through a per-capability if/else
in the native layer (iOS `nif_request_permission`, Android
`MobBridge.request_permission`).

Once Wave 2 extracts all five, that core enum/dispatch would be empty, so the
mechanism itself has to become extensible: a plugin must be able to add a new
runtime capability and its handler.

Kevin chose **Option A — keep the unified `Mob.Permissions.request(socket, cap)`
API; make the native request_permission table-driven; a plugin ships its own
permission handler and registers its capability** (vs Option B, a separate
per-plugin API surface). He framed it as "the extensible registry is on device".

## Decision

A **runtime** registry on each platform, populated by the plugin at load /
bootstrap time. (This supersedes the earlier sketch of a build-time *codegen*
dispatcher on iOS — see Consequences for why.)

**Elixir (`Mob.Permissions`)** — relax the hardcoded `when capability in [...]`
guard to accept any atom and delegate validity to the native layer. An unknown
capability returns `badarg` from the NIF (→ `ArgumentError`), so invalid caps
still error; valid plugin-registered caps now pass through. The core capability
list survives only as documentation. The real source of truth for "what's a
valid capability" is the native registry, i.e. genuinely on-device.

**iOS** — core `mob_nif.m` holds a small fixed handler table and exports a
stable C symbol:

    void mob_register_permission_handler(const char *cap,
                                         void (*fn)(ErlNifPid));

A plugin's C/ObjC NIF (already compiled + linked into the one static binary via
the `plugin_c_nifs` path) calls this from its `ERL_NIF_INIT` load callback to
register its capability. `nif_request_permission`'s `else` branch looks the
capability up in the table and calls `handler(pid)`; the handler drives the
native permission API and delivers `{:permission, cap, :granted|:denied}` to
`pid` via raw `enif_send` (the plugin has `erl_nif.h`). Unknown cap → `badarg`.

**Android** — mob_dev generates a marker interface (mirroring `MobActivityAware`)

    interface MobPermissionProvider { fun permissionsFor(cap: String): Array<String>? }

and extends the generated `MobPluginBootstrap` to collect every registered
bridge that implements it and expose `permissionsFor(cap)`. Core
`MobBridge.request_permission`'s `else` branch consults
`MobPluginBootstrap.permissionsFor(cap)`; the rest of the flow
(`checkSelfPermission` / `ActivityCompat.requestPermissions` /
`onRequestPermissionsResult` → `onPermissionResult`) stays generic in core.
Android's request flow was already almost entirely capability-agnostic — only
the cap→permission-string mapping was specific, and that's exactly what the
provider supplies.

**Manifest** gains a `permissions:` field (tier-1, native, non-hot-pushable):

    permissions: [%{capability: :location, ios: %{handler: "mob_location_request_permission"}}]

`:capability` is the atom `Mob.Permissions.request/2` accepts. `ios.handler` is
documentation of the cdecl symbol the plugin self-registers (not consumed by a
codegen step). Android needs no manifest entry — the provider is auto-discovered
by `bridge is MobPermissionProvider` at `registerAll`.

## Consequences

- **Much smaller surface than the codegen sketch.** No iOS permission codegen
  module, no new `-Dplugin_perm_c` build.zig option (would have touched 4 files:
  both iOS build templates + both demo copies), no `Merge` permission gatherers.
  mob_dev changes reduce to Manifest validation + the Android Kotlin emitters.
- **iOS needs one exported core symbol** (`mob_register_permission_handler`).
  It is referenced by plugin objects in the same static binary, so it links and
  survives `-dead_strip` (reachable from the plugin's load callback).
- **Load-order**: the plugin's handler is registered when its NIF's `on_load`
  fires (BEAM boot), well before any user-initiated permission request. The
  table is written once at load, read later on a scheduler thread — same
  single-write-then-read pattern as other core globals; no lock added.
- **Symmetry**: both platforms are now runtime registries populated at
  load/bootstrap, which matches Kevin's "registry on device" mental model better
  than the asymmetric (iOS-codegen / Android-runtime) sketch did.
- Proven with a trivial `mob_demo_perm` prototype on both platforms before the
  real `mob_location` extraction, per the epic's trivial-first discipline.
