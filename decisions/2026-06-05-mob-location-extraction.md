# Extract location from core into the mob_location plugin (Wave 2)

- Date: 2026-06-05
- Status: accepted

## Context

Wave 1 extracted Bluetooth into the `mob_bluetooth` plugin and proved the
plugin native pipeline (zig NIFs, Android bridge classes, per-host signing).
Wave 2 moves the runtime-permission-backed device capabilities (location,
camera, notify, photos, biometric) out of core. `mob_location` is the
pattern-setter: unlike bt (Android-only) it is cross-platform, so it exercises
the iOS plugin-NIF path (ObjC/`.m` via `lang: :objc`), the Android zig NIF
path, and the extensible permission registry (`mob_register_permission_handler`
on iOS, `MobPermissionProvider` on Android) all at once.

The three blocking infra pieces (permission registry, per-platform NIF source
tagging, ObjC plugin NIF compile path) landed and were device-verified earlier;
this decision covers the relocation itself.

## Decision

Move location out of core into a standalone `mob_location` tier-1 plugin
(`/Users/kevin/code/mob_location`) and **hard-remove** it from core — no shim,
no deprecation alias, matching the Wave 1 bt precedent.

- **Coexistence then strip.** The plugin registers Erlang module
  `mob_location_nif`; core kept `:mob_nif.location_*`. Different module names =
  no symbol/registration collision, so the plugin was built and device-verified
  on both platforms *while core still owned location*. Only after that proof did
  core get stripped (the breaking step).
- **What left core:** `lib/mob/location.ex`; the `location_*` NIFs +
  `MobLocationDelegate`/`MobLocationPermissionDelegate` + `setup_location_manager`
  + the hardcoded `"location"` branch of `nif_request_permission` in
  `ios/mob_nif.m`; the `nif_location_*` exports + `mob_deliver_location` +
  Bridge method-ids + `cacheRequired` + nif-table entries in
  `android/jni/mob_nif.zig`; the `mob_deliver_location` decl in `mob_beam.h`;
  the three `location_*` stubs in `src/mob_nif.erl`; `:location` from the
  `Mob.Permissions` documented core-capability list and `@type capability`.
- **Permission flow after strip:** removing the hardcoded iOS `"location"`
  branch lets `:location` fall through to the plugin handler the
  `mob_location_nif.m` load callback registers via
  `mob_register_permission_handler`. On Android the plugin's
  `MobLocationBridge` implements `MobPermissionProvider`, discovered by the
  generated `MobPluginBootstrap`. The unified `Mob.Permissions.request/2` API is
  unchanged.
- **Templates:** the same location surface was stripped from the mob_new
  generated-app templates (`MobBridge.kt.eex`, `beam_jni.c.eex`,
  `AndroidManifest.xml.eex` LOCATION perms, `build.gradle.eex`
  play-services-location). A generated app now gets location only by depending
  on `mob_location`, whose manifest contributes the perms + gradle dep +
  CoreLocation framework + plist key at build-time merge.

## Consequences

- **Breaking:** `Mob.Location` is gone from core. Any caller must add the
  `mob_location` dep and call `MobLocation`. No in-repo caller used it; the one
  external consumer is version-pinned (safe until they bump). CHANGELOG updated.
- Core's `nif_request_permission` no longer special-cases location; the
  registry path is now the *only* location-permission path, exercising Phase A
  infra in production rather than just the `mob_demo_perm` prototype.
- Device-verified on Moto G (ZY22DP6HFL) + iPhone SE (iOS 26.5) after the strip:
  `mob_location_nif.location_{start,get_once}` round-trip real fixes through the
  plugin alone, core location grep = 0.
- `mob_location` still needs its own signing key + GitHub repo (follow-up,
  mirrors `mob_bluetooth`); until then it rides the demo's
  `acknowledge_unsafe_plugins` hatch.
