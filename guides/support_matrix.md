# Device support matrix

What runs where, why, and what happens if you point Mob at a device
below the floor.

This guide is the contract — `mix mob.deploy` validates against these
numbers before any build runs, so a device the framework can't actually
support will fail fast with a clear error rather than silently
producing an APK that crashes at install or runtime.

---

## The floor (every Mob app)

| Platform | ABIs | Minimum OS | Source of constraint |
|---|---|---|---|
| Android | `arm64-v8a`, `x86_64` (emulator), `armeabi-v7a` | API 28 / Android 9 | Mob ships pre-built BEAM/erts tarballs for each supported slice. Android emulators on x86_64 hosts require the `otp-android-x86_64-*` release asset; `armeabi-v7a` works for vanilla Mob apps but remains unsupported for Pythonx-enabled apps. |
| iOS | `arm64` (device + sim on Apple Silicon), `x86_64` (sim on Intel Macs) | iOS 13 | Mob's iOS template `IPHONEOS_DEPLOYMENT_TARGET` is set to 13.0 and the bundled OTP is arm64-only. Older iOS versions (and 32-bit hardware — i.e. iPhone 5/5c) cannot run Mob. |

This floor is enforced at deploy time by `MobDev.SupportMatrix.check_device/2`,
called from `mix mob.deploy` before any build kicks off.

---

## Per-feature additions

A feature inherits the base floor unless it tightens it further. Tightening
shows up in `MobDev.SupportMatrix.feature_requirements/1`.

### `pythonx` (embedded CPython)

| Platform | ABIs | Minimum OS | Source of constraint |
|---|---|---|---|
| Android | `arm64-v8a`, `x86_64` | API 28 | [Chaquopy](https://chaquo.com/chaquopy/) ships its prebuilt CPython distribution for `arm64-v8a` and `x86_64` only. **They dropped `armeabi-v7a` (32-bit ARM) several releases back.** Pythonx-enabled Mob apps cannot run on 32-bit Android phones, regardless of OS version. |
| iOS | `arm64` (device + sim) | iOS 13 | [BeeWare's `Python-Apple-support`](https://github.com/beeware/Python-Apple-support) framework targets iOS 13+. Older iPads / iPhones can't load it. |

Bundle size adds ~70 MB on iOS, ~30 MB on Android. See
[`mob_dev/guides/python_embedding.md`](../../mob_dev/guides/python_embedding.md)
for the full pipeline.

---

## Why we don't try harder for older devices

The instinct is "people with low-income or older hardware deserve to
be considered, even if Google or Apple have abandoned them." That's
real, and the team agrees with it. For vanilla Mob apps, that means the
base runtime includes an `armeabi-v7a` slice alongside modern arm64 and
x86_64 emulator support.

Feature-specific native dependencies can still tighten the floor.
Pythonx is the current example: Chaquopy no longer ships a 32-bit
Android distribution, so Pythonx-enabled Mob apps require `arm64-v8a`
or `x86_64` even though vanilla Mob can run on `armeabi-v7a`.

The trade-off we make: declare the floor explicitly, validate it at the
earliest possible moment, and tell the user *which* of their devices
won't work and *why* — including which upstream vendor's decision is
the cause. They get the full picture before they invest time, instead
of a cryptic gradle error after a 5-minute build.

If you have hardware that falls below the floor and want to discuss
whether a path exists, open an issue. We'd rather hear the use case
than have it land in a confused-user category silently.

---

## What the user sees

When the project's enabled features and the targeted device's
discovered properties don't line up, `mix mob.deploy` halts before the
build with output like:

```
Device compatibility check failed.
  ✗ · moto e (Android 10)  [physical]  10.0.0.82:5555
      - Mob requires android arm64-v8a or x86_64; this device is
        armeabi-v7a. Mob's BEAM/erts runtime is built for arm64-v8a
        and x86_64 (emulator) only. 32-bit Android (armeabi-v7a) is
        not built — the OTP runtime tarballs in mob_dev's GitHub
        releases don't have an armv7 slice.
      - pythonx requires android arm64-v8a or x86_64; this device is
        armeabi-v7a. Pythonx on Android bundles Chaquopy's prebuilt
        CPython distribution. Chaquopy ships arm64-v8a and x86_64
        only — they dropped armeabi-v7a (32-bit ARM) several releases
        back. Apps that target Pythonx cannot run on 32-bit Android
        phones, regardless of OS version.

  See guides/support_matrix.md for the per-feature device floor, or
  pick a different device with --device <id>.
```

Every reason names the upstream-vendor cause. Users with old hardware
deserve to know it's not us being cute with scope — it's that
Chaquopy/BeeWare/Apple have already drawn the line, and Mob is being
honest about which side of it the device sits on.

---

## Adding a feature with new requirements

Three places to keep in sync:

1. **`MobDev.SupportMatrix.feature_requirements/1`** — add a clause
   returning the platform-specific ABI/SDK constraints. Include a
   `:reason` string that names the upstream vendor whose constraint
   you're inheriting. The reason is what the user reads; make it
   honest, not generic.

2. **`MobDev.SupportMatrix.enabled_features/1`** — add a detection
   function that returns `true` when *this* project actually uses the
   feature. We infer from project artifacts (deps, generated files),
   not from a flag — so a user can't bypass validation by forgetting
   an option.

3. **This guide** — add a row to "Per-feature additions" so the
   constraint is documented alongside everything else, not buried in
   code.

Tests live in `test/mob_dev/support_matrix_test.exs`. Cover at minimum:
the happy path on a supported device, the failure path with the
expected upstream-vendor citation in the message, and the "discovery
didn't fill in abi/sdk" case (which should pass-through silently
rather than false-positive).
