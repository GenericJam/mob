# Agentic coding with Mob

AI coding assistants work best when they can close the loop themselves: make a change,
verify it worked, decide what to do next. This guide explains how to give an agent the
full context it needs to work effectively on a Mob app — and why the default approach
most agents reach for will give you worse results.

## The context problem

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

## Priming the agent

Before the MCP tools and tunnels, give the agent the mental model of the
project. Each Mob repo has an `AGENTS.md` at its root — a five-minute
orientation covering what's where, how to drive a running app, and the
pre-empt-failure rules that come from this team's hard-earned lessons. The
file is the standard cross-tool entry point (Cursor, Codex, Aider all read
it; Claude Code reads it via the `CLAUDE.md` reference).

Point your agent at the relevant `AGENTS.md` for the repo it's working in:

- **[`mob/AGENTS.md`](https://github.com/GenericJam/mob/blob/main/AGENTS.md)** —
  runtime library. The "what is Mob", three-repo topology, and the full
  "driving apps from your session" reference (Mob.Test, MCP fallbacks,
  round-trip workflow).
- **[`mob_dev/AGENTS.md`](https://github.com/GenericJam/mob_dev/blob/main/AGENTS.md)** —
  build/deploy/devices toolkit. TDD policy and the public-but-undocumented
  testing seams.
- **[`mob_new/AGENTS.md`](https://github.com/GenericJam/mob_new/blob/main/AGENTS.md)** —
  project generator. Template gotchas and the LiveView phoenix-owned-files
  blocklist.

For multi-repo work, prime with all three. The root `mob/AGENTS.md` is the
"system view" — the other two link back to it for cross-cutting context.

The files are deliberately short (≤ 200 lines) so agents read them in full
rather than skimming — that's the difference between a session where the
agent already knows your conventions and one where it stumbles into them.
**These docs go stale fast** if the project moves and they don't. The
top-of-file note in each `AGENTS.md` instructs the agent to update them in
the same commit as any change that contradicts the guidance — keeping it
up to date is a contract, not a suggestion.

## Setting up the MCP tools

The Layer 2 visual tools require two MCP servers to be installed and registered with
your AI agent.

### ios-simulator-mcp

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

### adb-mcp

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

### Verifying the setup

After adding both servers, restart Claude Code and check that the tools are available.
In a conversation, the `mcp__ios-simulator__screenshot` and `mcp__adb__dump_image`
tools should appear in the tool list. You can also ask the agent: *"List the MCP tools
available to you"* — it should enumerate both server namespaces.

---

## Prerequisites

Before an agent can inspect the running app, tunnels must be established:

```bash
mix mob.connect --no-iex
```

This sets up the adb/simctl tunnels and prints node names, then exits — leaving the
distribution network open. Keep this running in a terminal while you're working with
an agent. Re-run it after a device restart or if `mix mob.push` loses contact.

Node names:
- iOS simulator:     `mob_demo_ios@127.0.0.1`
- Android emulator:  `mob_demo_android@127.0.0.1`

## The three-layer inspection stack

Use these in order. Only go deeper if the layer above doesn't answer your question.

### Layer 1 — Erlang distribution (always try this first)

`Mob.Test` gives the agent exact knowledge of what's happening inside the running app.
No image parsing, no heuristics, no guessing.

```elixir
node = :"mob_demo_ios@127.0.0.1"

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

This is available via `iex -S mix` (after `mix mob.connect` has set up the tunnels)
or directly from an agent that can run shell commands, using:

```bash
iex -S mix --eval 'IO.inspect Mob.Test.assigns(:"mob_demo_ios@127.0.0.1")'
```

### Layer 2 — MCP platform tools (for rendering and layout)

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

### Layer 3 — Raw platform tools (almost never needed)

`xcrun simctl`, raw `adb shell`, Xcode Instruments. These are what agents reach for
by default — resist it. They give you less information than Layer 1 and are slower
than Layer 2. The only reason to drop here is if the MCP servers aren't configured
or a specific low-level query has no higher-level equivalent.

## The standard agent loop

```
1. Edit Elixir source
2. mix mob.push                      ← push changed BEAMs (no restart needed)
3. Mob.Test.screen(node)             ← confirm which screen is active
4. Mob.Test.assigns(node)            ← confirm data state is what you expect
5. Mob.Test.tap(node, :some_tag)     ← drive an interaction
6. Mob.Test.assigns(node)            ← confirm state updated
7. mcp__ios-simulator__screenshot    ← visual check only if layout matters
8. repeat from 1
```

For changes that touch native code (NIFs, Swift, Kotlin):

```
1. Edit source
2. mix mob.deploy --native           ← full rebuild + install + restart
3. mix mob.connect --no-iex          ← re-establish tunnels after restart
4. continue with loop above
```

## Steering the agent

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
1. Run `mix mob.connect --no-iex` to establish distribution tunnels (if not already running)
2. Use `Mob.Test` from IEx to query exact state:
   - `Mob.Test.screen(node)` — what screen is active?
   - `Mob.Test.assigns(node)` — what is the live data?
   - `Mob.Test.tap(node, :tag)` — drive a tap by tag atom
   - `Mob.Test.find(node, "text")` — locate a widget by visible text
3. Only reach for `mcp__ios-simulator__screenshot` or `mcp__adb__dump_image` when
   you need to verify rendering or layout — not to check app state.

Node names:
- iOS simulator:    mob_demo_ios@127.0.0.1
- Android emulator: mob_demo_android@127.0.0.1
```

Replace `mob_demo` with your actual app name.

## Why Mob.Test beats screenshots for state inspection

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

## Worked example: debugging a counter that doesn't update

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
node = :"mob_demo_ios@127.0.0.1"

# Before
Mob.Test.assigns(node)
#=> %{count: 0}

Mob.Test.tap(node, :increment)

# After — immediate, exact
Mob.Test.assigns(node)
#=> %{count: 1}

# If it's still 0, the handle_event clause isn't matching — check the tag name
Mob.Test.find(node, "Increment")
#=> [{[0, 1], %{"type" => "button", "on_tap_tag" => "inc"}}]
# Ah — the tag is :inc, not :increment
```

The distribution layer tells you exactly what happened and why. No image comparison,
no inference.

## Quick reference: on_tap tags

Tags come from `on_tap: {self(), :tag_atom}` in the render tree. To see all widgets
and their tags on the current screen, use the full snapshot:

```elixir
node = :"mob_demo_ios@127.0.0.1"
Mob.Test.inspect(node)
# %{screen: ..., assigns: ..., tree: %{"type" => "column", "children" => [...]}}
```

Or just read the screen's `render/1` function — every interactive widget has a tag
in its props. The tag atom in `on_tap: {self(), :my_tag}` is what you pass to
`Mob.Test.tap(node, :my_tag)`.
