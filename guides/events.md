# Events in Mob — User Guide

Comprehensive guide to receiving events from widgets, gestures, and the
device. For the underlying design, see [`event_model.md`](event_model.md).

## TL;DR

Every event in Mob — taps, text changes, gestures, scroll, device lifecycle —
arrives in your handler as one of two shapes:

```elixir
# Legacy / Phase 1-3 widgets:
{:tap, tag}
{:change, tag, value}
{:focus, tag}  {:blur, tag}  {:submit, tag}

# Canonical envelope (recommended for new code):
{:mob_event, %Mob.Event.Address{}, event_atom, payload}
```

Either path delivers the same logical event; the canonical envelope just
includes more context (screen, component path, render generation).

`Mob.Event.Bridge` converts legacy → canonical so screens can opt into the
new shape one at a time.

## Quick reference

### Taps and text input

```elixir
button("Save", on_tap: {self(), :save})

text_field(value: @email, on_change: {self(), :email_changed},
                          on_focus:  {self(), :email_focused},
                          on_blur:   {self(), :email_blurred},
                          on_submit: {self(), :email_submitted})

# In handle_info/2:
def handle_info({:tap, :save}, socket), do: ...
def handle_info({:change, :email_changed, value}, socket), do: ...
```

### Selection (pickers, menus)

```elixir
picker(items: @options, on_select: {self(), :picked})

def handle_info({:select, :picked}, socket), do: ...
```

### Gestures

```elixir
button("Avatar",
  on_long_press: {self(), :show_menu},
  on_double_tap: {self(), :zoom})

card(
  on_swipe_left:  {self(), :delete},
  on_swipe_right: {self(), :archive},
  on_swipe:       {self(), :any_swipe})  # also fires; payload includes direction

def handle_info({:long_press, :show_menu}, socket), do: ...
def handle_info({:swipe, :any_swipe, direction}, socket), do: ...   # :left | :right | :up | :down
```

### Scroll — three tiers

**Tier 1 — raw deltas** (rarely needed; throttle defaults to 30 Hz):

```elixir
scroll(on_scroll: {self(), :feed})

def handle_info({:scroll, :feed, %{y: y, dy: dy, phase: phase}}, socket), do: ...
```

Override the throttle when you need higher fidelity:

```elixir
scroll(on_scroll: {self(), :feed, throttle: 16})         # 60 Hz
scroll(on_scroll: {self(), :feed, throttle: 0})          # raw firing rate (escape hatch)
scroll(on_scroll: {self(), :feed, debounce: 200})        # only after stillness
scroll(on_scroll: {self(), :feed, throttle: 50, delta: 8})  # 20 Hz + 8px deadzone
```

**Tier 2 — semantic events** (use these by default):

```elixir
scroll(
  on_scroll_began:    {self(), :feed_began},
  on_scroll_ended:    {self(), :feed_ended},
  on_scroll_settled:  {self(), :feed_settled},   # fires after deceleration
  on_top_reached:     {self(), :pull_to_refresh},
  on_end_reached:     {self(), :load_more},      # already wired pre-Batch 5
  on_scrolled_past:   {self(), :show_back_to_top, 600})  # threshold = 600 px

def handle_info({:scroll_began, :feed_began}, socket), do: ...
def handle_info({:scrolled_past, :show_back_to_top}, socket), do: ...
```

**Tier 3 — native-side, no BEAM round-trip** (parallax, sticky headers, fades):

```elixir
image(src: "hero.jpg",
  parallax: %{ratio: 0.5, container: :main_scroll})

navbar(
  fade_on_scroll: %{container: :main_scroll, fade_after: 100, fade_over: 60})

header(
  sticky_when_scrolled_past: %{container: :main_scroll, threshold: 200})
```

These never deliver events to BEAM — they're computed natively at display
refresh rate.

### IME composition (CJK / Korean / Vietnamese / accent input)

Languages with multi-stage input show a "marked" or "composing" region
before the user picks a final character. Apps that read text mid-keystroke
(search-as-you-type, network sync) need to know about composition state to
avoid sending partial input.

```elixir
text_field(value: @text,
  on_change:  {self(), :text},      # fires on every change (including composing)
  on_compose: {self(), :ime})       # fires on composition phase changes

# Events:
# {:compose, :ime, %{phase: :began,     text: "n"}}     # composition started
# {:compose, :ime, %{phase: :updating,  text: "ni"}}    # composing
# {:compose, :ime, %{phase: :committed, text: "你"}}    # user picked candidate
# {:compose, :ime, %{phase: :cancelled, text: ""}}      # user dismissed IME
```

Commit-only handler pattern (the typical use case):

```elixir
def handle_info({:compose, _id, %{phase: :began}}, socket),
  do: {:noreply, assign(socket, :composing, true)}

def handle_info({:compose, _id, %{phase: :committed, text: text}}, socket) do
  # Real commit replaces whatever raw text we got during composition.
  {:noreply, assign(socket, composing: false, text: text)}
end

def handle_info({:compose, _id, %{phase: :cancelled}}, socket),
  do: {:noreply, assign(socket, :composing, false)}

def handle_info({:change, _id, value}, %{assigns: %{composing: true}} = socket),
  do: {:noreply, socket}                 # ignore raw text while composing

def handle_info({:change, _id, value}, socket),
  do: {:noreply, assign(socket, :text, value)}
```

For most apps (forms that read the final value on submit), you don't need
`on_compose` at all — UIKit/Compose handle IME natively and the committed
text ends up in `value` correctly. Only opt in when partial input matters.

### Device lifecycle

```elixir
# Subscribe in mount/2 (or anywhere — process is monitored, auto-cleaned):
Mob.Device.subscribe()                  # default: :app, :display, :audio, :memory
Mob.Device.subscribe(:all)              # all categories
Mob.Device.subscribe([:thermal, :power])

# Receive events:
def handle_info({:mob_device, :did_enter_background}, socket), do: ...
def handle_info({:mob_device, :thermal_state_changed, :serious}, socket), do: ...
def handle_info({:mob_device, :battery_level_changed, pct}, socket), do: ...
```

See [`event_model.md`](event_model.md) for the full event vocabulary.

## When to use Tier 1 vs Tier 2 vs Tier 3 (scroll)

| You want to... | Use |
|---|---|
| Trigger pagination at the bottom of a list | Tier 2 — `on_end_reached` |
| Show a "back to top" button after 600 px | Tier 2 — `on_scrolled_past` |
| Hide a navbar while user is actively scrolling | Tier 2 — `on_scroll_began` / `on_scroll_settled` |
| Run analytics on "user reached product N" | Tier 2 — `on_scrolled_past` |
| Smoothly fade a header from 100 % to 0 % over 60 px | Tier 3 — `fade_on_scroll` |
| Parallax a hero image | Tier 3 — `parallax` |
| Animate something as a function of scroll position | Tier 3 |
| You **really** need raw scroll deltas | Tier 1 (and explain why in code review) |
| Scroll-driven game / drawing canvas | Tier 1 with `throttle: 0` |

The rule of thumb from React Native's experience: if your code looks like
"compute a transform from scroll position," it belongs in Tier 3, not Tier 1.

## Throttle / debounce / delta semantics

```elixir
on_scroll: {pid, tag, opts}
```

`opts` accepts:

- `throttle: ms` — minimum interval between emissions. Default 33 ms (≈ 30 Hz)
  for scroll, 16 ms (60 Hz) for drag/pinch/rotate, 33 ms for pointer move.
  `0` disables throttling.
- `debounce: ms` — only emit after `ms` ms of no events. Default 0 (off).
- `delta: number` — minimum change in x or y (or scale, or degrees) to trigger
  an emit. Default 1 px for scroll/drag, 0.01 (1 %) for pinch, 1° for rotate,
  4 px for pointer.
- `leading: bool` — emit the first event of a burst. Default `true`.
- `trailing: bool` — emit the final event after debounce window expires.
  Default `true` for most events; `false` for `pointer_move`.

**Phase-boundary events always fire**, regardless of throttle. So
`{:scroll, tag, %{phase: :began}}` and `{:scroll, tag, %{phase: :ended}}` are
guaranteed to deliver even if `throttle: 1000`.

## Event payload reference

### `{:scroll, tag, payload}`
```elixir
%{
  x: 0.0,          # current x offset in px
  y: 1240.0,       # current y offset in px
  dx: 0.0,         # delta since last emitted event (px)
  dy: 12.0,
  velocity_x: 0.0, # px/sec
  velocity_y: 720.0,
  phase: :began | :dragging | :decelerating | :ended,
  ts: 18472,       # ms since boot (monotonic; safe for diffs)
  seq: 891         # monotonic counter per handle, detects drops
}
```

### `{:drag, tag, payload}`
Same shape minus `velocity_x`/`velocity_y`.

### `{:pinch, tag, payload}` / `{:rotate, tag, payload}`
```elixir
%{scale: 1.25,   velocity: 0.3,  phase: ..., ts: ..., seq: ...}     # pinch
%{degrees: 45.0, velocity: 0.1,  phase: ..., ts: ..., seq: ...}     # rotate
```

### `{:pointer_move, tag, payload}`
```elixir
%{x: 320.0, y: 480.0, ts: ..., seq: ...}
```

### `{:swipe, tag, direction}`
`direction` is `:left | :right | :up | :down`.

### Tier 2 single-fire events
`{:scroll_began, tag}`, `{:scroll_ended, tag}`, `{:scroll_settled, tag}`,
`{:top_reached, tag}`, `{:end_reached, tag}`, `{:scrolled_past, tag}` — no
payload. The `tag` identifies the source widget.

## The canonical envelope

For new code, prefer the canonical envelope. Use `Mob.Event.Bridge`:

```elixir
def handle_info(msg, socket) do
  case Mob.Event.Bridge.legacy_to_canonical(msg, __MODULE__) do
    {:ok, {:mob_event, addr, event, payload}} ->
      handle_canonical(addr, event, payload, socket)

    :passthrough ->
      # Not a recognised event — handle normally.
      ...
  end
end

defp handle_canonical(%Address{widget: :button, id: :save}, :tap, _, socket) do ...
defp handle_canonical(%Address{widget: :scroll, id: list_id},
                       :scroll, %{y: y, phase: :ended}, socket) do ...
defp handle_canonical(%Address{widget: :list, id: list_id, instance: index},
                       :select, _, socket) do ...
```

The address gives you `screen`, `component_path`, `widget`, `id`, `instance`,
`render_id` — which is *much* richer matching power than the legacy 2-tuple.

## Targeting events to non-screen processes

For Phase 4+ widgets (gestures and beyond), you can target a specific process
other than the screen:

```elixir
button("Pause", on_tap: :pause, target: MyApp.AudioPlayer)
button("Sync",  on_tap: :sync,  target: {:via, Registry, {:workers, "sync"}})
button("Cancel", on_tap: :cancel, target: :screen)        # explicit
button("Save",  on_tap: :save,   target: :parent)         # default
button("Use",   on_tap: :use,    target: {:component, :outer_form})
```

In-tree targets (`:parent`, `:screen`, `{:component, _}`) get framework
guarantees: render-id staleness check, auto-cleanup on widget unmount.
External targets (registered atom, pid, `{:via, ...}`) are best-effort —
the framework just sends the message and trusts the recipient exists.

(Note: `target:` is currently in the design phase; the renderer landing in a
follow-up batch will wire it up. Today, every widget's events go to the pid
you put in `on_tap: {pid, ...}`.)

## Stateful components own their subtree's events

If you write a reusable component (e.g., a date picker, an autocomplete,
a chart), declare it as `Mob.Event.Component`:

```elixir
defmodule MyApp.Form do
  use Mob.Event.Component

  def mount(props, state), do: {:ok, Map.put(state, :email, "")}

  def render(state) do
    column(...)  # contains text fields, buttons
  end

  def handle_event(%Address{id: :email}, :change, value, state) do
    {:noreply, %{state | email: value}}    # internal — screen doesn't see
  end

  def handle_event(%Address{id: :submit}, :tap, _, state) do
    send(state.parent, {:form_submitted, state.email})  # escalate semantic event
    {:noreply, state}
  end
end
```

Widget events inside the component default to landing here, not the screen.
The screen sees only `:form_submitted` — clean encapsulation, regardless of
how many widgets the component contains internally.

## Debugging — `Mob.Event.Trace`

Live-watch every event in IEx:

```elixir
Mob.Event.Trace.start()
Mob.Event.Trace.subscribe()             # all events
# or with a filter:
Mob.Event.Trace.subscribe(fn addr -> addr.widget == :scroll end)

# Now in your IEx session:
flush()
# {:mob_trace, %Address{widget: :scroll, id: :feed},
#               :scroll, %{y: 240.0, dy: 8.0, phase: :dragging, seq: 12}}
# ...

Mob.Event.Trace.unsubscribe()
```

When no tracers are registered, `Mob.Event.dispatch/4` does one ETS lookup
(~50 ns) and returns. Zero impact on production performance.

## Performance notes

- **Tap-family events** (tap, change, focus, blur, submit, select): one
  `enif_send` per event. ~1–10 µs. Negligible.
- **Gestures** (long-press, double-tap, swipe): same — single user-level
  events.
- **High-frequency events** (scroll, drag, pinch, rotate, pointer move):
  throttled and delta-thresholded native-side **before** the BEAM crossing.
  Default 30 Hz cap means at most 30 `enif_send` per active scroll session,
  even if the underlying scroll is 120 Hz.
- **Tier 3 native primitives** (parallax, fade, sticky): zero BEAM
  involvement during the scroll. Animation runs at display refresh rate
  natively.

## Migration — from `register_tap` to canonical

The framework still uses `register_tap` (returning integer handles) under
the hood. The visible API has not changed: continue to write
`on_tap: {pid, tag}`. As you migrate screens to use `Mob.Event.Bridge`
or stateful components, the legacy shapes keep working — both arrive at
the same handler.

When/if `Mob.List` is migrated to a stateful component, its row-tap shape
(`{:tap, {:list, id, :select, idx}}`) will change to a canonical envelope
emitted from the list's pid. The bridge already handles this conversion
transparently for screens that opt in.

## Common patterns

### Pull-to-refresh

```elixir
scroll(on_top_reached: {self(), :refresh},
       on_scroll: {self(), :feed, throttle: 100}) do
  ...rows...
end

def handle_info({:top_reached, :refresh}, socket) do
  Task.async(fn -> reload_feed() end)
  {:noreply, assign(socket, :refreshing, true)}
end
```

### Infinite scroll

```elixir
scroll(on_end_reached: {self(), :load_more}) do ...end

def handle_info({:end_reached, :load_more}, socket) do
  if !socket.assigns.loading do
    Task.async(fn -> load_next_page() end)
    {:noreply, assign(socket, :loading, true)}
  else
    {:noreply, socket}
  end
end
```

### Show "back to top" button

```elixir
column(spacing: 0) do
  scroll(
    on_scrolled_past: {self(), :show_back_to_top, 600},
    on_top_reached:   {self(), :hide_back_to_top}) do
    ...long content...
  end

  if @show_back_to_top, do: floating_button("↑", on_tap: {self(), :scroll_to_top})
end
```

### Card stack with swipe-to-dismiss

```elixir
for {card, idx} <- Enum.with_index(@cards) do
  card(id: card.id,
       on_swipe_left:  {self(), {:dismiss, card.id}},
       on_swipe_right: {self(), {:save, card.id}}) do
    ...card contents...
  end
end

def handle_info({:swipe_left, {:dismiss, id}}, socket), do: ...
def handle_info({:swipe_right, {:save, id}}, socket), do: ...
```

### Photo viewer with pinch-to-zoom and pan

```elixir
image(src: @url,
      on_pinch: {self(), :zoom},
      on_drag:  {self(), :pan})

def handle_info({:pinch, :zoom, %{scale: scale, phase: :ended}}, socket) do
  # Final zoom level — commit it.
  {:noreply, assign(socket, :zoom, scale)}
end

def handle_info({:pinch, :zoom, %{scale: scale, phase: :dragging}}, socket) do
  # Live update — typically you'd render with this on the way to the final.
  {:noreply, assign(socket, :live_zoom, scale)}
end
```

### Hero parallax with native-only animation

```elixir
scroll(id: :main, on_scroll_began: {self(), :hide_chrome}) do
  image(
    src: "hero.jpg",
    parallax: %{ratio: 0.5, container: :main})  # NEVER hits BEAM during scroll

  ...content...
end
```

## Anti-patterns

❌ **Don't put `on_scroll` with no throttle and synchronous work in the
handler.** A slow handler at 60 Hz will overflow the screen GenServer's
mailbox and lag the app. If you really need every frame, use Tier 3.

❌ **Don't use `String.to_atom/1` to derive `id` from user data.** Atoms are
not GC'd. Use binaries for data-derived IDs:
```elixir
# ❌ leaks
on_tap: {self(), String.to_atom("contact_#{contact.id}")}

# ✅ safe
on_tap: {self(), {:contact, contact.id}}
on_tap: {self(), "contact:#{contact.id}"}
```

❌ **Don't compute layout from scroll deltas in BEAM.** The frame budget is
~16 ms; a BEAM round-trip plus computation can easily exceed it. Use Tier 3.

❌ **Don't override `target:` to a process you don't control its lifecycle of.**
External targets are best-effort — if the target dies, your event is silently
dropped (logged in dev). For "fire and forget" that's fine; for "must
receive" it's a footgun.

## Where to find more

- [`event_model.md`](event_model.md) — design contract, address shape, ID rules
- [`event_audit.md`](event_audit.md) — current native emitters, migration plan
- [`PLAN.md`](../PLAN.md) — roadmap; what's done, what's coming
