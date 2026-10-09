# Agentic coding with Mob

AI coding assistants work best when they can close the loop themselves: make a change,
verify it worked, decide what to do next. This guide explains how to give an agent the
full context it needs to work effectively on a Mob app — and why the default approach
most agents reach for will give you worse results.

The guide is in two halves. [Working with one agent](#working-with-one-agent)
covers the loop for a single agent driving a single app — stop there if that's
you. [Working with agent teams](#working-with-agent-teams) builds on that loop
for fleets: many agents, shared devices, and the discipline that keeps them
from trampling each other.

## Working with one agent

### The context problem

An LLM working on a mobile app normally has two options for inspecting the running app:

1. **Screenshots** — `xcrun simctl io booted screenshot` or `adb exec-out screencap`
2. **Accessibility trees** — `xcrun simctl ui` or `adb shell uiautomator dump`

Both are what LLMs are trained on. Both are slow, noisy, and lossy. A screenshot tells
the agent roughly what's on screen; an accessibility dump tells it roughly what widgets
exist. Neither tells it what state the BEAM is in, what data is driving the render, or
what the navigation stack looks like.

Mob apps are different. The UI is driven by a GenServer running on an Erlang node — and
that node is reachable from your dev machine over Erlang distribution. You can query
exact state, not infer it from pixels.

**The agent should connect to the running Erlang node and ask it directly.**

### Where an app's agent finds the docs

An agent working on a Mob **app** (not on Mob itself) should read, in this order:

1. `deps/mob/usage-rules.md`: the short rules (screens, async loading, lists,
   navigation, testing), each naming its guide.
2. `deps/mob/guides/*.md`: every guide, for exactly the mob version in
   `mix.lock`. Both ship in the Hex package from mob 0.9.17 on.
3. https://hexdocs.pm/mob/llms.txt: the index of guides and modules; every
   page is also served as Markdown (`https://hexdocs.pm/mob/<page>.md`).
   `mix hex.docs fetch mob` gives an offline copy.
4. Module docs from the running code: IEx `h Mob.Socket.start_async`.

Agents that know Phoenix LiveView get the fastest start from
[Coming from Phoenix LiveView](coming_from_liveview.md).

### Priming the agent

Before the MCP tools and tunnels, give the agent the mental model of the
project. Each Mob repo has an `AGENTS.md` at its root — an
orientation covering what's where, how to drive a running app, and the
pre-empt-failure rules that come from this team's hard-earned lessons. The
file is the standard cross-tool entry point (Cursor, Codex, Aider all read
it; Claude Code reads it via the `CLAUDE.md` reference).

When working on Mob itself, point your agent at the `AGENTS.md` of the repo it's working in:

- **[`mob/AGENTS.md`](https://github.com/GenericJam/mob/blob/master/AGENTS.md)** —
  runtime library. The "what is Mob", three-repo topology, and the full
  "driving apps from your session" reference (Mob.Test, MCP fallbacks,
  round-trip workflow).
- **[`mob_dev/AGENTS.md`](https://github.com/GenericJam/mob_dev/blob/master/AGENTS.md)** —
  build/deploy/devices toolkit. TDD policy and the public-but-undocumented
  testing seams.
- **[`mob_new/AGENTS.md`](https://github.com/GenericJam/mob_new/blob/master/AGENTS.md)** —
  project generator. Template gotchas and the LiveView phoenix-owned-files
  blocklist.

For multi-repo work, prime with all three. The root `mob/AGENTS.md` is the
"system view" — the other two link back to it for cross-cutting context.

**These docs go stale fast** if the project moves and they don't. The
top-of-file note in each `AGENTS.md` instructs the agent to update them in
the same commit as any change that contradicts the guidance — keeping it
up to date is a contract, not a suggestion.

### Setting up the MCP tools

The Layer 2 visual tools require two MCP servers to be installed and registered with
your AI agent.

#### ios-simulator-mcp

Interacts with the iOS Simulator from outside the app: screenshots, taps, text input,
accessibility tree queries.

```bash
npm install -g ios-simulator-mcp
```

GitHub: https://github.com/joshuayoes/ios-simulator-mcp

Add to your Claude Code MCP config (`~/.claude.json`, under `mcpServers`):

```json
"ios-simulator": {
  "type": "stdio",
  "command": "ios-simulator-mcp",
  "args": [],
  "env": {}
}
```

#### adb-mcp

Provides ADB-backed tools for Android: screenshots, UI dumps, shell access, logcat.

```bash
npm install -g adb-mcp
```

GitHub: https://github.com/srmorete/adb-mcp

> **Note:** The npm package is marked deprecated but remains functional. It is the
> current recommended option until a maintained alternative stabilises.

Add to `~/.claude.json`:

```json
"adb": {
  "type": "stdio",
  "command": "npx",
  "args": ["adb-mcp"],
  "env": {}
}
```

#### Verifying the setup

After adding both servers, restart Claude Code and check that the tools are available.
In a conversation, the `mcp__ios-simulator__screenshot` and `mcp__adb__dump_image`
tools should appear in the tool list. You can also ask the agent: *"List the MCP tools
available to you"* — it should enumerate both server namespaces.

---

### Prerequisites

Before an agent can inspect the running app, the tunnels must be up and the app
registered in the Mac's EPMD:

```bash
mix mob.connect --no-iex               # restarts the app, prints node names, exits
mix mob.connect --no-iex --no-restart  # attaches to the app as it is, state intact
```

`mix mob.connect` sets up the adb/simctl tunnels, waits for each node, prints
its name and exits; the tunnels stay in place. By default it **restarts** the
app, which is what makes a fresh session reliable (the app registers in the
Mac's EPMD through the tunnels just set up). When the agent is there to
inspect a session that is already running (a bug reproduced by hand, state
you don't want to lose), pass `--no-restart`. That attaches only if the app
started while the tunnels were up; if it didn't, restart it. Add
`--device <serial or udid substring>` to target one device. Re-run after a
device reboot.

Node names (`<app>` is your OTP app name):
- Android:        `<app>_android_<serial stub>@127.0.0.1` after a deploy or
  `mix mob.connect` restart. A start from the launcher reuses that name and
  port: every Android deploy records them in the app's `mob_dist` file, which
  mob 0.9.6+ reads when the launch intent carries none. `--no-restart` also
  finds an app registered under the bare `<app>_android`.
- iOS simulator:  `<app>_ios_<first 8 hex of the udid>@127.0.0.1`
- iOS device:     `<app>_ios@<device ip>`

Don't hard-code a name or port: read the names `mix mob.connect --no-iex`
prints, or `epmd -names`. Each app's dist port is derived from the device
serial **and** the app name (mob_dev 0.7.5+), so two Mob apps on one device
no longer collide.

`Mob.Test` and every `:rpc.call` need a distributed caller with the app's
cookie. It is private per app: mob_dev generates it under `~/.mob/dist_cookies/`
and hands it to the app at deploy/connect time. Load it inside the VM, from
the project directory, so it never shows up in the process arguments. From a
shell, one-shot:

```bash
elixir --name agent_$$@127.0.0.1 -S mix run --no-start -e '
Node.set_cookie(MobDev.DistCookie.for_project!())
IO.inspect Mob.Test.screen(:"my_app_ios_1a2b3c4d@127.0.0.1")'
```

An app built against mob before MOB-49 still answers only to the old public
`mob_secret`; mob_dev's own tasks fall back to it with a warning. Update the
`mob` dependency and run `mix mob.deploy` (`--native` for iOS): deploy restarts
an app on the legacy cookie, so it comes back on the private one.

A host node name already in use isn't fatal for the mob_dev tasks: `mix
mob.connect`, `mix mob.deploy` and `mix mob.watch` fall back to
`mob_dev_<os pid>@127.0.0.1` when `mob_dev@127.0.0.1` is taken, so an agent's
session and yours can run side by side.

### The three-layer inspection stack

Use these in order. Only go deeper if the layer above doesn't answer your question.

#### Layer 1 — Erlang distribution (always try this first)

`Mob.Test` gives the agent exact knowledge of what's happening inside the running app.
No image parsing, no heuristics, no guessing.

```elixir
node = :"mob_demo_ios_1a2b3c4d@127.0.0.1"   # as printed by mix mob.connect --no-iex

Mob.Test.screen(node)
#=> MobDemo.CounterScreen

Mob.Test.assigns(node)
#=> %{count: 3, safe_area: %{top: 62.0, bottom: 34.0, left: 0.0, right: 0.0}}

Mob.Test.find(node, "Increment")
#=> [{[0, 1], %{"type" => "button", "on_tap_tag" => "increment"}}]

Mob.Test.tap(node, :increment)
#=> :ok

Mob.Test.inspect(node)
#=> %{screen: MobDemo.CounterScreen, assigns: %{count: 4}, nav_history: [], tree: ...}
```

This is available from `iex --name me@127.0.0.1 -S mix` after
`Node.set_cookie(MobDev.DistCookie.for_project!())` (once
`mix mob.connect` has set up the tunnels), from `mix mob.connect`'s own IEx
session, or from an agent that can run shell commands with the one-shot
`elixir --name … -S mix run --no-start -e …` form under Prerequisites. A plain
`iex -S mix` is not distributed, so every call answers `{:badrpc, :nodedown}`.

**Ask what this build can be probed with, before committing to an approach.**

Which probes work is a runtime fact, not a property of the platform. On Android
most harness NIFs return `{:error, :not_loaded}` when the app's generated
`MobBridge.kt` lacks the matching method, and that file is generated once and
never re-rendered, so apps drift as the template moves. On iOS the harness is
compiled out of release builds.

```elixir
Mob.Test.capabilities(node)
#=> %{
#=>   dist_rpc: true,
#=>   view_tree: false,      ui_tree: false,        screen_info: true,
#=>   tap_xy: false,         tap_by_label: false,   long_press_xy: false,
#=>   swipe_xy: false,       type_text: false,      delete_backward: false,
#=>   clear_text: false,     ax_action: false,      element_frames: true,
#=>   scroll_info: true,     scroll_to: true,       sample_region: false,
#=>   screenshot: true,      native_stats: false
#=> }
```

That is an Android app generated **before `mob_new` 0.4.32** — abridged only in
layout, not in content; every one of the eighteen keys is shown, because
guessing at the rest is exactly what goes wrong. That template defined
`screenInfo`, `elementFrames`, `screenshot`, `scrollInfo` and `scrollTo`, and
nothing else in the harness set.

Regenerating against 0.4.32 or newer flips `tap_xy`, `long_press_xy`,
`swipe_xy`, `type_text` and `delete_backward` to `true` (MOB-160) and
`native_stats` to `true` (MOB-146); 0.4.33 or newer also flips `view_tree`
(MOB-157: the Android bridge walks the Mob node tree and emits the same
eight-key shape iOS does, with `frame` only on nodes that carry an `:id`). `clear_text` stays `false` there on
purpose — two implementations of it reported success while clearing nothing,
so the bridge ships without one rather than lie. Which is the point of asking
the build instead of reading a table: this paragraph is already a snapshot of
two releases, and `capabilities/1` is not.

Two of those `false`s bite harder than they look:

* `sample_region: false` means `Mob.Test.sample_color/2` is unavailable — there
  is no Android NIF for it at all, so the call **raises** rather than returning
  an error tuple. `screenshot: true` sitting next to it is not a substitute.
* `tap_by_label: false` removes the documented fallback for `tap_xy`, so this
  build has no synthetic input of any kind.

`Mob.Test.tap/2` still works: it delivers the same `{:tap, tag}` message a
native tap produces straight to the screen process over dist, never touching
the bridge. It is fire-and-forget — `:ok` whether or not a screen matched — so
assert the state change, per *The honesty contract* above.

**When there is no synthetic input, that is your cue to drop to Layer 2**: drive
the UI with `mcp__adb__*` below and keep `Mob.Test` for reading state.

Four answers, and three of them are not "the app is fine":

| Result | Means |
|--------|-------|
| probes true/false, `dist_rpc: true` | the real answer |
| all `:unknown`, `dist_rpc: true` | app predates `capabilities/0` (added 0.7.40) — upgrade `mob` rather than guessing |
| all `false`, `dist_rpc: true` | `load_nif` failed on the device: every NIF is down, and the fix is a native rebuild, not the bridge |
| all `false`, `dist_rpc: false` | nothing answered. An iOS **release** build reports exactly this by default because mob drops its development `-name` and EPMD. An app can explicitly own distribution through `Mob.InitArgs`, so check the app's launch arguments as well as the node name and tunnel |

`capabilities/2` takes a timeout, defaulting to 5s. That matters here because
this is the first call an agent makes, and a wedged-but-reachable device would
otherwise hang it indefinitely.

#### Layer 1, continued — what happened, not just what is

Everything above answers "what is the app showing now". Since mob 0.8 the app
can also answer "what did my action do", "is the framework healthy", "what
crashed while nobody was looking", "does the other platform agree", and "how
long did that take". All of it is read over the same distribution link, and
none of it needs a screenshot.

**Receipts: which layer is answerable.** Every action gets an `action_id`,
and the screen records the stages the action reached — dispatched, handled
(or unhandled), assigns changed, navigation requested, frame changed,
committed. The first stage it fails to reach names the layer to look at, so
"the tap did nothing" becomes "the handler ran and changed `:count`, and the
tree did not change", which points at a `render/1` that never reads `:count`.

An action is a `Mob.Screen.dispatch/3` (`handle_event/3`) **or a discrete
native input** — a real tap, a text change, a submit, a list-row select —
which reaches the screen's `handle_info/2`. `Mob.Test.tap/2` and
`Mob.Test.select/3` send exactly what the finger would, so they get the same
receipt:

```elixir
Mob.Test.tap(node, :increment)
Mob.Test.settle(node)

:rpc.call(node, Mob.Agent.Receipts, :recent, [1])
#=> [%Mob.Agent.Receipt{event: {:tap, #Mob.Event.Address<MyApp.CounterScreen→button#increment@1>},
#=>                     screen: MyApp.CounterScreen,
#=>                     handler: {MyApp.CounterScreen, :handle_info, 2},
#=>                     stages: [:dispatched, :handled, :assigns_changed],
#=>                     error: nil, elapsed_us: 412, ...}]

[receipt] = :rpc.call(node, Mob.Agent.Receipts, :recent, [1])
Mob.Agent.Receipt.owner(receipt)   #=> :render_function
```

The receipt records *which* stages were reached, not which keys changed:
`:assigns_changed` means the assigns map differed. `Mob.Agent.Receipt.owner/1`
turns the stage list into the layer answerable, and `effect/1` into a
one-word verdict. A `handle_info/2` has no "no clause matched" — screens keep
a catch-all — so a tap the screen ignores reads `:inert`, not `:unhandled`.

A tap on a screen that has **died** — its handler crashed, `Mob.Router`
restarted it under a new pid, and native is still showing the old tree —
reaches no handler. It is not redirected to the replacement; its receipt has
the single stage `:undeliverable` (`effect/1` → `:undeliverable`, `owner/1` →
`:event_routing`, `screen: nil`), and
`Mob.Diag.health().listener.undeliverable` counts every such event.

Display-rate streams — scroll, drag, pinch, a slider drag — get no receipt:
the store keeps 256, and one scroll would evict the tap you are about to ask
about. `Mob.Event.Trace` shows them (see `guides/events.md`).

`recent/1` lists the newest, `fetch/1` retrieves one by id, and `count/0` /
`dropped/0` tell a missing receipt apart from an id that never existed (the
store is bounded at 256). The stages are observed by the screen's own
before/after comparison, so a handler cannot claim an effect it did not have.
Receipts carry the input's address (for a dispatch, the event name) and a
reduced crash — never the assigns, and never an input's payload, so what the
user typed into a field stays out. See `Mob.Agent.Receipt` and
`Mob.Event.NativeInput`.

**Invariants: the framework checking itself.** `Mob.Invariant` runs checks an
application cannot make — a live component under a dead owning screen, a dead
screen still in the navigation stack — at sampling points such as screen
teardown, and only records a violation that is still there at the next sample
and at least 50 ms old, so a screen mid-teardown does not read as a leak.

```elixir
:rpc.call(node, Mob.Invariant, :violations, [])
#=> []                          # or [%Mob.Invariant.Violation{...}, ...]
:rpc.call(node, Mob.Invariant, :cost_us, [:on_screen_stop])
```

**The defect bus: defects as data.** Confirmed invariant violations,
cross-platform divergences and post-mortems become `Mob.Defect.Capsule`s on
`Mob.Defect.Bus`: fingerprinted (so one class groups across devices and
releases), deduplicated, with bounded, redaction-tagged evidence.

```elixir
:rpc.call(node, Mob.Defect.Bus, :classes, [])          # every class held, with counts
:rpc.call(node, Mob.Defect.Bus, :recent, [])           # the newest capsules
:rpc.call(node, Mob.Defect.Bus, :subscribe, [self()])  # push each new capsule to this shell
```

Pass `self()` when subscribing over `:rpc`: the call runs in a short-lived
process on the device, and subscribing that process delivers to nobody.

If the connection to the device drops (over `adb` the device cannot dial back,
so it stays down until your shell reconnects), the subscription is parked, not
lost: once `Node.connect/1` or any `:rpc.call` re-establishes it, delivery
resumes without subscribing again. Capsules emitted while disconnected are not
replayed; read them with `:recent`. A shell that stays away for 10 minutes
(`config :mob, :subscriber_park_ms`) is dropped. `Mob.Diag.health/0` counts
parked subscribers under `subscribers.parked`.

`Mob.Defect.Sinks.Dev` logs every capsule at a severity-driven level if you
start it; mob owns the format and the bus, never the destination.

**Are the diagnostics themselves working?** An empty answer from any of the
above is only evidence if the store behind it is healthy. `Mob.Diag.health/0`
says, per store, who holds its tables, how many writes were `lost`, and how
often it was `reset` (everything recorded before a reset is gone):

```elixir
:rpc.call(node, Mob.Diag, :health, [])
```

A non-zero `lost` or `resets` means the store's answers are incomplete. An
`owner` that stays `nil` while its tables are `held_by: :heir` means the owner
died and was not restarted. Either the restart failed (the log says why), or,
when `framework_vsn` shows a `current` that differs from `expected`, the owner
died under an older `mob` and nothing has written to the store since. In that
second case the store's next write brings the owner back. Either way, until an
owner holds the tables again its rows are kept, but they are lost if the heir
dies too.

**Post-mortems: what died while nobody was looking.** `Mob.PostMortem.sweep/0`
picks up the evidence the OS and the BEAM leave behind and puts it on the bus:
`erl_crash.dump` files (`:beam_crash`, with the normalised slogan as the
fingerprint), iOS MetricKit crash, hang and CPU/disk diagnostics, and
Android's `ApplicationExitInfo` history (crashes, ANRs, OOM kills). The OS
hands a MetricKit payload or an exit over once, so mob journals it and every
sweep, across boots, emits it again until that capsule has been observed:
handed to a `Mob.Defect.Bus` subscriber when it was emitted, or returned by
`Mob.Defect.Bus.recent/1`. Subscribing afterwards, or listing `classes/1`, does
not count. An app restart before you attached (`mix mob.connect` does one) no
longer loses it: the new boot's sweep emits it again, and
`:rpc.call(node, Mob.Defect.Bus, :recent, [])` shows it (a sweep that already
ran this boot emits nothing new). Nothing runs automatically; call it from
`on_start/0` or from your session after a launch you did not watch.

```elixir
:rpc.call(node, Mob.PostMortem, :sweep, [])
#=> [%Mob.Defect.Capsule{kind: :native_crash, severity: :fatal, ...}]
```

**Differential: does the other platform agree?** `Mob.Differential.compare/3`
takes an iOS and an Android `view_tree/1` and returns `:ok` or the first
divergence (structure, label, value, and frames within a dp tolerance where
both sides carry one), or `{:error, :not_ready}` when either snapshot is not
a tree yet (no window, or a `view_tree/1` error): a harness gap, not a
framework defect. `MobDev.Differential.run/3` in mob_dev samples both
live devices and feeds the pair through it. A divergence is the framework
failing its own one-design-both-platforms promise, and it lands on the bus
too.

**Render timing: measure before optimising.** `Mob.RenderStats` times the
BEAM half of every frame by stage (`enable/0`, `summary/0`) and, with
`native_enable/0` / `native_summary/0`, the native apply on both platforms,
which is additionally split by transition so a steady-state re-render is
not pooled with a push.
It is a before-and-after tool for one platform, not a cross-platform
comparison.

**Proving the push landed.** `mix mob.attest` compares each module's
`module_info(:md5)` on the device with the local `.beam`, so a push that never
landed, landed in the wrong container, or landed and was never loaded all
show up — and it exits non-zero when the check itself could not run.
`mix mob.deploy --json` gives an orchestrator one machine-readable document
naming the deployed, failed and skipped devices. `mix mob.mutate` breaks the
lines a branch changed one at a time and reports what no test noticed;
`mix mob.flake` (in mob itself) runs the suite repeatedly to surface tests
that are not deterministic. Three ways to learn that a green run proved less
than it looked.

#### Layer 2 — MCP platform tools (for rendering and layout)

When the question is visual — "does this text overflow?", "is the button in the right
position?", "did the animation play?" — use the platform MCP servers.

These are available as tools in Claude Code:

**iOS Simulator** (`mcp__ios-simulator__*`):

| Tool | Use for |
|------|---------|
| `screenshot` | Visual confirmation of layout and styling |
| `ui_tap` | Tap at specific screen coordinates |
| `ui_type` | Enter text into a focused field |
| `ui_swipe` | Swipe gestures |
| `ui_view` | Accessibility tree — widget hierarchy |
| `ui_describe_point` | What is at these coordinates? |
| `ui_describe_all` | Full accessibility dump |
| `record_video` / `stop_recording` | Capture an interaction sequence |

**Android** (`mcp__adb__*`):

| Tool | Use for |
|------|---------|
| `dump_image` | Screenshot from emulator or connected device |
| `inspect_ui` | XML accessibility dump |
| `adb_shell` | Run shell commands on device |
| `adb_logcat` | Tail device logs (Elixir output appears under the `Elixir` tag) |

#### Layer 3 — Raw platform tools (almost never needed)

`xcrun simctl`, raw `adb shell`, Xcode Instruments. These are what agents reach for
by default — resist it. They give you less information than Layer 1 and are slower
than Layer 2. The only reason to drop here is if the MCP servers aren't configured
or a specific low-level query has no higher-level equivalent.

### The standard agent loop

```
1. Edit Elixir source
2. mix mob.push                      ← hot-load changed BEAMs (no restart, state kept)
3. mix mob.attest                    ← prove the device runs the code you pushed
4. Mob.Test.screen(node)             ← confirm which screen is active
5. Mob.Test.assigns(node)            ← confirm data state is what you expect
6. Mob.Test.tap(node, :some_tag)     ← drive an interaction
7. Mob.Test.settle(node)             ← wait for the frame to commit…
8. Mob.Test.assigns(node)            ← …then confirm state updated
9. Mob.Agent.Receipts.recent(1)      ← if it did not: which stage did the action reach?
10. mcp__ios-simulator__screenshot   ← only if layout matters
11. repeat from 1
```

`tap/2` is fire-and-forget, and rendering is committed asynchronously by
`Mob.Sender` — so before reading anything on the *native* side (screenshots,
`view_tree/1`, `element_frames/1`, `tap_id/2`), call `Mob.Test.settle(node)`.
Reading `assigns/1` or `tree/1` doesn't need it.

For changes that touch native code (NIFs, Swift, Kotlin):

```
1. Edit source
2. mix mob.deploy --native           ← full rebuild + install + restart
3. mix mob.connect --no-iex --no-restart  ← attach to the app the deploy just started
4. continue with loop above
```

### Verify effects, not exit codes

Build and deploy tooling can exit 0 without doing what you meant: a device id
that matched nothing, a toolchain half-installed, a deploy that quietly went to
a different simulator. An exit code proves the tool ran; it does not prove the
app changed. After any deploy, assert the effect before proceeding:

```
# Wrong approach
mix mob.deploy && echo "deployed"    # exit 0 — but to what?

# The Mob approach — prove the app is up and answering
mix mob.deploy --device <id>
mix mob.connect --no-iex --no-restart   # prints the node name; keeps the app as deployed
```

```elixir
node = :"mob_demo_ios_1a2b3c4d@127.0.0.1"   # the name mob.connect printed
Mob.Test.screen(node)
#=> MobDemo.HomeScreen        ← the app exists, the node connects, a screen is live
# {:badrpc, :nodedown} here means the deploy did NOT land — stop and find out why
```

For a code push, prove the code changed. `mix mob.attest` does it by
checksum — the device's `module_info(:md5)` against the local `.beam`, for
exactly the set `mix mob.deploy` pushes — and exits non-zero on a mismatch or
when the check could not run at all. Failing that, bump something observable
(a version assign, a log line) and read it back through `Mob.Test.assigns/1`
before trusting any further conclusions.

Read the deploy summary as data too: it says per device whether the app was
hot-loaded over dist (`Hot-loaded into the running app — not restarted`, the
same pid and state) or pushed and restarted (`Apps restarted`). A physical
iPhone deserves one more check: `mix mob.deploy` can report "Apps restarted"
over a process iOS killed at launch. An empty `Documents/beam_stdout.log` in
the app container, or a fresh `.ips` from
`xcrun devicectl device copy from --domain-type systemCrashLogs`, is the tell
(MOB-199 was found this way).

### The honesty contract

Success means **a handler ran**, not that the call returned `:ok`.
`Mob.Test.tap/2` returns `:ok` whether or not any screen matched the tag —
it's a fire-and-forget message send. The only honest assertion is a state
change:

```elixir
before = Mob.Test.assigns(node).count
Mob.Test.tap(node, :increment)
Mob.Test.settle(node)
assert Mob.Test.assigns(node).count == before + 1
```

If the state didn't change, the tap didn't reach a handler that acted on it —
wrong tag, a `handle_info/2` clause that doesn't match, or a stale handle. That
is a first-class diagnostic signal, not a flake to retry — and the receipt for
the action (`Mob.Agent.Receipts.recent/1`) says which stage it stopped at, so
the next question is never a guess: `:inert` for a tag no clause acted on,
`:undeliverable` for a real tap on a screen that had died and been replaced.

Coordinate driving is held to the same contract by the framework itself:
`Mob.Test.tap_xy/3` (and `tap_id/2`, which inherits its contract) returns
`:ok` only when **the app reacted** — an event reached the BEAM within 300 ms
of the tap. Everything else is an honest error, never a "probably worked":

- `{:error, :no_view_at_point}` — hit-test found nothing at that coordinate
- `{:error, :no_element_at_point}` — iOS simulator: a view is there but no
  accessibility element to activate
- `{:error, :no_effect}` — the OS accepted the input but no handler ran

Read `Mob.Test.tap_xy/3` before treating a non-`:ok` as a test failure: a
SwiftUI `Box`/`Row`/`Column` with `on_tap:` has no activate action on the
simulator, and on a physical iOS device coordinate injection currently
delivers no touch at all — both legitimately report `{:error, :no_effect}`,
and `tap/2` (by tag) is the way to drive them.

One assumption to respect: effect detection is **process-wide**. Both the
state-change assertion and `tap_xy`'s 300 ms effect window count *any* Mob
event that reaches the BEAM — another agent, a timer, a scroll notification —
so concurrent activity can false-positive either check. The harness is assumed
serial: one synthetic interaction in flight at a time, and exactly one agent
driving a given device (see
[Working with agent teams](#working-with-agent-teams)).

### Match the evidence to the question

Each question has one cheapest sufficient source of evidence — collect that
one, not a screenshot of everything:

- **State** ("did the handler run?", "what's in the list?") —
  `Mob.Test.assigns/1`, `tree/1`. Never pixels.
- **Layout / geometry** ("is the button below the fold?", "do these
  overlap?") — `Mob.Test.element_frames/1` and `frame/2` give exact
  `{x, y, w, h}` per `:id`, no screenshot required. `scroll_info/2` for
  scroll positions.
- **Exact color** ("is this Box actually `:primary`?", "did the theme drop
  the background?") — `Mob.Test.sample_color/2`: real rendered pixels for one
  element's frame (or an explicit rect), reduced to
  `%{average:, dominant:, dominant_share:, ...}` as `0xAARRGGBB` integers.
  Assert on `:dominant` for flat fills, `:average` for gradients/glass, and
  compare regions against each other to catch a theme regression (two
  different tokens sampling identical is the bug). iOS-only and debug-build
  only — a release build deliberately ships no sampling probe.
- **Holistic appearance** ("does this screen look right?", "did the font
  apply?") — a screenshot (`Mob.Test.screenshot/2`), compared with tolerance.
  Pixel colors vary by device profile, scale and alpha compositing; treat
  exact equality across a whole screenshot as a bug in the test. For a
  single color *decision*, prefer `sample_color/2` above.
- **Transitions and animation** ("did the push slide?") — a still proves
  nothing about motion. Use the MCP `record_video` / `stop_recording`
  tools, or capture a timed sequence of `screenshot/2` frames and compare.
- **Human-facing evidence** ("show me it works") — screenshots and
  recordings. That's their real job; they're the *last* tool for deciding,
  and the first for demonstrating.

### Simulating lifecycle events

Cold-start and notification paths are drivable without a hand on the device.

For the **in-app half** — your `handle_info/2` clauses — stay in-process:

```elixir
Mob.Test.send_message(node, {:notification, %{id: "n1", title: "Hi", body: "Hello", data: %{}, source: :push, presentation: :tap, action: "default"}})
```

For the **OS half** — delivery while backgrounded, cold-start from a
notification tap — use the platform tools. iOS simulator, with a payload file:

```bash
cat > /tmp/note.apns <<'JSON'
{
  "Simulator Target Bundle": "com.example.mob_demo",
  "aps": { "alert": { "title": "Hi", "body": "Hello" } }
}
JSON
xcrun simctl push booted /tmp/note.apns
```

Android emulator, broadcast to the app's push receiver (or exercise the
notification shade itself):

```bash
adb shell am broadcast -p com.example.mob_demo -a com.google.android.c2dm.intent.RECEIVE
adb shell cmd notification post -S bigtext -t 'Hi' demo_tag 'Hello'
```

Cold start is the same idea: `xcrun simctl terminate booted <bundle>` then
`launch`, or `adb shell am force-stop <pkg>` then `am start`. After any
restart, re-run `mix mob.connect --no-iex` and re-verify the node answers
before drawing conclusions.

### Environment discipline

Agents dead-end on toolchain gaps a human shrugs off — a human notices the
`zig: command not found` buried in build output and installs it; an agent may
conclude the code is broken. Make the environment complete and declarative:

- **A complete `.tool-versions`.** Erlang and Elixir, plus everything the
  native builds need: Zig for the Android NIF build, a JDK for Gradle. If a
  tool is required to build, it belongs in the file — "it was on my PATH" is
  not reproducible for an agent.
- **The path-override chain for framework work.** To test a change to the
  framework itself end-to-end against a real app, point the app at your local
  checkouts instead of Hex: `MOB_DIR` / `MOB_DEV_DIR` (used by
  `mix mob.new --local` and the iOS build) and `MOB_NEW_DIR` (local project
  generator). See [Getting Started](getting_started.md) for the full env-var
  table.

### Steering the agent

LLMs have extensive training data on `xcrun simctl`, `adb`, UIKit, and Jetpack Compose
testing patterns. They will reach for that toolbox instinctively, especially when asked
to "verify" or "check" something visual.

You need to redirect this explicitly. Put something like the following in your project's
`CLAUDE.md`:

```markdown
## Inspecting the running app

This is a Mob app. The running app is an Erlang/OTP node. Do NOT use xcrun simctl
screenshots or adb screencap as your primary inspection method.

Instead:
1. Run `mix mob.connect --no-iex` to establish distribution tunnels and print the
   node names (it restarts the app; add `--no-restart` to keep a running session)
2. Use `Mob.Test` from a distributed IEx (`iex --name me@127.0.0.1 -S mix`, then
   `Node.set_cookie(MobDev.DistCookie.for_project!())`)
   to query exact state:
   - `Mob.Test.capabilities(node)` — ask FIRST: which probes does this build serve?
   - `Mob.Test.screen(node)` — what screen is active?
   - `Mob.Test.assigns(node)` — what is the live data?
   - `Mob.Test.tap(node, :tag)` — drive a tap by tag atom
   - `Mob.Test.find(node, "text")` — locate a widget by visible text
   - `Mob.Agent.Receipts.recent(1)` (via :rpc) — what the last action reached
3. Only reach for `mcp__ios-simulator__screenshot` or `mcp__adb__dump_image` when
   you need to verify rendering or layout — not to check app state.

Node names: use the ones `mix mob.connect --no-iex` prints (or `epmd -names`):
- Android:        <app>_android_<serial stub>@127.0.0.1
- iOS simulator:  <app>_ios_<8-char udid prefix>@127.0.0.1
```

### Why Mob.Test beats screenshots for state inspection

| | Mob.Test | Screenshot |
|---|---|---|
| Screen module | Exact atom | OCR guess |
| Assigns | Full Elixir map | Not available |
| Navigation stack | Exact list | Not available |
| Widget tree | Structured map | Inferred from pixels |
| Speed | Milliseconds | Seconds |
| Ambiguity | None | Font size, locale, DPI |
| Works in CI | Yes | Requires display |

Screenshots are for humans and for verifying that the visual output *looks right*.
They are not a substitute for inspecting what the program is actually doing.

### Worked example: debugging a counter that doesn't update

A common first instinct for an agent:

```
# Wrong approach
xcrun simctl io booted screenshot /tmp/before.png
# ... make change ...
xcrun simctl io booted screenshot /tmp/after.png
# "The screenshots look the same, the counter didn't change"
```

The Mob approach:

```bash
# Check what state the app is actually in
iex -S mix
```

```elixir
node = :"mob_demo_ios_1a2b3c4d@127.0.0.1"

# Before
Mob.Test.assigns(node)
#=> %{count: 0}

Mob.Test.tap(node, :increment)

# After — immediate, exact
Mob.Test.assigns(node)
#=> %{count: 1}

# If it's still 0, the handle_info clause isn't matching — check the tag name
Mob.Test.find(node, "Increment")
#=> [{[0, 1], %{"type" => "button", "on_tap_tag" => "inc"}}]
# Ah — the tag is :inc, not :increment
```

The distribution layer tells you exactly what happened and why. No image comparison,
no inference.

### Quick reference: on_tap tags

Tags come from `on_tap: {self(), :tag_atom}` in the render tree. To see all widgets
and their tags on the current screen, use the full snapshot:

```elixir
node = :"mob_demo_ios_1a2b3c4d@127.0.0.1"
Mob.Test.inspect(node)
# %{screen: ..., assigns: ..., tree: %{"type" => "column", "children" => [...]}}
```

Or just read the screen's `render/1` function — every interactive widget has a tag
in its props. The tag atom in `on_tap: {self(), :my_tag}` is what you pass to
`Mob.Test.tap(node, :my_tag)`.

## Working with agent teams

Everything above assumes one agent, one app, one loop. This half is about
fleets — multiple agents (or one orchestrator with subagents) working the same
codebase and the same devices. It builds on Part 1's loop; the loop itself
doesn't change, but who may run it against what does.

### One driver per device

Erlang distribution happily lets *many* host nodes attach to one running app —
inspection is cheap and concurrent. Driving is not. The honesty contract's
effect detection is process-wide: "assigns changed after my tap" is only
evidence if yours was the only tap. Two agents driving one device produce
false effect signals for both, in both directions.

So serialize UI driving per device:

- **Exactly one agent drives a given device at a time.** Read-only inspection
  (`assigns/1`, `tree/1`, `screenshot/2`) from others is fine; taps,
  navigation, and `send_message/2` are not.
- **Use a lease.** A claim file, a lock, an orchestrator-assigned slot —
  the mechanism matters less than the rule: acquire before driving, release
  when done, and put the device id in the lease so it's auditable.
- **Humans outrank agents on physical hardware.** A person holding the phone
  wins; agents fall back to simulators/emulators or wait for the lease.

### Unique node names per agent session

Every `mix mob.connect` session names its local node — the default is
`mob_dev@127.0.0.1`, and two sessions with the same name cannot both register
with EPMD. Give each agent session its own name:

```bash
mix mob.connect --no-iex --name agent_a@127.0.0.1
mix mob.connect --no-iex --name agent_b@127.0.0.1
```

This also makes `Node.list/0` on the device an audit trail: you can see who is
attached.

### Per-task git worktrees

Agents should never share a working tree — with each other, or with a human's
primary checkout. A half-finished edit in a shared tree becomes another
agent's mysterious compile error. `git worktree add ../worktrees/<task> -b
<branch> origin/master` gives each task an isolated tree on its own branch for
the cost of a checkout; clean it up when the branch merges.

### Hot-push fan-out: a single-developer convenience

`mix mob.push` (and `mix mob.watch`) connect to **every** running node of the
app they can find and push changed modules to all of them — there is no
per-device scoping flag. For one developer with one device, that's the point.
With a fleet attached, it's cross-contamination: one agent's probe module
lands on physical devices and on other agents' targets. (In-memory only —
a restart clears it — but the other agents' evidence is now polluted.)

Fleet rule: treat `mob.push`/`mob.watch` as single-developer conveniences.
Agents in a fleet deploy per device with `mix mob.deploy --device <id>` (over a
live dist connection that is a hot load: the app keeps its pid and state and
the BEAMs are also persisted for its next launch; otherwise it pushes and
restarts), or hot-push over their own distribution connection (`nl/1` from
their named session pushes only to the nodes *that session* is connected to).
Read the
result as data — `mix mob.deploy --json` names the deployed, failed and
skipped devices — and attest per node (`mix mob.attest --node <name>`)
before reporting that anything landed.

### Durable artifacts outlive the context window

An agent's context ends; the next agent starts cold. Anything discovered but
not written down is re-discovered at full price — or worse, contradicted.
Conclusions belong where the next agent (or human) will find them:

- **PR comments and descriptions** for "why this change, what was tried".
- **Decision records** (this repo's `decisions/`) for anything the next
  change must not accidentally undo.
- **Committed findings** — a failing test reproducing a bug is worth more
  than a paragraph describing it.

The handoff medium between agents is the repository, not the conversation.
