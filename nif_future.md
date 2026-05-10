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
