# Magnetometer / compass support in Mob.Motion

- Date: 2026-07-02
- Status: accepted; partially superseded by `2026-07-04-magnetometer-stable-key-contract.md` (the "Android registers whenever hardware present (v1)" activation trigger and the map-shape/`nil`-key contract — the magnetic-north scope, additive keys, and delivery-via-`mob_deliver_motion_mag` decisions still stand)
- Issue: MOB-6

## Context

`Mob.Motion` exposed accelerometer + gyroscope but not the magnetometer, so a mob
app couldn't build a compass/heading. The sensor is present on most (not all)
phones. This adds it, cross-repo (`mob` Elixir + iOS + zig, `mob_new` Kotlin
template, per-app bridge regen).

## Decision

- **Report both `mag` (µT) and a fused `heading`** (degrees), not just the raw
  field — a raw vector isn't a usable compass; heading needs sensor fusion, which
  the platforms already do.
- **Magnetic north only.** True north needs location + geomagnetic declination —
  out of scope; an app can layer it with `Mob.Location`.
- **iOS: opt-in via the sensor list.** When `:magnetometer` is requested and the
  device supports the `XMagneticNorthZVertical` attitude reference frame, switch
  device motion to that frame (fuses accel+gyro+mag → calibrated `magneticField` +
  `heading` on one stream). Otherwise the plain accel/gyro stream is unchanged.
- **Android: register when the hardware is present** (v1), rather than threading
  the sensor set through the JNI `motion_start` signature. Android already ignored
  the sensor list (both accel+gyro always registered), so this matches existing
  behavior; heading comes from `TYPE_ROTATION_VECTOR` → `getRotationMatrixFromVector`
  → `getOrientation`. **Follow-up:** make it opt-in (encode the sensor set in the
  existing `motion_start` string arg — no ABI change) to avoid running the
  magnetometer for accel-only consumers.
- **Delivery via a new `mob_deliver_motion_mag`** (5-key `{:motion, _}` map) rather
  than widening `mob_deliver_motion` — keeps the existing accel/gyro path
  byte-identical (zero risk to current consumers like the tilt-follow eyes).
- **`heading < 0` ⇒ `nil`.** Both platforms use a negative sentinel for
  "unavailable"; the native layer converts it to the atom `nil`.

## Consequences

- `mag`/`heading` are **additive** map keys — existing accel/gyro consumers are
  unaffected (map patterns aren't exclusive).
- Android v1 runs the magnetometer + rotation-vector whenever the hardware exists,
  a small battery cost for accel-only users until the opt-in follow-up lands.
- iOS is opt-in; Android is present-if-hardware. The `heading`/`mag` contract is
  identical; only the activation trigger differs (documented in `Mob.Motion`).
- The new delivery function must bind through the generated JNI thunk seam; the
  per-app `MobBridge.kt` needs regenerating from the `mob_new` template (the same
  bridge-refresh step every native addition needs).
