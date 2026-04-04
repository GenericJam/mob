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

**NIF layer (C):** `mob_nif.c` — the bridge. Compiled into the app `.so`. Calls `MobBridge.java` (Android) / `MobBridge.swift` (iOS future).

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

  def render(assigns) do
    ~M"""
    <.column padding={16}>
      <.text size={24}><%= @greeting %></.text>
    </.column>
    """
  end
end
```

---

### Iteration 4 — handle_event + counter screen ✅ planned

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

- HEEx template rendering (use plain Elixir map trees first, HEEx in Phase 2)
- Jetpack Compose (sticking with Android Views — already proven, Compose migration in Phase 2)
- iOS (architecture is designed for it, implementation in Phase 2)
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
