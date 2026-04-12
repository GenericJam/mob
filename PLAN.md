# Mob — Build Plan

> A mobile framework for Elixir that runs the BEAM on-device.
> Last updated: 2026-04-04

---

## Session Recovery

If this session is lost, key context:

- **POC lives at:** `~/code/beam-android-test/BeamHello` (Android) and `~/code/beam-ios-test` (iOS)
- **POC status:** Working end-to-end on Android emulator + real Moto G phone. Counter + 50-item scroll list with like buttons. Touch events round-trip through BEAM.
- **Architecture proven:** BEAM embedded in Android APK → NIFs make JNI calls → BeamUIBridge dispatches to UI thread via CountDownLatch → views created on UI thread, refs returned as Erlang resources.
- **Key bug fixed:** `enif_get_int` fails for ARGB values > 0x7FFFFFFF. Use `enif_get_long` for color params.
- **Boot times:** Moto G cold 984ms (Erlang + Elixir + 150 Views), emulator ~300ms warm.
- **mob library:** `~/code/mob` — Mix project, TDD
- **mob_demo:** `~/code/mob_demo` — Android app + Elixir screens that exercise the library

---

## Architecture Decision: NIF Model (not IPC)

The plan doc proposed JSON/ETF over stdin/stdout IPC. We are **not doing that**. The POC proves NIFs work better:

- Direct JNI calls from BEAM scheduler threads — no serialization, no extra processes
- UI thread dispatch via CountDownLatch gives synchronous semantics from Elixir's perspective
- Zero IPC overhead — function call, not message passing
- Already working in production on real hardware

**NIF layer (C):** `mob_nif.c` — the bridge. Compiled into the app `.so`. Calls `MobBridge.java` (Android) / SwiftUI state store (iOS).

**Elixir layer:** Pure Elixir. `Mob.Screen`, `Mob.Component`, `Mob.Socket` etc. Calls `:mob_nif` directly.

---

## Repository Layout

```
~/code/mob/                        # The library (this repo, Mix project)
├── lib/mob/
│   ├── screen.ex                  # Mob.Screen behaviour + __using__ macro
│   ├── component.ex               # Mob.Component behaviour + __using__ macro
│   ├── socket.ex                  # Mob.Socket struct + assign/2, assign/3
│   ├── renderer.ex                # Renders component tree → NIF calls
│   ├── registry.ex                # Maps component names → NIF constructors
│   └── node.ex                    # BEAM node config + startup helpers
├── lib/mob.ex                     # Top-level convenience API
├── test/mob/
│   ├── screen_test.exs
│   ├── component_test.exs
│   ├── socket_test.exs
│   ├── renderer_test.exs
│   └── registry_test.exs
├── PLAN.md                        # This file
└── mix.exs

~/code/mob_demo/                   # The demo Android app
├── lib/
│   ├── hello_screen.ex            # Iteration 1: static hello world
│   ├── counter_screen.ex          # Iteration 2: counter with state
│   ├── list_screen.ex             # Iteration 3: scroll + like buttons
│   ├── nav_screen.ex              # Iteration 4: multi-screen navigation
│   └── kitchen_sink_screen.ex    # Full component showcase
├── BeamHello/                     # Android Studio project
│   └── app/src/main/
│       ├── jni/
│       │   ├── mob_nif.c          # Renamed/refactored from android_nif.c
│       │   ├── beam_jni.c         # JNI entry points (unchanged)
│       │   ├── driver_tab_android.c
│       │   └── CMakeLists.txt
│       └── java/com/mob/demo/
│           ├── MainActivity.java
│           ├── MobBridge.java     # Renamed from BeamUIBridge
│           └── MobTapListener.java
└── PLAN.md                        # Demo-specific notes
```

---

## Iterative Build Plan

Each iteration has:
1. TDD tests in `mob/` written first
2. Implementation to pass tests
3. Demo screen in `mob_demo/` exercising the feature
4. Screenshot/logcat evidence it works on device

---

### Iteration 1 — Mob.Socket + Mob.Screen skeleton ✅ planned

**Goal:** Define the core data structures and behaviour contracts. Nothing renders yet — just the Elixir shape.

**TDD (mob/):**
- `Mob.Socket` struct: `%{assigns: %{}, __mob__: %{screen: module, platform: atom}}`
- `socket |> assign(:count, 0)` returns updated socket
- `socket |> assign(count: 0, name: "test")` bulk assign
- `Mob.Screen` behaviour defines: `mount/3`, `render/1`, `handle_event/3`, `handle_info/2`, `terminate/2`
- `use Mob.Screen` injects default implementations (all no-ops that raise if not overridden except `terminate`)

**Demo screen:** None yet — iteration is library-only.

---

### Iteration 2 — Mob.Registry + component tree ✅ planned

**Goal:** Component names → NIF calls. Mob.Registry maps `:column`, `:button`, etc. to platform-specific constructors. The renderer walks a component tree description and makes NIF calls.

**TDD (mob/):**
- `Mob.Registry.register(:column, android: :mob_nif, :create_column, [])`
- `Mob.Registry.lookup(:column, :android)` → `{:mob_nif, :create_column, []}`
- `Mob.Registry.lookup(:unknown, :android)` → `{:error, :not_found}`
- Renderer: given `%{type: :column, children: [...], props: %{}}`, calls NIF and returns view ref
- Renderer: given `%{type: :text, props: %{text: "hello"}}`, creates label and returns ref

**Demo screen:** None yet.

---

### Iteration 3 — Hello World screen on device ✅ planned

**Goal:** First end-to-end screen. `Mob.Screen` `mount/3` + `render/1` lifecycle drives a static "Hello, Mob!" on the real device.

**What changes in the Android project:**
- Rename `BeamUIBridge` → `MobBridge`, `BeamTapListener` → `MobTapListener`, `android_nif.c` → `mob_nif.c`
- `hello_world.erl` → calls `MobDemoApp` (Elixir) which starts `HelloScreen`
- `HelloScreen` uses `Mob.Screen`, renders a column with a text label

**TDD (mob/):**
- `HelloScreen.mount(%{}, %{}, socket)` → `{:ok, socket}`
- `HelloScreen.render(assigns)` → returns component tree map
- Renderer walks the tree and calls NIFs

**Demo screen:** `hello_screen.ex`
```elixir
defmodule HelloScreen do
  use Mob.Screen

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :greeting, "Hello, Mob!")}
  end

  # Sigil syntax (primary — familiar to LiveView developers)
  def render(assigns) do
    ~MOB"""
    <.column padding={16}>
      <.text size={24}>{@greeting}</.text>
    </.column>
    """
  end

  # Tuple syntax (alternative — composable, programmatic)
  # def render_data(assigns) do
  #   {:column, {:text, assigns.greeting, size: 24}, padding: 16}
  # end
end
```

---

### Iteration 3.5 — Battery benchmarking ⬜ first priority on resuming

**Goal:** Verify the BEAM is viable on a real Android phone before building further. Run the benchmark methodology described in the "Battery / Resource Benchmarking" section above. If untuned BEAM is bad, apply the scheduler flags and re-measure. Update the plan with findings.

**Success criteria:** Tuned BEAM idle battery drain is in the same order of magnitude as a comparable React Native or Flutter hello world app. Doesn't need to win — just needs to not be a dealbreaker.

**If it fails:** The scheduler tuning flags are the main lever. If `+sbwt none +S 1:1` doesn't get to acceptable numbers, investigate dirty scheduler configuration and process count. Escalate to a dedicated investigation before proceeding.

---

### Iteration 3.6 — iOS SwiftUI migration ⬜ next (iOS)

**Goal:** Replace the current UIKit/ObjC NIF layer with SwiftUI. HelloScreen already works on iOS via UIKit — this migrates it to SwiftUI and establishes the pattern for all future iOS work. UIKit implementation is thrown away after this; SwiftUI is the permanent iOS target.

**How it works:**

SwiftUI is declarative — you can't create views imperatively from C NIFs the way UIKit allows. Instead the NIF layer updates a Swift state store that SwiftUI observes:

```swift
class MobViewModel: ObservableObject {
    @Published var tree: [ComponentNode] = []
}

struct MobRootView: View {
    @ObservedObject var model: MobViewModel
    var body: some View { renderTree(model.tree) }
}
```

NIF calls update `model.tree` → SwiftUI diffs and re-renders. The Elixir side (`render/1`, component tree) is unchanged.

**Component definitions — `.swiftinterface` approach:**

Apple doesn't publish a standalone SwiftUI spec, but the full public API is machine-readable in the iOS SDK:
```
Xcode.app/…/iPhoneOS.sdk/…/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64-apple-ios.swiftinterface
```
Parse with SwiftSyntax to generate Swift structs for all SwiftUI views and modifiers. This is the same approach LiveView Native uses with their `ModifierGenerator` tool. Community archive of historical versions: [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs).

**What changes:**
- `mob/ios/mob_nif.m` — rewritten: NIFs update `MobViewModel` instead of creating UIView objects
- `mob/ios/mob_beam.m` — hosts `UIHostingController<MobRootView>` instead of a bare UIViewController
- `mob_demo/ios/AppDelegate.m` — sets root to `UIHostingController`
- `driver_tab_ios.c` — unchanged

**`--disable-jit` required for real iOS devices:**
iOS enforces W^X (write XOR execute) — apps cannot generate and execute new code at runtime without special entitlements. The BEAM's JIT writes native code to memory then executes it, which iOS blocks. Add `--disable-jit` to the OTP build flags for all real device targets. The iOS simulator runs on macOS which doesn't enforce W^X, so simulator builds can keep JIT enabled. Android is unaffected — JIT works fine there.

**What stays the same:**
- All Elixir code — `Mob.Screen`, `render/1`, component tree format, NIF function signatures
- Android — unaffected

---

### Iteration 3.7 — Render syntax (sigil + tuple) ⬜

**Goal:** Both render paths working. Primary audience is LiveView developers — sigil syntax is familiar and comfortable. Tuple syntax is available from day one as the composable alternative. Both funnel through the same normalization layer; maintenance burden is minimal.

**Architecture: one normalization layer, two entry points**

```
render/1      →  ~MOB sigil  ─┐
                               ├→  normalize/1  →  internal map tree  →  Renderer  →  NIFs
render_data/1 →  tuple tree  ─┘
```

The internal map format (`%{type:, props:, children:}`) is unchanged. `normalize/1` is ~20 lines and converts either format. The renderer never changes regardless of which syntax the developer uses.

**Sigil syntax (`render/1`) — primary, for LiveView developers:**

```elixir
def render(assigns) do
  ~MOB"""
  <.column padding={16}>
    <.text size={24}>{@greeting}</.text>
    <.button on_tap="increment">+</.button>
  </.column>
  """
end
```

Familiar to anyone who knows Phoenix/LiveView. Compiles to the tuple format at build time — no runtime overhead.

**Tuple syntax (`render_data/1`) — composable, programmatic:**

```elixir
def render_data(assigns) do
  {:column,
    [
      {:text, assigns.greeting, size: 24},
      {:button, "+", on_tap: "increment"}
    ],
    padding: 16}
end
```

Rules (per community feedback):
- 3-tuple `{tag, children, props}` or 2-tuple `{tag, children}`
- Props as keyword list, always last
- Bare string auto-promoted to `{:text, string}`
- Single child auto-promoted to list

**Prior art: JSX vs React.createElement**

This is the same tradeoff React/React Native solved. JSX compiles to `React.createElement` calls — the template syntax is sugar over the functional form:

```jsx
// JSX (template form)
<View style={styles.container}><Text>Hello</Text></View>

// Compiles to (functional form)
React.createElement(View, {style: styles.container},
  React.createElement(Text, null, "Hello"))
```

Experienced RN developers regularly drop to the functional form for programmatic composition — generating lists of elements, conditional trees, higher-order components. Both are idiomatic, both are first-class. Mob's `~MOB` sigil and tuple syntax are the same split.

**Why both from the start:**
- Sigil: easy onramp for LiveView and mobile developers — conventional understanding of how layouts work, familiar to anyone coming from Phoenix, RN, or Flutter
- Tuple: composable, functional form — standard Elixir tools (pattern matching, pipe, higher-order functions) work on the data structure directly, no macro magic. More natural for programmatic tree construction.
- Both: AI coding agents generate tuple trees reliably; sigil templates are familiar from docs and examples
- Zero extra maintenance: `normalize/1` is the only shared code; both paths test against the same internal format

**TDD:**
- `normalize({:column, {:text, "hello"}, padding: 16})` → correct map tree
- `normalize("bare string")` → `%{type: :text, props: %{text: "bare string"}, children: []}`
- `normalize({:button, "tap me"})` → map with empty props
- Sigil compiles to same output as equivalent tuple

---

### Iteration 4 — handle_event + counter screen ⬜ next (Android + iOS)

**Goal:** Touch events delivered to `handle_event/3`, state updates re-render the screen.

**TDD (mob/):**
- Event dispatch: `Mob.Screen.dispatch(pid, "increment", %{})` sends `{:mob_event, "increment", %{}}` to screen process
- `handle_event("increment", %{}, socket)` → `{:noreply, assign(socket, :count, socket.assigns.count + 1)}`
- After event, renderer diffs old tree vs new tree → only calls `set_text` NIF, not full rebuild

**Demo screen:** `counter_screen.ex` (mirrors existing DemoApp counter but via Mob.Screen lifecycle)

---

### Iteration 5 — Scroll list + lazy rendering ✅ planned

**Goal:** Scroll view with many items. Prove no performance cliff at 50, 200, 500 items.

**TDD (mob/):**
- `<.scroll>` component renders inner list via `:create_scroll` + child NIFs
- `<.lazy_list items={@items} key={:id}>` renders only visible items (future — just `scroll` for now)

**Demo screen:** `list_screen.ex` — 200-item list with toggleable like buttons. Measure scroll FPS.

---

### Iteration 6 — Navigation ✅ planned

**Goal:** Push/pop screens. Android back button handled.

**TDD (mob/):**
- `Mob.Router.push(CounterScreen)` → sends nav event to Android client
- `Mob.Router.pop()` → back
- Nav stack state in `Mob.Socket.__mob__.nav_stack`

**Demo screen:** `nav_screen.ex` — top-level screen with buttons that push counter and list screens.

---

### Iteration 7 — Full kitchen sink ✅ planned

**Goal:** Every component in the vocabulary exercised in one app.

Components: `column`, `row`, `stack`, `scroll`, `text`, `button`, `text_field`, `toggle`, `slider`, `divider`, `spacer`, `progress`, `image`.

**Demo screen:** `kitchen_sink_screen.ex`

---

## Component Vocabulary (Phase 1 Android)

| Mob tag | NIF call | Android View | Notes |
|---|---|---|---|
| `<.column>` | `create_column/0` | `LinearLayout(VERTICAL)` | |
| `<.row>` | `create_row/0` | `LinearLayout(HORIZONTAL)` | |
| `<.text>` | `create_label/1` | `TextView` | |
| `<.button>` | `create_button/1` | `Button` | |
| `<.scroll>` | `create_scroll/0` | `ScrollView` + inner `LinearLayout` | |
| `<.text_field>` | `create_text_field/1` | `EditText` | Iteration 5+ |
| `<.toggle>` | `create_toggle/1` | `Switch` | Iteration 5+ |
| `<.slider>` | `create_slider/3` | `SeekBar` | Iteration 6+ |
| `<.divider>` | `create_divider/0` | 1dp `View` with background | |
| `<.spacer>` | `create_spacer/0` | `View` with weight | |
| `<.image>` | `create_image/1` | `ImageView` | Iteration 6+ |
| `<.progress>` | `create_progress/0` | `ProgressBar` | Iteration 6+ |

---

## NIF Function Signatures (mob_nif.c)

All unchanged from POC except renamed module from `uikit_nif` → `mob_nif`.

```c
// Creation — return {:ok, view_ref}
create_column/0
create_row/0
create_label/1       // text :: binary
create_button/1      // text :: binary
create_scroll/0      // returns scroll view; inner layout via get_tag

// Tree
add_child/2          // parent :: view_ref, child :: view_ref
remove_child/1       // child :: view_ref
set_root/1           // view :: view_ref

// Mutation
set_text/2           // view, text :: binary
set_text_size/2      // view, sp :: float
set_text_color/2     // view, argb :: long   ← was int, fixed
set_background_color/2 // view, argb :: long ← was int, fixed
set_padding/2        // view, dp :: int

// Events
on_tap/2             // view, pid :: pid
```

---

## Mob.Socket

```elixir
defmodule Mob.Socket do
  defstruct [
    assigns: %{},
    __mob__: %{
      screen: nil,
      platform: :android,
      root_view: nil,
      view_tree: %{},      # ref → %{type, props, children}
      nav_stack: []
    }
  ]
end
```

---

## Mob.Screen Behaviour

```elixir
defmodule Mob.Screen do
  @callback mount(params :: map, session :: map, socket :: Mob.Socket.t) ::
    {:ok, Mob.Socket.t} | {:error, reason :: term}

  @callback render(assigns :: map) :: Mob.ComponentTree.t

  @callback handle_event(event :: String.t, params :: map, socket :: Mob.Socket.t) ::
    {:noreply, Mob.Socket.t} | {:reply, map, Mob.Socket.t}

  @callback handle_info(message :: term, socket :: Mob.Socket.t) ::
    {:noreply, Mob.Socket.t}

  @callback terminate(reason :: term, socket :: Mob.Socket.t) :: term

  # Optional lifecycle
  @callback on_focus(socket :: Mob.Socket.t) :: {:noreply, Mob.Socket.t}
  @callback on_blur(socket :: Mob.Socket.t) :: {:noreply, Mob.Socket.t}
  @callback on_foreground(socket :: Mob.Socket.t) :: {:noreply, Mob.Socket.t}
  @callback on_background(socket :: Mob.Socket.t) :: {:noreply, Mob.Socket.t}

  @optional_callbacks [
    handle_event: 3, handle_info: 2, terminate: 2,
    on_focus: 1, on_blur: 1, on_foreground: 1, on_background: 1
  ]
end
```

---

## Battery / Resource Benchmarking (first priority when resuming development)

Feedback from the LiveView Native team (who ran a similar experiment via github.com/otp-interop) flags the BEAM as a resource hog that drains battery on mobile. Their experience predates the OTP 25+ ARM64 JIT and several rounds of scheduler tuning. Trust but verify — benchmark early before building further.

**The mechanical issue:**
BEAM schedulers run one OS thread per CPU core by default. Those threads can prevent the CPU from entering deep sleep states even when the app is idle. Mobile battery life depends heavily on deep sleep. This is the specific thing to measure and tune.

**Reference implementation: Nerves vm.args**

Nerves has already solved BEAM-on-constrained-hardware tuning. Use their vm.args as the starting point rather than building the flag set from scratch:
`github.com/nerves-project/nerves_bootstrap/blob/main/templates/new/rel/vm.args.eex`

**Tuning flags — starting config for mobile:**
```
## Scheduler busy-wait — most important for battery
+sbwt none          # disable scheduler busy-wait, prevents idle CPU spin
+sbwtdcpu none      # disable dirty CPU scheduler busy-wait
+sbwtdio none       # disable dirty I/O scheduler busy-wait

## Scheduler count
+S 1:1              # single scheduler (fewer threads awake); try 2:2 on high-end devices

## Time — critical for mobile (NTP sync, timezone changes, DST all shift the clock)
+C multi_time_warp  # Erlang system time tracks OS time closely; avoids timer surprises

## Memory
+P 1024             # limit process table size
+hms 256            # smaller minimum heap size
-env ERL_FULLSWEEP_AFTER 10  # more aggressive GC — trade CPU for lower memory footprint

## Reliability
-heart -env HEART_BEAT_TIMEOUT 30  # heartbeat: separate OS process restarts BEAM if it crashes

## Code loading
-code_path_choice strict  # load exactly what boot script says, no fallback searching
## -mode embedded          # load all code at startup (slower boot, fully predictable)
##                         # vs interactive (default, faster boot, loads on demand)
##                         # benchmark both — embedded may suit low-RAM devices better
```

**Recent BEAM improvements that help (OTP 25-29):**
- **ARM64 JIT (OTP 25+):** Beam bytecode compiles to native ARM instructions at load time. More efficient execution = less CPU time for the same work. Directly relevant — all Android and Apple Silicon devices are ARM64.
- **Scheduler busy-wait refinements:** Tuning flags are more granular and defaults are better across OTP 25-29.
- **Better process hibernation:** Idle processes are cheaper than older BEAM versions.

**Benchmark methodology — parallel matrix:**

Run all configurations simultaneously rather than sequentially. Each run is 30 minutes with HelloScreen visible, no interactions. Because each configuration needs a separate APK (different vm args baked into `mob_beam`), build all APKs first then run the matrix in one session.

**Configurations to test in parallel:**

| Config | Flags | What it tests |
|---|---|---|
| A — baseline | none (stock Android Activity, no BEAM) | Floor |
| B — untuned | default BEAM flags | Worst case |
| C — sbwt only | `+sbwt none +sbwtdcpu none +sbwtdio none` | Busy-wait fix alone |
| D — sbwt + single scheduler | C + `+S 1:1` | Fewer active threads |
| E — full Nerves | C + D + `+C multi_time_warp -env ERL_FULLSWEEP_AFTER 10` | Full tuning set |
| F — reference | React Native hello world | Industry comparison |

Six APKs, one 30-minute window, results comparable because they ran concurrently under the same ambient conditions (temperature, WiFi, background system load).

**Execution:**
```bash
# Reset all battery stats before starting
adb shell dumpsys batterystats --reset

# Start all six apps simultaneously (separate devices or emulators if available,
# otherwise run sequentially and compare relative deltas)

# After 30 minutes, pull stats
adb shell dumpsys batterystats > stats_config_X.txt

# Key metric: mAh consumed per config
# Also check CPU governor states during run:
adb shell cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
```

If only one device is available, run configs sequentially starting from full charge each time — less ideal but still conclusive if deltas are large. The busy-wait flags (Config C) are expected to be the biggest lever; if C ≈ A the remaining configs are academic.

**The comparison that matters:** A game running 60fps or Google Maps polling GPS continuously is a far heavier sustained load than an idle BEAM with busy-wait disabled. The question is whether tuned BEAM idle is in the same ballpark as other background processes, not whether it beats a no-op app.

**Elixir Desktop evidence:** Apps in the wild running BEAM on desktop and mobile via elixir-desktop/runtimes have not reported battery drain as a showstopper. Anecdotal but relevant.

**Note from elixir_pack analysis:** Their implementation has no battery tuning flags at all — no `+sbwt none`, no scheduler tuning. If the LVN team's battery testing used a similar untuned configuration (Config B above), that likely explains a significant portion of their reported battery concerns.

---

## Key Technical Constraints (learned from POC)

1. **Color values must use `enif_get_long`** — ARGB white is 0xFFFFFFFF = 4294967295, overflows `enif_get_int`.
2. **FindClass on non-main threads fails** — cache all class refs in `JNI_OnLoad` via `mob_ui_cache_class(env)`.
3. **CountDownLatch must have try/finally** — if the Runnable throws, latch never fires → deadlock. Always `finally { latch.countDown(); }`.
4. **`enif_keep_resource`** when registering tap listener — Java holds raw ptr, GC must not free resource.
5. **`-Wl,--allow-multiple-definition`** needed before `--whole-archive` for libbeam.a.
6. **`DED_LDFLAGS="-shared"`** not `"-r"` — Android lld rejects `-r` with `-ldl`.
7. **`application:start(compiler)`** before `application:start(elixir)` — Elixir depends on it.
8. **Deploy beam files via `run-as`** on non-rooted devices: push to `/data/local/tmp/` then `run-as com.beam.hello cp`.

---

## mob_demo Android Project

**Derived from BeamHello POC.** Key renames:
- `BeamUIBridge` → `MobBridge`
- `BeamTapListener` → `MobTapListener`
- `android_nif.c` → `mob_nif.c`
- Package: `com.mob.demo`
- `-s hello_world start` → `-s mob_demo start`

**mob_demo entry point (Erlang):**
```erlang
-module(mob_demo).
-export([start/0]).
start() ->
    ok = application:start(compiler),
    ok = application:start(elixir),
    ok = application:start(logger),
    'Elixir.MobDemo.App':start(),
    timer:sleep(infinity).
```

**MobDemo.App:**
```elixir
defmodule MobDemo.App do
  def start do
    # Start root screen via Mob.Screen
    Mob.Screen.start_root(MobDemo.HelloScreen)
  end
end
```

---

## What's NOT in Phase 1

- Sigil syntax (`~MOB`) is planned for Iteration 3.7 — see Render Syntax section below
- Jetpack Compose (sticking with Android Views — already proven, Compose migration in Phase 2)
- iOS SwiftUI migration is Iteration 3.5 — UIKit working now, SwiftUI is next
- `mix mob.new` generator (Phase 3)
- Distribution / clustering (works out of the box via OTP, document but don't build tooling)
- Stylesheet system (Phase 2)

---

## Immediate Next Steps

1. Write `Mob.Socket` with tests (Iteration 1)
2. Write `Mob.Screen` behaviour with tests (Iteration 1)
3. Write `Mob.Registry` with tests (Iteration 2)
4. Set up mob_demo Android project (copy+rename from BeamHello)
5. Wire HelloScreen through the stack end-to-end on device (Iteration 3)

---

## Phase 2+ Roadmap

### Code Generation (Igniter)

Igniter (`hex.pm/packages/igniter`) is the foundation for all Mob generators — the same infrastructure Phoenix uses for `mix phx.gen.live`. Added as `{:igniter, "~> 0.6", optional: true}` so it's a dev/generation dependency only, never pulled into production builds.

**Why generators matter:**
- Easy onramp: `mix mob.gen.screen` gets a new developer to a working screen faster than reading docs
- AI coding agents benefit as much as humans — giving an agent access to well-defined generators produces more uniform, idiomatic code than asking it to write from scratch. The generator is the canonical pattern; the agent just invokes it.
- Patching existing files intelligently (via Igniter's AST zipper transforms) means generators add routes, wire supervision trees, and update config without telling the user to do it manually

**Planned generators:**

`mix mob.install` — first-run setup
- Adds `{:mob, "~> x.x"}` to `mix.exs`
- Creates `mob.exs` config file
- Generates app entry point (`MobApp` module)
- Generates root screen stub

`mix mob.gen.screen MyApp.CounterScreen` — new screen
- Creates `lib/my_app/counter_screen.ex` with `mount/3`, `render/1`, `handle_event/3` stubs
- Adds screen to router (patches existing file via AST transform)
- Generates `test/my_app/counter_screen_test.exs` with `Mob.ScreenTest` stubs

`mix mob.gen.component MyApp.Components.Card` — reusable component
- Creates component module with `render/1`
- Registers in component registry

`mix mob.gen.release android|ios` — scaffolds release config
- Creates platform build config
- Sets up signing config stubs in `mob.exs`

**Implementation approach:**
Each generator is a module using `use Igniter.Mix.Task` that implements `igniter/1`. Generators are composable — `mob.gen.screen` calls `mob.install` first if Mob isn't set up yet. Igniter's `copy_template/5` for new files, `create_or_update_elixir_file/4` + zipper transforms for patching existing ones.

**AI agent usage:**
Generators are the blessed path for AI-assisted Mob development. An agent scaffolding a new screen calls `mix mob.gen.screen` rather than writing the module from scratch — the output is idiomatic, consistent, and correct by construction. Document each generator's flags and output clearly so agents can invoke them confidently without hallucinating the API.

---

### lazy_list API
`<.lazy_list>` needs `on_end_reached` event (fires when user scrolls near the end, for infinite scroll) and a `threshold` prop (how many items from the end to trigger — mirrors React Native FlatList's `onEndReachedThreshold`). NIF side: listen for RecyclerView scroll state; Elixir side: `handle_event("end_reached", %{}, socket)`.

### Push Notifications
`mob_push` package. FCM (Android) / APNs (iOS). Registration token surfaced via `handle_info({:notification, payload}, socket)`. App requests permission via `Mob.Permissions.request(:notifications, socket)` (see Permissions below). Server-side sending out of scope for mob library — just receive and route.

### Permissions System
`Mob.Permissions.request(:camera | :location | :microphone | :notifications, socket)` — triggers OS dialog, result delivered as `handle_info({:permission_result, :camera, :granted | :denied | :not_determined}, socket)`. `Mob.Permissions.status(:location)` → synchronous check. Android: `ActivityCompat.requestPermissions`; iOS: `AVCaptureDevice.requestAccess` etc.

### Offline / Local Storage
SQLite via NIF (`exqlite` or a thin mob-specific wrapper). Blessed pattern: one `Mob.Repo` per app, schema defined in Elixir, migrations run on app start. Keeps it familiar for Phoenix devs. Key constraint: WAL mode on by default; single writer, multiple readers OK on device.

### App Store / Play Store Build Pipeline
`mix mob.release --platform android|ios` — triggers Gradle/Xcode build, signs the artifact, outputs `.aab` / `.ipa`. Fastlane integration for upload. Separate `mix mob.release.upload --track internal` for Play/TestFlight. Needs signing config in `mob.exs` (keystore path, provisioning profile).

### Accessibility
TalkBack (Android) / VoiceOver (iOS) support. Prop: `accessible_label` on any component (maps to `contentDescription` / `accessibilityLabel`). `accessible_hint` for secondary description. `accessible_role` (button, image, header, etc.) maps to `AccessibilityNodeInfoCompat.setRoleDescription` / `UIAccessibilityTraits`. Goal: zero-config for text components (label text is used automatically); explicit opt-in for images and custom components.

### Mob.DevServer (AI + Playwright integration)

Starts alongside `mix mob.dev`. Exposes the running app to external tools — Playwright, Tidewave, Claude — for two distinct feedback loops with different tools for each.

**Two feedback loops, two tools:**

**Functional feedback — event-driven, no screenshots:**
`Mob.Screen` holds the full render tree and assigns in memory. `Mob.DevServer` exposes these over a WebSocket that streams changes as they happen — no polling, no pixels. A Playwright script or Tidewave connects once and watches for state changes, fires events, and asserts on structure. This is the fast iteration loop.

```
WS   /live    →  streams assigns + tree on every state change (event-driven)
GET  /assigns →  current screen assigns as JSON
GET  /tree    →  raw component tree as JSON
GET  /ui      →  platform accessibility tree (iOS: xcrun simctl ui describe all,
                 Android: uiautomator dump) — structural element query, not pixels
POST /tap     →  simulate a tap event
POST /event   →  send any named event to the running screen
```

Example Playwright functional test — no screenshot in the loop:
```js
// watch for state change after tap
await page.request.post('/tap', { data: { id: 'increment-button' } })
await page.waitForFunction(() => window.__mobState?.assigns?.count === 1)
```

**Visual/styling feedback — screenshots:**
`/screenshot` returns a PNG from the real platform renderer — SwiftUI on iOS, Android Views on Android. Platform differences (SF Pro font, Material ripple, corner radii, dark mode, etc.) are all preserved because it's the actual rendered output, not an HTML approximation. Used for styling review and visual regression, not functional testing.

```
GET  /screenshot  →  PNG from real platform renderer (iOS or Android)
```

**Tidewave usage:**
`/assigns` and `/tree` feed structured JSON directly to Claude — logic state without needing to parse pixels. `/ui` gives Claude the platform element tree for layout questions.

**What each tool is for:**

| Tool | Endpoint | Use case |
|---|---|---|
| Playwright | `/live` WS + `/ui` | Functional tests — event-driven, structural |
| Tidewave | `/assigns` + `/tree` | State inspection, logic debugging |
| Screenshots | `/screenshot` | Styling review, visual regression |
| Claude (all) | all of the above | Full feedback loop |

---

### Testing Story

**`Mob.ScreenTest` — unit tests, no device needed**

Pure Elixir, no emulator, no NIF calls. NIFs stubbed out; component tree returned as a plain map for assertions. API mirrors LiveView's `live/2` + `render_click`.
```elixir
test "counter increments" do
  {:ok, screen} = Mob.ScreenTest.mount(CounterScreen)
  assert screen.assigns.count == 0
  {:ok, screen} = Mob.ScreenTest.event(screen, "increment", %{})
  assert screen.assigns.count == 1
end
```

**`Mob.UITest` — integration tests against a running device**

Connects to the on-device node over Erlang distribution (same WiFi, `mac.local`). Drives the real running app — real NIFs, real platform views. No Appium, no Espresso, no XCUITest. Same API for Android and iOS.

```elixir
test "counter increments on tap" do
  {:ok, screen} = Mob.UITest.mount(device_node, CounterScreen)
  assert Mob.UITest.assigns(screen).count == 0

  Mob.UITest.tap(screen, "increment-button")
  assert Mob.UITest.assigns(screen).count == 1
  assert Mob.UITest.text(screen, "counter-label") == "Count: 1"
end
```

Screenshot support via a NIF that returns a PNG binary — useful for visual regression tests. Simulator/emulator can also use platform tools (`xcrun simctl io`, `adb`) when available.

**Remote inspection (free once distribution is set up):**
- `:observer.start()` on Mac shows on-device process tree, memory, message queues
- `:dbg` / `:recon` for function call and message tracing on-device from Mac IEx
- `:sys.get_state(pid)` to inspect any live GenServer

### Fonts and Assets
`mix mob.gen.assets` — copies fonts/images into the correct platform dirs (`res/font/`, `Assets.xcassets`). `<.text font="MyFont-Bold">` maps to a registered font name. Images: `<.image src={:my_logo}>` resolved from asset catalog at build time. Hash-based cache busting for OTA updates.

### Hot Deploy (Dev UX)

Two modes: dev (code lives on Mac) and release (self-contained on device).

**Dev mode — Erlang distribution + file watcher**

Device runs a minimal install: ERTS (compiled into the app binary) + OTP base apps (kernel, stdlib, elixir, logger beams — stable). All `mob` library and app screen code lives on the Mac.

Bootstrap on device dials home to the Mac node on startup. From that point the device is a display terminal — app code runs on-device via distribution, but the source of truth is the Mac.

Mac side runs `iex -S mix mob.dev`, which:
1. Starts a file watcher on `lib/` (same as Phoenix's `mix phx.server`)
2. On `.ex` change: recompiles → calls `nl(Module)` to push bytecode to all connected nodes (device included)
3. Sends a re-render signal so the running `Mob.Screen` picks up the new module

From IEx you also get the full dev loop manually:
```elixir
r(MobDemo.CounterScreen)  # recompile + load on device instantly
Node.call(:"mob_demo@device", :sys, :get_state, [MobDemo.CounterScreen])  # inspect live state
```

Device dials Mac's LAN IP directly over WiFi — no adb, no platform-specific tooling. Same mechanism works identically on Android and iOS. Bootstrap dials `mac.local` (mDNS) — works out of the box on both platforms when on the same WiFi. Zero config, survives IP changes.

Re-render hook: `Mob.Screen` implements `code_change/3` (standard OTP GenServer callback) — called automatically by OTP when the module is hot-loaded. Triggers a re-render with current assigns.

**Release mode — self-contained**

`mix mob.release --platform android|ios` bundles everything (OTP base + mob library + app beams) onto the device. No Mac connection. This is also the App Store / Play Store path.

Deploy commands:
```bash
./deploy.sh --dev      # minimal install, dials home to Mac IEx
./deploy.sh --release  # or: mix mob.release --platform android
```

### Error Boundaries
`<.error_boundary>` component with a `fallback` slot. Catches crashes in child component trees (via process links or try/rescue in renderer) and renders the fallback instead of crashing the whole screen. Configurable supervision: `:restart` (re-mount screen), `:show_fallback` (static error UI), `:propagate` (let it crash — default OTP behaviour). Useful for isolating third-party components or experimental screens.

### Video Playback

`<.video>` component backed by platform players — thin NIF wrappers around mature native libraries. Playback is straightforward: no NAT traversal, no P2P, client pulls from a URL.

- **iOS:** `AVPlayer` / `AVKit` — HLS is first-class (Apple invented it), adaptive bitrate, DRM, subtitles all handled automatically
- **Android:** `ExoPlayer` / Jetpack `Media3` — HLS, DASH, SmoothStreaming; this is what YouTube uses internally

```elixir
%{type: :video, props: %{src: "https://…/stream.m3u8", autoplay: true}}
```

Both platform players handle buffering, codec selection, and adaptive bitrate switching. The Mob NIF layer is a thin wrapper — most of the work is already done by the platform.

Live publishing (broadcasting from device camera) is harder and overlaps with the Media / Video Calls section below.

### Media / Video Calls (nice to have)

Real-time audio/video between devices. Significantly more complex than playback — NAT traversal is the core hard problem regardless of stack.

**The Membrane angle:** Membrane Framework (maintained by Software Mansion) handles audio/video capture, encoding, RTP/SRTP, WebRTC signaling, and SFU routing in Elixir/OTP. It's the piece that makes this not a from-scratch problem. With Mob + Membrane:

- **Device:** capture/encode via platform NIFs (VideoToolbox on iOS, MediaCodec on Android — hardware accelerated)
- **Server:** Membrane SFU in Elixir, supervised by OTP
- **Transport:** WebRTC for browser interop, raw SRTP for Mob-to-Mob

OTP supervision is a genuine advantage over browser WebRTC: crashed media pipelines restart automatically, GenStage handles backpressure, 50 simultaneous call pipelines on one server without JS impedance mismatch.

Hard parts to not implement from scratch: echo cancellation (use platform AEC — built into iOS/Android audio stacks), jitter buffers (Membrane handles), hardware codec NIFs (complex but well-trodden APIs).

**Batteries-included vision:**
```elixir
def handle_info({:media_ready, stream}, socket) do
  {:noreply, Mob.Media.join_room(stream, "room_id", socket)}
end
```
`Mob.Media` wraps platform capture NIFs + Membrane pipeline. Developer never sees SRTP or ICE.

### Haptics

Simplest native win on the list. Single NIF call, big UX improvement.

- iOS: `UIFeedbackGenerator` — impact (light/medium/heavy), selection, notification (success/warning/error)
- Android: `VibrationEffect`

```elixir
Mob.Haptics.impact(:medium)
Mob.Haptics.notification(:success)
Mob.Haptics.selection()
```

### Clipboard + Share Sheet

Simple, very common.

- **Clipboard:** `UIPasteboard` (iOS) / `ClipboardManager` (Android) — read/write text and images
- **Share sheet:** `UIActivityViewController` (iOS) / `Intent.ACTION_SEND` (Android) — "share this to…"

```elixir
Mob.Clipboard.copy("some text")
Mob.Share.sheet(%{text: "Check this out", url: "https://…"})
```

### Biometrics

Simple API surface, important for auth flows. Result delivered via `handle_info`.

- iOS: `LocalAuthentication` — Face ID / Touch ID
- Android: `BiometricPrompt` — fingerprint / face unlock

```elixir
Mob.Biometrics.authenticate("Confirm payment")
# → handle_info({:biometric, :success | :failure | :cancelled}, socket)
```

### Deep Links

Routes external links (from notifications, web, other apps) into `Mob.Router`. Important for app ecosystem integration.

- iOS: Universal Links + custom URL schemes
- Android: App Links + Intent filters

Configure in `mob.exs`; incoming links arrive as `handle_info({:deep_link, path, params}, socket)` on the root screen.

### Camera

Two distinct use cases with different complexity:

**Photo/video picker (low complexity)** — platform handles all UI, app just receives the result:
- iOS: `PHPickerViewController`
- Android: `MediaStore` photo picker

```elixir
Mob.Camera.pick_photo()
Mob.Camera.pick_video()
# → handle_info({:media_picked, %{path: …, type: :photo | :video}}, socket)
```

**Live capture (medium complexity)** — full camera viewfinder, capture button, flash control:
- iOS: `AVFoundation` / `AVCaptureSession`
- Android: `CameraX`

Rendered as a `<.camera_view>` component with capture events. Hardware-accelerated via platform APIs. Also the foundation for the Media / Video Calls section.

### File System (`Mob.FS`)

Raw filesystem access is platform-specific (iOS is sandboxed; Android scoped storage has tightened since API 29). A unified API covers the two cases that work identically on both:

| Concept | iOS | Android |
|---|---|---|
| App-private storage | `Documents/`, `Library/` | `getFilesDir()` |
| Permission required | none | none |
| User file picker | `UIDocumentPickerViewController` | Storage Access Framework |

```elixir
Mob.FS.app_dir()       # private app storage path — same on both platforms
Mob.FS.pick_file()     # platform file picker → handle_info({:file_picked, path}, socket)
Mob.FS.save_file(data) # platform save dialog
```

Arbitrary path access (outside app sandbox) is intentionally not abstracted — behaviour diverges too much and encouraging it leads to permission headaches.

---

## Not Planned (why)

- **Maps UI** — requires Google Maps SDK / MapKit; heavy, licensing complexity. Location coords via permissions are fine; a full map component is a separate library concern.
- **In-App Purchases** — StoreKit 2 / Play Billing are completely different APIs with legal and financial complexity. Out of scope for the framework.
- **Contacts / Calendar** — privacy-sensitive, complex, limited demand.
- **AR** — ARKit / ARCore. Complex, niche.
- **Sensors (accelerometer, gyroscope)** — straightforward NIFs, very niche. Easy to add if demand emerges.
- **Bluetooth** — real use cases, complex API. Worth a dedicated `mob_bluetooth` package rather than bundling.
- **HTTP / WebSocket** — BEAM handles these natively. No NIF work needed.

---

## Long Term / Experimental

### Headless Mode (phone as a server)

Run BEAM as an Android Foreground Service with no UI component. The Foreground Service keeps the process at foreground priority — Android won't kill it under memory pressure. A persistent notification is required (the OS-enforced cost of the feature).

Use case: a phone running a full OTP application — GenServers, Phoenix, Ecto, PubSub — with no screen. Essentially a low-power server node you can put in a drawer. The phone's LTE/WiFi makes it reachable anywhere; OTP clustering means it can join a distributed system.

Intentionally long-term: background execution is a battery and abuse vector. Would need rate limiting, battery-aware supervision (pause work when battery is low), and clear user consent. iOS equivalent is heavily restricted by the OS and would require a declared Background Mode (audio, location, VoIP) — no general-purpose equivalent.
