# Future Developments

Speculative ideas and wishlist items that are worth preserving but not yet planned.

## Security Enhancements

### Ephemeral BEAM delivery with narrow distribution window

The BEAM's introspection capabilities (`:code.get_object_code/1`, `:erlang.fun_info/1`,
`Node.connect/1`) are a unique attack surface: a connected node can pull loaded modules
back out of a running app. Mitigation ideas:

**Narrow EPMD window**
Open EPMD only for the duration of a hot-push delivery, then shut it down. Combined
with a per-session rotating cookie (only known to the delivery server), this shrinks
the connection window from "any time the app is running" to a few authenticated seconds.
`Mob.Dist` already controls distribution startup — a `Mob.Dist.open_for_delivery/1`
API could orchestrate this.

**Encrypted + ephemeral module delivery**
Sensitive logic (API endpoints, keys) delivered as BEAM bytecode rather than baked
into the app binary defeats static analysis of the installed app. Bytecode is still
readable in process memory and via Frida on a jailbroken device, so this raises the
bar against casual reverse engineering rather than eliminating the attack surface.
Requires authenticated, signed delivery — the distribution channel becomes a high-value
target if not secured.

**Known limitations**
- Memory inspection and Frida operate below the BEAM and are unaffected by any of the above
- App Store policy (Apple/Google) restricts dynamic code loading — production use would need careful positioning
- The BEAM introspection vector is Mob-specific; worth documenting as a known limitation for security-sensitive deployments

---

## Separate Project: WireTap

*Renamed from "Pegleg" — the project is now called **WireTap** (see `wire_tap.md`).
The old name is preserved below for historical context and so existing `pegleg`
references in code/notes don't read as orphaned.*

*Lives at `/Users/kevin/code/pegleg` — see `PLAN.md` there for the full vision.*

*Original name rationale: mobile developers have been hopping on one leg (outside-in testing,
screenshots, accessibility trees) without realising the support was available.
Piratey — because it pirates any app into the BEAM's control.*

A standalone mobile testing tool that embeds a minimal BEAM node in an iOS app and
exposes live app state to a desktop client. Nothing like this exists in the mobile
testing space today — all current tools (XCUITest, Espresso, Detox, Appium, Maestro)
interact with apps from the outside via accessibility APIs and screenshots, with no
knowledge of actual app state.

**What it would provide**
- Exact screen state and data after every interaction — no polling, no arbitrary sleeps
- Drive interactions at the logical level (tap by intent, not by coordinate)
- Inject any device scenario (camera result, location, permissions, notifications) without OS-level mocking
- Assert on application state directly rather than inferring from rendered output
- MCP server interface so AI agents can drive and verify app behaviour

**Why it matters for Elixir adoption**
The tool is a Trojan horse. Developers encounter a genuinely useful, free testing tool
and discover a connected BEAM node giving them capabilities they've never had before.
Elixir adoption happens as a side effect of solving a real pain point — a better first
impression than any tutorial.

**Key insight: thin NIF as a universal wrapper**
Pegleg doesn't require the host app to be written in Elixir or use Mob at all. A thin
NIF library linked into any iOS or Android app — SwiftUI, React Native, Flutter, whatever
— starts a BEAM node in the background and intercepts/injects touch events at the NIF
level, below the app's own UI layer. The developer adds one dev dependency and their
existing app gains a fully connected test rig without changing their framework.

**Initial target**
iOS-first. The simulator shares the Mac's network stack so there's no tunneling
complexity. iOS developers are underserved by current testing tooling and have budget.
Android is a separate developer community and can follow independently.

**Prototype scope**
Small — the core API (`Mob.Test`) is already built as part of Mob. A prototype is an
Elixir CLI or desktop app that connects to a running node, displays current screen and
assigns, and exposes tap/navigate/inject. Weeks of work, not months.

**Element detection and touch injection**

For Mob apps, element detection is free — the component tree lives in the BEAM already.
Every element, its type, bounds, visible text, and tag are queryable without screenshots:

```elixir
Pegleg.find(node, "Submit")           # find by visible text
Pegleg.elements_at(node, {142, 386})  # what's at this coordinate?
```

For third-party apps (SwiftUI, React Native, Flutter, etc.), Pegleg falls back to the
platform accessibility tree or a vision model on a screenshot to locate elements, then
injects a real platform touch event — not a simulated one:

- **iOS**: synthesize a `UITouch` and deliver it via `UIApplication.sendEvent()` through
  the responder chain. The app cannot distinguish it from a real finger.
- **Android**: inject via `Instrumentation.sendPointerSync()` or `UiAutomation` using
  a real `MotionEvent`.

The BEAM stays in the business of logic and coordination; the native Pegleg layer handles
platform mechanics. Apps receive real platform events regardless of their framework.

```
BEAM node
  ↓ logical command ("tap Submit")
Native Pegleg layer (Swift/Kotlin)
  ↓ resolves element bounds
  ↓ injects UITouch / MotionEvent
Host app receives real platform touch event
```

**Record and replay**

Because Pegleg captures semantic events rather than coordinates, recordings are stable
across device sizes and OS versions. A recorded session captures intent:

```
tap :submit  (screen: CheckoutScreen, assigns: %{form: %{valid: true}})
```

Not position:

```
tap x:142 y:386  ← breaks when layout shifts
```

Recordings serve two purposes:
- **Regression tests** — replay the sequence and assert assigns match expected values at each step
- **Generated test files** — export an ExUnit test from the recording that developers can commit, read, and edit

The generated test removes the biggest barrier to test adoption: writing them. Record a
manual interaction, get a meaningful test file, commit it.

**Business model**
Open source the tool to drive Elixir exposure. Potential commercial layer around cloud
device farms, CI integration, or selling the same workflow to other app agencies as
internal tooling.

**Why this area is significant**
The intersection of BEAM and mobile is largely unexplored. The properties that make the
BEAM exceptional for backend observability — live introspection, distribution, hot code
loading, process isolation — translate directly into mobile testing capabilities that
the existing tools can't match. Pegleg is one expression of that; there are likely others.

### Stretch goal: framework-agnostic UI introspection (sidecar mode)

The "agent introspects any native app" promise of WireTap requires UI walkers that
don't depend on the app being a Mob app. Today's `mob_nif:ui_tree/0` works for Mob
apps via two strategies — a UIView walk on iOS, and (planned) an `onGloballyPositioned`
registry baked into Mob's Compose renderer on Android. Both stop being useful the
moment WireTap attaches to an app the developer wrote without Mob.

**The asymmetry**

| Platform | Mob apps | Sidecar / arbitrary apps |
|---|---|---|
| iOS (UIKit/SwiftUI) | UIView walk works for both — SwiftUI compiles down to UIView | Same UIView walk works |
| Android (Views) | View walk works | Same View walk works |
| Android (Compose) | Registry via Mob renderer | **Stops at `AndroidComposeView` — needs a separate walker** |

So the gap is specifically: *arbitrary Compose apps in sidecar mode*. iOS is fine
either way; Android plain-View apps are fine either way; Compose apps need a
semantics-tree walker.

**Why this likely lives in WireTap, not Mob**

Mob's renderer can keep using the simpler `onGloballyPositioned` registry — it's
faster, eject-safer, and Mob owns its renderer so there's no awkward reflection.
The Compose-semantics walker is only needed for the sidecar use case, which is
WireTap's core pitch (testing apps the developer didn't write in Elixir). Putting
it in WireTap keeps Mob lean and lets WireTap evolve its native introspection
independently of the Mob library version.

**What the walker has to do**

1. Find every `AndroidComposeView` in the View hierarchy (one per Compose root —
   activity content, dialogs, popups each get their own).
2. Pull the `SemanticsOwner` from each — accessible only via reflection, since
   the property is `@RestrictTo(LIBRARY_GROUP)`. UIAutomator and the Compose
   Inspector both do this.
3. Walk the `SemanticsNode` tree (`.children`, `.config`, `.boundsInWindow`).
4. Extract `SemanticsProperties.{Text, ContentDescription, Role, EditableText, …}`
   — pick the right ones to match the iOS UIView walk's tuple shape.
5. Choose merged vs unmerged tree (default: unmerged, finer-grained for testing).
6. Convert pixel bounds to dp.

**Cost estimate**

Initial implementation: ~200 lines Kotlin + ~40 lines JNI wiring, roughly one
focused day to first version. Ongoing maintenance: 1-2 days every 6-12 months
reacting to Compose API churn (the reflection paths break across major Compose
versions — UIAutomator's git history is the reference here).

**iOS counterpart — programmatic AX activation (a real requirement, not just polish)**

iOS doesn't have the Android Compose problem at the *tree* level for plain
UIKit: a UIView walk sees the whole hierarchy. But for **SwiftUI** specifically
— which is what Mob renders to today, and what most modern iOS apps use —
the View walk is shallow. SwiftUI doesn't materialize its content as separate
UIView instances under the hosting view. Buttons, labels, sliders all live
inside private SwiftUI rendering types that the walker can't classify.

The semantic content lives in iOS's accessibility tree, but here's the catch:
**SwiftUI's accessibility tree is lazy.** It only materializes when an
accessibility *service* is actively querying — VoiceOver, Switch Control,
Voice Control, or an automation client. With nothing active, `mob_nif:ui_tree/0`
returns an empty list even though the app is rendering normally.

Today's workaround in this codebase: ask the user to toggle VoiceOver on in
Settings before any AX-based introspection (`ui_tree`, `tap` by label,
`ax_action`, `adjust_slider`). It works but it's awful UX and shouldn't be
how the cocoon model presents itself to a developer.

**The fix that makes this a non-issue: link `XCTAutomationSupport.framework`
debug-only and call `[XCAXClient_iOS sharedClient]` once at NIF load.**

`XCTAutomationSupport` is shipped with Xcode and is what XCUITest uses under
the hood. Calling its `XCAXClient_iOS` initializer registers the process as
having an active AX client, which causes SwiftUI to start materializing its
accessibility tree — without any VoiceOver UI, no audio narration, no
Settings toggle for the user.

```objc
// In mob_beam.m or mob_nif.m, debug builds only
#if DEBUG
@import XCTAutomationSupport;  // weak-linked, debug-only
[XCAXClient_iOS sharedClient]; // tree comes alive
#endif
```

| Platform / framework | AX tree availability today | Production fix |
|---|---|---|
| iOS UIKit (sidecar against UIKit app) | ✅ View walk works directly | None needed |
| iOS SwiftUI (Mob today, modern iOS apps) | ❌ Needs VoiceOver toggle — cheating | Link `XCTAutomationSupport`, AX active automatically |
| Android plain Views | ✅ Always available | None needed |
| Android Compose | ✅ Eager semantics (private API) | Reflection paths in walker |

The production-build risk: `XCTAutomationSupport` is not an App Store-shipping
framework. Linking it must be **debug-only** with build-config gates so release
builds never touch it. Same trust model as the rest of mob's debug sidecar
philosophy: invisible to production, full-featured in development.

This lands in **WireTap, not Mob** — same reasoning as the Compose walker.
Mob apps can keep using the Mob render tree (`Mob.Test.tree/1`) for their own
introspection without needing the AX subsystem at all. WireTap's pitch is
"introspect any app, including non-Mob ones," and that pitch only delivers
once the AX tree comes alive without user action.

There's also a touch-level gap worth noting: synthesizing a `UITouch` that
fires SwiftUI's own gesture recognizers (`DragGesture`, `LongPressGesture`,
`MagnificationGesture`) doesn't work reliably with our current
`IOHIDEventCreate` path. Synth touches reach the app's responder chain (so
`accessibilityActivate`-style button taps fire) but SwiftUI gesture
recognizers want internal touch properties (`_phase`, `_locationInWindow`)
that synthesized touches don't carry. The mitigation today is to use AX
actions for sliders/scrolls/escapes (see `Mob.Test.ax_action/3`); the proper
sidecar fix is the same `XCTAutomationSupport` activation, which historically
also enables a richer touch-injection path.

System-level gestures iOS owns *above* the application process — edge-pan
back, swipe-up app switcher, pull-down notification center — are
fundamentally out of reach for in-process synthesis on physical devices.
For the simulator, `xcrun simctl io booted touch` from outside the process
is the privileged path; for sidecar mode against a real device, there isn't
one. Document the limitation; don't promise it.

**Decision (today)**

Phase 1 ships the simpler strategy on both platforms (iOS View walk; Android Mob
registry). Phase 2 — Compose-semantics walker + iOS AX activation — gets queued
under WireTap when there's a real sidecar customer to validate the design against.
Don't pre-build it in Mob.

## Cross-app WebView via shared loopback broker

Surfaced when investigating the LV-port-collision bug (issues.md #4): every Mob LV
app's WebView loads `http://127.0.0.1:<port>/`, and on iOS/Android the loopback
interface has no UID-based filtering. Any process on the device can bind a loopback
port and any other app's WebView can load from it. That's a footgun for spoofing,
but it's also a *primitive*.

**The pattern**

A Mob app on the device runs a "broker" — a small Phoenix endpoint (or even just
Bandit + Plug) on a known loopback port (or one published over `Mob.Cluster`). Other
Mob LV apps' generated `mob_app.ex` accepts an optional `liveview_url:` env var that
overrides the default `http://127.0.0.1:4200/`. When set, the WebView loads from the
broker instead of from its own BEAM's endpoint.

The broker can:
- Serve a UI of its own that the other apps render (shared chat surface, system tray,
  notification dropdown).
- Proxy/stitch content from other Mob apps' BEAMs over Erlang distribution (each Mob
  LV app's BEAM is a node — `Mob.Cluster.join/2` already gets you there). The broker
  becomes a dispatcher rather than a content source.
- Mediate "switch into this other app's view" flows without OS-level intent plumbing.

Combined with `Mob.Cluster`, this gives you cross-app collaboration on a single
device with no IPC layer to design. The mechanism is just HTTP over loopback +
distributed Erlang.

**Why this is interesting**

Mobile apps have historically been silos. Cross-app communication on iOS/Android is
limited to URL schemes, share sheets, and (rarely) document providers — all
heavyweight, all mediated by the OS. Loopback + BEAM dist lets independent Mob apps
on the same device collaborate at the level of Erlang processes and HTML, with
sub-millisecond latency and arbitrary-shape data.

**What it needs**

- `Mob.Broker` GenServer in mob (or a separate `mob_broker` package) — minimal
  Phoenix/Bandit pipeline that can serve LV-rendered content and dispatch.
- `liveview_url:` override in the LV generator's `mob_app.ex` so apps can be told
  "load from the broker" at deploy time.
- Discovery: the broker advertises its port over `Mob.Cluster` so client apps don't
  need to know it ahead of time. Each app on first launch tries to connect to a
  well-known broker node name; if found, uses its URL; if not, falls back to its own
  endpoint.

**Caveat: this is the same primitive as the spoofing risk**

Anything that lets a "broker" hijack other apps' WebViews also lets a hostile app
do the same. Mitigations are the same: signed URL tokens, per-app port via bundle-id
hash (issues.md #4 fix option 1 makes this harder accidentally), or a handshake over
distribution before the WebView is told to load from the broker.

The architecture is interesting *because* it's the same loopback weakness mobile
platforms have always had — Mob is the first thing that makes it useful instead of
just dangerous.
