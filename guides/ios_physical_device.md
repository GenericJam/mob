# iOS Physical Device — Build & Deployment Guide

Physical iOS devices are fundamentally different from the simulator in ways that
are not obvious and will waste days if you don't know about them. This document
covers the happy path and every significant pitfall encountered when getting the
BEAM running on a real iPhone for the first time.

---

## Why the simulator is not a useful proxy

The iOS simulator runs on macOS. The app process is a macOS process. This means:

- `/tmp` is the Mac's `/tmp` — shared between the simulator and the host. OTP
  can live at a fixed path like `/tmp/otp-ios-sim` and be found at runtime.
- The network stack is the Mac's network stack. EPMD running on the Mac is
  reachable from the simulator on `localhost:4369`.
- `dlopen` works normally. `.so` NIFs load without restriction.
- Memory limits are the Mac's limits. The BEAM's default 1 GB virtual super
  carrier reservation succeeds.
- Executables in the bundle can be `exec`'d without restriction.

**None of these are true on a physical device.** Each point is a separate crash
that gives no obvious error.

---

## Happy path

### 1. Build OTP from source for `arm64-apple-ios`

```bash
cd /tmp/otp_ios_device_build
git clone https://github.com/erlang/otp.git
cd otp
git checkout OTP-28.1

./otp_build autoconf
./configure \
  --host=aarch64-apple-ios \
  --build=arm64-apple-darwin \
  --with-ssl=no \
  --disable-jit \
  --disable-esock \
  --without-asn1 \
  --without-runtime_tools \
  --without-os_mon \
  CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 \
      -isysroot $(xcrun -sdk iphoneos --show-sdk-path)"

make -j$(sysctl -n hw.ncpu)
```

Critical flags and why:
- `--disable-jit` — iOS enforces W^X (write xor execute). The JIT allocates
  writable+executable memory, which is rejected by the kernel on real hardware.
  The simulator's macOS process has no such restriction.
- `--disable-esock` — `net/if_arp.h` is missing from the iOS SDK; configure
  fails without this.
- `--without-asn1 --without-runtime_tools --without-os_mon` — these OTP
  applications contain NIFs that reference ERTS symbols not exported from a
  static `libbeam.a`. The linker cannot resolve them.

### 2. Assemble the OTP cache

Collect static libs from the build tree into a cache directory:

```
cache/otp-ios-device-<hash>/
  erts-16.1/
    include/          ← copy from build: erts/include/ + erts/aarch64-apple-ios/
    lib/
      libbeam.a            ← from bin/aarch64-apple-ios/
      libepcre.a           ← from erts/emulator/pcre/obj/aarch64-apple-ios/opt/
      libryu.a             ← from erts/emulator/ryu/obj/aarch64-apple-ios/opt/
      libzstd.a
      asn1rt_nif.a         ← built separately (see pitfalls)
      internal/
        liberts_internal_r.a
        libethread.a
  lib/                ← OTP applications (kernel, stdlib, elixir, logger, etc.)
  releases/           ← boot scripts
```

### 3. Bundle OTP inside the `.app`

On the simulator, `/tmp` is shared with the Mac so OTP can live at a fixed path.
On the device, `/tmp` is the app's sandbox — empty on every install. OTP must be
bundled inside the `.app` and the path resolved at runtime:

```objc
#ifdef MOB_BUNDLE_OTP
NSString *bundle_otp = [[[NSBundle mainBundle] bundlePath]
                         stringByAppendingPathComponent:@"otp"];
const char *otp_root = [bundle_otp UTF8String];
#endif
```

Bundle the OTP tree at `.app/otp/` using `rsync` during the build:

```bash
OTP_BUNDLE="$APP/otp"
rsync -a --delete "$OTP_ROOT/lib/"      "$OTP_BUNDLE/lib/"
rsync -a --delete "$OTP_ROOT/releases/" "$OTP_BUNDLE/releases/"
rsync -a --delete "$OTP_ROOT/mob_qa/"   "$OTP_BUNDLE/mob_qa/"
mkdir -p "$OTP_BUNDLE/$ERTS_VSN/bin"    # BINDIR must exist (even if empty)
```

Compile `mob_beam.m` with `-DMOB_BUNDLE_OTP -DERTS_VSN=\"erts-16.1\" -DOTP_RELEASE=\"28\"`.

### 4. Cap the BEAM memory super carrier

The BEAM reserves a 1 GB virtual address range for its memory super carrier by
default. macOS grants this without complaint. iOS on real hardware rejects it and
the process is killed silently before any Elixir code runs. Add `-MIscs 10` to
the `erl_start` args to cap it at 10 MB:

```c
#ifdef MOB_BUNDLE_OTP
"-MIscs", "10",
#endif
```

### 5. Run EPMD as an in-process thread

Erlang distribution requires EPMD listening on port 4369 before `erl_start`.
On the simulator this works because the Mac's EPMD is already running and
reachable via the shared network stack. On the device, there is no EPMD.

The fix: compile the EPMD sources directly into the app binary and start them
on a `pthread` before calling `erl_start`:

```bash
# In build_device.sh — compile EPMD with renamed main()
OTP_BUILD_SRC="/path/to/otp_build"
EPMD_SRC="$OTP_BUILD_SRC/erts/epmd/src"

xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 \
    -DHAVE_CONFIG_H -DEPMD_PORT_NO=4369 -Dmain=epmd_ios_main \
    -I "$OTP_BUILD_SRC/erts/aarch64-apple-ios" \
    -I "$EPMD_SRC" \
    -I "$OTP_BUILD_SRC/erts/include" \
    -I "$OTP_BUILD_SRC/erts/include/internal" \
    -c "$EPMD_SRC/epmd.c"     -o epmd_main.o
# repeat for epmd_srv.c and epmd_cli.c
```

```objc
// mob_beam.m
#ifdef MOB_BUNDLE_OTP
extern int epmd_ios_main(int argc, char **argv);
static void* epmd_thread(void *arg) {
    char *args[] = {"epmd", NULL};
    epmd_ios_main(1, args);   // event loop; does not return
    return NULL;
}
#endif

// ... before erl_start() ...
#ifdef MOB_BUNDLE_OTP
pthread_t epmd_t;
pthread_create(&epmd_t, NULL, epmd_thread, NULL);
pthread_detach(epmd_t);
usleep(300000);  // give EPMD 300ms to bind port 4369
#endif
```

Do **not** pass `-daemon` to `epmd_ios_main`. The daemon path calls `fork()`,
which is not permitted in iOS sandboxed apps.

### 6. Register third-party NIFs in the static NIF table

iOS cannot `dlopen` `.so` NIFs. All NIFs must be statically linked into the
binary and registered in `driver_tab_ios.c` (which overrides ERTS's
`erts_static_nif_tab` by being linked before `libbeam.a`).

For exqlite's `sqlite3_nif`:

```bash
# Compile with STATIC_ERLANG_NIF_LIBNAME to get a predictable init symbol
$CC ... \
    -DSTATIC_ERLANG_NIF_LIBNAME=sqlite3_nif \
    -c deps/exqlite/c_src/sqlite3_nif.c -o sqlite3_nif.o
```

This produces `sqlite3_nif_nif_init` instead of `nif_init`. Register it:

```c
// driver_tab_ios.c
void *sqlite3_nif_nif_init(void);

ErtsStaticNif erts_static_nif_tab[] = {
    // ... existing entries ...
    {sqlite3_nif_nif_init, 0, THE_NON_VALUE, NULL},
    {NULL,                 0, THE_NON_VALUE, NULL}
};
```

---

## Erlang Distribution

The BEAM on a physical device supports full Erlang distribution — `mix mob.connect`,
`Mob.Test.*`, hot code push, and direct IEx RPC all work the same as on the simulator.

The node name is determined at startup. A launch that sets `MOB_NODE_HOST` to one of
the device's own IPv4 addresses gets that address (see below); otherwise the device's
network interfaces are walked in priority order:

| Priority | Connection | Node name | Requires |
|----------|------------|-----------|----------|
| 1 | WiFi / LAN | `<app>_ios@10.0.0.x` | Same network as Mac |
| 1 | Tailscale | `<app>_ios@100.x.x.x` | Tailscale running on both devices |
| 1 | Personal Hotspot | `<app>_ios@172.20.10.1` | Mac connected to iPhone's hotspot |
| 2 | USB cable only | `<app>_ios@169.254.x.x` | Cable plugged in, no WiFi |
| 3 | None | `<app>_ios@127.0.0.1` | No network — unreachable without iproxy |

> **WiFi is checked before USB.** This is the opposite of what you might expect.
> The reason: if the node started with a USB link-local address and you later unplug
> the cable, the Mac can no longer reach that address and distribution dies. With WiFi
> taking priority, the node IP stays stable whether the cable is in or out.
>
> If both WiFi and USB are connected when the app launches, the node will use the
> WiFi IP. Plugging in USB afterwards does not change it.
>
> **USB only (no WiFi):** the node falls back to the link-local address and
> `mix mob.connect` finds it the same way — no difference in that workflow.
>
> **`mix mob.connect` names the host itself (mob 0.9.16 + mob_dev 0.7.18).** When it
> relaunches the app it passes `MOB_NODE_HOST` (as `DEVICECTL_CHILD_MOB_NODE_HOST`)
> set to the address it reaches the phone at, and waits for exactly that node. Over
> USB that is usually the link-local `169.254.x.x` address, so a phone whose WiFi is
> on a network the Mac can't route to is still reachable; the trade is that a node
> launched this way is stranded if the cable is pulled — run `mix mob.connect` again.
> An address the phone doesn't hold is ignored.

### The node name is still fixed at app launch

The BEAM picks an IP once, at startup, and does not change it while running.
Connecting or disconnecting WiFi after launch has no effect. The improvement is
that WiFi is now chosen over USB at launch time, so the node survives USB
reconnects without needing a restart.

**If distribution isn't working:** force-quit the app and relaunch it so it picks
up the current network state. `mix mob.connect` will find it automatically.

### USB (recommended for development)

Plug in the cable. No configuration needed.

```bash
mix mob.connect
```

The iPhone presents a USB networking interface on the Mac (typically `en11`) with a
`169.254.x.x` link-local address. The device's in-process EPMD and dist port both bind
`0.0.0.0`, so the Mac can reach them directly at that address.

### WiFi

Works automatically when Mac and iPhone are on the same network — no cable, no setup.

```bash
mix mob.connect
```

If it doesn't connect, check: was the app last launched with USB plugged in? If so,
force-quit and relaunch the app on the iPhone (without USB), then run `mix mob.connect`
again.

**Limitation:** public WiFi (coffee shops, hotels, conferences) and many corporate
networks enable client isolation, which blocks device-to-device traffic. If the device
isn't found, use USB or Tailscale.

### Tailscale (any network, including cellular)

[Tailscale](https://tailscale.com) is a mesh VPN built on WireGuard. Once installed,
devices on the same Tailscale account can reach each other on any network — same WiFi,
different WiFi, cellular, corporate network. It's free for personal use.

**Setup (one time):**

1. Install the Tailscale app on your Mac and iPhone.
2. Sign in to the same Tailscale account on both.
3. On the iPhone: open the Tailscale app and enable the VPN.

**Usage:**

```bash
mix mob.connect   # works the same — no change to the workflow
```

The BEAM detects the Tailscale interface (`100.x.x.x`) at startup and registers the
node there. The Mac reaches it directly over the WireGuard tunnel — Tailscale's servers
are only involved in the initial connection handshake.

**Important:** Tailscale must be active on the iPhone *before* the app launches.
The node name is fixed at BEAM startup. If you enable Tailscale after the app is
already running, restart the app.

### Personal Hotspot

Connect the Mac to the iPhone's Personal Hotspot (Settings → Personal Hotspot).
The iPhone's hotspot address (`172.20.10.1`) is detected automatically — no setup beyond
connecting the Mac to the hotspot WiFi.

### Finding the node name manually

If you're unsure what address the BEAM registered under, query the device's EPMD
directly (USB must be connected):

```bash
# Substitute your device's link-local IP (shown in ifconfig as 169.254.x.x on en11)
elixir -e "
{:ok, s} = :gen_tcp.connect({169, 254, 235, 134}, 4369, [:binary, active: false], 3000)
:gen_tcp.send(s, <<0, 1, ?n>>)
{:ok, <<_port::32, names::binary>>} = :gen_tcp.recv(s, 0, 3000)
:gen_tcp.close(s)
IO.puts(names)
"
# → name smoke_test_ios at port 9101
```

---

## Pitfalls

### "No provider was found" from devicectl

Benign. `xcrun devicectl` always prints this warning when the provisioning
profile database lookup fails, even when the command succeeds. Ignore it;
check the exit code and the "App installed" line instead.

### Bundle ID with underscores rejected

`com.mob.mob_qa` is rejected when creating provisioning profiles (Xcode
generates an invalid scheme name like `XC com mob mob_qa`). Use only dots and
alphanumeric characters: `com.mob.mobqa`.

### No crash log after silent crash

The BEAM crashing inside `erl_start` before signal handlers are registered
produces no entry in the system crash logs and no `ERL_CRASH_DUMP`. The app
simply vanishes. To diagnose: redirect `stdout`/`stderr` to a file in Documents
before calling `erl_start`, and add sentinel files at key points:

```c
int fd = open("/path/to/Documents/beam_stdout.log", O_WRONLY|O_CREAT|O_TRUNC, 0644);
dup2(fd, STDOUT_FILENO);
dup2(fd, STDERR_FILENO);
close(fd);
```

Use `xcrun devicectl device copy from ... --domain-type appDataContainer` to
pull Documents off the device without needing Xcode.

### `system()` unavailable on iOS

OTP's `erlexec.c` and `heart.c` call `system()`, which does not exist on iOS.
The linker will fail or the binary will crash. Patch both files with:

```c
#if !(defined(__APPLE__) && defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE)
    // original system() call
#endif
```

### `asn1rt_nif.a` must use `STATIC_ERLANG_NIF`

If `asn1rt_nif.c` is compiled without `-DSTATIC_ERLANG_NIF`, it exports
`nif_init` instead of `asn1rt_nif_nif_init`. The linker will include the object
but the symbol won't be found by `driver_tab_ios.c`'s declaration. Rebuild with
the flag.

### `libmicro_openssl.a` (historical — no longer needed)

Earlier setups linked against `libmicro_openssl.a` to satisfy `MD5Init`/
`MD5Update`/`MD5Final` symbols. With `--without-ssl` OTP, nothing in the
linked code path references them — `libbeam.a`'s own `erts_md5_*` covers
everything that does get called. The lib is dropped from the LIBS list
entirely; do not re-add it.

### dlopen of `.so` NIFs silently fails at runtime

On the device, `dlopen` for a `.so` NIF does not crash the BEAM immediately. It
logs a warning (`The on_load function for module X returned: {:error, :load_failed}`)
and the connection pool start-up fails later with a seemingly unrelated error.
If you see `UndefinedFunctionError` from `Exqlite.Sqlite3NIF.open/2`, the NIF
was never loaded — the `.so` does not exist and the static registration is
missing.

### EPMD error: `Protocol 'inet_tcp': register/listen error: econnrefused`

This is logged to BEAM stdout (captured in `beam_stdout.log` if you redirect
it). It means `erl_start` found no EPMD on port 4369. On the device the Mac's
EPMD is not reachable. Fix: in-process EPMD thread (see step 5 above).

### OTP bundle size / watchdog timeout

The default OTP `lib/` includes 67 MB of `lib/erlang/` (duplicated under a
different path) and dozens of unused applications. Strip aggressively before
bundling:

- Remove `lib/erlang/` (it's a duplicate of the top-level layout)
- Remove unused OTP apps: `common_test`, `diameter`, `edoc`, `erl_interface`,
  `eunit`, `inets`, `mnesia`, `parsetools`, `public_key`, `reltool`,
  `syntax_tools`, `tools`, `xmerl`

Target: `lib/` under 40 MB, total `.app/otp/` bundle under 50 MB.

### ERTS version vs OTP release version

OTP-28.1 installs as `erts-16.1`, not `erts-16.3` (which is OTP-28.3). The
`OTP_RELEASE` passed to `-boot` must match the actual release number. Always
auto-detect:

```bash
ERTS_VSN=$(ls "$OTP_ROOT" | grep '^erts-' | sort -V | tail -1)
```

And pass matching compile-time defines:
```bash
-DERTS_VSN=\"erts-16.1\" -DOTP_RELEASE=\"28\"
```

### `BINDIR` must exist even though binaries can't run

The BEAM reads the `BINDIR` environment variable and checks the directory
exists. Even though no binary in it can be exec'd on iOS, the directory itself
must be present or the BEAM aborts early. Create it:

```bash
mkdir -p "$OTP_BUNDLE/$ERTS_VSN/bin"
```

### Root-level OTP assets not bundled

The bundle step copies `lib/`, `releases/`, and the app BEAM directory — but
not root-level files sitting directly in `$OTP_ROOT`. If your Elixir code
references assets via `System.get_env("ROOTDIR")` (e.g. logo images), those
files must be explicitly copied into the `.app/otp/` root during bundling:

```bash
for f in "$OTP_ROOT"/*.png "$OTP_ROOT"/*.jpg; do
    [ -f "$f" ] && cp "$f" "$OTP_BUNDLE/"
done
```

On the simulator `ROOTDIR` points to the Mac's `/tmp/otp-ios-sim` which is
writable and populated by the deployer, so assets are always there. On the
device they must be in the bundle.

### Crash dump is written to Documents, not /tmp

On the device, `/tmp` is the app's sandbox temporary directory and is cleared
on each install. Set `ERL_CRASH_DUMP` to a path inside Documents:

```c
snprintf(crash_dump, sizeof(crash_dump), "%s/mob_erl_crash.dump", docs_dir);
setenv("ERL_CRASH_DUMP", crash_dump, 1);
```

---

## Checking the device after a crash

Pull Documents off the device (no Xcode needed):

```bash
xcrun devicectl device copy from \
  --device <DEVICE_UUID> \
  --domain-type appDataContainer \
  --domain-identifier com.mob.mobqa \
  --source Documents \
  --destination /tmp/mobqa_docs
```

List files on device without pulling:

```bash
xcrun devicectl device info files \
  --device <DEVICE_UUID> \
  --domain-type appDataContainer \
  --domain-identifier com.mob.mobqa
```

System crash logs (Jetsam events, signal crashes):

```bash
xcrun devicectl device info files \
  --device <DEVICE_UUID> \
  --domain-type systemCrashLogs
```
