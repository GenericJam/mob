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
  cookie:    :mob_secret,
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
  Mob.Dist.ensure_started(node: :"my_app_ios@127.0.0.1", cookie: :mob_secret)
end
```

**With OTA BEAM updates:** distribution needs to be live, but only during the
update session. The recommended pattern is on-demand: the app polls your server
over HTTP for an update manifest, starts EPMD + distribution only when an
update is available, connects to your update server's BEAM node to receive new
BEAMs via `:code.load_binary`, then shuts distribution back down. Because the
phone initiates the outbound connection, no inbound ports need to be open and
the cookie can be rotated per session via the manifest.

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
   The cookie in your app's `Mob.Dist.ensure_started/1` call must match the
   `--cookie` flag passed to `mix mob.connect` (default: `mob_secret`).

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
Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1", cookie: :mob_secret, delay: 5000)
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
registration works. But if the dist port (default 9101 for iOS) is blocked by
macOS firewall or already in use, the actual distribution channel can't be
established even though EPMD sees the node.

**Fix:** Check if 9101 is in use:

```bash
lsof -i :9101
```

If something else is using it, configure a different dist port in
`Mob.Dist.ensure_started/1` and update `mob.exs` accordingly.

---

## iOS: `Req` / `Finch` / `Mint` request fails with nxdomain on device

**Symptom:** HTTPS calls that work everywhere else (host, simulator, Android)
fail on a physical iOS device. Errors look like `nxdomain`, `:einval`, or a
generic "lookup failed."

**Cause:** BEAM's `inet_gethost` helper is spawned via `execve`, which iOS's
app sandbox forbids. Every hostname lookup through `:inet` fails immediately.
Android works because its OTP helpers ship as `lib*.so` in `jniLibs/`, which
SELinux allows to exec; iOS has no equivalent escape hatch.

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
