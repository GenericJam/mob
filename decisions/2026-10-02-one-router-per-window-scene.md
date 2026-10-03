# One router per window scene, one BEAM for all of them

- Date: 2026-10-02
- Status: accepted (iPad half; device runs pending, see Verification)
- Tickets: MOB-245 (multi-instance, iPad half), epic MOB-200 (iPhone Duo).
  Android follow-up filed separately (see Android).

## Context

iPadOS has run several windows of one app since iOS 13: each window is a
`UIWindowScene`, and the user opens more from the app switcher, Split View,
Stage Manager or the app's own "New Window" affordance. iPhone Duo inherits
the same model with iOS 27.1 (`decisions/2026-10-01-fold-aware-layouts.md`
item 8: `UIWindowSceneActivationAction` and
`UIWindowSceneActivationInteraction` are iOS 15 API, so nothing here needs
27.1).

mob assumed one window:

- `Mob.Router` is the navigation owner. It registers `:mob_screen`, which
  native resolves with `enif_whereis_pid` for the back gesture, alert results,
  size-class changes, `{:mob_window, :connected}` and notifications, and
  which `Mob.Test` sends and calls into. `Mob.Test.screen/1` returns *the*
  screen.
- `Mob.Sender` commits the tree of one active screen ref. Everything else is
  dropped as "not on screen" (`decisions/2026-08-28-screen-processes-and-supervision.md`,
  `decisions/2026-08-29-router-off-the-hot-path.md`).
- `set_root` has no window key. `ios/mob_nif.m` keeps one double-buffered tap
  registry, one `g_transition`, and pushes every tree to the singleton
  `MobViewModel.shared`, which every `MobHostingController` observes. Two
  windows would show the same tree, and a render for one would invalidate the
  other's tap handles.
- The mob_new template hardcodes `UIApplicationSupportsMultipleScenes=false`.

## Decision

### 1. A scene id is native's, and it is `UISceneSession.persistentIdentifier`

The scene id is the session's `persistentIdentifier`, a string. iPadOS keeps
the session when it discards a backgrounded scene to save memory and hands
the same identifier back when the user returns, so the id survives
disconnect/reconnect. Native assigns it; the BEAM never invents one. Elixir
carries it as a binary. Platforms with no scenes (Android today) and a router
that has not met a scene yet report `nil`.

### 2. One `Mob.Router` per scene, not one router with per-scene graphs

Each scene gets its own `Mob.Router`, with its own navigation stacks and its
own `Mob.Screen.Server` processes. All of them run in the one BEAM and share
`Mob.State`, `Mob.Sender`, `Mob.Listener`, plugins and the app's processes.

One router holding a map of graphs was the alternative. It would put every
window's navigation, restarts and crash recovery in one process and one
state map, and every router function would grow a scene argument. A router
per scene reuses the router as it is: navigation, restart ceilings,
`on_no_live_screen`, nav hooks and the MOB-112 isolation all apply per window
unchanged, and a window whose router is wedged in a slow navigation does not
stall the other. The cost is a registry, which is item 3.

### 3. `Mob.Scenes` is the registry and owns the lifecycle

`Mob.Scenes` (a named GenServer, started by the first rendering router like
`Mob.Sender`) maps scene ids to routers:

- **The primary router** is the one the app starts with
  `Mob.Screen.start_root/2` in `on_start/0`. It registers with `Mob.Scenes`
  and hands over its root module and params: the template every later scene
  starts from.
- **Native reports scenes**: `{:mob_scene, :connected, id, default?}` and
  `{:mob_scene, :disconnected, id}`, from `UISceneWillConnectNotification` /
  `UISceneDidDisconnectNotification` observers mob installs itself (no
  template change needed). Only application-role window scenes count: an
  external display's scene is not a window of the app. Native can't reach the
  BEAM before it is up, so `Mob.Scenes` also pulls `mob_nif:scenes/0` when it
  starts; both paths are idempotent, and a scene already recorded is not
  announced to its router again.
- **A connecting scene** that already has a router is told the window is back
  (`{:mob_window, :connected}`). Otherwise, if it is native's *default* scene
  and the primary is unbound, it is the primary's window. Otherwise
  `Mob.Scenes` starts a new router, bound to the id, from the primary's root
  module and params. The router mounts its root screen after it has started
  (`handle_continue`), so `Mob.Scenes` never waits on an app's `mount/3`: a
  mount may call `Mob.Scene.list/0`, and every window's events pass through
  `Mob.Scenes`.
- **A session replacing the kept one** (item 6) arrives as `{:mob_scene,
  :replaced, old_id, new_id, default?}` and moves the old id's router to the
  new id. A plain `connected` for an unknown id never adopts a kept router.
- **`Mob.Scenes.list/0`** and **`screens/0`** answer which scenes exist and
  what each shows.

### 4. The primary router is unbound and renders to native's default scene

The primary router never carries a scene id. It renders exactly as before:
`clear_taps/0`, a JSON root with no `"scene"` key, `set_root/1`. Native sends
such a frame to its **default scene**: the scene holding tap set 0 and
`MobViewModel.shared`, which is the first scene to connect when none is
attached. A single-window app (every iPhone, every iPad app without the
opt-in, Android) therefore runs the same code path as before this change,
natively and in `Mob.Sender`.

Routers `Mob.Scenes` starts for further scenes are **bound**: their screens
render through `clear_taps/1` with the scene id, and `Mob.Renderer` adds
`"scene": id` to the JSON root. Native looks the id up and builds, commits
and displays into that scene's own tap set and view model.

`Mob.Sender` keeps one active ref per scene: the existing fields hold the
unbound (default) scene, and a `scenes` map holds each bound scene's active
ref, reserved transition, activation gate and active module. A flush commits
the pending tree of every active ref, each to its own scene. Two windows
navigating at once each keep their transition.

### 5. `:mob_screen` stays, and means "the primary scene's router"

`:mob_screen` stays registered to the primary router, so native callers,
`Mob.Test` and plugins keep working unchanged in a single-scene app. When the
primary's window closes for good while other windows remain, `Mob.Scenes`
first makes sure every remaining window has a router, registers
`:mob_screen` to the oldest remaining one (which then drains notifications
native stored meanwhile) and only then stops the primary: as soon as native
sees one scene attached it sends that window's events to `:mob_screen`.

Native routes the events that belong to a window by the window they came
from:

- **Back gesture, size class and alert results** come from a known scene
  (`MobHostingController`, `MobRootView` and the presenting alert carry it).
  With one scene attached native sends them to `:mob_screen` exactly as
  before. With several it sends `{:mob_scene_event, id, message}` to
  `Mob.Scenes`, which forwards `message` to that scene's router (or to
  `:mob_screen` if no router claims the id).
- **Alerts** and action sheets shown by a screen in a bound scene go through
  `alert_show/4` and `action_sheet_show/3`, which take the scene id, present
  on that scene's window and route the result back to it. Unbound screens
  use the existing NIFs, which now present on the default scene's window.
- **Size class and safe area reads** at mount take the scene id
  (`size_class/1`, `safe_area/1`) for a bound screen. The unbound reads
  prefer the default scene's window, so a second window cannot hand the
  primary its insets.
- **Notifications are app-wide.** They go to `:mob_screen`, i.e. the primary
  scene's current screen, unless a process registered through `mob_notify`,
  as before.
- **Taps need no routing.** `Mob.Listener` already delivers each tap to the
  screen pid baked into its handle; what changes is that each scene has its
  own native tap set, so one window's render no longer invalidates the
  other's handles. Native event blocks capture the tap set they were built
  for, so a handle resolves only against its own window's table, including
  the identity fallback text fields use (a handle from an older frame whose
  slot still routes to the same place).

### 6. Disconnect: stop the window's router unless it is the last

iPadOS disconnects a scene both when the user closes a window and when it
discards a background one to reclaim memory; the app cannot tell which at
that point. When a scene disconnects:

- If other scenes remain attached, its router is stopped. Its screens
  terminate normally, so persisted screens dump their state. If the scene
  comes back (same id), `Mob.Scenes` starts a fresh router for it from the
  root template: navigation inside a discarded secondary window is not
  restored.
- If no other scene is attached (decided by attached scenes, as native does,
  not by how many routers exist), its router is kept, bound and alive, so a
  reconnect of the same id shows the same screens with their assigns, as a
  single-window app does today.
- If a different id connects while no scene is attached, native hands it the
  kept entry's tap set and model only when the kept entry's session is gone
  from `UIApplication.openSessions` (the user really discarded it), and says
  so with `replaced`; the kept router then shows the new id. Otherwise the
  kept session may still come back (iPadOS restoring a split of discarded
  windows in any order), so the new id gets a fresh set and router, and the
  kept ones wait for their own id.
- A kept entry whose session native finds gone from `openSessions` (checked
  whenever a scene attaches or activates) is dropped natively and reported as
  `{:mob_scene, :discarded, id}`; its router stops, unless it is the app's
  only router, and `:mob_screen` moves on as above if it held it.

Native mirrors this: a disconnecting scene with others still attached
releases its tap set (every per-slot field reset) and model; the last one
keeps them.

### 7. `Mob.Test` addresses a scene with `scene:`

- `Mob.Test.screens(node)` returns `[{scene_id, screen_module, pid}]`, one
  entry per router, primary first. On a single-scene app it is one entry (the
  scene id is `nil` on Android).
- `Mob.Test.screen/1`, and every helper that addresses "the" screen
  (`assigns`, `inspect`, `tree`, `find`, `tap`, `back`, `select`,
  `send_message`, the navigation helpers), keeps working with one scene and
  raises `Mob.Test.MultipleScenesError` when several are live and no
  `scene:` is given. Each takes `scene: id`, which addresses that scene's
  router. Guessing a window for an agent would turn a wrong target into a
  silent no-op.
- `Mob.Test.settle/2` settles every scene.
- `Mob.ScreenCase` stays single-scene: it mounts one screen with no router.

### 8. Opening a window

`Mob.Scene.request_new/0` asks iOS for a new window
(`activateSceneSessionForRequest:errorHandler:`, iOS 17). It returns `:ok`,
or `{:error, :unsupported}` when the app or device does not support multiple
scenes; an asynchronous refusal (Duo's outer display, a system limit) arrives
as `{:mob_scene, :request_failed, reason}` at the caller.
`Mob.Scene.supported?/0` answers whether a "New Window" button should be
shown at all. A native `UIWindowSceneActivationAction` affordance would hide
itself automatically, but mob's UI is SwiftUI rendered from the BEAM, so the
documented API is the affordance for now.

The opt-in is `config :mob_dev, multi_window: true` in `mob.exs`. mob_dev
stamps `UIApplicationSupportsMultipleScenes` into the built bundle's
Info.plist with PlistBuddy, the way it already applies `ios_target_devices`
(`MobDev.IosLayoutPlist`). The template's `ios/Info.plist` keeps `false`, so
existing apps are unaffected until they opt in.

## Consequences

- **Persisted screen state is per module, shared by scenes.** Two windows
  showing the same `persist: true` screen dump to the same `Mob.ScreenState`
  key; the last dump wins and a new window's screen restores it.
- **Native-reading test helpers read the default scene.** `view_tree/1`,
  `screenshot/2`, `element_frames/1` and `tap_id/2` were written against one
  window. Secondary scenes do not take part in the element frame registry or
  the navigation frame generation; giving them their own is follow-up work.
- **`on_no_live_screen` applies to the primary only.** A secondary router
  whose screen cannot be restarted leaves that window on its last frame
  instead of ending the app.
- **A tap set per scene is capped** (`MOB_SCENE_LIMIT` in `mob_nif.m`). A
  scene beyond the cap renders nothing and logs why.
- **Hot code push.** `Mob.Sender` reads its new `scenes` field with a
  default, so a sender started before this change keeps working; routers
  started before it are unbound primaries, which is what they were.

## Android

Out of scope for this change. `g_activity` (a single global `jobject` in the
generated `beam_jni.c`) and `android:launchMode="singleTop"` assume one
activity; what multi-instance would take there is written up in the
follow-up issue. The Elixir model above is platform-neutral: an Android
implementation reports activities as scenes and implements the scene NIFs.

## Verification

Host tests cover the routing, `Mob.Scenes` lifecycle, `Mob.Sender`'s
per-scene commits, `Mob.Test.screens/1`, `MultipleScenesError` and `scene:`,
and fail with the change reverted. The native half has not run on a device:
iOS simulators were down on this machine when it was written. Pending device
checks are listed on MOB-245.
