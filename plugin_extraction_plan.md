# Plugin extraction plan

This is the rolling tracker for migrating core mob modules into plugins
under `MOB_PLUGINS.md` and `MOB_STYLES.md`. It captures sequencing,
open questions, and the rationale for what stays vs what leaves core.

## Scope — the lanes mob is in

Mob's design lanes are explicit. Picking a small number of lanes the
framework excels at beats spreading thin across every possible
direction. The lanes:

1. **Elixir-first.** The first-class authoring language. The
   `~MOB"""..."""` sigil, screen lifecycle macros, theme structs,
   and tooling (`mix mob.*`) target Elixir developers. Ergonomic
   surface gets prioritized for Elixir.
2. **BEAM-native.** Apps live as supervised BEAM processes on
   device. Distribution, hot-push, screen GenServers, the OTP
   release model. The framework's value proposition rests on this.
3. **Gen AI enabled.** Both the app surface (clean integration of
   LLM clients, on-device inference via NIFs and Pythonx, agent
   patterns for end-user features) and the development surface
   (mob is built to be hospitable to AI-pair-programmers — the
   existing `guides/agentic_coding.md` is the entry point).

### What's explicitly parked

These directions are valid use cases that mob is not actively
designing for. The door is left open for ambitious plugin authors
to attempt them, but the framework's design decisions don't try
to enable them at the cost of clarity in the chosen lanes.

- **Full-language frontends in non-BEAM languages** (entire app
  written in Python via Pythonx, JS via QuickJS, Lua, etc.). The
  hooks exist conceptually — see `MOB_PLUGINS.md` "Future:
  full-language plugins." Anyone determined enough can build it;
  the spec doesn't currently provide a turn-key path.
- **Native-only apps using BEAM as a backend service.** This is
  inverted from mob's architecture (mob owns the runtime; native
  is the rendering surface). Use Phoenix / a separate Erlang
  service if that's the shape you want.
- **Web/PWA targets.** Mob is mobile-first. Phoenix LiveView is
  already excellent for web; we're not competing.
- **Cross-platform pixel-identical UI by default.** Each platform
  uses native primitives. Pixel parity is achievable via style
  plugins (see `MOB_STYLES.md`) but isn't the default behavior.

The lanes determine which extensions are first-class and which
rely on community initiative. A plugin in-lane gets framework
infrastructure designed to support it (theme presets, Gen AI
integrations, NIF language packs). A plugin out-of-lane has to
build more of its own scaffolding — and that's fine, but the
framework won't co-evolve to make it easier.

The plan has three phases:

1. **Prototype phase** — build greenfield prototype plugins at each
   tier (plus one style) as local `path:` deps. Validates the
   manifest schema, compile-time merge, native dispatch table, and
   style cascade against fresh code. No core churn.
2. **Vetting infrastructure** — design and partially implement the
   trust model from `MOB_PLUGIN_SECURITY.md` in parallel with phase 1.
   Real extractions wait for this to land.
3. **Extraction waves** — once the infrastructure proves itself,
   migrate existing core modules into plugins in sequenced waves. Each
   wave produces a real Hex package, vetted via the new tooling,
   replacing the in-core module with a no-op deprecation stub for one
   minor cycle.

Each phase has its own checklist below. Tick boxes as work lands.

There's a **Phase 0** below — preconditions that must be true before
the rest is productive. Do those first.

## Phase 0 — Preconditions

Done before Phase 1 begins. None of these are large; collectively
they unblock the rest.

- [ ] Design docs committed to master: `MOB_PLUGINS.md`,
  `MOB_STYLES.md`, `MOB_PLUGIN_SECURITY.md`, this file. Push to
  origin so the design is reviewable by anyone tracking the repo.
- [ ] Premature implementation reverted from any active branches
  (the in-flight Swift edits to `MobToggle` / `MobTextField` were
  reverted on the material-3 worktree; the worktree itself should
  be retired or repurposed — its branch name no longer matches the
  work).
- [ ] `plugins/` directory created at the working host's level
  (initial host: `mob_m3_test`). This is where the Phase 1
  prototype `path:` deps will live.
- [ ] **Rustler env-var fix tested and confirmed working on a
  physical Android device.** This unblocks the tier-1.5 Rust NIF
  prototype in Phase 1 and the eventual `mob_rustler` extraction
  in Wave 1.5. Brief: `agent_briefs/rustler_env_var_test.md`.
- [ ] `MobDev.Plugin.host_config/3` API stubbed (can be a one-line
  `Application.get_env/3` wrapper for now — the point is the call
  surface exists so Phase 1 prototypes can use it). The spec-v2
  generator prototypes need this.

These preconditions are independent and parallelizable. Items 1-3
and 5 are author-driven (Kevin or in-conversation work). Item 4 is
delegated to the agent brief.

### Phase 0 exit criteria

- [ ] Design corpus visible on `origin/master`.
- [ ] `plugins/` directory exists, ready to receive `path:`-deps.
- [ ] At least one rustler-based NIF demo deploys to a physical
  Android device and resolves `enif_*` symbols correctly.
- [ ] `MobDev.Plugin.host_config/3` callable from a generated
  context (verified by a trivial test reading a known config key).

## Phase 1 — Prototype plugins

Six local-only packages under `plugins/` in the working directory,
wired into `mob_m3_test` (or a dedicated demo host) via `path:` deps.
The intent is to exercise every code path in the manifest schema
before touching real code.

### `plugins/mob_palette_demo` (Tier 0)

Pure Elixir helper. No manifest required.

- [ ] Hex package with one module: `MobPaletteDemo.suggest_complement/1`
- [ ] Depends on `:mob` (`~> 0.6`).
- [ ] No `priv/mob_plugin.exs` at all — proves tier-0 path works.

**Validates:** `mix mob.plugins` correctly reports "no manifest, treated
as regular dep." The framework's compile step does nothing special.

### `plugins/mob_demo_haptic_extras` (Tier 1)

NIF + Elixir wrapper. The native code is trivial (returns a constant)
so the focus is on the build pipeline.

- [ ] `priv/mob_plugin.exs` with `:nifs`, `:ios.frameworks`,
  `:android.gradle_deps`.
- [ ] Minimal NIF in `priv/native/jni/haptic_extras.c` (one function
  returning `:ok`).
- [ ] Elixir wrapper `MobDemoHapticExtras` that loads the NIF.

**Validates:** static-NIF merge into `libpigeon.so` (Android) and the
host's iOS binary. The host can call the wrapper from any screen.
Confirms the no-dlopen rule survives plugins.

### `plugins/mob_demo_signature_pad` (Tier 2)

New `<SignaturePad>` component. The drawing is a no-op (renders a
single colored rectangle) — focus is on `:ui_components` registration.

- [ ] Manifest's `:ui_components` declares the tag/atom + view names.
- [ ] iOS: `priv/native/ios/MobSignaturePadView.swift` — simple
  `RoundedRectangle` view that reads `bg_color` and `corner_radius`
  from the node.
- [ ] Android: `priv/native/android/MobSignaturePad.kt` — same shape.
- [ ] Host (`mob_m3_test`) renders `<SignaturePad bg_color={:primary}
  corner_radius={:radius_lg} />` on a test screen.

**Validates:** the native dispatch table picks up the plugin's view
class names, the renderer routes correctly, props flow through.

### `plugins/mob_demo_kv_browser` (Tier 3)

Multi-screen plugin — a browse-screen for the contents of
`Mob.Storage`. Real-ish utility, simple enough to ship.

- [ ] Manifest's `:screens`, `:migrations`, `:assets` populated.
- [ ] Two screens: `MobDemoKvBrowser.ListScreen` and
  `MobDemoKvBrowser.DetailScreen`.
- [ ] One trivial Ecto migration in `priv/repo/migrations/` (with
  `repo_namespace: "mob_demo_kv_browser_"`).
- [ ] One bundled font in `priv/assets/fonts/`.
- [ ] Host wires the screens into `App.navigation/1` after activation.

**Validates:** screen module discovery + route declaration, migration
prefix collision rules, asset merging, the `mix mob.add_plugin`
interactive flow (if implemented).

### `plugins/mob_demo_uptime_kit` (Tier 4)

Embedded sub-app. Pings a hardcoded URL every 30s (interval is a
setting) and exposes a status screen + a notification handler.

- [ ] Manifest with full `:lifecycle`, `:settings`, `:notifications`
  sections.
- [ ] `MobDemoUptimeKit.PingWorker` GenServer under the host's
  supervisor.
- [ ] `MobDemoUptimeKit.SettingsScreen` editor.
- [ ] Notification handler reacts to a fake `%{type: "uptime_alert"}`
  push.

**Validates:** supervisor wiring, settings schema validation,
notification dispatch by handler-match, `on_resume` / `on_background`
lifecycle hooks.

### `plugins/mob_style_neutral_loud` (Style)

A deliberately-loud style for visible verification of the dispatch.
Replaces the `<Toggle>` thumb with a hot-pink square, the `<Button>`
with a thick black border + yellow fill. Easy to see "is the override
working?" at a glance.

- [ ] `priv/mob_style.exs` with `:theme`, `:component_views` for
  `:toggle` and `:button`.
- [ ] Theme struct module `MobStyleNeutralLoud.Theme` with garish but
  valid token values.
- [ ] iOS + Android primitives following the prop contracts for Toggle
  and Button.
- [ ] Host activates as `config :mob, :styles, [:mob_style_neutral_loud]`
  + `config :mob, :default_style, :mob_style_neutral_loud`.
- [ ] Per-element opt-out tested: `<Toggle style={nil}/>` should fall
  back to baseline.
- [ ] Cherry-pick tested: install the loud style + a hypothetical
  `mob_style_neutral_quiet` (token-only, no overrides), verify
  per-element `style:` props swap correctly.

**Validates:** `MOB_STYLES.md` end-to-end — cascade resolution, native
registry keyed by `(style_name, atom)`, baseline fallback, the prop
contract.

### `plugins/mob_demo_ash_resources` (Code-generated tier 3+)

Validates the spec-v2 `:screens_generator` and `MobDev.Plugin.host_config/3`
path. This must work before we let other parties (Ash maintainers, in
particular) build on the plugin system — if it can't be done, the
extensibility story is incomplete.

- [ ] Minimal Ash-shaped domain in the host (one stub resource —
  `MobM3Test.Note` with `:title` / `:body` attributes, in-memory
  storage, no real database needed for the prototype).
- [ ] `priv/mob_plugin.exs` with `plugin_spec_version: 2` and
  `screens_generator: {MobDemoAshResources.ScreenGenerator, :generate, []}`.
- [ ] `MobDemoAshResources.ScreenGenerator.generate/0` reads host
  config via `MobDev.Plugin.host_config(:mob_m3_test, :ash_resources, [])`
  and returns a list of three generated screens per resource.
- [ ] Generated modules created with `Module.create/3` at compile
  time. Each screen renders a placeholder UI (`<List>` of attribute
  rows for the list screen; a `<Form>`-shaped thing for the form
  screen — actual Ash integration is out of scope here, this is
  about the codegen path).
- [ ] Host wires the generated routes into `App.navigation/1`.
- [ ] Removing the resource from `:ash_resources` removes the screens
  on next compile (no stale modules).
- [ ] Adding a second resource doubles the screen count on next
  compile, verifying the generator runs each time.

**Validates:** compile-time generator invocation, the
`MobDev.Plugin.host_config` API surface, `Module.create/3` for
generated screens, spec-v2 versioning, the path Ash (or any other
code-generating ecosystem) would actually use.

### Phase 1 exit criteria

- [ ] All six prototypes deploy and render on iOS sim, iOS device,
  Android emulator, Android physical device.
- [ ] `mix mob.plugins` and `mix mob.styles` list and describe each
  correctly.
- [ ] Hot-push deploys an Elixir-only change in the tier-3 plugin
  without rebuild (the part that's hot-pushable).
- [ ] Removing a plugin from `config :mob, :plugins` cleanly removes
  its contributions from the next build.
- [ ] The contract test suite from `MOB_STYLES.md` runs against
  `mob_style_neutral_loud` and passes.

## Phase 2 — Vetting infrastructure (parallel)

See `MOB_PLUGIN_SECURITY.md` for the trust model design.
Implementation tasks belong here.

- [ ] `mix mob.audit_plugins` — scan activated plugin sources for
  flagged patterns (`Code.eval_string`, `:erlang.binary_to_term/2`
  with untrusted input, undeclared file/network access).
- [ ] Plugin manifest signing — extend `mix hex.publish` flow with
  a mob-specific signature over the manifest + native source tree.
- [ ] Capability enforcement at compile time — refuse to merge iOS
  frameworks or Android permissions for plugins that don't declare
  them in the manifest.
- [ ] Source-hash pinning in `mix.lock` for plugin `priv/native/` trees.
- [ ] Plugin allowlist / concerns feed — fetched by `mix mob.doctor`.
- [ ] Wire vetting status into `mix mob.plugins` output (alongside
  installed-but-not-activated, hot-pushability, etc.).

Phase 2 doesn't have to be fully shipped before Phase 3 begins, but
the *trust model and manifest-signing format* should be locked before
extracting modules that previously enjoyed implicit trust as part of
core.

### Phase 2 exit criteria

- [ ] `mix mob.audit_plugins` runs against the Phase 1 prototypes
  and produces correct results (clean findings for the well-behaved
  ones; flagged findings for any deliberately-crafted test cases).
- [ ] Manifest signing format locked: format documented in
  `MOB_PLUGIN_SECURITY.md` is stable; reference implementation
  signs + verifies a prototype manifest end-to-end.
- [ ] Capability enforcement demonstrably refuses to merge an
  undeclared iOS framework or Android permission. Test by adding
  an undeclared framework to a prototype's source and confirming
  the build fails with a clear error.
- [ ] `:acknowledge_unsafe_plugins` flow works: building with an
  unsigned plugin without the acknowledgement fails; with it,
  succeeds + prints the persistent banner.
- [ ] `mix mob.plugins` output shows signing/audit/vetting status
  for each installed plugin.

## Phase 3 — Extraction waves

Once Phase 1 + Phase 2's manifest signing is in place, migrate
existing modules out of core. Each extraction:

1. Creates a new Hex package mirroring the existing module's API.
2. Includes the in-tree tests (moved over) plus a contract test
   showing parity with the previous core behavior.
3. Leaves a deprecation stub in core for one minor version, then
   removes.
4. Updates `mob_new`'s generated project to depend on the plugin
   when the user opts in via the wizard.

Each wave produces multiple plugins. Run in parallel within a wave.

### Wave 1 — proves the extraction shape

Just one plugin, the heaviest non-essential dep:

- [ ] `mob_bluetooth` ← extracts `lib/mob/bt.ex` + `lib/mob/bt/{hfp,hid,spp}.ex` (548 LoC + native)
  - Already documented as the canonical tier-1 example in `MOB_PLUGINS.md`.
  - Permissions: `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `NSBluetoothAlwaysUsageDescription`.

### Wave 2 — privacy-heavy capabilities

Each needs `Mob.Permissions` integration. Demonstrates the
permission opt-in story.

- [ ] `mob_camera` ← `lib/mob/camera.ex` (165 LoC + heavy iOS/Android)
- [ ] `mob_location` ← `lib/mob/location.ex` (65 LoC + native)
- [ ] `mob_notify` ← `lib/mob/notify.ex` (107 LoC + APNs/FCM routing)
- [ ] `mob_photos` ← `lib/mob/photos.ex` (33 LoC + native)
- [ ] `mob_biometric` ← `lib/mob/biometric.ex` (28 LoC + native)

### Wave 3 — specialty

- [ ] `mob_vendor_usb` ← `lib/mob/vendor_usb.ex` (334 LoC). The
  air_cart_max use case. Very specialized.
- [ ] `mob_scanner` ← `lib/mob/scanner.ex` (47 LoC). Likely depends
  on `mob_camera`.
- [ ] `mob_webview` ← `lib/mob/webview.ex` (48 LoC + heavy native).
- [ ] `mob_canvas` ← `lib/mob/canvas.ex` (272 LoC + draw ops).

### Wave 4 — theme presets as style packages

These extract under `MOB_STYLES.md`, not `MOB_PLUGINS.md`. Can run
in parallel with Wave 1.

- [ ] `mob_theme_material3` ← `lib/mob/theme/material3.ex` (191 LoC)
  + custom native primitives for Toggle/TextField/Button to match
  M3 spec pixel-perfectly.
- [ ] `mob_theme_obsidian` ← `lib/mob/theme/obsidian.ex` (token-only)
- [ ] `mob_theme_citrus` ← `lib/mob/theme/citrus.ex` (token-only)
- [ ] `mob_theme_birch` ← `lib/mob/theme/birch.ex` (token-only)

**Stays in core (baseline):** `theme/light.ex`, `theme/dark.ex`,
`theme/adaptive.ex`, `theme/adaptive_watcher.ex`. These are the
no-style-installed path described in `MOB_STYLES.md`.

### Wave 5 — small fries (optional)

Only if a minimal core is desired. Skip otherwise.

- [ ] `mob_audio` ← `lib/mob/audio.ex` (107 LoC)
- [ ] `mob_motion` ← `lib/mob/motion.ex` (48 LoC)
- [ ] `mob_share` ← `lib/mob/share.ex` (25 LoC)
- [ ] `mob_haptic` ← `lib/mob/haptic.ex` (41 LoC)
- [ ] `mob_clipboard` ← `lib/mob/clipboard.ex` (46 LoC)

### Wave 6 — Gen AI plugins (in-lane, new packages)

These are *not* extractions from core — they're new plugins that
flesh out the "Gen AI enabled" design lane stated above. Listed
here so the lane has concrete deliverables. Each is independently
useful, ships on its own timeline, and validates that the plugin
system handles AI-shaped capabilities cleanly.

- [ ] `mob_llm` — generic LLM client. One protocol, multiple
  providers (Anthropic, OpenAI, Bedrock, local-via-mob_pythonx).
  Tier-1 (NIF-free; just HTTP + streaming). Becomes the canonical
  way mob apps call cloud LLMs.
- [ ] `mob_speech` — speech-to-text + text-to-speech. STT via
  Whisper-on-device (mob_pythonx + Whisper.cpp via NIF, or
  iOS/Android system APIs). TTS via system APIs. Tier-1/2.
- [ ] `mob_local_llm` — on-device LLM inference. Backends: llama.cpp
  (via Zig NIF), MLX on iOS (already partially in mob's existing
  ML work). Tier-1.5 (language-pack pattern, since it ships an
  inference runtime).
- [ ] `mob_embeddings` — vector embeddings + vector store. Local
  vector DB (sqlite-vec via NIF) + remote embedding APIs. Tier-1.
- [ ] `mob_rag` — RAG pattern helpers. Depends on `mob_llm` +
  `mob_embeddings`. Tier-0/1.
- [ ] `mob_agent_kit` — multi-step agent loop primitives (tool use,
  conversation state, tool registry). Tier-3 (ships screens for
  agent inspection + chat UI). Depends on `mob_llm`.

The framework's job is to make sure these compose cleanly — a mob
app should be able to install `mob_llm` + `mob_speech` +
`mob_agent_kit` and have them work together without per-pair glue.

### Phase 3 exit criteria

Per-wave exit criteria — a wave isn't done until all of these hold
for every plugin in it:

- [ ] Plugin is a real Hex package (or stable git tag), versioned,
  documented, hexdocs published.
- [ ] In-core module replaced with a deprecation shim that
  re-exports from the new plugin for one minor cycle (with a
  deprecation warning), then removed in the cycle after.
- [ ] Contract tests demonstrate parity with the previous in-core
  behavior — same API surface, same return shapes.
- [ ] `mob_new` generator updated to depend on the plugin via the
  wizard's opt-in question.
- [ ] CHANGELOG and migration notes published.

Phase 3 as a whole is done when every wave's plugins are landed +
the deprecation shims are removed. Realistically a multi-quarter
process; expect to release intermediate mob versions during.

## What stays in core, finalised

Re-stated here so the boundary is explicit.

**UI runtime:** `renderer.ex`, `ui.ex`, `sigil.ex`, `component.ex`,
`component_registry.ex`, `component_server.ex`, `nav/`.

**App lifecycle:** `app.ex`, `screen.ex`, `screen_state.ex`,
`socket.ex`, `state.ex`.

**Distribution + diagnostics:** `dist.ex`, `dns.ex`, `event/`,
`event.ex`, `live_view.ex`, `native_logger.ex`, `diag.ex`,
`formatter.ex`, `list.ex`, `registry.ex`.

**Storage primitives:** `storage.ex` + `storage/`.

**Files:** `files.ex` — small, universal.

**Permissions coordinator:** `permissions.ex` — every privacy-gated
plugin depends on it. Stays as the central point of integration.

**Device detection:** `device.ex`, `device/android.ex`,
`device/ios.ex`.

**Theme baseline:** `theme.ex` + `theme/{light,dark,adaptive,adaptive_watcher}.ex`.
These are the no-style-installed path. The neutral baseline that hand-coding
users rely on.

**Test harness:** `test.ex` — plugins themselves need this to be
testable.

## Open questions parked deliberately

- **Inter-plugin dependencies.** `mob_scanner` likely depends on
  `mob_camera`. Does Hex's existing dep resolution handle it
  cleanly, or do we need a `:requires` field in the manifest? Likely
  the former; verify before Wave 2.
- **Hot-push under multi-plugin loads.** With 5+ plugins active,
  does `mix mob.push` correctly diff per-plugin and skip native
  rebuilds for plugins that didn't change? Test during Phase 1
  with the prototypes.
- **CI matrix.** Each plugin's CI is independent. The host app's CI
  matrix grows by `(plugins choose 2) + 1` if we want to test pairwise
  combinations. Probably overkill; ship "no plugins" + "all plugins"
  + per-plugin and accept the gaps.
- **Re-installation of capabilities the user already wrote against.**
  When `lib/mob/bt.ex` extracts to `mob_bluetooth`, every existing
  app using `Mob.Bt` breaks unless we keep an alias. A one-cycle
  deprecation shim that re-exports the moved module from core
  buys time. Decide per-extraction.
- **Plugin discoverability.** Once there are 20+ plugins on Hex,
  users need a curated entry point. `awesome-mob` or
  `mob.docs/plugins` index, refreshed weekly from Hex.
- **Version-skew between plugin and core.** A plugin built against
  mob 0.6.x might break on 0.7.x. The `mob_version` requirement
  already enforces this at compile time, but the user UX when the
  constraint fails needs polish — clear "this plugin needs an
  update" message + suggested action.

## Risk register

Top risks worth tracking. Listed with current mitigation thinking; revisit when each phase begins.

- **Phase 1 surfaces a manifest design flaw.** Building the seven
  prototypes is the test of whether `MOB_PLUGINS.md` / `MOB_STYLES.md`
  hold up. *Mitigation:* prototypes are local `path:` deps, not
  published — the manifest spec can revise via spec_version bump
  before any plugin is in user hands.
- **Native build complexity for tier-1.5 (Rust, Python) plugins.**
  Cross-target toolchain coordination is hairy. *Mitigation:* the
  rustler env-var fix (Phase 0) confirms the static-link path works
  end-to-end; Pythonx is already running on-device in the existing
  codebase, so the extraction is reorganization, not new R&D.
- **Plugin combinatorial blow-up.** With 20+ plugins on Hex, pairwise
  testing is intractable. *Mitigation:* per `MOB_STYLES.md`, the
  cascade is computed Elixir-side and native dispatch is a flat
  table — plugins compose by construction, not by ad-hoc glue. CI
  matrix is "no plugins" + "all common combinations" + per-plugin.
- **Migration friction for existing Mob apps.** When `lib/mob/bt.ex`
  moves to `mob_bluetooth`, every app using `Mob.Bt` breaks.
  *Mitigation:* one-cycle deprecation shim re-exporting the moved
  module. Concrete pattern documented per-wave in Phase 3.
- **Supply-chain trust expectations exceed what we can guarantee.**
  `MOB_PLUGIN_SECURITY.md` is explicit that mob is not a sandbox and
  the curated allowlist isn't gatekept entry. *Mitigation:*
  prominently surface the trust model + non-promises in user docs;
  don't oversell.
- **filmor / rustler upstream relationship.** The PR may stall or
  not land; the env-var approach may need iteration. *Mitigation:*
  the `GenericJam/rustler` fork already exists; users can pin to it
  via `[patch.crates-io]` indefinitely if upstream doesn't merge.
  Worst case is a maintained fork.
- **Time to value.** Phase 3 is multi-quarter. Users and contributors
  may lose interest if there's nothing concrete to point at.
  *Mitigation:* Phase 1 prototypes produce visible deliverables in
  weeks, not months. The `mob_m3` style package (a fast Wave 4 win)
  is a flagship that motivates the work.

## Kickoff checklist

Day-1 concrete actions, in order. Tick as work starts.

- [ ] Push the design corpus (this file + `MOB_PLUGINS.md` +
  `MOB_STYLES.md` + `MOB_PLUGIN_SECURITY.md`) from local master to
  `origin/master`. The commits are already landed locally; this
  publishes them.
- [ ] Hand off `agent_briefs/rustler_env_var_test.md` to a coding
  agent. It runs in parallel; results come back independently.
- [ ] Create `mob_m3_test/plugins/` directory.
- [ ] Scaffold `plugins/mob_palette_demo` (tier 0 — easiest). Confirm
  `mix.exs` + `mix compile` accept it as a `path:` dep with no
  manifest. This validates the lowest-friction plugin shape.
- [ ] Stub `MobDev.Plugin.host_config/3` in `mob_dev` as a one-line
  wrapper around `Application.get_env/3`. Commit + bump mob_dev
  patch version.
- [ ] Decide the working host for Phase 1: `mob_m3_test` (current
  test app) or a dedicated `mob_plugin_demo` repo. The latter
  decouples plugin-system iteration from theme work but adds repo
  overhead. Default to the current `mob_m3_test` unless there's a
  reason to split.

After this checklist, Phase 1 prototypes start landing one at a
time. Order suggestion (easiest → hardest):

1. `mob_palette_demo` (tier 0 — no manifest)
2. `mob_demo_haptic_extras` (tier 1 — NIF baseline)
3. `mob_demo_signature_pad` (tier 2 — new component)
4. `mob_style_neutral_loud` (style — exercises `MOB_STYLES.md`)
5. `mob_demo_kv_browser` (tier 3 — multi-screen)
6. `mob_demo_uptime_kit` (tier 4 — sub-app)
7. `mob_demo_ash_resources` (code-generated — depends on
   `host_config/3` stub)
8. `mob_demo_rust_nif` (tier 1.5 — depends on Phase 0 rustler fix)

Items 7 and 8 are unblocked by Phase 0 work; you can start in any
order once Phase 0 lands.

## Status

Phase 0: in design.
Phase 1: not started.
Phase 2 (design): captured in `MOB_PLUGIN_SECURITY.md`; implementation pending.
Phase 3: blocked on Phase 1 + Phase 2's manifest signing.
