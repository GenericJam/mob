# Mob — Agent Instructions

You're in the **mob** repo, the runtime library for the Mob mobile framework.
Read this in full before making changes — it covers repo topology, how to
drive a running app from your session (Mob.Test, MCP fallbacks), the
pre-empt-failure rules, and the commit/review/release workflow. It will keep
you from re-deriving things the rest of the team has already learned (or
learned the hard way).

> **Keep this file up to date** when you change repo conventions, add a
> new piece of CLI surface area, deprecate a workflow, or hit a new
> gotcha — see "Keep this file up to date" at the end.

See [`guides/agentic_coding.md`](guides/agentic_coding.md) for the full
agent round-trip workflow: connecting to the running Erlang node, when
to use `Mob.Test` vs MCP platform tools, and how to avoid the instinct
to reach for `xcrun simctl` screenshots.

For the in-flight build-system refactor (Mix → Igniter → Zig build),
see [`build_system_migration.md`](build_system_migration.md) — multi-month
sequenced plan; phase ownership lives there.

---

## What Mob is, in one paragraph

Mob lets you write iOS and Android apps in Elixir, with the BEAM running
on-device. The phone hosts an Erlang node — a real one, distribution-capable,
introspectable, hot-code-loadable. Two modes: a SwiftUI/Compose UI driven by
Elixir GenServers (Mob UI apps), or a sidecar BEAM embedded in a normal native
app to give agents and tests live access (Mob as test harness). The sidecar
mode is the long-term bet. Both modes produce a real Erlang node you can `Node.connect/1` to.

For the *why* (the BEAM-on-mobile pitch), see `guides/why_beam.md`.

## Repo topology

Mob is three coordinated repos. **Know which one to edit before you change anything.**

| Repo | Path | What lives here | Edit when |
|---|---|---|---|
| **mob** | `~/code/mob` | Runtime library: `Mob.Screen`, `Mob.App`, `Mob.Renderer`, `Mob.Dist`, `Mob.Test`, the iOS Swift / Android Kotlin native bridges, the NIF | UI behavior, on-device runtime, native bridge changes |
| **mob_dev** | `~/code/mob_dev` | Mix tasks: `mob.deploy`, `mob.connect`, `mob.devices`, `mob.emulators`, `mob.provision`, `mob.doctor`, `mob.battery_bench_*`. Igniter installers (`mob.add_nif`, `mob.enable`, `mob.adopt`). Device discovery (`MobDev.Discovery.{Android,IOS}`). Native build orchestration (`MobDev.NativeBuild`). OTP tarball download/cache (`MobDev.OtpDownloader`). | Build/deploy mechanics, device handling, dev tooling, **Igniter tasks that mutate an existing project** |
| **mob_new** | `~/code/mob_new` | Project generator. Hex archive (`mix archive.install hex mob_new`). Templates in `priv/templates/mob.new/`. Generates both native Mob UI projects and Phoenix LiveView wrappers. | Greenfield generator output. **Must stay self-contained** (`ArchiveSelfContainedTest`) — no hex-dep modules reachable from archive code, so Igniter-based tasks live in mob_dev, not here |

Cross-repo changes are common — fixing one user-visible behavior often needs
the runtime patched in `mob`, the build retooled in `mob_dev`, **and** the
generator template updated in `mob_new` so newly-generated projects pick up
the fix without manual edits.

The OTP runtime tarballs (Android arm64/arm32, iOS sim, iOS device) are built
separately and uploaded to GitHub Releases — see `mob_dev/build_release.md`
and `mob_dev/scripts/release/`. Patches we apply to OTP source live at
`mob_dev/scripts/release/patches/`.

## Issue tracking — status lives in Linear

We use **Linear** (team `MOB`) as the single live status board across `mob`,
`mob_dev`, and `mob_new`. It answers "what's in flight, blocked, or next" — the
thing that used to be scattered across branches, PRs, and decision docs. Each
layer now has **one job**, so they don't compete:

- **Linear (`MOB`)** — live status + worklist. One issue per thread/feature.
- **`decisions/`** — durable rationale (ADRs). Link it from the issue; don't copy it in.
- **`AGENTS.md` / `~/.claude` memory** — conventions + agent recall.
- **PRs / git** — the code. Reference the issue id.

### Access

GraphQL only, `https://api.linear.app/graphql`. The API key is in `~/code/mob/.env`
as `LINEAR_API_KEY` (gitignored — **never commit it**; sibling repos `source
~/code/mob/.env`). The auth header is the key **raw, with no `Bearer` prefix**
(that prefix is for OAuth tokens only — the usual first tripwire). Team `MOB` =
`07dd0939-c66d-44f2-8da5-e3a4a243e953`. No Linear MCP is wired in; use the API.

### The discipline (keep it light)

- **Start of a non-trivial task** → search Linear for the matching `MOB-N` issue;
  create one if none exists. Trivial one-off edits don't need an issue.
- Put `MOB-N` in the **branch name, PR title, and commits** so code ↔ issue link
  both ways.
- Keep the issue **state** current: In Progress when you start, Blocked (+ why) when
  stuck, Done when merged **and** verified. Drop a one-line progress comment at real
  checkpoints (blocked, device-verified, shipped) — not a running narration.
- **Cross-repo work is ONE issue, not three.** A change spanning `mob` + `mob_new`
  (e.g. a NIF + its template) is a single `MOB-N` with both PRs linked.
- **Link `decisions/` docs and PRs from the issue; don't duplicate their content.**

Minimal create (needs the team UUID above):

```bash
set -a; source ~/code/mob/.env; set +a
curl -s https://api.linear.app/graphql -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query":"mutation($t:String!,$ti:String!){issueCreate(input:{teamId:$t,title:$ti}){success issue{identifier url}}}","variables":{"t":"07dd0939-c66d-44f2-8da5-e3a4a243e953","ti":"Your title"}}'
```

---

## Worktrees

**Default assumption: work happens in a git worktree.** The user runs
multiple agents in parallel; each task in its own worktree prevents conflicts
between agents and keeps `master` clean while work is in flight.

If you're assigned a task and worktree usage **isn't mentioned**, ask:

> "Should I use a worktree for this?"

The user will answer:

- **yes** — long task, or other agents may be working in parallel; create a
  worktree (use `EnterWorktree` or spawn the work via Agent with
  `isolation: "worktree"`)
- **no** — quick change with no parallel agent work; work in-place on the
  current branch

If the user explicitly says "use worktrees" up front, do so without asking.
If the task is trivially small (single-file doc edit, one-line config change)
and clearly won't conflict with anything, working in-place is acceptable —
but if in doubt, ask.

---

## Driving apps from your session

The default instinct — screenshots — is wrong. Mob apps run a real Erlang node
you can talk to directly. Read the BEAM, drive it, then verify visually only
when state isn't enough.

### Connect

```bash
mix mob.devices                 # list everything connected (sims, emulators, physical)
mix mob.emulators --list        # list virtual devices (running and stopped)
mix mob.connect                 # set up tunnels, restart apps, start IEx attached to all running nodes
mix mob.connect --no-iex        # just print node names + tunnels (for scripting)
```

Node names are platform-specific:

```
mob_demo_ios@127.0.0.1                     # iOS simulator
mob_demo_android_<serial-suffix>@127.0.0.1  # Android (suffix from ro.serialno, e.g. emulator_5554)
```

### EPMD tunneling

iOS simulator shares the Mac's network stack — the iOS BEAM registers directly in
the Mac's EPMD on port 4369. No forwarding needed.

Android is a separate network namespace. `mob_dev` sets up adb tunnels automatically
(physical devices on Wi-Fi are reached at their own IP — see "Dist ports are
serial-derived" below):

```
adb reverse tcp:4369 tcp:4369       # EPMD: device → Mac (Android BEAM registers in Mac EPMD)
adb forward tcp:<port> tcp:<port>   # dist:  Mac → device, same port both ends
```

### Port assignment (handled by mob_dev)

Each app's dist port on a device is derived from the Android serial or iOS UDID and
the app name (`MobDev.Tunnel.base_port/2`, crc32 of `"<app>@<serial>"` into
`9100..9899`), not a per-run index. A given app on a given device gets the same port
across runs, and `Tunnel.assign_dist_port/3` bumps past any port a live node or another
device's forward already holds.
The device-side BEAM listens on that same port, so the forward is 1:1 and the port
EPMD advertises matches it.

iOS dist port is passed via `SIMCTL_CHILD_MOB_DIST_PORT` env var; `mob_beam.m` reads
`MOB_DIST_PORT` at startup. A simulator launch without it (icon tap, `xcrun simctl
launch`) derives the port the way `Tunnel.base_port/2` does from the app and
`SIMULATOR_UDID`, then takes the first free one in the window (`ios/mob_dist_port.h`);
a physical device uses 9101. A port that won't bind is shown on the startup error
screen and logged as `[MobBeam] ERROR: Distribution can't start: …`, not handed to
the BEAM. Android dist port is passed as the `mob_dist_port` intent
extra (set by `MobDev.Discovery.Android.restart_app/4`); the generated app's
`MainActivity.kt` reads it (`intent.extras.getInt("mob_dist_port")`) and exports it as
the `MOB_DIST_PORT` env var, which `mob_beam` consumes at startup. Override with
`mix mob.deploy --dist-port <N>` (e.g. to dodge a port another app is squatting in the
shared Mac EPMD); pair it with `adb forward tcp:<N> tcp:<N>`.

Both iOS and Android end up registered in the same Mac EPMD. `mix mob.connect` sets
up all tunnels automatically.

### Inspect (`Mob.Test`, BEAM-state, fast, exact — prefer this)

```elixir
node = :"mob_demo_ios@127.0.0.1"   # or mob_demo_android_<serial-suffix>@127.0.0.1

Mob.Test.screen(node)            # which screen is showing?  #=> MobDemo.NavScreen
Mob.Test.assigns(node)           # live socket assigns       #=> %{depth: 0, safe_area: %{top: 62.0, ...}}
Mob.Test.find(node, "Device APIs") # locate widget by visible text
#=> [{[0, 0, 9], %{"type" => "button", ...}}]
Mob.Test.inspect(node)           # full snapshot for debugging
#=> %{screen: MobDemo.NavScreen, assigns: ..., nav_history: [...], tree: ...}
```

This is faster, exact (not pixel-inferred), and works without taking a
screenshot. Use it as the default.

**Colour is the exception.** `view_tree/1`'s `bg_color`/`text_color` are `nil`
for virtually all SwiftUI content (iOS 26 paints via `SDFLayer` or rasterises
into `contents` — colour for 4 of 443 nodes when measured). To verify what was
actually drawn, sample pixels:

```elixir
Mob.Test.sample_color(node, "my-card")   # {:ok, %{average: 0xFF2196F3, dominant: ..., ...}}
```

It crops in the NIF, so only that element's pixels cross dist. See
`decisions/2026-08-09-view-tree-colour-needs-screenshot-sampling.md` and
`decisions/2026-08-10-sample-region-crops-natively-and-stays-debug-only.md`.

### Drive

```elixir
Mob.Test.tap(node, :open_text)              # tap by tag atom (the on_tap: {self(), :tag})
Mob.Test.send_message(node, {:custom, :msg}) # arbitrary handle_info
```

Tag atoms come from `on_tap: {self(), :tag_atom}` in the render tree. Check the
screen's `render/1` to find them. After a tap, call `Mob.Test.screen(node)` again
to confirm navigation happened. Call `Mob.Test.assigns(node)` to confirm state changed.

### Visual verify (MCP, slower, image-based — only when needed)

When layout/animation/rendering matters, fall back to the platform MCP
servers. These are available as tools in the agent environment.

**iOS Simulator** (`mcp__ios-simulator__*`):

| Tool | When to use |
|------|-------------|
| `screenshot` | Capture the current simulator frame |
| `ui_tap` | Tap at x,y coordinates |
| `ui_type` | Type text into focused input |
| `ui_swipe` | Swipe gesture |
| `ui_view` | Inspect the accessibility tree |
| `ui_describe_point` | What element is at this coordinate? |
| `ui_describe_all` | Full accessibility dump |
| `record_video` / `stop_recording` | Record an interaction sequence |

**Android** (`mcp__adb__*`):

| Tool | When to use |
|------|-------------|
| `dump_image` | Screenshot from the connected device/emulator |
| `inspect_ui` | XML accessibility dump of the current view |
| `adb_shell` | Run arbitrary shell commands on the device |
| `adb_logcat` | Tail logcat (Elixir logs appear under the `Elixir` tag) |

Without the adb MCP: `adb shell input tap` / `adb shell input swipe`,
`adb shell screenrecord`.

Use these to confirm a layout looks right, spot animation glitches, or
debug rendering (a bug only visible in the rendered output). **Don't use them
for state queries** — `Mob.Test.assigns/1` is always better: exact, fast, no
image parsing.

### Round-trip workflow

Use all three layers in order — BEAM state first, then visual verification
only when needed.

```
1. Edit Elixir/Swift/Kotlin code
2. mix mob.push                  # fast: BEAM-only push, no native rebuild
   mix mob.deploy --native       # slower: native rebuild needed (NIF / Swift / Kotlin change)
3. Mob.Test.screen(node)         # confirm navigation / state
4. mcp__*__screenshot            # spot-check visual (only if layout matters)
5. Mob.Test.tap(node, :button)   # drive next interaction
6. Mob.Test.assigns(node)        # confirm state updated
7. repeat
```

Full workflow detail: `guides/agentic_coding.md`.

### Day-to-day development loop

```bash
# Edit Elixir code, then:
mix mob.deploy          # compile + push BEAMs + restart apps
mix mob.connect         # tunnel + restart apps + wait for nodes + drop into IEx

# In IEx (after mob.connect):
mix compile && nl(MobDemo.CounterScreen)   # hot-push one module without restart
Node.list()                                # verify both devices connected
:rpc.call(:"mob_demo_android_<serial-suffix>@127.0.0.1", MobDemo.CounterScreen, :some_fn, [])
```

### Reading live screen state

```elixir
# Screen pid is logged at app start: "[mob] step 5 => {ok,<0.92.0>}"
pid = :rpc.call(:"mob_demo_android_<serial-suffix>@127.0.0.1", :erlang, :list_to_pid, [~c"<0.92.0>"])
socket = :rpc.call(:"mob_demo_android_<serial-suffix>@127.0.0.1", Mob.Screen, :get_socket, [pid])
socket.assigns   # live assigns
```

### Hot code push

```bash
# After editing a screen (from the terminal):
mix mob.push          # compile + push all changed modules to all connected devices
mix mob.push --all    # force-push every module

# Or from inside IEx (after mob.connect), one module at a time:
nl(MobDemo.CounterScreen)
# Returns: {:ok, [{:"mob_demo_ios@127.0.0.1", :loaded, MobDemo.CounterScreen}]}
```

### Android distribution

Android cannot start distribution at BEAM launch (races with hwui thread pool, causes
SIGABRT via FORTIFY `pthread_mutex_lock on destroyed mutex`). Instead, `Mob.Dist.ensure_started/1`
defers `Node.start/2` by 3 seconds after app startup. This is handled in the mob library —
app code just calls `Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1", cookie: :my_secret)`.

ERTS helper binaries (`erl_child_setup`, `inet_gethost`, `epmd`) cannot be exec'd from the
app data directory (SELinux `app_data_file` blocks `execute_no_trans`). They are packaged in
the APK as `lib*.so` in `jniLibs/arm64-v8a/` (gets `apk_data_file` label, which allows exec).
`mob_beam.zig` symlinks `BINDIR/<name>` → `<nativeLibraryDir>/lib<name>.so` before `erl_start`.

## Connecting an IEx session to a running mob app (Mac → device BEAM)

Drive any running mob app from a Mac-side IEx via Erlang
distribution. Beats `adb shell input tap` for anything
state-related — you get full RPC into the device BEAM.

### The happy path (single device)

```bash
cd /path/to/your_mob_app

mix mob.connect            # starts IEx connected to all devices
# or
mix mob.connect --no-iex   # sets up tunnels, prints node names, exits
```

Then from any other IEx (or one-shot script) on the Mac:

```bash
elixir --name probe@127.0.0.1 -S mix run --no-start -e '
Node.set_cookie(MobDev.DistCookie.for_project!())
node = :"your_app_android_<suffix>@127.0.0.1"
Node.connect(node)
:rpc.call(node, YourApp.Module, :function, [args])
'
```

The cookie is private per app (MOB-49): mob_dev keeps it under
`~/.mob/dist_cookies/` and hands it to the app at deploy/connect time. Load
it inside the VM as above (in IEx: `Node.set_cookie(MobDev.DistCookie.for_project!())`);
`--cookie <value>` would put it in the process arguments. Apps built against
an older mob still use the public `mob_secret`, which mob_dev falls back to
with a warning; `mix mob.deploy` restarts them onto the private cookie. `--name` (long names) is required when
the device node uses a numeric host like `@10.0.0.120`.

### Multi-Android — node naming (FIXED 2026-05-28 in mob_dev, commit `7497f4b`)

`mob_dev` now derives the Android dist node-name suffix from the device
**serial** (matching what `Mob.Dist` registers), not the IP. Two emulators
get distinct suffixes (`emulator_5554` / `emulator_5556`) and no longer
collide in EPMD. See `mob_dev/decisions/2026-05-28-android-node-name-by-serial.md`.

### Dist ports are serial-derived (mob_dev 0.6.7+)

Ports are no longer assigned by per-run index, which made every project's
first device claim 9100 and collide in the shared Mac EPMD. Each device
gets a stable port from its serial / UDID and listens on it device-side,
so `adb forward` is 1:1 and matches what EPMD advertises. If
`mix mob.connect` fails it reports why (app not running, dist not
registered, port mismatch, no forward, cookie mismatch). To inspect by
hand:

```bash
epmd -names           # registered nodes + their ports
adb forward --list    # host→device forwards (should be 1:1, no dupes)
```

For physical-device-on-Wi-Fi targets (iPhone, real Android), the
node name uses the device IP directly (`@10.0.0.120`) and dist
goes through real network — no adb-forward dance required.

### Inspecting state that contains opaque resources

Several mob/Pigeon operations return values containing opaque NIF
resources (e.g. `Pythonx.Object`, ETS table refs). These cannot
cross Erlang distribution: `:rpc.call/4` will fail with `:badrpc`
on the way back. Pattern: do the resource-touching work *on the
device side* and return primitives (strings, maps, ints).

Example — bad (returns `Pythonx.Object`, dies on dist boundary):

```elixir
:rpc.call(node, Pythonx, :eval, [src, %{}])  # returns {Pythonx.Object, _}; cannot serialize
```

Good — wrap in a helper module compiled into the app:

```elixir
defmodule YourApp.IexHelpers do
  def python_state do
    {obj, _} = Pythonx.eval("...", %{})
    Jason.decode!(Pythonx.decode(obj))   # plain map; safe to ship
  end
end
```

Then `:rpc.call(node, YourApp.IexHelpers, :python_state, [])` works.
Pigeon has `Pigeon.IexHelpers` exactly for this purpose — copy
that pattern when adding device-side debugging surfaces.

### What to reach for first

Write small named functions in `<your_app>.IexHelpers`, push with
`mix mob.deploy`, call by RPC. That keeps the Mac-side script
minimal and debuggable, and the helpers double as documentation
of the operations you actually need.

---

## iOS accessibility activation

SwiftUI lazily populates its accessibility tree only when an accessibility service is
active. `mix mob.connect` runs this automatically for every iOS simulator target
(`MobDev.Discovery.IOS.enable_accessibility/1`, called from `MobDev.Connector.connect_all/1`
before waiting for nodes, with a 500ms settle delay after — MOB-99). Manual invocation
(e.g. driving a sim without going through `mix mob.connect`) still needs it run by hand:

```bash
UDID=<booted-simulator-udid>
xcrun simctl spawn $UDID defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool YES
xcrun simctl spawn $UDID notifyutil -p com.apple.accessibility.voiceover.status.changed
```

Wait ~500ms for propagation. Survives app restarts within the same simulator session.

Even with accessibility active, `Mob.Test.tap_id/2` (which walks the accessibility
tree by point — see `find_a11y_at_point` in `ios/mob_nif.m`) can still race a very
recent layout/navigation: the element's *frame* (tracked separately via
`MobFrameTracker`'s GeometryReader callback) can be ready before SwiftUI has
finished rebuilding the accessibility tree itself. `nif_tap_xy` and
`nif_ax_action_at_xy` retry the point lookup a few times with a short delay
before giving up with `:no_element_at_point` — if you still hit it, the gap
is likely wider than that retry window, worth its own investigation before
assuming ordinary touch interaction is broken.

---

## Verification fidelity ladder

Run every applicable lower rung, plus the highest rung the change actually
reaches. Then say which rung you stopped at. "Tests pass" is not a claim about
a device.

1. **Static.** `mix format --check-formatted`, `mix credo --strict` (ex_slop
   included), `mix compile --warnings-as-errors`.
2. **Host unit.** `mix test`. Proves the Elixir logic. Proves nothing about
   rendering, NIFs, or either platform.
3. **Simulator or emulator.** Deployed, attached over dist, driven through
   `Mob.Test` — read `assigns/1` back after the action, don't trust the tap.
4. **Physical device, both platforms.** The pool is not the world: an
   API-33-only call crashed on Android 11 and was invisible across an
   all-Android-13 emulator pool. `tap_xy/3` returns `{:error, :no_effect}` on a
   real device where the simulator lets it through. iOS needs the cable out
   before dist RPC works.
5. **Release build, not debug.** Different linkage, different packaging,
   different failures. iOS release links plugin NIFs by a separate path
   (`mob_dev` `decisions/2026-07-07-ios-release-links-plugin-nifs.md`), and a
   release leaves an `assets/otp.zip` that crash-loops the next debug deploy
   until it is removed.
6. **Published artifact.** Built from the packed tarball or the store split,
   not the working tree. Hex packaging omits repository-root dotfiles, and AGP
   packs native libs into a release App Bundle that the BEAM needs on the
   filesystem — debug defaults masked both until an install from Play failed.

Every rung above exists because something got through the one below it.

Two rules that outrank the list:

- **Never substitute a lower rung because a higher one is slow, broken, or
  inconvenient.** Fix the harness, open an issue, or state plainly that the rung
  was unavailable and why. An unavailable rung is a fine answer. A silently
  skipped one is not.
- **Verify effects, not exit codes.** An exit code proves a tool ran. It does
  not prove a build happened, a deploy landed, or a screen rendered. After a
  deploy, prove the app is up and answering before believing anything else.

## When the ladder can't be climbed, propose the missing readback

Before falling back to a screenshot or a "looks right to me", ask yourself:

- Can I interact with this thing as text?
- Can I ask it for its state and get a machine-parseable answer?
- If not, is there a small hook I could suggest that would make its state
  legible to future agents?

If the answer to the last question is yes, **file it in the right issue
tracker**:

- Working *on* mob, mob_dev, or mob_new? Those use Linear — file a Linear
  issue (the API key lives in `~/code/mob/.env` as `LINEAR_API_KEY`; the raw
  GraphQL endpoint works fine, no MCP needed).
- Working *on a plugin* (mob_scene3d, mob_bluetooth, mob_camera, etc.)? Those
  use `bd` (beads) — file it in the plugin's own bd.
- Working on a mob-derived app that hit the gap while consuming the framework?
  File a GitHub issue on the framework repo with the observation. A
  well-described gap from a downstream consumer is worth as much as an
  in-team bead — the "concrete case that forced the ask" section is what
  makes it actionable.

Describe:

1. What state the agent needs to see.
2. The smallest API that would expose it (a NIF, an RPC helper, a `Mob.Test`
   assertion, a readback JSON — smallest surface that answers the question).
3. The concrete case that forced the ask ("I hit X while trying to verify Y").

This is the framework's agent-first bet made explicit: `Mob.Test.assigns/1`,
the screenshot/scroll NIFs, `Mob.Scene3d.scene/frame_stats/sample_region`, and
the BEAM observability MCP tools all exist because someone noticed a gap and
wrote the readback instead of squinting at a screenshot. Do the same. Don't
silently skip opportunities to make mob and its plugins more legible — file
the issue (or bead, or GH issue — whichever the current repo uses), and if
it's small, ship it alongside the work that revealed the gap.

Corollary: when you build a new NIF, plugin, or subsystem, design its
introspection surface up front. The question is not "does this render", it's
"can an agent verify this rendered". If the answer needs a screenshot, add a
readback.

## Trust the instrument last

Every rung of the fidelity ladder assumes the thing measuring is honest. When it
is not, the failure does not look like an error — it looks like a result.

Two from one session, both of which were believed for a while:

* A navigation benchmark reported a 6.5x improvement. The tree was installed by
  a `LaunchedEffect`, which runs *after* composition, so the frame being timed
  still showed the old screen. The real figure was about half that, and the
  published numbers had to be retracted.
* An on-device check printed `PASS` against a build that had failed to compile,
  because the deploy before it had failed and the previous build was still
  installed. The screen it claimed proved the fix had never scrolled.

So:

- **A number better than the theory allows is a bug in the measurement.**
  Navigation cannot be cheaper than re-rendering the same tree. When the result
  is too good, go and find out why before reporting it.
- **Make a probe fail loudly when its own precondition does not hold.** A check
  that silently passes when the setup did not happen is worse than no check.
- **Corroborate against something you did not build.** Platform counters,
  `Davey!` frame reports, `Skipped N frames`, a screenshot. Agreement within
  30% of an independent source is evidence; your own instrument agreeing with
  itself is not.
- **When you publish a number that turns out wrong, retract it in place** and
  say what was wrong. Someone will otherwise act on it.

## Pre-empt-failure rules — read before you touch anything

These are the things we've burned ourselves on. Following them isn't optional.

1. **Default arguments evaluate eagerly.** `System.get_env("ROOTDIR", Path.expand("~/..."))`
   evaluates `Path.expand` *every call*, regardless of whether `ROOTDIR` is set.
   `Path.expand("~/...")` calls `System.user_home!()` which raises on Android
   (no `HOME` env var). Use `case System.get_env(...)` or `||` instead. Burned us
   once — see commit `d77932e`.

2. **Don't silently swallow `Mob.Screen.start_root` errors.** It returns
   `{:ok, pid}` or `{:error, reason}` and crashes from inside `init` are reported
   via `{:error, ...}`. If you don't pattern-match, the screen never renders and
   the app sits on the "Starting BEAM…" splash forever. The on_start callback
   should `{:ok, _} = Mob.Screen.start_root(...)` so failures crash loudly.
   Mob itself logs `[mob] root screen <Module> failed to start; …` at error
   level either way, since init failures leave no crash log of their own.

3. **Never call the render NIFs outside `Mob.Sender`.** `clear_taps`,
   `register_tap`, `set_transition`, and `set_root` are one build-then-commit
   sequence sharing a single global build cursor in the native tap tables
   (`ios/mob_nif.m`, `android/jni/mob_nif.zig`). The double buffering there
   protects concurrent *readers* — a drag event mid-render — and does nothing
   for concurrent *writers*: two renders in flight interleave their handles into
   the same building table and one screen's tree is never committed. Screens
   build a tree and hand it to `Mob.Sender.render/5`; the sender is the only
   caller. See `decisions/2026-08-28-sender-serialises-render.md`.

   Native event handles encode the render generation on both platforms.
   `clear_taps` advances the build generation, and `set_root` commits the table,
   count, and generation under the same mutex. Treating a handle as a bare slot
   can route a callback from an old native tree into the current screen. A sender
   must also copy the tag into its delivery environment while holding that
   mutex; the table's `tag_env` may be freed as soon as the lock is released.
   Change events, animation-delayed dismissals, press in/out, and taps on a
   node that also declares `on_press_in` / `on_press_out` may cross renders
   when both retained registrations have identical PID and tag identity; plain
   taps and the other gestures stay generation-strict. A plain tap must stay
   strict because a positional tag (Mob.List's `{:select, id, index}`) from an
   old tree would select a different row after the list changes. A press
   node re-renders between a finger's down and up (`on_press_in`), so its tap
   goes through the tolerant `mob_send_press_tap`. A press_out's routing is
   copied at touch-down and sent from the copy, so the pair survives any number
   of renders (`decisions/2026-10-03-press-in-out-and-held-press.md`).
   Invalidate the building table's generation at `clear_taps` so stale lookup
   never observes a partially rebuilt table.

4. **TDD discipline in mob_dev.** Every new public function gets a test.
   `mob_dev/AGENTS.md` makes this explicit. Don't bypass — the tests are how we
   catch the multi-step regressions like the iOS-device deploy chain.

5. **Format + credo before commit.** `mix format && mix credo --strict` from the
   relevant repo, every time. Both are clean across the codebase today; don't
   regress them. The full list, in order, is the Pre-commit checklist below.

   **And the native formatters, if you touched native source.** CI runs
   `xcrun clang-format --dry-run -Werror ios/mob_nif.m android/jni/mob_beam.h`
   and swiftlint, and `mix format` says nothing about either. Adding one line
   to an aligned C initialiser is enough to fail it, because clang-format
   re-flows the whole block around the new entry — which is how this note came
   to be written. Run `xcrun clang-format -i <file>` on any `.m`/`.h` you
   edited before committing.

6. **Multi-repo changes batch together.** A user-visible fix in mob often needs
   matching changes in mob_dev (build) and mob_new (template). Bumping versions
   without coordination produces ghost regressions. Check all three before
   declaring done.

7. **iOS device sandbox blocks `fork()`.** The BEAM's `forker_start` and EPMD's
   `run_daemon` both call fork; both are patched in our OTP cross-compile.
   Patches at `mob_dev/scripts/release/patches/`. Don't undo them.

8. **iOS sim and iOS device are different build paths.** Sim → `ios/build.sh`
   (`build_ios/1` in NativeBuild). Device → `ios/build_device.sh`
   (`build_ios_physical/2`). When `--device <udid>` is passed, mob_dev resolves
   it via `IOS.list_devices/0` to know which path to take. Don't shortcut.

9. **LV port 4200 is global per device.** Two installed Mob LV apps + one
   running = the second can't bind. Workaround for now: force-stop the squatter.
   Real fix tracked in `issues.md` #4 (hash bundle id into port).

10. **Compile-time `~r//` literals are unsafe on OTP 28.** They bake a
    `:re_exported_pattern` and call `:re.import/1` at runtime; OTP 28.0 removed
    that function. Use `Regex.compile!("...", "flags")` to compile at runtime.
    71 literals across mob_dev were swept in 0.3.17.

11. **`:mob_nif.log/1` for early startup logging, `Logger` after Mob.App.start.**
    `Mob.NativeLogger.install()` runs as part of `Mob.App.start` and reroutes
    `Logger` to NSLog/logcat. Before that point (steps 1–4 in the Erlang
    bootstrap), `Logger` output goes to stderr and is invisible. Use
    `:mob_nif.log("message")` for diagnostics during early init.

12. **NIFs on Android must be statically linked, not `dlopen`'d.** Android's
    `System.loadLibrary` loads native libs `RTLD_LOCAL` by default — the
    parent's `enif_*` symbols are invisible to subsequently-`dlopen`'d
    children. The OTP-internal NIFs (`crypto`, `asn1rt_nif`) are built as
    `.a` archives and linked into the app's main native lib via
    `--whole-archive`; the BEAM resolves their `nif_init` via
    `dlsym(RTLD_DEFAULT)` (registered through `--enable-static-nifs` at
    OTP build time, listed in `erts_static_nif_tab[]`). Any custom NIFs
    a mob app adds must follow the same pattern. See
    `mob/common_fixes.md` for symptoms and the dead-end attempts (we
    tried `-Wl,--export-dynamic` and runtime `RTLD_GLOBAL` self-dlopen;
    neither works on Android).

13. **`:crypto` on-device is real OpenSSL** (3.x, statically linked).
    No more shim — old code that special-cased "no crypto on mobile"
    can be deleted. The deployer's `generate_crypto_shim/0` only fires
    when a cached OTP runtime *lacks* `lib/crypto-*/ebin/crypto.beam`;
    current tarballs have it. See `mob/crypto_plan.md` for the rebuild
    process when bumping OpenSSL.

14. **Igniter-based tasks live in mob_dev, never in the mob_new archive.**
    mob_new ships as a self-contained Mix archive; `ArchiveSelfContainedTest`
    pins that no hex-dep modules are reachable from archive code (an archive
    bundles only its own beams, so a call into a hex dep crashes every
    installed user with `UndefinedFunctionError`). Igniter is a hex dep, so any
    `Igniter.Mix.Task` (`mob.add_nif`, `mob.enable`, `mob.adopt`) belongs in
    mob_dev — a normal project dependency where Igniter is on the path. A task
    that needs mob_new's *templates* (e.g. `mob.adopt --android/--ios`) reads
    them from the installed mob_new archive via `:code.priv_dir(:mob_new)`
    rather than duplicating them. See
    `mob_dev/decisions/2026-06-19-mob-adopt-lives-in-mob_dev.md`.

15. **Don't drive iOS by coordinate — use `Mob.Test.tap/2`.** `tap_xy/3` works
    on the simulator only for elements SwiftUI gives an accessibility action
    (`Button`, text fields); a `Box` with `on_tap:` has none. On a physical
    device the injected IOHID touch is accepted and never delivered, so every
    coordinate fails. Both now return `{:error, :no_effect}` instead of the
    `:ok` they used to — a harness that reported success for taps that did
    nothing let a downstream iOS renderer bug sit unverified for weeks. When
    you add a harness NIF, make its success value mean *observed effect*, never
    *the platform API didn't complain*. See
    `decisions/2026-08-09-tap-xy-reports-observed-effect.md`.

16. **Never capture `[nsstring UTF8String]` in a block that can outlive the
    scope.** The pointer belongs to the NSString and may become invalid before
    a delayed callback runs. Capture the object and convert inside the block.
    Both alert NIFs previously relied on the pointer remaining valid; short
    action names often masked the problem.

17. **A diagnostic table goes through `Mob.Diag.Store`, never a hand-written
    owner.** Five hand-rolled owners all returned from `start/0` on
    `{:already_started, pid}`, before `init/1` had created the tables, and
    concurrent first callers wrote to nothing (1,400 of 1,600 calls in a
    probe). Implement the behaviour instead: readiness, heir-backed tables,
    versioned state, `guard/3` on write paths and `Mob.Diag.health/0` come
    with it. The same trap applies to any lazily started named process whose
    callers use something `init/1` creates. `GenServer.start/3` returning
    `already_started` means the name exists, not that `init/1` finished. See
    `decisions/2026-09-30-diagnostic-stores-share-one-hardened-owner.md`.
    A write path must read `Mob.Diag.Store.state/1` (that is where an upgrade
    re-runs setup), and a test that stops a store owner deletes its tables
    first: an owner that dies holding them hands them to the heir, which
    starts another owner under your teardown (MOB-302).

18. **Never `:global.trans` for a node-local lock, and never let evidence from
    a destructive drain live only in memory.** `:global` backs off by sleeping
    (0.2–2.5 s under contention) and releases on the node name captured at
    acquire time, so a `Node.start` inside the section (Android `Mob.Dist`,
    seconds after boot) leaks the lock for good. Serialise through a locally
    registered process. A drain that advances a marker or empties an OS queue
    is written to `Mob.PostMortem.Journal` before it is emitted and kept until
    that specific capsule is observed, never inferred from a sequence range
    (MOB-303).

19. **Native input never passes through `Mob.Event.dispatch/4`.** Taps,
    changes and gestures arrive at `Mob.Screen.Server.handle_info/2` as
    `{event, tag[, payload]}` via `Mob.Listener`. Anything that should observe
    user actions hooks there through `Mob.Event.NativeInput.kind/1`, and never
    records the payload: text-field values are user data (MOB-305).

## Device shapes

Foldables (iPhone Duo), iPad and Split View: layout keys on `:size_class` (MOB-204), never orientation; the fold will be `:reserved_regions` (MOB-202, not yet shipped), kept apart from `:safe_area`.
Read `decisions/2026-10-01-fold-aware-layouts.md` before touching size class, reserved regions, `<Arrangement>`, hinge events, scene accessories or multi-window.

---

## Tests cover everything, not just runtime code

Every behavior in this repo gets a test — including build helpers
and any CLI surface that lives here (less common in `mob` than in
`mob_dev`, but the discipline is the same). Runtime modules like
`Mob.Screen`, `Mob.Renderer`, `Mob.Sigil` get the obvious
unit/integration coverage. **Beyond runtime:**

- NIF stub modules (`mob_nif.erl`, when it gains more surface):
  pure helpers extracted from the C/Zig side get Elixir tests.
- Sigil compile-time AST transforms: test the generated AST,
  not just runtime behavior. This caught the
  `Mob.Sigil.wrap_child/1` per-call-site warning regression this
  session.
- Build-time helpers (driver_tab generators, native build glue
  when it lives here): same rule.

The goal is **find bugs in CI before users hit them.** A bug found
by a test takes minutes to fix; one found by a user takes a
bug-report-to-fix cycle plus damage to confidence. When you touch
something untested, either add coverage or note it as a follow-up.

### Tests are part of the change, not a follow-up

New behaviour ships with a test unless the change is small enough that a test
would only restate it — a rename, a doc string, a formatting pass.

The bar is not coverage percentage, it is: **would this test fail if the fix
were reverted?** Check by reverting it. A test that passes either way is worse
than none, because it is claimed as evidence. More than one fix here shipped
with a test that could not fail — including a headline fix whose entire clause
could be deleted with the full suite still green.

---

## Commit workflow

### Pre-commit checklist

Before committing changes, run **all** in this order:

```bash
mix test            # full suite must pass (call out any pre-existing flake explicitly)
mix format          # apply Elixir formatting
mix credo --strict  # **whole tree, not just changed files** — includes ExSlop (catches AI-generated patterns: blanket rescue, narrator docs, etc). Pre-existing issues are tracked separately, but new ones (including in tests) must be fixed
mix erlfmt --check src/                          # Erlang formatting (src/mob_nif.erl)
xcrun clang-format --dry-run -Werror \
  ios/*.m ios/*.c \
  android/jni/*.c android/jni/*.h               # C/ObjC formatting
swiftlint ios/                                   # Swift linting (brew install swiftlint)
```

Auto-fix formatting (don't use for check-only CI):
```bash
mix erlfmt --write src/
xcrun clang-format -i ios/*.m ios/*.c android/jni/*.c android/jni/*.h
swiftlint --fix ios/
```

For native-code changes (iOS `.m`, Android `.kt` / `.c`), Elixir tests don't
exercise the change. Deploy with `mix mob.deploy --native` and verify
manually with a screenshot or `Mob.Test` interaction before committing.

### Decision log

Non-obvious decisions — tradeoffs, workarounds, conventions, "why we chose X
over Y" — go in `decisions/`, **one file per decision**:

    decisions/YYYY-MM-DD-short-slug.md

Each file is a lightweight ADR:

    # <Title>
    - Date: YYYY-MM-DD
    - Status: accepted | superseded by <file> | proposed
    ## Context        — what prompted this
    ## Decision       — what we chose
    ## Consequences   — tradeoffs, follow-ups

**Append new files; never rewrite an existing decision.** The one in-place edit
is correcting a factual error inside a record (see "Decision log — check both
directions" below). If a decision changes, add a
new file and mark the old one `Status: superseded by <new-file>`. One file per
decision keeps the log conflict-free across parallel agents/worktrees — the
date-sorted directory listing is the index. Record a decision the moment you
make a non-obvious call, not later.

### Decision log — check both directions

Before committing, ask two questions, not one.

**Does this need a new record?** Anything non-obvious: a tradeoff, a workaround,
a convention, a "why X and not Y". The test is whether a reader six months from
now would ask why it is like this. If the commit message is explaining a
decision, that decision belongs in `decisions/` where it is findable, not only
in `git log`. Record it in the same commit, not as a follow-up.

**Does this INVALIDATE an existing record?** This is the half that gets missed,
and it is the more dangerous one. A record asserting a property the code no
longer has is worse than no record: it is a claim a maintainer will act on.
Grep `decisions/` for the mechanism you are changing before you commit.

Both failed in one session, on the same change:

* A decision record claimed "the frame-registry generation is untouched because
  the parked slot stops re-registering once it stops laying out." It reasoned
  about the outgoing direction only. The returning direction was broken —
  silently, for exactly the screens the change optimised for — and the record
  said it was fine.
* Source comments elsewhere stated invariants the same change inverted:
  `MobLazyList`'s latch reasoned that "only navigation changes the container's
  identity", which had just stopped being true.

When you correct a record, correct it **in place** with a note saying what was
wrong, rather than quietly deleting the claim. The wrong version is the part a
future reader needs to recognise, and `decisions/` is append-only for
superseding whole decisions, not for silently editing away a mistake inside one.

### Adversarial review — before the commit, by a subagent

**Non-trivial work gets an adversarial review before it is committed.** Spawn a
subagent, point it at the actual diff, and tell it to find defects rather than
to approve. Act on what it finds, then commit.

It must be a **separate agent**, not a re-read of your own work. The thing that
is wrong is usually the author's mental model of the change, and that model is
exactly what a self-review carries into the second pass.

Give the reviewer: the diff to read (`git diff <base>..HEAD`, and the base
explicitly, since a diverged local branch will otherwise sweep in the whole
tree), what the change claims to do, and the specific things you are least sure
about. Tell it to cite `file:line` for every finding, to rank them
blocking / should-fix / nitpick, and to separate what it verified in source from
what it is reasoning about platform semantics. Ask it to say plainly if the
change is sound rather than inventing problems — but only after it has looked
hard.

**Skip it for** mechanical or trivial changes: formatting, a typo, a version
bump, a changelog edit, moving a file. Reach for it when the change has
behaviour, touches native code, or spans a platform boundary.

This is not ceremony. In one session, pre-commit reviews caught, each of which
would otherwise have shipped:

* a helper defined inside `#if !MOB_RELEASE` but called unconditionally from
  Swift, which linked in debug and would have failed **every iOS release
  build**;
* a cache whose tests asserted the write path and nothing about the read, so
  deleting the lookup, or reading under a constant key, passed the whole suite;
* a fix that covered 3 of 7 call sites on one platform while claiming parity
  with the other;
* a comment and a decision record asserting a race was closed when the code
  only narrowed it;
* generated source telling every user that a feature does nothing, in the
  release that made it work.

The one substantial change that skipped review that session was the largest one
in the batch. Do not let size be the reason to skip.

### Before the merge — a second review, on the PR

The pre-commit review reads a diff. This one reads a diff **that claims to be
finished**, against a master that has moved since you started. Those are
different questions, and the second one has caught more.

Both frame-timing PRs in one session passed pre-commit review. The pre-merge
review then found that one of them shipped its headline fix untested — it
deleted the conversion and all 1545 tests still passed — and blocked the other
outright over per-widget state that navigation had silently stopped resetting.
Neither was visible in the diff alone; both needed someone asking "is this
actually done, and does it still fit?"

Give the reviewer the PR, what it claims, and what you are least sure of, and
ask for a verdict — MERGE or DO NOT MERGE, with reasons. Then act on it. A
review you overrule is fine if you say why; a review you skip because the work
felt done is the case this exists for.

**Check the mechanical preconditions yourself; do not delegate them:**

- **CI is green AND the run is newer than the last commit.** A green check from
  before your latest push proves nothing. One PR here carried a month-old green
  run from 40 commits of master ago.
- **The branch is not behind master.** The `pre-push` hook says how far.
- **Cross-repo claims are true now, not eventually.** Documentation that names
  a sibling's version — "requires mob_new 0.4.32" — is false until that version
  exists. Land the sibling first, or make the claim true in the same session.
- **Stacked PRs merge base-first**, and the child gets retargeted and re-checked
  after the base lands.

---

## Release flow

See [`RELEASE.md`](RELEASE.md) for the canonical release process —
trigger model (mix.exs is the source of truth), version-bump rules
(patch default, always ask, never auto-bump), CHANGELOG conventions,
local preflight, and the per-step idempotency of `release.yml`.

> **Review gate is on by default.** Everything that landed since the
> last published version gets a code review *before* you publish —
> scoped at `v<last-published>..HEAD`, not per-PR, because the diff a
> user pulls from Hex is rarely the shape of any one PR — plus the
> version-sanity checks (is this version already published? did
> anything merge after the bump commit and therefore miss the
> release?). Skip only if the user says so. See RELEASE.md →
> "Review gate". This governs `mob`, `mob_dev`, and `mob_new` alike.

**Pre-push hook**: `.githooks/pre-push` runs `mix format
--check-formatted`, `mix credo --strict`, and `mix compile
--warnings-as-errors` on every push (~5-10 s). When the push touches
`mix.exs` it additionally runs the full test suite as the release
preflight. The hook is committed in the repo; activate it once per
clone or worktree with:

```bash
git config core.hooksPath .githooks
```

git stores `core.hooksPath` locally per-clone, so every worktree
needs the same one-liner.

---

## Running tests

```bash
mix test          # from ~/code/mob
```

### Onboarding integration tests

The `test/onboarding/` suite verifies the full first-run flow end-to-end: archive
install, project generation, `mix mob.install`, `mix mob.doctor`, and failure modes.
These tests are **excluded from `mix test` by default** (they take minutes and require
Hex/network access). Run them explicitly:

```bash
# Fast subset — no simulator needed (~3 min, suitable for PR gating)
MIX_ENV=test mix test --only generator

# Failure-mode checks — no simulator needed (~2 min)
MIX_ENV=test mix test --only pre_device

# Everything above in one pass
MIX_ENV=test mix test --only onboarding

# Full suite including post-device tests (requires a booted iOS simulator)
MIX_ENV=test mix test --only failure_modes
```

Run one file at a time with `--max-cases 1` to avoid workspace ID collisions between
concurrent tests:

```bash
MIX_ENV=test mix test test/onboarding/generator_test.exs --only generator --max-cases 1
MIX_ENV=test mix test test/onboarding/failure_modes_test.exs --only pre_device --max-cases 1
```

**What they test:**

| Tag | File | Covers |
|-----|------|--------|
| `:generator` | `generator_test.exs` | Archive install, `mix mob.new`, `mix mob.install`, `mix mob.doctor` |
| `:pre_device` | `failure_modes_test.exs` | Failure modes that don't need a running simulator |
| `:post_device` | `failure_modes_test.exs` | Failures requiring a live iOS simulator |

**Preserved workspaces:** When a test fails, its workspace is kept at
`/tmp/mob_onboarding/run_<PID>/<test_id>/`. Inspect `logs/` for per-step output.
Workspaces from passing tests are deleted automatically.

**Known limitations (published `mob_dev 0.1.7`):**

- `MOB_OTP_BASE_URL` is not respected — OTP download URL cannot be overridden for
  failure injection. Network failure tests verify OTP reporting format instead.
- `check_elixir` reads `System.version()` (the running BEAM) — PATH-based fake Elixir
  versions have no effect. The Elixir version test verifies the check produces clear output.
- `check_java` ignores exit code (`{out, _}` pattern) — a fake java always shows ✓.
  The java test verifies the check is present and reports useful version info.
- `xcrun` and `java` share `/usr/bin` with `dirname`/`basename` used by mise/asdf elixir
  launcher scripts. Filtering `/usr/bin` from PATH crashes the subprocess. Tests for these
  tools verify the success path format instead of injecting a missing-tool failure.

## Common pitfalls

See [`common_fixes.md`](common_fixes.md) for a running log of diagnosed bugs and their
fixes — consult it first when hitting silent crashes or unexpected BEAM behavior.

## User issues log

See [`user_issues.md`](user_issues.md) for a record of real issues encountered by
beta users, their root causes, and fixes applied. Read this before working on setup,
deployment, or tooling problems — the same issues recur, especially for Nix users.
User alias "Nova" = macOS + Nix-managed toolchain throughout.

## Key files

- `lib/mob/screen.ex` — GenServer wrapper, lifecycle callbacks
- `lib/mob/socket.ex` — assigns + internal mob state
- `lib/mob/renderer.ex` — walks component tree, issues NIF calls
- `lib/mob/dist.ex` — platform-aware distribution startup
- `src/mob_nif.erl` — Erlang NIF stub (declares all NIF functions)
- `ios/mob_nif.m` — iOS NIF implementation (SwiftUI bridge + test harness)
- `android/jni/mob_nif.zig` — Android NIF implementation (JNI bridge)
- `ios/mob_beam.m` — iOS BEAM launcher
- `android/jni/mob_beam.zig` — Android BEAM launcher (Phase 6b iter 2 — was `.c`)
- `android/jni/mob_zig.zig` — Hand-declared JNI / libc / Android FFI bindings used by mob_beam.zig

## Transport-handler reentrancy: spawn before calling back into the GenServer

If your app registers a wire handler (e.g. via `Pigeon.Transport.expose/2`)
that the transport invokes via `Pythonx.send_tagged_object` →
`handle_info({:rns_packet, ...}, state)` → `dispatch_inbound`, **don't
run the handler synchronously inside that GenServer's process** if the
handler might call back into the same GenServer.

Concrete bug we hit in Pigeon: an inbound `:hello` envelope ran
`Pigeon.Handlers.on_hello/2` synchronously inside
`Pigeon.Transport.Reticulum.Server.handle_info/2`. `on_hello` reciprocated
by calling `Handlers.push_hello/1` → `Transport.send/3` →
`GenServer.call(Pigeon.Transport.Reticulum.Server, ...)` — but we were
already inside that GenServer's `handle_info`. Erlang refuses a process
calling itself with `:calling_self` and the GenServer crashes:

    {:calling_self, {GenServer, :call, [Pigeon.Transport.Reticulum.Server,
                                        {:send, ..., :hello, ...}, 10000]}}

The mistake is conceptually simple — synchronous reentrancy from a
handler that holds the GenServer's mailbox lock — but the symptom is
mystifying: messages arrive, handler logs fire, then the GenServer
silently terminates and the supervisor restarts it without you
noticing the cycle.

**Fix pattern**: wrap each handler invocation in a `spawn` so the
handler's call-chain runs in its own process and can re-enter the
transport without deadlocking. Pair with a `try/rescue + Logger.error`
so the spawned process doesn't die silently:

    spawn(fn ->
      try do
        fun.(sender_pubkey, payload)
      rescue
        e ->
          Logger.error(
            "[transport] handler #{name} crashed: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end
    end)

Applies to any transport-style GenServer that dispatches incoming
events to user-registered callbacks. Using a `Task.Supervisor` is
cleaner once the app already has one; for a leaf transport the bare
`spawn` is fine — handlers are idempotent and don't need restart
semantics.

## Where to look

| Question | File |
|---|---|
| Round-trip workflow + MCP setup | `guides/agentic_coding.md` |
| System architecture / native cocoon model | `AGENTS.md` → "Native App Test Harness — Vision", `ARCHITECTURE.md` |
| "I hit error X — has this happened before?" | `common_fixes.md` |
| "Does this user-facing setup issue ring a bell?" | `user_issues.md` |
| Open known issues with diagnoses + fixes | `issues.md` |
| Speculative ideas, longer-term plans | `future_developments.md`, `wire_tap.md`, `PLAN.md` |
| Per-feature deep dives (events, navigation, theming, ...) | `guides/*.md` |
| Architecture decisions (one ADR per cross-cutting decision) | `decisions/` |
| iOS device deployment (provisioning, build chain, gotchas) | `guides/ios_physical_device.md` |
| Generator templates (mob_new) | `mob_new/priv/templates/mob.new/` |
| Build / release tooling | `mob_dev/scripts/release/`, `mob_dev/build_release.md` |

---

## Native App Test Harness — Vision

### What mob is (beyond the UI framework)

Mob has two modes of use:

1. **Mob UI apps** — Elixir-driven SwiftUI/Android apps. The BEAM renders the UI.
2. **Native sidecar** — The BEAM runs invisibly inside any native Xcode/Android Studio
   app as a debug-only test and agent harness. The native app has zero Elixir dependency.
   In production builds the BEAM is stripped entirely.

The sidecar mode is the long-term bet. It gives native developers (who write zero Elixir)
a way to let agents introspect and drive their apps during development and CI — without
changing how they build or ship.

### The cocoon model

The BEAM + NIF wraps the native app completely. From the OS's perspective, there is one
process: the native app. The BEAM runs on a background thread. The NIF, being in-process,
has privileges no external tool has:

- Direct access to the iOS/Android UI object graph (no accessibility bridge latency)
- Ability to intercept and synthesize touch events before they reach the app
- Access to non-UI state: model objects, view controller hierarchy, memory
- Faster and more reliable than Appium, XCUITest, or `xcrun simctl` — no IPC round-trip

The end goal is that the BEAM is **the whole world to this app**: it can observe every
touch, inject synthetic touches, read every visible label, and report full UI state — all
over Erlang distribution to a remote test runner or agent.

### Why BEAM / why not XCUITest

- XCUITest runs out-of-process and requires a separate test host target — it cannot read
  in-memory model state, only rendered accessibility output
- Appium adds an HTTP layer and has significant latency
- The BEAM runs in-process with sub-millisecond IPC via Erlang distribution
- Tests can be written in any language that speaks Erlang distribution (Elixir, Erlang,
  or via the distribution protocol directly)
- Hot code push means test logic can be updated without restarting the app or rebuilding

### Development phases

**Phase 1 — Attachment and reporting (complete)**

- `ui_tree/0` — walks `UIApplication.shared` windows via UIAccessibility APIs, returns
  `[{type, label, value, {x,y,w,h}}, ...]` tuples. Works on any app with zero modification.
- `ui_debug/0` — raw accessibility dump for debugging

**Phase 2 — Synthetic interaction (partial — see the honesty note below)**

- `tap/1` — tap by accessibility label
- `tap_xy/2` — tap at screen coordinates (with responder-chain walk to focus text fields)
- `type_text/1` — type into the focused text field
- `delete_backward/0`, `key_press/1`, `clear_text/0` — keyboard control
- `long_press_xy/3`, `swipe_xy/4` — gesture synthesis

Coordinate-driven input is *not* finished, whatever the list above implies.
`tap_xy/2` now returns `:ok` only when the app demonstrably reacted; on the
simulator that limits it to `Button`s and text fields, and on a physical device
the injected IOHID touch is accepted but never delivered, so every coordinate
returns `{:error, :no_effect}`. `swipe_xy/4` and `long_press_xy/3` still report
on acceptance and their `:ok` is unverified. Drive Mob screens with
`Mob.Test.tap/2` (by tag). See
`decisions/2026-08-09-tap-xy-reports-observed-effect.md` and
`decisions/2026-08-09-ios-device-tap-injection-has-no-effect.md`.

**Phase 3 — Full cocoon / event interception (future)**

Intercept the touch event stream before it reaches the app's responder chain. The BEAM
decides whether to pass events through, suppress them, or inject new ones. At this point
the BEAM is the authoritative input source and the app is fully contained.

---

## inject / eject — native project integration

For native-only developers (no Elixir, just Xcode or Android Studio), mob is added and
removed as a debug sidecar via a single command. The production app is never affected.

```bash
mix mob.inject MyApp.xcodeproj   # add sidecar to Xcode project (one time)
mix mob.eject  MyApp.xcodeproj   # remove it cleanly — git diff shows nothing
```

### What inject does (iOS)

- Adds `mob_nif.m`, `mob_beam.m` as Debug-only compile sources
- Links `libbeam.a` and supporting static libs as Debug-only
- Copies ERTS runtime directory as a Debug-only bundle resource
- Adds `#if DEBUG mob_start_beam() #endif` to AppDelegate/SceneDelegate

### What inject does (Android)

```gradle
// build.gradle (app) — added by inject
debugImplementation 'io.mob:sidecar:VERSION'
```

```kotlin
// Application.onCreate() — added by inject
if (BuildConfig.DEBUG) MobSidecar.start(this)
```

(The `Application.onCreate` line can be eliminated with a ContentProvider auto-init,
making Android injection truly zero-touch.)

### eject guarantee

`eject` is a clean inverse. `git diff` after eject shows nothing meaningful. This is
important for the trust model — a developer can verify mob leaves no footprint.

**Status:** `inject`/`eject` are planned; pre-built `libbeam.a` fat binary (simulator +
device + Android) is the prerequisite.

---

## MCP server — `mob_mcp` (planned)

### Design intent

The MCP server is an abstraction layer between the agent and the BEAM. The agent
never sees Erlang nodes, distribution, or NIF calls directly — it talks to typed
tools that happen to be backed by the BEAM internally.

**The abstraction is the point.** A developer using mob with an agent should not be
able to accidentally write Elixir, because no tool exists to do so. The agent has
everything it needs to verify and drive the native app, and nothing that lets it reach
into the BEAM layer.

### Package split

```
mob_dev   — Mix tasks: deploy, connect, push, doctor, new, inject, eject
mob_mcp   — MCP server: native-mode tools for agent-driven development
```

`mob_mcp` depends on `mob_dev` for device discovery and tunnel setup.
`mob_dev` has no knowledge of MCP. Clean dependency direction.

### Single mode

The MCP server has one mode. There is no `MOB_MODE=elixir`. If a developer
wants full BEAM access they open IEx directly — that is a human workflow,
not an agent workflow. Giving the agent an Elixir-level tool would just be
a worse IEx with predefined functions.

### Tools exposed

| Tool | Backed by |
|------|-----------|
| `mob_deploy` | `mix mob.deploy --native` |
| `mob_build` | `xcodebuild` / `gradlew assembleDebug` + `simctl install` |
| `mob_ui_tree` | `mob_nif:ui_tree/0` via RPC |
| `mob_tap` | `mob_nif:tap_xy/2` via RPC (finds by label internally) |
| `mob_type_text` | `mob_nif:type_text/1` via RPC |
| `mob_swipe` | `mob_nif:swipe_xy/4` via RPC |
| `mob_screenshot` | `xcrun simctl io` / adb screencap |
| `mob_logs` | simulator console / adb logcat |
| `mob_assert_visible` | `ui_tree` + label/value match |
| `mob_wait_for` | poll `ui_tree` with timeout + backoff |

### Agent loop for native-only projects

```
1. edit Swift/Kotlin files (appear in Xcode/AS immediately)
2. mob_build  → xcodebuild + simctl install
3. mob_ui_tree → confirm screen state
4. mob_tap / mob_type_text → drive interactions
5. repeat
```

The developer sees all code changes in their IDE in real time and can intervene at
any point. They never need to touch the terminal or know Erlang exists.

### Project integration

`mix mob.new` and `mix mob.inject` both emit `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "mob": {
      "command": "mix",
      "args": ["mob_mcp.server"]
    }
  }
}
```

Every developer and every agent session gets the same tools automatically.
No per-session setup required.

---

## Conventions worth knowing

- **Terse responses.** Default to short, dense communication. The user reads code
  changes via diff; don't recap them in chat.
- **No premature abstractions.** Three similar lines beats a half-baked helper.
- **No comments explaining the code.** Comments explain *why* — invariants,
  hidden constraints, surprising behavior. Never the *what*.
- **Trust internal callers.** Don't add validation/error handling for cases
  that can't happen. Validate at system boundaries (user input, external APIs).
- **Don't add features beyond what was requested.** A bug fix doesn't need
  surrounding cleanup; a one-shot doesn't need a helper.
- **Write UI the LiveView way.** The `~MOB` sigil supports `@assigns` shorthand
  and `:if` / `:for` control attributes (`<Row :for={u <- @users}>`), and
  `Mob.Socket` has `assign/2,3`, `update/3`, `assign_new/3`. See
  `guides/components.md` → Control flow. Async loading is
  `Mob.Socket.start_async/3` + `handle_async/3` (not a bare `Task.async/1`);
  see `guides/screen_lifecycle.md`.

## Don't write this slop

LLMs reach for the same anti-patterns over and over. The list below is the
shape of code our `mix credo --strict` (via `ex_slop`) refuses to merge — but
catching it post-hoc costs a round-trip. Don't write it in the first place.

**Error handling**
- No blanket `rescue _ -> nil` or `rescue _e -> {:error, "..."}`. Rescue the
  specific exception or let it crash.
- No `rescue e -> Logger.error(...); :error` — that logs the bug into oblivion.
  Either reraise or return a typed error tuple the caller can match on.
- No `try/rescue` around functions that don't raise (`Map.get`, `Enum.find`,
  `String.split`). Look up whether the function actually raises before wrapping it.

**Database access**
- Filter in SQL, not in Elixir: `from(u in User, where: u.active)` —
  not `Repo.all(User) |> Enum.filter(& &1.active)`.
- No N+1 in `Enum.map`: don't `Enum.map(ids, &Repo.get(...))`. Use `Repo.all(from … where: id in ^ids)`.
- Don't write a GenServer whose entire job is `Map.get`/`Map.put` on state —
  use ETS, Agent, or a struct passed by value.

**Maps**
- Pick one key type per map. Don't `Map.get(m, :key) || Map.get(m, "key")` —
  normalize once at the boundary.
- Iterate the map directly. Not `Map.keys(m) |> Enum.map(fn k -> m[k] end)`.

**Enum / list idioms** — use the function that exists:
- `Enum.reject(&is_nil/1)`     not `Enum.filter(&(&1 != nil))`
- `Enum.empty?(x)`             not `length(x) == 0`
- `List.last(x)` / `Enum.at(x, -1)` not `Enum.at(x, length(x) - 1)`
- `Map.new/2`                  not `Enum.reduce(%{}, fn ..., &Map.put/3)`
- `Enum.into(list, %{})`       only if you actually have a Collectable target;
  for a plain literal target it's just `Map.new`.
- `Enum.filter`                not `Enum.flat_map(fn x -> if cond, do: [x], else: [] end)`
- `Enum.sum`                   not a hand-rolled reduce with `+`
- `Enum.max` / `Kernel.max`    not `if a > b, do: a, else: b`
- `Enum.sort(list, :desc)`     not `Enum.sort(list) |> Enum.reverse()`
- `Enum.min(list)`             not `Enum.sort(list) |> Enum.at(0)`
- `Enum.map_join(list, sep, &f/1)` not `Enum.map(list, &f/1) |> Enum.join(sep)`

**`with` blocks**
- No identity `else` clause. `with :ok <- foo() do :ok end` — drop the
  `else err -> err` part.

**Strings**
- `String.length(s)` not `length(String.graphemes(s))`.
- For counting specific ASCII chars, prefer `:binary.matches/2` over graphemes.
- No manual string reverse via graphemes + reverse + join — use `String.reverse/1`.

**Paths**
- `Application.app_dir(:my_app, "priv/...")` over `Path.expand("...priv...", __DIR__)`.
  The Mix-task code in `mob_dev` is an exception — it needs cwd-relative paths
  for the *user's* project.

**Docs and comments**
- No "This module provides functionality for..." moduledoc. State *why* it
  exists or what's surprising; if there's nothing to say, omit it.
- No obvious comments (`# Fetch the user` above `Repo.get(User, id)`).
- No narrator comments (`# We need to...`, `# Here we...`).
- No step comments (`# Step 1: Do X`, `# Step 2: Do Y`) — function names cover that.
- No `@doc false` on a `defp` — private already means undocumented.
- Boilerplate `## Parameters / ## Returns` sections are noise unless the
  parameters are non-obvious.

**Code shape**
- Don't shadow `Kernel` functions with local variables named `length`, `min`,
  `max`, `node`, etc.
- Don't rebind a parameter inside the function body. Pick a new name.
- Don't write `x = foo(); x` at the end of a function — just `foo()`.
- Don't extract `[a, b] = list` only to immediately rebuild `[a, b]`.
- Use the same name for the same parameter across all clauses of a function.

> **Periodic check:** `ex_slop` and the related (but heavier) [`credence`](https://hex.pm/packages/credence)
> linter add new AI-pattern checks regularly. Both ecosystems are young —
> when something here feels stale or you spot a new ExSlop release, skim
> the changelogs and update this section. Credence has ~70 rules ExSlop
> doesn't port yet; if any get backported (or if `credence` becomes worth
> wiring in alongside Credo), revisit `mob/AGENTS.md` and the deps lists.

## Keep this file up to date

The next agent's first decision will be informed by this file. Stale guidance
here causes wrong decisions everywhere downstream.

When you change something this doc describes — repo topology, conventions,
gotchas, a new piece of CLI surface area, a deprecated workflow — **update
this file in the same commit**. Not in a follow-up. The history of "I'll fix
the docs later" is that it doesn't happen.

If you discover a gotcha that bit you — something that should have been on the
pre-empt list but wasn't — add it to rule #N+1 with a one-line summary and a
link to the commit/test that demonstrates it. Future you will thank present
you.
