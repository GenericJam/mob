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

## Separate Project: Pegleg

*Lives at `/Users/kevin/code/pegleg` — see `PLAN.md` there for the full vision.*

*Name rationale: mobile developers have been hopping on one leg (outside-in testing,
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
