# nif_future.md — deferred infrastructure that the build-system rebuild can absorb

Notes on things mob ought to handle properly that aren't worth a
point-fix today because the build-system migration
(`build_system_migration.md`) will land the right primitives.

When the build rebuild reaches the relevant phase, refer back here
so we don't re-derive the failure mode.

---

## 1. Application env not delivered to device by `mix mob.deploy`

**Failure mode**: app code that calls `Application.get_env(:my_app, :key)`
at runtime gets `nil` on device because the BEAM-only deploy ships no
`sys.config`. Diagnosis path is awful — every `Application.get_env`
returns whatever the calling code uses as `default`, so behaviour
silently diverges between `iex -S mix` (env populated) and the device
(env empty). We hit this hard with Pigeon: `transport_backend` defaulted
to `Pigeon.Transport.Stub` on every device for weeks because
`config/config.exs` configures it as `Pigeon.Transport.Reticulum` but
that env never reached the device. Symptom looked like "messages don't
deliver" rather than "the wrong transport is loaded."

**Workaround currently in use**: explicit `Application.put_env(...)` in
the app's `on_start/0`. Works, but sidesteps `config/config.exs`
entirely — anything else in there is also stranded.

**What the build rebuild can do**: the Zig-based build can either
- emit a `sys.config` next to the BEAMs at deploy time and ship it as
  a release artefact (the canonical OTP path), or
- inject `Application.put_all_env(...)` calls based on
  `Mix.Project.config()[:config]` content into a generated bootstrap
  module that runs before `<App>.start/0`.

The first is cleanly OTP-aligned; the second is closer to what
`mix mob.deploy` already does and avoids changing the on-device boot
sequence. Pick the OTP-aligned one if the build rebuild is moving
toward releases.

**Detection bonus**: `mix mob.doctor` could also surface a warning
when an app reads env keys that no `Application.put_env` ever sets at
runtime — catches this whole class of bug before deploy.

---

## 2. Bundled Python missing `socket.if_nametoindex`

**Failure mode**: Chaquopy's CPython distribution ships
`socket` without `if_nametoindex` — the libc thunk that Python's
multicast-bind helpers call to translate `wlan0` (string) into the
kernel's interface index (int). Any pure-Python library that binds
multicast on a specific interface hits this and the failure surface
is mystifying:

    [Error] Could not configure the system interface wlan0 …
            module 'socket' has no attribute 'if_nametoindex'
    [Warn]  AutoInterface[Default Interface] could not autoconfigure.
            This interface currently provides no connectivity.

In Pigeon's case Reticulum's `AutoInterface` ended up with zero usable
interfaces, AutoInterface reported "no connectivity," and no announces
left the device. The log says "no connectivity" which suggests Wi-Fi
/ kernel issues, not a missing Python symbol.

**Workaround currently in use**: a 30-line ctypes/libc shim in
`Pigeon.Transport.Reticulum`'s Python bridge, run before
`import RNS` to install `socket.if_nametoindex` from `libc.so`'s
`if_nametoindex(3)`:

    if not hasattr(socket, "if_nametoindex"):
        import ctypes, ctypes.util
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so",
                           use_errno=True)
        libc.if_nametoindex.argtypes = [ctypes.c_char_p]
        libc.if_nametoindex.restype = ctypes.c_uint
        def _shim(ifname):
            name = ifname.encode() if isinstance(ifname, str) else ifname
            idx = libc.if_nametoindex(name)
            if idx == 0:
                err = ctypes.get_errno()
                raise OSError(err, os.strerror(err), ifname)
            return idx
        socket.if_nametoindex = _shim

Every consumer that bundles Python via mob will need this same shim
unless mob installs it once at Python-interpreter init.

**What the build rebuild can do**: when the Pythonx pipeline runs
on Android, drop a `mob_socket_shim.pth` (or equivalent) into
`site-packages/` that runs the shim at interpreter startup. Then any
`import RNS` / mDNS / multicast library Just Works without
per-app patching. iOS likely needs the same shim — verify against
BeeWare's python-apple-support before assuming parity.

**Pythonx upstream alternative**: the shim could equivalently live
in Pythonx's own Android initialization, since Pythonx is what
pulls in Chaquopy. That removes the burden from mob entirely.
Either location works; the bug is in Chaquopy's CPython build, but
patching Chaquopy upstream is a long path.

---

## 3. iOS Python parity (RNS + cffi + cryptography)

**Status**: not present in the current mob iOS bundle. Pigeon's
Reticulum transport works on Android via Chaquopy but stops at
`ModuleNotFoundError: No module named 'RNS'` on iOS because BeeWare's
python-apple-support framework doesn't include the C-extension
dependencies (`cffi`, `cryptography`) that RNS imports.

**What's needed**: cross-compile `cffi` and `cryptography` for
`arm64-apple-ios` and bundle the wheels into `<App>.app/otp/python/
lib/python3.13/site-packages/`. BeeWare's Mobile Forge project does
exactly this — it publishes iOS wheels for both packages. Add a step
to `ios/build_device.sh` (or its Zig successor) that downloads /
builds these wheels and copies them in, plus a codesign pass on every
embedded `.dylib`.

**Estimated cost**: 2–5 day focused spike. Adds ~10–15MB binary size
(cryptography pulls in OpenSSL or Rust crypto routines).

**Long-term alternative**: `reticulum_ex` (pure-Erlang Reticulum
implementation) sidesteps the cross-compile burden entirely on both
platforms but is currently incomplete (Link + Transport layers
haven't landed). Adopting it removes Python from the mesh-comms
critical path.

---

## Cross-cutting note

Items 1 and 2 are both "the device's runtime environment doesn't
match the host's" — config and Python bundle respectively. Both are
the kind of thing the build rebuild can address as part of "what
gets shipped to the device" rather than as point patches in app
code or per-consumer monkey-patches. Worth keeping them in mind as
test cases when the new build pipeline reaches the deploy step.

---

## 4. iOS device build skips `copy_project_python_wheels`  (verified 2026-05-11, **FIXED 2026-05-11 19:10 PT on branch `fix/ios-wheel-copy`** — re-verified end-to-end on iPhone SE 3rd gen)

**Resolution (2026-05-11 evening, branch `fix/ios-wheel-copy`,
commit `78ebf2e` on `deps/mob_dev`)**: `bundle_otp_runtime/4` in
`lib/mob_dev/native_build.ex` now calls a new
`copy_ios_safe_project_python_wheels/1` right after the python rsync
into `<App>.app/otp/python/`. The helper mirrors the Android
`copy_project_python_wheels/1` pattern but filters out wheels that
contain any `.so` extension — today's `priv/python_wheels/` ships
Chaquopy-compatible Android binaries under names like
`_cffi_backend.so` and `_rust.so` (no "android" in the filename), so a
name-based filter misses them. "Has any `.so`" matches the current
reality: pure-Python wheels (rns, lxmf, pyserial, pycparser) land,
Android-only ones get skipped with a `[ios-wheels] skipped` log line.
RNS falls back to its internal crypto provider when `cryptography`
isn't importable, so the pure-Python subset is enough to bring the
Reticulum stack up.

Note: `ios/build_device.sh:179` still nukes
`<OTP_ROOT>/python/Python.framework` and
`<OTP_ROOT>/python/lib/python3.13` on every build — so a
stage-into-the-cache workaround would not survive. Doing the wheel
copy in `bundle_otp_runtime/4` (which runs AFTER the rsync into the
`.app`) sidesteps that.

**Verification (iPhone SE 3rd gen 00008110-001E1C3A34F8401E)**:
- `Pigeon.app/otp/python/lib/python3.13/site-packages/` now contains
  `RNS/`, `LXMF/`, `serial/`, `pycparser/`, `chaquopy/` (metadata-only)
  plus their `*.dist-info/` directories.
- BEAM boot trace (via temporary `Pigeon.App.on_start` file logger):
  `on_start enter` → `backend=Pigeon.Transport.Reticulum` →
  `python init start` → `python init ok` (+124 ms) →
  `transport start (…)` → `transport started ok` (+2.5 s).
- Process stays alive (`xcrun devicectl device info processes`
  shows Pigeon running). Previously exited cleanly at the
  `{:ok, _transport_sup} = …` pattern match.

The historical 2026-05-11 morning + 2026-05-11 17:40 PT notes
below are kept for context.

---

### Earlier note: 2026-05-11 17:40 PT — "did not actually land"

The 2026-05-11 morning note claimed the iOS device path was wired to
`copy_project_python_wheels/1` via `maybe_setup_pythonx_sim/5` /
`maybe_setup_pythonx_device/5`. Re-check on 2026-05-11 17:40 PT showed
neither helper nor either call site existed in `deps/mob_dev` HEAD —
the prior fix attempt didn't land. That's what triggered the current
fix on branch `fix/ios-wheel-copy`.

---

### Earlier note that turned out to be inaccurate

`mob_dev` `lib/mob_dev/native_build.ex` —
`copy_project_python_wheels/1` generalised (param renamed
`assets_root` → `python_root`, docstring covers both platforms) and
wired into both `maybe_setup_pythonx_sim/5` (right after the
lib-dynload `copy_dir!`) and `maybe_setup_pythonx_device/5` (right
after the lib-dynload `cp_r!`). Both call sites pass
`<otp_root>/python` as the root — same `lib/python3.13/site-packages/`
suffix as Android, so the helper works unchanged. **Re-check on
2026-05-11 evening shows neither helper nor either call site exists
in `deps/mob_dev` HEAD; whatever was intended did not land.**

---

### Original report


**Refines item 3 above** — the cryptography cross-compile spike isn't
actually required. RNS gracefully falls back to its internal pure-
Python crypto provider when `cryptography` isn't importable (see
`RNS/Cryptography/Provider.py`), and `lxmf` is pure-Python on top of
RNS. So the wheel set we actually need on iOS is just `rns + lxmf`
(both pure-Python, ~few MB total), plus `pyserial` + `pycparser` if
any project uses them.

**The gap**: Android's `copy_python_assets/1` already does
`copy_project_python_wheels(assets_root)` after dropping stdlib +
lib-dynload into the APK. iOS *simulator's* `ios/build.sh` (the
project-local one mob_dev does NOT regenerate) was patched in the
Pigeon session to do the same into `<otp_root>/python/lib/python3.13/
site-packages/`. iOS *device's* auto-generated `build_device.sh`
(produced by `MobDev.NativeBuild.generate_build_device_sh/2`) bundles
Python.framework + stdlib + lib-dynload but never copies
`priv/python_wheels/*` in. Result: device boots, hits `import RNS`,
crashes with `ModuleNotFoundError: No module named 'RNS'`, app
appears stuck on the launch spinner.

**Workaround for manual dev cycles**: after a build, find the staged
`Pigeon.app` (under `$TMPDIR/mob_ios_device_*`), copy
`priv/python_wheels/{rns,lxmf,pyserial,pycparser}/.` into
`Pigeon.app/otp/python/lib/python3.13/site-packages/`, re-sign with
the in-build `mob_device.entitlements` file, then `xcrun devicectl
device install app`. Verified working on iPhone SE 3rd gen
(00008110-001E1C3A34F8401E) on 2026-05-11.

**What the build rebuild should do**: add a wheel-copy step to the
iOS device path mirroring Android's. The cleanest spot is right
after the `cp -R "$PYTHON_LIB_DYNLOAD" "$OTP_ROOT/python/lib/
python3.13/lib-dynload"` line in the build_device.sh template (or
its Zig successor — `ios/build_device.zig` is where this naturally
lives after Phase 2 iter 12). Same shape as Android, same wheel
source (`priv/python_wheels/<wheel>/`), same destination layout
(`<otp_bundle>/python/lib/python3.13/site-packages/<wheel-contents>`).

---

## 5. iOS device default relay host  (verified 2026-05-11)

**Symptom**: Pigeon (or any mob app using a Mac-based dev relay) on
physical iOS gets `[Errno 61] Connection refused` for the relay
TCPInterface. `127.0.0.1` resolves to the *phone's* loopback, not the
developer's Mac — different from the iOS simulator (which shares the
host network stack via XPC) and Android emulator (which has the
`10.0.2.2` host-loopback alias).

**Where the bad default came from**: `Pigeon.App.on_start/0`
hard-codes a platform-aware default of `127.0.0.1` for iOS and
`10.0.2.2` for Android via `Pigeon.PythonPaths.detect/1`. Both are
*simulator/emulator* defaults; neither works on real hardware.

**Workaround for now**: rely on AutoInterface multicast over LAN
(verified working — iPhone SE 3rd gen reached the bridge via shared
Wi-Fi). Set `PIGEON_RELAY_HOST` to the Mac's actual LAN IP when
explicit relay routing is needed.

**What's needed**: detect "physical device" vs "simulator/emulator"
at build time (or compute the Mac's LAN IP and stamp it into the
build env) so the in-app default is right by default. The detection
is already in `Pigeon.PythonPaths.detect/1` (returns `:ios` for
both sim and device today — that's the bug); split into `:ios_sim`
vs `:ios_device` or surface the Mac's LAN IP via a build-time env
var the way `MOB_IOS_TEAM_ID` etc. flow today.

Both items 4 and 5 are small mob_dev template changes. Either land
them as point fixes in build_device.sh / build_device.zig templates,
or fold them into Phase 2 iter 12d's bundle-assembly + provisioning
move into Mix proper.
