# Per-node multi-pointer `on_touch`

- Date: 2026-11-12
- Status: accepted
- Ticket: MOB-518

## Context

Magpie (a phone sampler) has 16 pads. Each pad takes its own fingers, and a
hit's velocity comes from where the finger lands:
`v = round(127 × (1 − 0.85 × y / h))`. A finger that slides off one pad onto
another must not trigger the second. FMutate needs the same thing.

None of the existing surfaces can do this:

- `on_press_in` / `on_press_out` (decisions/2026-10-03-press-in-out-and-held-press.md)
  carry no position and no pointer id, and they follow one finger per node.
- `on_drag` exists only on `canvas` / `gpu_view`, follows one finger, and fires
  `began` after a slop decision (`detectDragGestures` on Android).
- The `mob_touch` plugin is window-wide. The app would have to hit-test the
  pads itself, and there is no frame API it could use to do that.
- PLAN.md's Batch 7 sketch (`canvas(on_touch:)`,
  `{:touch, :down, %{finger_id: ...}}`) was canvas-only, and its message
  shape puts the phase where `Mob.Listener` expects the tag.

## Decision

### API

```elixir
box(on_touch: {self(), :pad})                           # down, up, cancel
box(on_touch: {self(), :pad, moves: true})              # plus moves: 16 ms / 1 dp per pointer
box(on_touch: {self(), :pad, moves: true, throttle: 0, delta: 0})   # every move

def handle_info({:touch, :pad, %{phase: :down, y: y, height: h}}, socket), do: ...
```

`on_touch` works on any node, the same way press in/out does. Every message
is `{:touch, tag, payload}`, the `{event, tag, payload}` shape every other
stream event uses, so `Mob.Listener`, `Mob.Event.Bridge` and
`Mob.Event.NativeInput` handle it the way they handle every other event. The
payload:

| Key | Value |
|---|---|
| `phase` | `:down`, `:move`, `:up` or `:cancel` |
| `pointer_id` | integer; the same from a pointer's down to its up/cancel, and different from every other pointer down at the same time anywhere in the window |
| `x`, `y` | float, dp (iOS points), relative to the node's top-left corner; outside `0..width` / `0..height` once a captured pointer has left the node |
| `width`, `height` | float, dp; the node's size when the event happened |
| `ts` | integer ms, the platform's own input-event time (Android `uptimeMillis`, iOS `UITouch.timestamp`). Monotonic; only differences mean anything |

`pointer_id` is Compose's `PointerId.value` on Android and a per-`UITouch`
counter on iOS. Both increase across touches, but the contract only promises
the two properties in the table, so an app shouldn't assume the id is small
or starts at 0. It's called `pointer_id` and not PLAN.md's `finger_id`
because a stylus or mouse pointer also gets one. There is no `pressure` yet:
nothing needs it, and adding an optional key later breaks nobody.

### Semantics

1. **Capture.** A pointer belongs to the node it went down on until it lifts.
   Both platforms already deliver touches this way: Compose hit-tests a
   pointer once, at its down, and sends that pointer's later changes only
   down that hit path; UIKit binds a `UITouch` to the recognizers it reached
   at `touchesBegan`. So a finger dragged from pad A onto pad B gives B
   nothing, while A keeps getting moves (if asked for) and the up, with
   coordinates outside its bounds.
   Nested `on_touch` nodes are observers, not consumers, so a pointer that
   lands on the inner node is also the outer node's pointer.
2. **Independence.** Each pointer is its own stream. Two fingers on two nodes
   give each node its own down and up; two fingers on one node give that node
   two pointers.
3. **Pairing.** A delivered `:down` is always followed by exactly one `:up`
   or `:cancel` for that `pointer_id`. As with press_out, the routing (pid
   and tag) is copied at the down and later events are sent from that copy,
   so a re-render while the finger is down can't strand the rest of the
   stream. A pad's down nearly always re-renders (its pressed look), and with
   two fingers the second down can land between the BEAM's `set_root` and the
   UI thread applying the new tree. So the down resolves its handle
   identity-tolerantly (same slot, pid and tag), the allowance press in/out
   and change events already have (AGENTS.md pre-empt rule 3). A strict
   lookup would drop that second finger's down, which on a drum pad is a
   missed hit. If the handle can't be resolved even that way, nothing at all
   is sent for that pointer.
4. **`:cancel`** means the platform took the pointer away: iOS
   `touchesCancelled` (an enclosing ScrollView's pan, a system gesture),
   Compose's synthesised cancel (an `ACTION_CANCEL` reaching the view), or
   the node leaving the tree, or its `on_touch` being removed, while the
   pointer is down. On Android a scrolling ancestor that takes the drag over
   doesn't cancel children in Compose, so the pointer keeps reporting until
   it lifts; iOS cancels it. The difference is documented, not papered over.
5. **Moves are opt-in and throttled per pointer.** Without `moves: true`, no
   move is sent, so a pad that only needs down/up doesn't put a message on
   the BEAM for every frame. With it, a pointer's move is sent when at least
   `throttle` ms (default 16) have passed since that pointer's last sent
   event *and* it has travelled at least `delta` dp (L1, default 1) since
   then, the same rule `throttleCheck` applies to drag. The up carries the
   final position whatever the throttle dropped. `throttle:` or `delta:`
   without `moves: true` raises at render time, so the mistake can't
   silently do nothing.
6. **No disambiguation delay on the down.** Android observes on the Initial
   pass, before any detector on the node has decided anything; iOS uses a
   `UIGestureRecognizer` with `delaysTouchesBegan = false` that sends from
   its own `touchesBegan`. Neither waits for touch slop or a double-tap
   timeout.
7. **Coexistence.** `on_touch` never consumes. `on_tap`, `on_long_press`,
   `on_double_tap`, swipes, `on_press_in` / `on_press_out` and an ancestor's
   scroll on the same node all behave exactly as without it. A quick tap
   on a node with all of them gives `touch :down` and `press_in` first, then
   `touch :up` and `press_out`, then `tap`.

### Where things live

- **Per-pointer throttle state lives with the copied routing at the C level**
  (`mob_nif.zig` touch slots; an ObjC object captured by the iOS sink block),
  not on the per-handle throttle fields drag uses, and not in Kotlin/Swift.
  The per-handle fields are one x/y per node and are zeroed by every
  `clear_taps`. Decision 2026-09-02 found that a handler which re-renders
  therefore defeats its own throttle, and a pad's handler always re-renders.
  The decision itself is a pure function in `android/jni/touch_throttle.zig`
  and `ios/mob_touch_throttle.h`, unit-tested by `zig test` and
  `test/native`, which is what makes the throttle testable at all: neither
  repo has a Kotlin or Swift test harness in CI for gesture code.
- **Android**, in mob_new's `MobBridge.kt`: one `pointerInput(Unit)` per
  `on_touch` node, reading `PointerEventPass.Initial` in a plain loop, not
  `awaitEachGesture`, which would wait for every pointer to lift before it
  saw the next down. A change that goes from pressed to not pressed is an
  up, or a cancel when it arrives already consumed: Compose's
  `onCancelPointerInput` builds its cancel as every pointer going up with
  that change consumed, and nothing upstream of a node's Initial pass
  consumes a real lift. The `finally` cancels any pointer still down when
  the detector is torn down. Handles are read through `rememberUpdatedState`
  and the detector isn't keyed on them, as for every other gesture here.
  The JNI calls are `nativeTouchDown` (returns a token), `nativeTouchMove`
  and `nativeTouchEnd`. A token carries a slot generation, so a stale one
  can't reach a slot that has since been reused.
- **iOS 18+**: `MobTouchRecognizer`, a `UIGestureRecognizer` attached through
  `UIGestureRecognizerRepresentable`, built like MOB-380's
  `MobPressRecognizer`: it never recognizes, recognizes simultaneously with
  everything, and neither cancels nor delays touches. It tracks every
  `UITouch` it is given, sends from `touchesBegan` / `Moved` / `Ended` /
  `Cancelled`, and fails once its last tracked touch is gone so UIKit resets
  it. Positions are `touch.location(in: nil)` minus the node's global frame,
  which the modifier tracks with `onGeometryChange`.
  **iOS 17 doesn't get `on_touch`.** There is no
  `UIGestureRecognizerRepresentable` there, and the only SwiftUI fallback,
  `DragGesture`, has no pointer identity, sees one finger per view and blocks
  an enclosing ScrollView (the press-in decision documents that flaw). No
  iOS 17 runtime is installed here to test a fallback anyway. Shipping an
  untested single-finger imitation would be worse than an absence that is
  documented and logged once.
- **Elixir**: `Mob.Event.Touch` owns the contract: the payload type, option
  parsing and validation, and the message builder that `Mob.Test.touch/4`
  and `Mob.ScreenCase.render_touch/4` use, so a synthetic touch has the shape
  native sends. In `Mob.Event.NativeInput`, `:down`, `:up` and `:cancel` are
  discrete (a receipt each, at the rate a person taps), and `:move` is a
  stream.
- **A tap on an `on_touch` node is identity-tolerant**, routed through
  `mob_send_press_tap` like a press node's (iOS `onTap` deserialiser,
  Android `mobIsPressNode`). Found on the iPhone SE: a pad with `on_touch`
  and `on_tap` re-rendered on its down, and the strict tap at the lift was
  dropped as stale (`pad2_taps` stayed 0 while the down/up arrived). The
  same MOB-380 argument applies: the slot must still hold the same pid and
  tag, so the delivered message is the one the tapped node declared.

## Consequences

- The Android half is in the generated app (`MobBridge.kt`, `beam_jni.c`),
  so it needs a mob_new release whose templates call the three new C
  symbols, and an app generated before that has to port the bridge changes
  (mob_new CHANGELOG lists them). A template that calls them needs a mob that
  exports them, so the mob_new release must pin a mob version that does.
- The 32 touch slots on Android are shared by every node. A 33rd pointer
  down at once gets no events (and a log line). iOS has no such limit.
- `on_drag`'s single-finger, slop-gated stream is unchanged. `on_touch` with
  `moves: true` is the primitive for anything that needs every finger.
- PLAN.md's Batch 7 "Multi-touch tracking" sketch now points here.
