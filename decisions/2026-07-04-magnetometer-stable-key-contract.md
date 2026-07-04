# Mob.Motion magnetometer: stable-key contract + Android opt-in

- Date: 2026-07-04
- Status: accepted
- Issue: MOB-6
- Amends: `2026-07-02-magnetometer-compass.md` (supersedes its "Android registers
  when hardware present" and "heading nil sentinel only" points)

## Context

A review of the first magnetometer cut found the public `Mob.Motion` docstring
made two promises the implementation didn't keep:

1. "`heading` is `nil` on a device with no magnetometer." False — on both
   platforms a magnetometer-less device fell back to the 3-key map, so the
   `heading` key was **absent**, not `nil`. A compass app pattern-matching
   `%{heading: h}` would hit a `KeyError` on exactly the phones this feature must
   degrade gracefully on.
2. "`mag`/`heading` appear only when you request `:magnetometer`." True on iOS
   (which parses the sensor list) but false on Android: `motion_start` only ever
   received the interval, so it registered the magnetometer whenever the hardware
   existed — regardless of the request. An accel/gyro-only consumer (e.g. the
   tilt-follow eyes) on a magnetometer phone got surprise 5-key maps plus the
   battery cost of two extra sensors.

The earlier ADR documented the Android asymmetry as an accepted v1 shortcut with
"make it opt-in" as a follow-up. We're doing the follow-up now rather than
shipping an inaccurate public contract.

## Decision

Make the map shape a function of **what was requested**, uniformly across
platforms:

- **Requested `:magnetometer` ⇒ `mag` + `heading` keys are always present**, each
  `nil` when there's no reading (no magnetometer hardware, or heading not yet
  fused). Stable keys — safe to pattern-match.
- **Did not request ⇒ neither key** (the plain 3-key accel/gyro stream, byte-
  identical to before).

Mechanics:

- **Android sensor set is now plumbed through** without an ABI change: the
  `motion_start/2` NIF still takes `(sensors, interval_ms)`, and `nif_motion_start`
  (zig) encodes the request into the existing JNI string arg as
  `"<interval>"` or `"<interval>,magnetometer"`. Kotlin parses it, registers the
  magnetometer + rotation-vector **only when requested**, and picks the delivery
  accordingly.
- **`nil` sentinels ride the existing 12-arg delivery.** `mob_deliver_motion_mag`
  now maps a NaN `mag` component → `mag: nil` (in addition to the existing
  `heading < 0` → `heading: nil`). So "requested but no hardware" still uses the
  5-key delivery, passing NaN/−1, and the app sees `mag: nil, heading: nil`. No
  new FFI symbol.
- **iOS** already knew the request (`want_mag`); it now builds the 5-key map
  whenever `want_mag`, filling `nil`/`nil` when the magnetic-north reference frame
  isn't available, instead of dropping to the 3-key map.

## Consequences

- Public contract now matches the docstring on both platforms; the `KeyError`
  trap is gone and accel/gyro-only apps are untouched (and pay nothing extra).
- The FFI arity and the accel/gyro-only C path are still byte-identical — the
  change is additive (sentinel interpretation + a request flag in a string).
- Device-verified: happy path (real heading/mag) on moto g + iPhone SE; opt-in
  (no request ⇒ 3-key, no mag sensors) on a physical device; `nil`/`nil`
  requested-but-no-hardware path on the iOS simulator (which has no magnetometer).
- `NaN` is the "no mag reading" wire sentinel — callers never see it (the native
  layer converts to `nil`); documented at the `mob_deliver_motion_mag` export.
