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

---

## Wiretap as agent bridge — Elixir as the workflow layer

The original framing for wiretap was "MCP server for native app testing" — install
it, talk to it via MCP, ignore that BEAM is inside (analogous to RabbitMQ /
Supabase). That framing holds for the **runtime** but understates wiretap's value
when the workflow is agent-driven.

A sharper framing: **wiretap is an agent-augmented native development environment
that happens to ship a pure native app on eject.** The user writes (or reviews)
Swift/Kotlin. The agent uses Elixir during the iteration loop. The user is one
remove from the Elixir, not zero.

**Why agent quality on native is structurally lower (not just a current snapshot)**

Each of these is a 5–10× tax on agent productivity. They compound, and none are
tractable for a third party to fix:

- Swift's "expression too complex" errors land nowhere near the real problem;
  Kotlin compile + dex + reinstall is 5–13s per attempt.
- Test feedback (XCUITest, Espresso) is out-of-process, slow, returns text the
  LLM has to re-parse.
- No native equivalent of `Mob.Test.assigns` — agents infer state from rendered
  pixels, which is lossy and slow.
- Hot reload doesn't exist; every change is a full rebuild + reinstall + state
  loss.

The Elixir loop preserves BEAM state across edits, hot-loads in ~500 ms, and
gives `Mob.Test` exact-state introspection. The structural advantage isn't going
away on any timeline a vendor controls.

**Implication for wiretap's MCP surface**

If "Elixir as agent bridge" is the value prop, the MCP interface should model the
*workflow*, not just the primitives. Instead of exposing `mob_tap` / `mob_ui_tree`
and letting the agent figure out the loop, the high-leverage tools are something
like:

- `wiretap_prototype <feature spec>` — agent builds Elixir POC + tests, returns
  "passing"
- `wiretap_port <feature>` — agent translates POC to native, runs comparison,
  returns "parity achieved"
- `wiretap_test <feature>` — re-runs the suite

The native dev sees feature requests turning into PRs. They review the
Swift/Kotlin (which is what they care about). The Elixir POC is internal
scaffolding — visible if they want to look, deleted on cutover, never shipped.

This is a different product than "MCP server for native app testing." It's
closer to "agent-native app builder that happens to ship native."

**Empirical question: is the POC-then-port detour actually faster?**

This is the assumption the whole pitch rests on, and it has not been measured.
The alternative is straight-to-native: skip the Elixir phase, accept the
observation gap, and just see how effective an agent can be at writing
Swift/Kotlin directly with wiretap-driven UI verification.

**Pragmatic methodology: duelling agents.** Skip the rubric. Spawn both paths
against the same feature spec in parallel and take the first one to reach
"passing tests + reviewable PR." The race *is* the measurement. No scoring,
no defect-tracking infrastructure, no judgement calls — wall-clock is the
honest answer.

This generalises beyond measurement, and that's the bigger insight:

**Duelling as the default agent loop, not just an experiment.** Single-agent
workflows have a known failure mode — the agent gets stuck on a wrong
assumption about an API, can't see the bug, and burns iterations flailing
inside its own context. Two agents starting from different premises
(POC-with-Elixir-scaffolding vs straight-to-native-from-spec) take different
code paths, hit different walls, and succeed/fail at different rates. If one
flails, the other usually makes progress. The user is never blocked on a
single agent's blind spot.

Trade-offs to keep honest:

- **Cost**: 2× tokens per feature. Real money at scale. Probably worth it for
  load-bearing features and overkill for trivial CRUD — likely opt-in via a
  `--dual` flag, with a future mode that auto-enables it for high-stakes specs.
- **Loser's work isn't wasted.** The POC's `Mob.Test` script is valuable
  regardless of which path wins — keep it as a regression suite for the
  feature, even if straight-to-native shipped first. Same in reverse: a
  successful native impl validates the POC's spec.
- **Choosing the winner.** If both finish, wall-clock is the tiebreaker, but
  the human reviewer should see both PRs and pick on style/shape. The
  pragmatic default is "first to green ships, both stay around for a week as
  reference."
- **Spec contamination.** Both agents must get the same feature description
  with the same level of detail. If one agent has more context the comparison
  is meaningless and you're back to a single-agent workflow with extra steps.

The honest answer to the original question — POC-then-port vs straight-to-native
— may turn out to be "depends on the feature" (state-heavy → POC wins,
platform-API-heavy → native wins). Duelling sidesteps having to predict the
right answer per feature: it just runs both and lets the world decide. That's
the same pragmatism that makes the loop robust against flailing.

**UX implication: UI materialises before the code does**

If POC-then-port becomes the default agent path, native devs experience a
genuinely unusual workflow: they file a feature request and the **UI appears in
the running app first**, with the Elixir POC behind it. The Swift/Kotlin code
arrives later, already shaped by tests that pass, and is essentially a
translation exercise — open to bikeshedding on style and idiom but not on
behaviour or shape.

This inverts the normal mental model. Today: write code → see UI. With wiretap:
see UI → write code (or have the code written for you). It will feel uncanny at
first. Whether that's a feature ("the agent already validated the design, I just
review the implementation") or a bug ("I lost the design phase, all that's left
is bikeshedding") depends on the developer's relationship to the craft.

Worth surfacing in early-user docs and watching for friction. Some devs will love
it; others will reject it on principle. Both reactions are signal.

**What needs to exist for any of this to be testable**

- Wiretap MVP with the per-feature POC-then-port workflow from
  `docs/decisions/0002-wiretap-poc-then-port.md`.
- A feature corpus and scoring rubric for the head-to-head measurement.
- A reference agent loop (Claude Code with the wiretap MCP server) that defaults
  to POC-then-port but can be flagged into straight-to-native for comparison.
- A small panel of native devs willing to do side-by-side trials and report
  qualitative reactions to "UI before code."

---

## App Store-compatible release builds (libbeam.a static link)

`mix mob.release` produces a working device-installable `.ipa` today,
but it fails App Store Connect's automated validator. Four error
categories, ~17 errors total:

1. **Bundled OTP runtime contains `.so`/`.a`/standalone executables**
   (12 errors, code 90171) — Apple's bundle policy permits exactly one
   Mach-O per `.app`, no loadable libs. Currently mob copies the entire
   OTP `lib/` tree into the bundle.
2. **Test-harness NIFs reference private UIKit selectors** (1 error,
   code 50) — `tap_xy` / `swipe_xy` / `type_text` etc. in
   `ios/mob_nif.m` use `_addTouch:forDelayedDelivery:`, `_clearTouches`,
   `_setHIDEvent:`, etc. App Store auto-scans for these and rejects.
3. **Info.plist missing `MinimumOSVersion` / `DTPlatformName`** (3 errors)
4. **IPA `CodeResources` not preserved as symlink** (1 error, code 90071)

The hard one is #1. The proven approach (already validated in
`~/code/beam-ios-test`):

- Build OTP with `RELEASE_LIBBEAM=yes` → produces `libbeam.a` (~4.3 MB)
  with all NIFs/drivers compiled in. **Already built for
  `aarch64-apple-ios` and `aarch64-apple-iossimulator`** at
  `/Users/kevin/code/otp/bin/<target>/libbeam.a`.
- Static-link `libbeam.a` + supporting archives (`liberts_internal_r.a`,
  `libethread.a`, `libzstd.a`, `libepcre.a`, `libryu.a`, `asn1rt_nif.a`)
  into the main app binary at build time.
- Bundle only `.beam` bytecode files (Apple is fine with bytecode).
- Cross-compile any third-party NIFs the app uses (`exqlite` for
  SQLite-backed apps) as `.a` for the iOS targets, statically linked.

Boot time on the test rig: ~64ms cold start (M4 Pro simulator),
estimated ~120-180ms on real A18. Faster than React Native hello-world.
So the static path is also a perf win.

### Scope estimate

- ~half day: rewire `ios/release_device.sh` (or its Elixir-driven
  equivalent in `mob_dev`) to static-link rather than bundle
- ~half day: cross-build `exqlite` as `.a` for iOS device + sim targets
  (build script in mob_dev that `mix mob.release` invokes; cache the
  output)
- ~2 hours: wrap test-harness NIFs in `#if !MOB_RELEASE` (the stubs in
  `mob_nif.erl` can stay and `nif_error` at runtime — test harness
  isn't supposed to work in release mode anyway)
- ~1 hour: Info.plist `MinimumOSVersion`/`DTPlatformName` + switch IPA
  packaging from `zip` to `ditto -c -k --keepParent --sequesterRsrc`
- ~half day: end-to-end verify on iOS sim + device, then re-attempt
  App Store Connect upload until validation passes
- ~half day: tests for the new release path so this doesn't regress

Total: 2-3 days focused work in mob + mob_dev. The hardest unknown
("can we even ship a static-linked BEAM through App Store?") is
already resolved by the beam-ios-test prior art.

When this lands, the Known Limitation section in
`mob_dev/guides/publishing_to_testflight.md` and the corresponding
section in `mob/guides/publishing.md` get cleaned up, and Mob apps
become genuinely App Store-shippable.
