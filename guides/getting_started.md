# Getting Started

Mob runs on iOS and Android. Pick your target — you don't need both.

→ [iOS only](#ios-only)
→ [Android only](#android-only)
→ [Both platforms](#both-platforms)
→ [LiveView projects](#liveview-projects)

---

## iOS only

### What you need

- macOS
- Xcode 15 or later (`xcode-select --install` for command-line tools)
- Elixir 1.19 or later with Hex: `mix local.hex`
- `mob_new` installed: `mix archive.install hex mob_new`

That's enough to run on the **iOS Simulator**. For a **physical iPhone**, you also need:

- An Apple ID — free at https://appleid.apple.com
- Xcode signed in with that Apple ID: open Xcode → Settings → Accounts → [+]
- (For App Store distribution only) Apple Developer Program — $99/year.
  Free accounts can deploy to your own devices; profiles expire every 7 days.

### Create a project

```bash
mix mob.new my_app --ios
cd my_app
mix mob.install
```

`--ios` scopes the generator to iOS only — no `android/` directory is created
and `mix mob.install` skips the Android OTP download (saves ~400 MB of cache).
Drop the flag if you want both platforms.

`mix mob.install` downloads the pre-built OTP runtime for iOS and writes your `mob.exs`.

### Verify your environment

```bash
mix mob.doctor
```

Fix any failures before continuing. See [Troubleshooting](troubleshooting.md) if needed.

### Run on the iOS Simulator

Boot a simulator from Xcode → Open Simulator, or:

```bash
xcrun simctl boot "iPhone 16 Pro"
open -a Simulator
```

Then deploy:

```bash
mix mob.deploy --native --ios
```

This builds the `.app` bundle, installs it in the simulator, and pushes your BEAM files.
Subsequent deploys without `--native` are faster — they push only changed `.beam` files:

```bash
mix mob.deploy --ios
```

### Run on a physical iPhone

There are three one-time steps before your first deploy. Do them in order.

#### Step 1 — Trust the Mac

Connect your iPhone to your Mac with a USB cable. The phone will show:

> **"Trust This Computer?"**

Tap **Trust**, then enter your passcode. If this dialog doesn't appear, unplug and
replug the cable, or try a different port.

#### Step 2 — Enable Developer Mode on the iPhone

This is required on iOS 16 and later. You only do it once per phone.

On the iPhone: **Settings → Privacy & Security → Developer Mode → turn ON**

The phone will warn you and ask to restart. Tap **Restart**. After it reboots, a
dialog appears asking to confirm — tap **Enable** and enter your passcode.

> If you don't see Developer Mode in Settings, make sure the phone is connected to
> the Mac and Xcode is open. Xcode needs to recognise the device at least once for
> the option to appear.

#### Step 3 — Register your app ID and get a provisioning profile

Apple requires every app installed on a physical device to be signed with a
provisioning profile tied to your developer account. Run:

```bash
mix mob.provision
```

This generates a small Xcode project stub, uses it to register your bundle ID with
Apple, and downloads a development provisioning profile — all from the command line.
You won't need to build or launch anything in Xcode.

> **If `mix mob.provision` fails:** open Xcode, select your phone from the device
> picker at the top, and wait for it to finish "Preparing device for development".
> Then re-run `mix mob.provision`.

#### Deploy

```bash
mix mob.deploy --native --ios
```

Mob auto-detects the connected phone. The app will appear on your home screen.

If the profile expires (free accounts: every 7 days, paid Developer Program: 1 year),
re-run `mix mob.provision` then deploy again.

---

## Android only

### What you need

- Elixir 1.19 or later with Hex: `mix local.hex`
- `mob_new` installed: `mix archive.install hex mob_new`
- Java 17–21 (`brew install --cask temurin` on macOS)
- Android Studio (includes the SDK and `adb`)

For a **physical Android device**: enable Developer Options and USB Debugging on the
device, then connect via USB and accept the authorization prompt.

### Create a project

```bash
mix mob.new my_app --android
cd my_app
mix mob.install
```

`--android` scopes the generator to Android only — no `ios/` directory is created
and `mix mob.install` skips the iOS OTP download. Drop the flag if you want both
platforms.

`mix mob.install` downloads the pre-built OTP runtime for Android and writes your
`mob.exs` and `android/local.properties`.

### Verify your environment

```bash
mix mob.doctor
```

Fix any failures before continuing. See [Troubleshooting](troubleshooting.md) if needed.

### Run on an emulator

Start an AVD from Android Studio → Device Manager, then:

```bash
mix mob.deploy --native --android
```

This builds the APK, installs it on the emulator, and pushes your BEAM files.
Subsequent deploys without `--native` push only changed `.beam` files:

```bash
mix mob.deploy --android
```

### Run on a physical Android device

There are two one-time steps before your first deploy.

#### Step 1 — Enable Developer Mode on the phone

Android hides developer options until you unlock them.

1. Open **Settings → About phone**
   - On Samsung: **Settings → About phone → Software information**
2. Find **Build number** and tap it **7 times** in quick succession
3. You'll see: *"You are now a developer!"*
4. Go back to **Settings** — a new **Developer options** entry has appeared
5. Open **Developer options** and turn on **USB debugging**

#### Step 2 — Connect via USB and set the mode

Plug in the USB cable. On the phone:

- A prompt appears: **"Allow USB debugging?"** — tap **Allow**
  (tick "Always allow from this computer" so you're not asked every time)
- Pull down the notification shade and tap the USB connection notification
- Select **File Transfer** (sometimes labelled "MTP") — not "Charging only"

Verify the connection:

```bash
adb devices
```

You should see your device listed as `device` (not `unauthorized` or `offline`).
If it shows `unauthorized`, check for a missed dialog on the phone screen.

#### Deploy

```bash
mix mob.deploy --native --android
```

Mob detects connected devices automatically. If you have more than one, use
`mix mob.devices` to find the serial ID and `--device <id>` to target it.

---

## Both platforms

### What you need

Everything from the iOS and Android sections above — but you don't need a physical
device for both. Mix and match whatever you actually have:

| Setup | What to do |
|-------|-----------|
| iOS Simulator + Android emulator | Nothing extra — just deploy |
| Physical iPhone + Android emulator | Set up iPhone (trust + Developer Mode + `mix mob.provision`) |
| iOS Simulator + physical Android | Set up Android (Developer Mode + USB debugging + File Transfer) |
| Physical iPhone + physical Android | Set up both phones, then `mix mob.provision` for iOS |

### Create a project

```bash
mix mob.new my_app
cd my_app
mix mob.install
```

### Verify your environment

```bash
mix mob.doctor
```

### Deploy to everything you have connected

```bash
mix mob.deploy --native
```

Without `--ios` or `--android`, Mob targets all connected simulators, emulators, and
physical devices at once — whatever is available. On macOS it includes both platforms;
on Linux/Windows it deploys Android only. You don't need to tell it what you have.

### If you have a physical iPhone (one-time setup)

Before your first deploy to a physical iPhone, register your app with Apple:

```bash
mix mob.provision
```

Then deploy normally — Mob auto-detects the phone alongside any running simulators
or emulators and pushes to all of them in one command:

```bash
mix mob.deploy --native
```

If you only want to target the phone and skip the simulators for a deploy:

```bash
mix mob.deploy --native --ios
```

### Targeting one device at a time

Use `mix mob.devices` to see what's connected and their IDs, then `--device <id>` to
target a specific one — useful when you have multiple physical devices or want to
isolate a deploy while keeping others running.

---

## LiveView projects

Instead of writing screens in Elixir with the `~MOB` sigil, you can run a full
Phoenix LiveView app inside a native WebView. The native shell handles device
APIs and distribution; your UI is a regular Phoenix web app.

The first-run flow is **not the same** as a native project — it has database
setup, an extra asset-pipeline step, and a couple of paths to fill in by hand.
The full sequence is below.

### Mixed apps are fine

You don't have to pick one mode for the whole app. A native Mob project can
host LiveView screens (run `mix mob.enable liveview` in an existing project),
and a LiveView project can include native `Mob.Screen` modules alongside its
WebView screens. Use whichever fits each part of the app.

One thing to be aware of: a mixed app has **two distinct forms of navigation**.

  * **Phoenix routes** — `live "/foo", FooLive` in `router.ex`, navigated with
    `<.link navigate={...}>` or `push_navigate(...)`. Lives entirely inside the
    LiveView WebSocket; the WebView's URL changes but the native nav stack
    doesn't.
  * **Native navigation** — `Mob.Nav.push/2`, `pop/1`, tab bars, drawers.
    Lives in the native nav controller; the WebView is just one screen on
    that stack.

The two stacks don't talk to each other (by default but you control both sides so if you _really_ want to you could make that happen). A Phoenix route change inside a
WebView doesn't push a native screen, and a `Mob.Nav.push` doesn't navigate
the WebView. Plan crossings explicitly: a tap inside the LiveView that should
push a native screen sends a `mob_message` event up to the hosting
`Mob.Screen`, which calls `Mob.Nav.push/2`; a native back-button in a parent
screen pops the WebView screen as a whole, not the route inside it.

### Extra prerequisite

You need the `phx_new` archive in addition to `mob_new`:

```bash
mix archive.install hex phx_new
```

### Create a LiveView project

Pass `--liveview` to `mix mob.new`:

```bash
mix mob.new my_app --liveview
cd my_app
```

`--liveview` combines with `--ios` or `--android` if you want a single-platform
LiveView project — for example `mix mob.new my_app --liveview --ios` skips
Android scaffolding entirely.

This calls `mix phx.new` under the hood, then patches the generated project:
adds the Mob bridge hook to `app.js`, inserts the `mob-bridge` element in
`root.html.heex`, adds `Mob.App` to the supervision tree, and writes a
`mob.exs` with `liveview_port: 4000`.

### 1. Configure local paths

Unlike a native project, the LiveView template doesn't auto-fill machine-
specific paths. Open these two files and set the values for your machine.

**`mob.exs`** — set both keys:

  * `mob_dir`    — local path to the mob library (or `deps/mob` if vendored)
  * `elixir_lib` — your Elixir lib dir, e.g.
    `~/.local/share/mise/installs/elixir/1.19.5-otp-28/lib`

**`android/local.properties`** — set the Android SDK path:

```
sdk.dir=/Users/you/Library/Android/sdk
```

### 2. Run first-time setup

```bash
mix mob.install
```

Caches the OTP runtimes, generates a placeholder app icon, and finalises the
build config.

### 3. Configure and create the database

Edit `config/dev.exs` to point at your dev database (the Phoenix-generated
defaults work for most local Postgres setups), then:

```bash
mix ecto.create && mix ecto.migrate
```

### 4. Run the Phoenix server once (required)

This downloads JS/CSS dependencies and compiles static assets. **Skipping
this step is the most common cause of a blank-screen first deploy** — the
WebView loads `http://127.0.0.1:4000/` but the asset pipeline has never
produced any files for it to serve.

```bash
mix phx.server
```

Open `http://localhost:4000` in your browser to confirm it loads, then stop
the server (`Ctrl-C`).

### 5. Deploy to device

```bash
mix mob.deploy --native
```

The native app starts your Phoenix server at `http://127.0.0.1:4000/` and
loads it in a WebView.

### 6. Verify the LiveView bridge

After the app launches, open the WebView in a remote inspector (Safari Web
Inspector for iOS, `chrome://inspect` for Android) and run:

```js
window.mob.send({some: 'event'})
```

The call should route through Phoenix's `pushEvent` — visible as a LiveView
event on the server side — **not** through `window.postMessage`. That
confirms the Mob ↔ LiveView bridge is wired correctly.

### Day-to-day development

The workflow is the same as a native project — push changed BEAMs, restart,
or watch for file changes:

```bash
mix mob.deploy    # push BEAMs + restart (Phoenix server restarts inside the app)
mix mob.watch     # auto-push on file save
```

Phoenix code changes (templates, LiveViews) are picked up automatically when
the BEAM restarts. Asset changes (`app.js`, CSS) require running
`mix assets.build` locally first, since the device runs your compiled
assets, not the dev pipeline.

### Adding LiveView to an existing native project

If you already have a Mob project (created without `--liveview`) and want to
turn it into a LiveView app, run:

```bash
mix mob.enable liveview
```

This is the same patcher that `mix mob.new --liveview` runs for new projects:
generates `lib/<app>/mob_screen.ex`, injects `MobHook` into `assets/js/app.js`,
inserts the hidden `<div id="mob-bridge">` into `root.html.heex`, sets
`liveview_port` in `mob.exs`, and adds the Android `networkSecurityConfig`
that lets the WebView reach `127.0.0.1`. See [LiveView Mode](liveview.md) for
the full architecture explanation.

---

## After the first deploy

These commands work the same regardless of platform.

### Connect a live IEx session

```bash
mix mob.connect
```

Tunnels Erlang distribution and drops you into an IEx session connected to the running
BEAM on the device. You can inspect state, call functions, and push code live.

```elixir
Node.list()
#=> [:"my_app_ios@127.0.0.1"]

Mob.Test.assigns(:"my_app_ios@127.0.0.1")
#=> %{count: 0, safe_area: %{top: 62.0, ...}}
```

### Hot-push a code change

Edit a module, then push the new bytecode without restarting:

```bash
mix mob.push
```

Changed `.beam` files are loaded directly into the running BEAM via RPC — no restart,
no state loss. The screen updates immediately.

### Auto-push on save

```bash
mix mob.watch
```

Watches for file changes and runs `mob.push` automatically. Combine with
`mix mob.connect` to keep an IEx session open alongside.

---

## Deployment reference

| Command | Restarts? | Requires dist? | What it does |
|---------|:---------:|:--------------:|---|
| `mix mob.deploy --native` | Yes | No | Build native binary + install + push BEAMs |
| `mix mob.deploy` | Yes | No | Push BEAMs + restart (no native rebuild) |
| `mix mob.push` | No | **Yes** | Hot-push changed BEAMs via RPC |
| `mix mob.watch` | No | **Yes** | `mob.push` on every file save |
| `nl(MyApp.Screen)` in IEx | No | **Yes** | Hot-push a single module |

**Requires dist** means Erlang distribution must be active. Run `mix mob.connect` first,
or use the dashboard (`mix mob.server`) which sets it up automatically.

### Which command should I use?

- **First time, or after changing Swift/Kotlin/C?** → `mix mob.deploy --native`
- **Changed Elixir, want a clean restart?** → `mix mob.deploy`
- **Changed Elixir, want to keep app state?** → `mix mob.push`
- **Want changes pushed automatically while editing?** → `mix mob.watch`

---

## Toolchain managers

Mob is **tested against [mise](https://mise.jdx.dev/)** for managing Elixir
and Erlang versions. The repos ship a `.tool-versions` file that mise reads
automatically.

**asdf** uses the same `.tool-versions` format and should work without
changes — install Elixir/Erlang the asdf way and you're done. We don't
actively test it, but no Mob code touches mise or asdf directly; everything
works off whatever `mix`, `elixir`, `iex`, and `erl` resolve to on your PATH.

**Nix users** need to set a few env vars yourself, since mob_dev's auto-
detection assumes mise/asdf-style on-disk layouts (e.g. `~/.local/share/mise/
installs/elixir/...`). Override the defaults from your shell or `direnv`:

| Env var | What it sets | Default if unset |
|---|---|---|
| `MOB_ELIXIR_LIB` | Elixir lib dir used to bundle the stdlib into the iOS app | computed from the running BEAM (mise/asdf path) |
| `MOB_DIR` | Path to the mob library (only needed for `mix mob.new --local`) | resolves from `mob.exs` or `deps/mob` |
| `MOB_DEV_DIR` | Path to the mob_dev library (only for `--local`) | sibling discovery (`./mob_dev` then `../mob_dev`) |
| `MOB_CACHE_DIR` | OTP runtime cache for downloaded prebuilt tarballs | `~/.mob/cache/` |
| `MOB_SIM_RUNTIME_DIR` | iOS simulator's writable OTP root | `~/.mob/runtime/ios-sim/` |
| `ANDROID_HOME` | Android SDK location | read from `android/local.properties` `sdk.dir` |
| `JAVA_HOME` | JDK location for Gradle | inherited |

Quick recipe for a Nix user with Elixir from `pkgs.beam.packages.erlang_28.elixir_1_19`:

```sh
export MOB_ELIXIR_LIB="$(elixir -e 'IO.puts(Path.dirname(to_string(:code.lib_dir(:elixir))))')"
export MOB_CACHE_DIR="$HOME/.mob/cache"           # or somewhere your Nix gc-roots manage
export MOB_SIM_RUNTIME_DIR="$HOME/.mob/runtime/ios-sim"
export ANDROID_HOME="$HOME/Android/Sdk"           # wherever your nixpkgs AndroidSdk lives
```

`mix mob.cache` and `mix mob.cache --clear` know about both `MOB_CACHE_DIR`
and `MOB_SIM_RUNTIME_DIR` overrides — if you point them at a project-local
or sandbox-friendly path, that's also what cache listings and `--clear` will
target.

---

## Caches and disk usage

`mix mob.deploy` populates a few machine-wide locations outside your project tree:

- **`~/.mob/cache/`** — pre-built OTP runtimes for iOS sim, iOS device, and
  Android (one per ABI). Reused across every Mob project. ~200–400 MB each.
  Override with `MOB_CACHE_DIR`.
- **`~/.mob/runtime/ios-sim/`** — the OTP root that the running iOS simulator
  app reads from at startup (mob_new ≥ 0.1.20). One per machine, not per
  project — last project deployed wins. Override with `MOB_SIM_RUNTIME_DIR`.
  Older projects use `/tmp/otp-ios-sim` instead, which `mob.cache` still lists.
- **`~/Library/Caches/elixir_make/`** (macOS) or `~/.cache/elixir_make/`
  (Linux) — pre-built NIF tarballs that `exqlite` and other NIF deps download
  instead of recompiling from source. Owned by `elixir_make`, not Mob.

To inspect or clear them:

```bash
mix mob.cache                              # show paths + sizes (read-only)
mix mob.cache --include-transitive         # also show elixir_make's cache
mix mob.cache --clear                      # delete Mob's caches (with prompt)
mix mob.cache --clear --include-transitive # delete ours + elixir_make's
```

To relocate Mob-owned paths (sandbox-friendly for Nix or CI environments):

```bash
export MOB_CACHE_DIR=/path/to/cache         # OTP runtime cache
export MOB_SIM_RUNTIME_DIR=/path/to/runtime # iOS simulator runtime
```

`mob.cache` deliberately does not touch `~/.hex`, `~/.mix`, `~/.gradle`, or
Xcode's `DerivedData` — those are shared with non-Mob projects and clearing
them via Mob would silently break unrelated work.

---

## Your first screen

```elixir
defmodule MyApp.HomeScreen do
  use Mob.Screen

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, :count, 0)}
  end

  def render(assigns) do
    ~MOB"""
    <Column padding={24} gap={16}>
      <Text text={"Count: #{assigns.count}"} text_size={:xl} />
      <Button text="Tap me" on_tap={tap(:increment)} />
    </Column>
    """
  end

  def handle_info({:tap, :increment}, socket) do
    {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
```

`mount/3` initialises assigns. `render/1` returns the component tree via the `~MOB`
sigil. `handle_info/2` updates state in response to user events. After each update,
the framework calls `render/1` again and pushes the diff to the native layer.

---

## Next steps

- [Screen Lifecycle](screen_lifecycle.md) — mount, render, handle_event, handle_info
- [Components](components.md) — full component reference
- [Navigation](navigation.md) — stack, tab bar, drawer, push/pop
- [Theming](theming.md) — color tokens, named themes, runtime switching
- [Data & Persistence](data.md) — `Mob.State` for preferences, Ecto + SQLite for structured data
- [Device Capabilities](device_capabilities.md) — camera, location, haptics, notifications
- [LiveView Mode](liveview.md) — full Phoenix LiveView app inside a native WebView (the two-bridge architecture, `mix mob.enable liveview`)
- [Testing](testing.md) — unit tests and live device inspection
- [Troubleshooting](troubleshooting.md) — if something isn't working, start here
