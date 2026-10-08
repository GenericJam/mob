# Troubleshooting

## Start here: mix mob.doctor

Before diving into specific issues, run:

```bash
mix mob.doctor
```

This checks your entire environment in one go — required tools, `mob.exs`
configuration, OTP runtime caches, and connected devices — and prints specific
fix instructions for anything wrong. Most setup problems are caught here.

```
=== Mob Doctor ===

Tools
  ✓ adb — /usr/bin/adb
  ✗ xcrun — not found
      Install Xcode command-line tools:
      xcode-select --install

Project
  ✗ mob_dir — path not found: /Users/you/old/path/to/mob
      Update mob.exs — the path must exist on this machine

OTP Cache
  ✗ OTP iOS simulator — directory exists but contains no erts-* — extraction was incomplete
      Remove the stale directory and re-download:
      rm -rf ~/.mob/cache/otp-ios-sim-73ba6e0f
      mix mob.install

Devices
  ⚠ Android devices — none connected
      Connect a device via USB (enable USB debugging) or start an emulator

3 failures — fix the issues above and re-run mix mob.doctor.
```

The sections below cover issues that `mix mob.doctor` doesn't catch — runtime
behaviour, distribution quirks, and platform-specific edge cases.

---

Common issues encountered during development and how to resolve them.

## Elixir or Hex version too old

**Symptom:** `mix deps.get` or `mix mob.install` fails with errors like
`no matching version found`, `invalid requirement`, or dependency resolution
failures that look unrelated to your code.

**Cause:** Mob requires Elixir 1.18 or later. Older versions of Hex (pre-2.0)
also have issues resolving some package requirements used by `mob_dev`.

**Check:**

```bash
mix mob.doctor   # shows Elixir, OTP, and Hex versions with ✓/✗
elixir --version
mix hex --version
```

**Fix — Hex** (fast, no version manager needed):

```bash
mix local.hex --force
```

**Fix — Elixir** (choose the method that matches how you installed it):

```bash
# mise
mise install elixir@latest && mise use elixir@latest

# asdf
asdf install elixir latest && asdf global elixir latest

# Homebrew
brew upgrade elixir

# Nix / nix-shell: update your shell.nix or flake.nix to use elixir_1_18

# Official installer: https://elixir-lang.org/install.html
```

After upgrading, re-fetch deps:

```bash
mix deps.get
mix mob.doctor   # confirm versions are green
```

---

## OTP cache: "No erts-* directory found"

**Symptom:** `mix mob.deploy --native` fails with:

```
ERROR: No erts-* directory found in ~/.mob/cache/otp-ios-sim-73ba6e0f
       Have you built OTP for iOS simulator?
```

**Cause:** The OTP cache directory was created during a previous download attempt
that failed partway through (network error, SSL failure, or curl exiting non-zero).
Because the directory exists, subsequent runs skip re-downloading, so the problem
persists across restarts.

This is particularly common on **Nix-managed macOS** setups, where Nix provides
its own `curl` binary that uses a different CA certificate store than macOS system
curl. The GitHub release download may fail with an SSL certificate error that isn't
surfaced clearly.

**Fix:**

```bash
mix mob.doctor   # confirms the problem and shows the exact path

rm -rf ~/.mob/cache/otp-ios-sim-73ba6e0f   # remove stale cache
mix mob.install                             # re-download
```

If the download fails again (Nix curl SSL), download the tarball manually using
the system curl:

```bash
/usr/bin/curl -L https://github.com/GenericJam/mob/releases/download/otp-73ba6e0f/otp-ios-sim-73ba6e0f.tar.gz \
  -o /tmp/otp-ios-sim.tar.gz

mkdir -p ~/.mob/cache/otp-ios-sim-73ba6e0f
tar xzf /tmp/otp-ios-sim.tar.gz -C ~/.mob/cache/otp-ios-sim-73ba6e0f --strip-components=1
```

Verify it worked:

```bash
ls ~/.mob/cache/otp-ios-sim-73ba6e0f/erts-*   # should list erts-16.x
mix mob.doctor                                  # should show ✓ for iOS simulator OTP
```

---

## EPMD port conflict with adb (port 4369)

**Symptom:** App crashes on launch, Erlang distribution fails to start, or
`mix mob.connect` hangs indefinitely. Often surfaces as a silent failure with
no obvious error message — the node never comes online.

**Cause:** EPMD (Erlang Port Mapper Daemon) is registered with IANA on port
4369. The Android Debug Bridge also uses port 4369 in certain configurations.
When both are active on the same machine, EPMD fails to bind and Erlang
distribution cannot start — which means the device BEAM can't register itself
and `mix mob.connect` can never find it.

**Fix:** Move EPMD to a port nothing else uses. Port 4380 is a safe choice.
Set `ERL_EPMD_PORT` in both the device BEAM startup and your local dev
environment.

In `mob.exs`:

```elixir
config :mob_dev, epmd_port: 4380
```

In your app's `application.ex`, pass the port when starting distribution:

```elixir
Mob.Dist.ensure_started(
  node:      :"my_app_android@127.0.0.1",
  epmd_port: Application.get_env(:mob_dev, :epmd_port, 4369)
)
```

`mob_dev` will update the `adb reverse` tunnel to use the configured port
automatically.

**Why 4369 conflicts:** EPMD's port 4369 dates from 1993 (predating Android by
15 years). The collision is coincidental and there is no Erlang inside the
Android toolchain. Moving off the default port also has a secondary benefit:
Mob's device nodes become isolated from any other Elixir processes running on
your Mac.

---

## iOS simulator: BEAM dies silently on a dist port collision

**Symptom (before MOB-139):** the sim never reaches the app — it stays on the
home screen or shows the launcher spinner for a few hundred ms before the app
process exits. `mix mob.connect` may briefly see the node and then lose it.
There is no crash report. `Documents/beam_stdout.log` inside the sim's app
container shows:

```
Protocol 'inet_tcp': register/listen error: eaddrinuse
```

**Cause:** iOS simulators share the Mac's network stack, so a simulator app's
dist port competes with every other listener on `127.0.0.1`: other simulator
apps and `adb forward` tunnels for Android devices. Without `MOB_DIST_PORT`
(icon tap, `xcrun simctl launch`, agent-device relaunch) every simulator app
used to listen on 9101, so the second one launched that way failed to bind,
and the boot script exited, taking the app process with it.

**Now:** a launch without `MOB_DIST_PORT` takes the first free port from the
one mob_dev would assign (`9100 + crc32("<app>@<udid>") rem 800`). A pinned
port that is taken (`mix mob.deploy --dist-port N`, or
`SIMCTL_CHILD_MOB_DIST_PORT=N`) is not handed to the BEAM: the app stays on
the startup error screen with "Distribution can't start: port N
(MOB_DIST_PORT) is already in use", and the system log carries the same line
as `[MobBeam] ERROR: …`.

**Fix:** find the holder and either stop it or pick another port:

```bash
lsof -nP -iTCP:N -sTCP:LISTEN
epmd -names
mix mob.deploy --device <ios-sim-udid> --dist-port <free port>
```

`mix mob.deploy` and `mix mob.connect` already skip ports registered in EPMD
and other devices' adb forwards; a collision there means a listener neither
of those shows.

---

## A screen feels slow: measuring the render pipeline

Before changing anything, measure. `Mob.RenderStats` records where a frame's
time actually goes, and it is off by default because it is not free.

Enable it from a connected node (`mix mob.connect`), drive the app, then read
the summary:

```elixir
Mob.RenderStats.enable()
# ... drive the app ...
Mob.RenderStats.summary()
```

`summary/0` reports p50, p95 and max per stage, with the sample size `n`
alongside, because stages do not share a population. `frames/0` returns the raw
records, newest first, when a percentile hides what you are looking for.

### What the stages mean

| stage | what it covers |
|---|---|
| `render_us` | your `render/1` |
| `expand_us` | `Mob.Composite`, `Mob.List` and `Mob.Component` expansion |
| `reconcile_us` | the component reconcile pass |
| `prepare_us` | the renderer's tree walk: prop resolution, theme tokens, one `register_tap` per handler prop |
| `register_tap_us` | the `register_tap` calls alone — **nested inside `prepare_us`**, so adding the two double-counts |
| `encode_us` | `:json.encode` |
| `set_root_us` | handing the tree to native |

A frame spans two processes: the screen runs `render/1`, expansion and
reconcile, then hands off to `Mob.Sender`, which runs prepare, encode and
`set_root`. Frames the sender drops — superseded by a newer tree, or belonging
to a screen that is no longer active — are recorded with `committed: false`
rather than discarded, because BEAM-side work that gets thrown away is worth
knowing about. `summary/0` reports the two populations separately for that
reason.

Do not compare `total_us` against a frame budget. See the moduledoc for why.

### The native half

`set_root_us` closes when the tree reaches the main thread, **not** when it is
on screen. Everything the platform then does to build, lay out and display it
happens after that measurement closed, and on a navigation that is usually the
larger half of the frame.

```elixir
Mob.RenderStats.native_enable()
# ... drive the app ...
Mob.RenderStats.native_summary()
```

`native_summary/0` groups by transition, because a `"none"` sample re-renders
into an existing view tree while `"push"`, `"pop"` and `"reset"` rebuild it. On
a small screen the two differ by several milliseconds, and pooling them gives a
median that describes neither.

Read `apply_us` as an **upper bound** on that frame's native cost, not an
attribution: it is main-thread busy time from the tree being applied to the run
loop going idle, so anything else queued on the main thread in that window is
inside the number.

`dropped` tells you how many samples scrolled out of the fixed-size native ring
buffer. When it is above zero, the percentiles describe the tail of your run
rather than all of it.

**Availability.** iOS debug builds only. It returns `{:error, :unsupported}` on
Android, on the host, and in an iOS **release** build, because the reading NIFs
sit inside the same guard as the rest of the test harness. Profile a debug
build.

### Cost when enabled

`time/2` reads a `:persistent_term`; `accumulate/2` reads the process
dictionary. Neither allocates when disabled. The honest cost when enabled is
dominated by `accumulate/2`, which wraps every `register_tap` call — 615 times
on a 200-row screen, not once per frame. Measured at roughly 4 µs per dense
frame on a development Mac and plausibly 20-40 µs on a phone. Against a 27 ms
frame that is under 0.2%, but it is not nothing, which is why it is opt-in.

## Distribution in production

In development, `Mob.Dist.ensure_started/1` runs so `mix mob.connect` can
reach the app. In production the picture is different but not simply "turn it
off" — it depends on whether you want OTA BEAM updates.

**No OTA updates:** gate distribution on environment and leave it off in prod.
`Mob.Dist.ensure_started/1` is a no-op unless explicitly called, so production
builds are safe by default:

```elixir
# lib/my_app/application.ex
if Application.get_env(:my_app, :env) == :dev do
  Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1")
end
```

Development nodes are protected by a private per-app cookie that `mob_dev`
generates and hands to the app at deploy/connect time (Android: a file in the
app's private storage; iOS: the launch environment). Don't embed a cookie in
application source; `:mob_secret`, which generated apps used to pass, is public
and ignored.

**With OTA BEAM updates:** distribution needs to be live, but only during the
update session. The recommended pattern is on-demand: the app polls your server
over HTTP for an update manifest, starts EPMD + distribution only when an
update is available, connects to your update server's BEAM node to receive new
BEAMs via `:code.load_binary`, then shuts distribution back down. Because the
phone initiates the outbound connection, no inbound ports need to be open and
the cookie can be rotated per session via the manifest.

**Your own distribution transport (e.g. TLS):** `-proto_dist`,
`-ssl_dist_optfile` and similar flags are Erlang init arguments, which
`mob_beam_flags` (emulator flags, written only by `mix mob.deploy`) can't
carry. Write them from the app with `Mob.InitArgs.write/1`; the launcher
passes them at the next launch, in release builds too. On Android still start
distribution at runtime; on iOS an init argument list with `-name`/`-sname`
replaces mob's own dist flags. Details in `Mob.Dist` and `Mob.InitArgs`.

---

## `mix mob.connect` finds no nodes

**Check in order:**

1. **Is the app running on the device?**
   ```bash
   mix mob.devices   # confirms device is visible to adb / xcrun
   ```

2. **Did distribution start on the device?**
   Check the device log for `[mob] distribution started` — if absent, the
   `Mob.Dist.ensure_started/1` call either wasn't reached or failed silently
   (often due to the EPMD port conflict above).

3. **Do cookies match?**
   `mix mob.connect` manages the app's private cookie automatically, and
   `mix mob.deploy` writes it next to the app's BEAMs (`mob_dist_cookie`), so a
   relaunch from the home screen or `xcrun simctl launch` keeps it. An app
   with no valid cookie file runs with a random cookie: an iOS app built from
   Xcode or last deployed by mob_dev 0.7.7 or older, a physical iPhone only
   hot-loaded since a mob_dev 0.7.7 deploy (deploy once with `--native`), or
   an Android app no `mix mob.deploy` / `mix mob.connect` has written a cookie
   for yet.
   Let `mix mob.connect` restart it. On iOS the system log says which cookie
   the app used (`[MobBeam] dist cookie: …`). A custom cookie in your app's
   `Mob.Dist.ensure_started/1` call must be passed as `--cookie`.

4. **iOS: is the simulator booted?**
   ```bash
   xcrun simctl list devices | grep Booted
   ```

5. **Android: are the adb tunnels up?**
   ```bash
   adb reverse --list   # should show tcp:4369 tcp:4369 (or your custom port)
   adb forward --list   # should show tcp:9100 tcp:9100
   ```
   If missing, re-run `mix mob.connect` — it sets these up automatically on
   each run.

---

## Hot-push succeeds but changes don't appear

`nl(MyApp.SomeScreen)` returns `{:ok, [...]}` but the running screen still
shows old behaviour.

**Cause:** The screen process is still executing the old version of the module.
Hot code loading in the BEAM takes effect on the *next function call* — if the
screen is in the middle of a `handle_event/3` or `handle_info/2` call, it
finishes with the old code first.

**Fix:** Trigger any event on the screen (a tap, a `Mob.Test.tap/2`) to force
the process to make a new function call, picking up the new code. For layout
changes, navigate away and back so `render/1` is called fresh.

If you need a guaranteed clean reload, use `mix mob.deploy` (restarts the app)
rather than hot-push.

---

## Path-dependency mob: on-device `mob_nif:log` undef / stale beams

**Symptom:** You depend on mob as a local **path dependency**
(`{:mob, path: "../mob", override: true}`) to test an unreleased framework
change on a device. The app crash-loops at boot — logcat shows the bootstrap's
first `mob_nif:log/1` (or `mob_nif:platform/0`) call returning **`undef`**, even
though the on-device `mob_nif.beam` is present and exports the function and the
native `.so` loaded without a `load_nif` error.

**Cause:** The path-dep's beams in `_build` were stale or only partially
recompiled, so `mix mob.deploy` pushed an `mob` that disagreed with the boot
script — `mob_nif` wasn't loaded when boot first called it. A coherently-built
mob (the published Hex package, or a path-dep recompiled as its own step) boots
fine from the identical app, which is how you tell this apart from a real
framework regression.

**Fix:** Recompile the path-dep explicitly *before* deploying, then deploy:

```bash
mix deps.compile mob --force
mix mob.deploy --native --device <serial>
```

Also compile with the toolchain whose Elixir matches the on-device runtime
(`mob.exs`'s `elixir_lib`) — building candidate `.exs` with a different Elixir
(e.g. an `-rc` vs the final OTP build) emits `:elixir_quote` calls the device
stdlib lacks, a *separate* on-device `undef`. For the committed project, prefer
the Hex package and use the path-dep only as a transient verification vehicle.

---

## Android: app crashes on first distribution startup

**Symptom:** App starts successfully, then crashes 3–5 seconds later. Logcat
shows a signal abort or mutex error.

**Cause:** On Android, starting Erlang distribution too early (before the hwui
thread pool is fully initialised) causes a `pthread_mutex_lock on destroyed
mutex` SIGABRT. This is why `Mob.Dist.ensure_started/1` defers `Node.start/2`
by 3 seconds on Android.

**Fix:** Make sure you are calling `Mob.Dist.ensure_started/1` and not calling
`Node.start/2` directly. If you need distribution earlier, increase the defer
delay:

```elixir
Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1", delay: 5000)
```

---

## iOS: `Mob.Test.pop` / `pop_to_root` crashes the BEAM

**Symptom:** Calling `Mob.Test.pop(node)`, `Mob.Test.pop_to(node, ...)`, or
`Mob.Test.pop_to_root(node)` causes the iOS BEAM node to crash immediately.
Logcat shows a signal or the node goes offline.

**Cause:** The pop NIF calls SwiftUI's navigation stack from an Erlang distribution
thread. SwiftUI requires all UI mutations to happen on the main thread. The push
path is guarded correctly; the pop path is not yet.

**Workaround:** Drive backward navigation using platform taps instead:

```elixir
# Instead of: Mob.Test.pop_to_root(node)

# iOS — tap the native Back button via MCP:
mcp__ios_simulator__ui_tap(x: 20, y: 60)

# Or navigate forward to the desired screen and reset:
Mob.Test.navigate(node, MyApp.HomeScreen)
```

`Mob.Test.navigate/3` (push) is safe — it does not trigger the crash.

---

## iOS simulator: node connects but RPC calls fail

**Symptom:** `Node.connect/1` returns `true`, `Node.list/0` shows the device
node, but `:rpc.call/4` returns `{:badrpc, :nodedown}` or hangs.

**Cause:** The iOS simulator shares the Mac's network stack, so EPMD
registration works. But if the dist port is blocked by the macOS firewall, the
actual distribution channel can't be established even though EPMD sees the
node. (A port that is already taken no longer gets this far: the app shows
"Distribution can't start: port N … is already in use" on its startup error
screen instead.)

**Fix:** Find the node's port and check what listens on it:

```bash
epmd -names                # name <app>_ios_<udid8> at port N
lsof -nP -iTCP:N -sTCP:LISTEN
```

Pin a different port with `mix mob.deploy --dist-port <N>`, or launch with
`SIMCTL_CHILD_MOB_DIST_PORT=<N>`.

---

## iOS: `Req` / `Finch` / `Mint` request fails with nxdomain on device

**Symptom:** HTTPS calls that work everywhere else (host, simulator, Android)
fail on a physical iOS device. Errors look like `nxdomain`, `:einval`, or a
generic "lookup failed."

**Cause:** BEAM's `inet_gethost` helper is spawned via `execve`, which iOS's
app sandbox forbids. Every hostname lookup through `:inet` fails immediately.
Android works because its OTP helpers ship as `lib*.so` in `jniLibs/`, which
SELinux allows to exec; iOS has no equivalent escape hatch.

`Mob.App.start/0` already switches the lookup chain to `[:file]` on iOS so
distribution and local-loopback TCP work without setup. That doesn't help
public-internet hostnames though — you still need to opt into one of the
DNS strategies below to talk to Req / Finch / Mint endpoints.

**Fix:** Call `Mob.DNS.resolve/1` once per backend before your first request,
typically in your app's `on_start/0`:

```elixir
Mob.DNS.preresolve([
  "api.example.com",
  "auth.example.com"
])
```

After that, Req / Finch / Mint / `:httpc` / `gen_tcp` all work normally.

See the [DNS on iOS guide](dns_on_ios.md) for the full story, including why
manual resolution rather than automatic interception, what to do if the IP
changes mid-session, and which libraries (NIFs that do their own
`getaddrinfo`) don't need this fix.

---

## `Mob.Canvas` draw ops appear shifted, cropped, or in the wrong place

**Symptom:** Lines, rectangles, or other Canvas draw operations land at
the wrong screen coordinates. Bounding boxes drawn over a
`<CameraPreview>` are noticeably offset (typically down-and-right on
high-density Android devices, or off by some scale factor) and may
extend outside the visible canvas area.

**Cause:** The host app's `MobBridge` Canvas renderer is interpreting
coordinates as raw pixels (or as dp with no viewport scaling) instead
of treating the Canvas's declared `width` / `height` props as a
logical viewport. The intended contract is documented in
`Mob.Canvas`'s `@moduledoc`: a draw op at `(width / 2, height / 2)`
lands in the dead centre of the rendered canvas regardless of actual
pixel size or device density. Older / scaffolded `MobBridge.kt`s
predate this contract and shipped a 1 coord = 1 pixel renderer.

**Fix:** Apply the viewport-scaling recipe documented in
`Mob.Canvas`'s `@moduledoc` ("Implementing the renderer" section) to
your app's `MobBridge.kt` `MobCanvas` composable. Short version:
inside `Canvas { ... }`, compute

```kotlin
val sx = if (width  > 0f) size.width  / width  else 1f
val sy = if (height > 0f) size.height / height else 1f
```

and multiply every x-coord / width by `sx` and every y-coord / height
by `sy` inside `drawCanvasOp`. Scalar sizes (stroke widths, circle
radii, text sizes) use the average `(sx + sy) / 2` so they don't
squash when the viewport is non-square.

The same fix applies to `MobBridge.swift` on iOS — Compose and SwiftUI
both deliver pixel-space draw scopes that need translating.

**Why this isn't fixed once-and-for-all in Mob itself:** Mob ships
zero host-app Kotlin / Swift today; every app's `MobBridge` is its
own diverged copy. A future Mob improvement is to ship the renderer
as a generated module or an AAR / Swift package so this kind of
contract drift can't happen. Tracked in PLAN.md.
