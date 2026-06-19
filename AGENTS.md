# AGENTS.md — orientation for AI agents working on Mob

You're in the **mob** repo, the runtime library for the Mob mobile framework.
Read this in full before making changes — it's the 5-minute orientation that
will keep you from re-deriving things the rest of the team has already learned
(or learned the hard way).

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

## Driving apps from your session

The default instinct — screenshots — is wrong. Mob apps run a real Erlang node
you can talk to directly. Read the BEAM, drive it, then verify visually only
when state isn't enough.

### Connect

```bash
mix mob.devices                 # list everything connected (sims, emulators, physical)
mix mob.emulators --list        # list virtual devices (running and stopped)
mix mob.connect                 # set up tunnels, start IEx attached to all running nodes
mix mob.connect --no-iex        # just print node names + tunnels (for scripting)
```

Node names are platform-specific:

```
mob_demo_ios@127.0.0.1                     # iOS simulator
mob_demo_android_<serial-suffix>@127.0.0.1  # Android (suffix from ro.serialno)
```

For iOS simulator, the sim shares the Mac's network stack — distribution Just
Works. For Android (and iOS device), `mix mob.connect` sets up `adb reverse` /
similar tunnels.

### Inspect (`Mob.Test`, BEAM-state, fast, exact — prefer this)

```elixir
node = :"mob_demo_ios@127.0.0.1"

Mob.Test.screen(node)            # which screen is showing?  → ModuleName
Mob.Test.assigns(node)           # live socket assigns        → %{...}
Mob.Test.find(node, "Submit")    # locate widget by visible text
Mob.Test.inspect(node)           # full snapshot: screen, assigns, nav stack, widget tree
```

This is faster, exact (not pixel-inferred), and works without taking a
screenshot. Use it as the default.

### Drive

```elixir
Mob.Test.tap(node, :open_text)              # tap by tag atom (the on_tap: {self(), :tag})
Mob.Test.send_message(node, {:custom, :msg}) # arbitrary handle_info
```

After a tap, call `Mob.Test.screen(node)` again to confirm navigation
happened. Call `Mob.Test.assigns(node)` to confirm state changed.

### Visual verify (MCP, slower, image-based — only when needed)

When layout/animation/rendering matters, fall back to MCP platform tools:

| iOS simulator | Android |
|---|---|
| `mcp__ios-simulator__screenshot` | `mcp__adb__dump_image` |
| `mcp__ios-simulator__ui_view` | `mcp__adb__inspect_ui` |
| `mcp__ios-simulator__ui_tap {x, y}` | `adb shell input tap` |
| `mcp__ios-simulator__ui_swipe` | `adb shell input swipe` |
| `mcp__ios-simulator__record_video` | `adb shell screenrecord` |

Use these to confirm a layout looks right, spot animation glitches, or
debug rendering. **Don't use them for state queries** — `Mob.Test.assigns/1`
is always better.

### Round-trip workflow

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

3. **TDD discipline in mob_dev.** Every new public function gets a test.
   `mob_dev/CLAUDE.md` makes this explicit. Don't bypass — the tests are how we
   catch the multi-step regressions like the iOS-device deploy chain.

4. **Format + credo before commit.** `mix format && mix credo --strict` from the
   relevant repo, every time. Both are clean across the codebase today; don't
   regress them.

5. **Multi-repo changes batch together.** A user-visible fix in mob often needs
   matching changes in mob_dev (build) and mob_new (template). Bumping versions
   without coordination produces ghost regressions. Check all three before
   declaring done.

6. **iOS device sandbox blocks `fork()`.** The BEAM's `forker_start` and EPMD's
   `run_daemon` both call fork; both are patched in our OTP cross-compile.
   Patches at `mob_dev/scripts/release/patches/`. Don't undo them.

7. **iOS sim and iOS device are different build paths.** Sim → `ios/build.sh`
   (`build_ios/1` in NativeBuild). Device → `ios/build_device.sh`
   (`build_ios_physical/2`). When `--device <udid>` is passed, mob_dev resolves
   it via `IOS.list_devices/0` to know which path to take. Don't shortcut.

8. **LV port 4200 is global per device.** Two installed Mob LV apps + one
   running = the second can't bind. Workaround for now: force-stop the squatter.
   Real fix tracked in `issues.md` #4 (hash bundle id into port).

9. **Compile-time `~r//` literals are unsafe on OTP 28.** They bake a
   `:re_exported_pattern` and call `:re.import/1` at runtime; OTP 28.0 removed
   that function. Use `Regex.compile!("...", "flags")` to compile at runtime.
   71 literals across mob_dev were swept in 0.3.17.

10. **`:mob_nif.log/1` for early startup logging, `Logger` after Mob.App.start.**
    `Mob.NativeLogger.install()` runs as part of `Mob.App.start` and reroutes
    `Logger` to NSLog/logcat. Before that point (steps 1–4 in the Erlang
    bootstrap), `Logger` output goes to stderr and is invisible. Use
    `:mob_nif.log("message")` for diagnostics during early init.

11. **NIFs on Android must be statically linked, not `dlopen`'d.** Android's
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

12. **`:crypto` on-device is real OpenSSL** (3.x, statically linked).
    No more shim — old code that special-cased "no crypto on mobile"
    can be deleted. The deployer's `generate_crypto_shim/0` only fires
    when a cached OTP runtime *lacks* `lib/crypto-*/ebin/crypto.beam`;
    current tarballs have it. See `mob/crypto_plan.md` for the rebuild
    process when bumping OpenSSL.

13. **Igniter-based tasks live in mob_dev, never in the mob_new archive.**
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

## Where to look

| Question | File |
|---|---|
| Round-trip workflow + MCP setup | `guides/agentic_coding.md` |
| System architecture / native cocoon model | `CLAUDE.md` (top half), `ARCHITECTURE.md` |
| "I hit error X — has this happened before?" | `common_fixes.md` |
| "Does this user-facing setup issue ring a bell?" | `user_issues.md` |
| Open known issues with diagnoses + fixes | `issues.md` |
| Speculative ideas, longer-term plans | `future_developments.md`, `wire_tap.md`, `PLAN.md` |
| Per-feature deep dives (events, navigation, theming, ...) | `guides/*.md` |
| Architecture decisions (one ADR per cross-cutting decision) | `docs/decisions/` |
| iOS device deployment (provisioning, build chain, gotchas) | `guides/ios_physical_device.md` |
| Generator templates (mob_new) | `mob_new/priv/templates/mob.new/` |
| Build / release tooling | `mob_dev/scripts/release/`, `mob_dev/build_release.md` |

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
> wiring in alongside Credo), revisit `mob/CLAUDE.md` and the deps lists.

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
