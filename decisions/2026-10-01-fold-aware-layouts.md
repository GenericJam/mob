# Fold-aware layouts: size class and reserved regions, never orientation

- Date: 2026-10-01
- Status: accepted
- Ticket: MOB-208 (epic MOB-200; records the design for MOB-201, MOB-202,
  MOB-203, MOB-204, MOB-206, MOB-243, MOB-244, MOB-245)

## Context

Apple announced iPhone Duo, a foldable iPhone, on 2026-09-09. It ships on
2026-10-23 running iOS 27.1. It has a compact outer display and a large inner
display that folds. The developer surface for it ships in Xcode 27.1 and the
iOS 27.1 SDK. Several mob primitives have to grow to meet it, and this record
fixes their shape before the first of them ships and becomes hard to change.

What can be checked on the machine where this was written: Xcode 27.0 (build
27A266a), the iOS 27.0 SDK, and the iOS 27.0 and 26.5 simulator runtimes.
There is no 27.1 SDK and no Duo simulator. So every Apple claim below comes
from Apple's published material. Where a claim could also be checked against
the 27.0 SDK headers, it was, and the record says so.

### Sources

All fetched on 2026-10-01.

- [Get ready for iPhone Duo](https://developer.apple.com/iphone-duo/), the
  developer landing page that indexes everything below.
- [Build for iPhone Duo with new resources](https://developer.apple.com/news/?id=nyuppv9r),
  Apple developer news, 2026-09-18: the Xcode 27.1 beta, design kits and
  workshops. It makes no API claims. The 2026-09-16 post
  [Get ready with the latest beta releases](https://developer.apple.com/news/?id=rfb1rooi)
  confirms the 2026-10-23 date, iOS 27.1, and that "Xcode 27.1 will add
  development support for iPhone Duo".
- Tech Talk 111461, [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
  (transcript): size classes, orientation, safe areas, reserved regions, SDK
  behaviour.
- Tech Talk 111464, [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
  (transcript): the hinge, Split View multitasking, multiple scenes, scene
  accessories.
- Tech Talk 111463, [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
  (transcript): reserved regions in detail, displacement patterns,
  `ArrangementView`.
- [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo),
  a documentation article.
- [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo),
  the Human Interface Guidelines page (read through its JSON data feed; the
  HTML page renders client-side).
- Android: [`FoldingFeature`](https://developer.android.com/reference/androidx/window/layout/FoldingFeature)
  (Jetpack WindowManager) and the
  [`Sensor`](https://developer.android.com/reference/android/hardware/Sensor)
  reference, which lists `TYPE_HINGE_ANGLE`.

Watched as transcripts only, not as video: the chapter timings and on-screen
demos were not checked frame by frame. Not read: Tech Talks 111462 (bars),
111465 (camera) and 111466 (design), and the Group Lab Q&A.

### What Apple's material says, and where the tickets got it wrong

The MOB-200 tickets were written from the same talks, but several of their
claims don't match what Apple published. The decisions below follow the
sources. Each correction is noted where it matters.

1. **Apple advises against orientation-keyed layout; it does not deprecate
   it.** 111461: "The inner display doesn't honor your supported interface
   orientations. As with Idiom, avoid checking interface orientation for
   layout decisions. Use size classes instead." The documentation article
   adds: "Don't use `userInterfaceIdiom` or `UIInterfaceOrientation` for
   layout decisions." What 111461 *does* say will be deprecated is
   referencing the **main screen** (`UIScreen.main`), "ambiguous and will be
   deprecated in a future release". MOB-208's ticket text says Apple
   "deprecates orientation-keyed layout"; that overstates it.
2. **Size classes on Duo.** 111461: on the outer display, compact horizontal
   with regular vertical in portrait, and compact in both in landscape, like
   other iPhones. The inner display is regular in both. Duo is "still an
   iPhone app" (111461), so there is no new device family and no new idiom.
   The HIG says: "A compact width layout for the outer display and a regular
   width layout for the inner display give you the fundamentals for every
   pose."
3. **Reserved regions** come in two kinds (111463 and the documentation
   article). A *division* is the fold, splitting a large area into smaller
   ones. An *occlusion* is a hardware element covering part of the view:
   the inner front camera when it is active, and the outer front camera,
   which always occludes. A region is *active* or *inactive*. The fold's
   division is active only while the device is partially folded; when the
   device is flat it is inactive with zero width. Queries return only active
   regions unless `includeInactive` is passed, and Apple suggests using
   inactive regions for decisions such as an even number of grid columns.
   The API is `GeometryProxy.reservedRegions(kind:options:...)` in SwiftUI
   and `UIView.reservedRegions(kind:options:)` in UIKit, new in iOS 27.1.
   The HIG lists them "in addition to standard considerations for safe
   areas". They are not part of the safe area.
4. **`ArrangementView` / `UIArrangementViewController`** is a container for
   a primary and a secondary view, with a *split* style and an *overlay*
   style (111463, documentation article, HIG). It takes the size classes,
   the aspect ratio and any active division as inputs, and decides whether
   each view is shown and where. Split places the views side by side when
   the container is wider than it is tall, and stacked otherwise. Its axes
   can be restricted, and when it cannot split along its primary axis it
   shows only the primary view. Overlay layers primary over secondary when
   there is no active division, and puts them on either side of the fold
   when there is one. Apple says not to put an arrangement inside a `List`
   or `ScrollView`, and not to put navigation containers inside an
   arrangement.
5. **The hinge is for effects.** 111464: "Hinge data is observed live, and
   is ideal for driving interactions or effects. For layout, use the
   arrangement and region APIs." The APIs are SwiftUI `onHingeChange` and
   UIKit `UIHingeInteraction`. They report a status (closed, partially open,
   fully open) and a continuous angle, and a nil hinge means the device has
   none. The MOB-208 2026-09-14 comment says "layout stays on size class";
   Apple's actual wording names the arrangement and region APIs, with size
   classes as the general resizing signal (111461).
6. **The outer display is not "accessory-only".** 111464: "On the outer
   display of iPhone Duo, new windows cannot be created. That behavior is
   reserved for the inner display." When the device is closed, the app's
   main UI runs on the outer display as on any iPhone. What is restricted
   is creating *additional* windows there. While the device is open, the
   only way described to put content on the outer display is
   `CameraCaptureAccessory`. It is available when the app is full screen on
   the inner display *and* has an active camera session, and it is
   registered on the same view as the camera UI. MOB-244 and the MOB-208
   comment both state the stronger "accessory-only" claim.
7. **Scene accessories are not Duo-only, and the container API is not
   27.1.** 111464 presents scene accessories as an iPhone and iPad concept
   ("using your iPhone as a controller for a game on an external display"),
   with `CameraCaptureAccessory` as the new Duo case. The **iOS 27.0 SDK on
   this machine** declares `View.sceneAccessory(content:)`,
   `SceneAccessoryContent` and `onAvailabilityChange(perform:)` as
   `@available(iOS 27.0, *)`, and UIKit's `UISceneAccessory` as
   `API_AVAILABLE(ios(27.0))`. The UIKit header's own description: "the app
   must remain fully functional without them." `CameraCaptureAccessory` is
   **absent** from the 27.0 SDK, so it is the 27.1-only piece.
8. **Multiple scenes reuse iPad's API.** 111464: "iPhone Duo is the first
   iPhone to support multiple instances of your app's UI. If your app
   supports this on iPad, it will on iPhone Duo as well." Apple's advice is
   to handle errors when requesting a scene and to use
   `UIWindowSceneActivationAction`, "which automatically hides when new
   windows aren't available". The 27.0 SDK headers declare
   `UIWindowSceneActivationAction` and `UIWindowSceneActivationInteraction`
   as `API_AVAILABLE(ios(15.0))`. MOB-245 calls `UIWindowSceneActivation` a
   27.1 API; it is not. The new part is that iPhone now allows it.
9. **SDK behaviour** (111461). Apps not rebuilt still run on Duo,
   letterboxed beside the status bar and camera. An app built with the iOS 27
   SDK extends to the left of the status bar on the inner display. One built
   with the iOS 27.1 SDK reaches the screen edge, and its standard navigation
   bars and toolbars lay out vertically on the side. No new `Info.plist` key
   is involved. "iPhone Duo will continue to honor the `UIRequiresFullScreen`
   key, but your app will still resize when someone opens or closes" it.
   111464: "All apps participate in multitasking on iPhone Duo."
10. **Safe areas are asymmetric** (111461): "avoid assuming that insets on
    opposite sides are equal." Vertical bars can sit on the left in
    landscape and in Split View.

**Ticket claims no source confirms.** The MOB-208 ticket says hand-rolling a
split with reserved regions "loses the fold-transition animation and the
Split-View integration". The sources say neither; they say that system
containers adapt to reserved regions automatically. MOB-203 expects a closed
device to collapse an arrangement to its primary pane "per `ArrangementView`
default". The published rule is aspect-ratio based: a split arrangement on a
tall outer display stacks its two views unless its axes are restricted. Both
claims stay unverified until the 27.1 simulator is available.

**Internal tension in 111461.** It says both "The inner display doesn't honor
your supported interface orientations" and "iPhone Duo respects your
supported interface orientations, but your app will scale on the inner
display". The second is probably about the outer display, or about scaling
instead of rotating. Nothing below depends on which reading is right.

### What mob has today

- `:safe_area` is always on the socket as `%{top:, right:, bottom:, left:}`
  (`guides/screen_lifecycle.md`). Screens apply it themselves. The root
  respects the top inset automatically: `MobRootView` uses
  `.ignoresSafeArea(.container, edges: [.bottom, .horizontal])`, which ignores
  the bottom and sides and keeps the top.
- `Mob.Device.orientation/0`, the `:display` subscription's
  `{:mob_device, :orientation_changed, _}`, and
  `Mob.Device.lock_orientation/1`.
- One screen tree per screen process, presented in one window
  (`decisions/2026-09-04-two-slot-screen-presentation.md`,
  `decisions/2026-08-28-screen-processes-and-supervision.md`).
- The iOS deployment floor is iOS 17.0: `arm64-apple-ios17.0` in mob_new's
  `build.zig.eex` and `build_device.zig.eex`, and in mob_dev's
  `release.ex`.

## Decision

### 1. Layout keys on size class, never on orientation

The layout signal is the `:size_class` assign that MOB-204 is adding: a
`{horizontal, vertical}` tuple of `:compact | :regular`, sent to screens on
change as `{:mob_size_class_changed, new}`. Duo, iPad, Split View, Slide Over
and rotation all reach a screen through this one signal. Mob adds no `:fold`,
`:pose` or `:duo?` assign, and no Duo-specific idiom.

**Do not add an orientation check to a layout path "for symmetry"** with
size class. On the inner display it is simply wrong: the system ignores
supported orientations there (source item 1). Orientation remains available
for what it is actually for, such as camera rotation and sensor fusion.
`Mob.Device.lock_orientation/1` keeps working on other devices. On Duo's
inner display it cannot be honoured, given item 1. Whether its geometry
request is rejected or ignored there has not been observed, which matters
for MOB-165's existing finding that `lock_orientation/1` returns `:ok` when
it had no effect.

Screens get the same guidance Apple gives: use the compact layout for the
outer display and the regular one for the inner, and let the layout stretch
rather than designing one per pose (HIG).

### 2. `<Arrangement>` is a first-class primitive, a thin wrapper over Apple's

MOB-203 adds `<Arrangement>`. On iOS 27.1 or later it is backed by
`ArrangementView`, hosted in the same SwiftUI tree as everything else.
`UIArrangementViewController` is the UIKit twin, for the case where the
host needs it.

- **Why a primitive and not a recipe.** A screen could combine
  `:reserved_regions` and a `Row`/`Column` itself. But Apple's arrangement
  takes size class, aspect ratio and active divisions together, and it is
  what the system's own split layouts adapt with (item 4). A mob
  reimplementation would drift from it with every iOS release. The
  wrapper's job is to pass Apple's model through, not to reinvent it.
- **Shape.** The element takes exactly two children, primary and then
  secondary, in the same way `:anchored` takes trigger and then panel
  (`decisions/2026-09-12-ios-anchored-is-a-root-overlay.md`). Props follow
  Apple's names: `style: :split | :overlay` (Apple's default is split) and
  `axes: :horizontal | :vertical | :both`. Taps in either child go to the
  owning screen's pid, like taps anywhere else. MOB-203's draft API
  (`primary=`/`secondary=` props, `mode=`) is replaced by this.
- **Placement rules are checked, not just documented.** An `<Arrangement>`
  inside a `Scroll` or `List`, or a navigation container inside an
  `<Arrangement>`, is what Apple says not to do (item 4). MOB-203 should
  reject that nesting at render time rather than leave it to the platform.
- **Fallback where Apple's view doesn't exist**, which means iOS before 27.1
  and Android. On any iOS 27.1 device, folding or not, Apple's view is used
  and decides for itself. The fallback is **Apple's published split rule
  with no division**: side by side when the arrangement's frame is wider
  than it is tall, stacked otherwise, restricted by `axes`, and only the
  primary view when the permitted axis isn't available. Overlay falls back
  to primary over secondary. MOB-203 proposed "a Column on phones, a Row on
  tablets in landscape" instead, which is a device-class rule that would
  make the same screen behave differently on an Android tablet and an iPad.
  The aspect-ratio rule is what Apple ships, so a screen written for Duo
  gets the same layout everywhere a fold isn't present.

### 3. `:reserved_regions` sits alongside `:safe_area` and is never merged into it

MOB-202 adds a `:reserved_regions` assign and a
`{:mob_reserved_regions_changed, regions}` message.

- **Why not merged.** Safe area is four edge insets: padding. A division is
  a band through the middle of the frame, and an occlusion is an arbitrary
  rectangle. Neither can be written as an inset. Folding them into
  `:safe_area` would either lose the geometry or change `:safe_area` from
  "four numbers" into something every existing screen would mis-read. It
  would also make the non-Duo case confusing: a screen could not tell "no
  fold here" from "a fold of width zero". Apple keeps the two concepts
  separate too ("in addition to standard considerations for safe areas",
  HIG).
- **Shape.** A list of maps,
  `%{kind: :division | :occlusion, frame: {x, y, w, h}, active: boolean()}`,
  in window coordinates (points, origin top-left), the space
  `Mob.Test.element_frames/1` already reports in. It includes inactive regions with
  `active: false` (Apple's `includeInactive`), so a screen can make
  structural choices such as even grid columns while the device is flat, as
  Apple suggests (item 3). MOB-202's draft `[{kind, {x, y, w, h}}]` has
  nowhere to put the active flag; this shape replaces it.
- **Always present.** The assign is `[]` on every device without reserved
  regions, which today means every device mob runs on. This follows the
  `:safe_area` rule that a documented assign is never missing
  (`decisions/2026-09-10-a-safe-area-read-with-no-window-is-not-an-answer.md`).
  Like safe area, a value read before a window exists must not be trusted
  as final.

### 4. The fold is honoured automatically at the root; `respect_fold: false` opts out

**Decision: automatic, but narrower than MOB-202 proposed.** When the
screen's root container is a non-scrolling layout container (`Column`, `Row`,
`Box`) and there is an active division, the renderer makes sure no direct
child of that root straddles the division. Inactive divisions (the device
flat or closed) change nothing. A root `Scroll` or `List` is **not**
fold-honoured. Occlusions are **not** auto-honoured; they reach screens
through `:reserved_regions`, the same way safe-area insets do. Setting
`respect_fold: false` on the root turns auto-honour off for screens that mean
to paint across the crease, such as games, canvases, full-bleed media and
camera viewfinders.

Why automatic:

- **Mob's audience writes "a Column of Text".** If honouring the fold is
  opt-in, every app that hasn't heard of the fold puts text into the crease
  on the day Duo ships. Apple's system containers adapt on their own (HIG:
  "Many system components automatically adapt to reserved regions"), and a
  mob root container is in the same position for a mob app.
- **Precedent in mob.** The root already respects the top safe-area inset
  without being asked (`MobRootView`, see "What mob has today").

Why not `Scroll`/`List` (amending MOB-202, which proposed the "outermost
`Column`/`Scroll`"):

- 111463 is explicit: "Continuous scrolling content like articles, feeds,
  documents, and lists don't displace. These experiences already adapt
  through scrolling, so moving them between the available regions can
  interrupt continuity." Auto-honouring a root scroll would contradict
  Apple's guidance.

Why "no child straddles" and not something more ambitious:

- The HIG says to "move only what's necessary" and to "favor small
  adjustments over rearrangement". Re-flowing a whole screen into two panes
  is what `<Arrangement>` is for. The automatic layer only promises not to
  break anything. The exact displacement (which side of the band a child
  goes to, how spacing is redistributed) belongs to MOB-202. It has to be
  confirmed on the 27.1 simulator in every pose: book, tent, laptop and
  rotated.
- **To verify before implementing:** 27.1 SwiftUI may already displace plain
  stacks hosted in a `UIHostingController`. Apple says "framework-provided
  views and containers automatically adjust" but also that custom views need
  reserved regions, and neither source covers bare `VStack`s. If SwiftUI
  does displace them, mob's layer must not apply a second time. MOB-202's
  first sim check should answer this.

**Alternative recorded and rejected:** opt-in with `respect_fold: true`,
or no automatic behaviour at all, leaving everything to `<Arrangement>` and
`:reserved_regions`. That is more honest about the cost, because auto-honour
can move content the author placed deliberately. It was rejected because the
failure modes are asymmetric. A wrongly honoured fold shifts a child by the
width of the band, and one prop fixes it. A wrongly ignored fold puts
unreadable, untappable controls in the crease of every naive app, and the
author doesn't know there is a prop to look for.

**Misuse to watch for:** `respect_fold: false` on an ordinary text-and-
controls screen, usually copied from a canvas example, is the usual cause of
"content painted into the crease". `common_fixes.md` has the entry.

### 5. Hinge events drive effects; layout never reads them

MOB-243 delivers `{:mob_hinge_change, %{status: s, angle: degrees}}` with
`s` in `:closed | :partially_open | :fully_open`, coalesced to at most 60 Hz.
There is **deliberately no hinge assign**. A screen that wants the angle for
an effect (parallax, a pitch bend, a shutter) assigns it itself in
`handle_info/2`. Putting it on the socket by default would invite
`render/1` to branch layout on the hinge, which Apple says not to do
("For layout, use the arrangement and region APIs", item 5).

The layout split is:

| Question | Signal |
|---|---|
| Which layout (compact vs regular)? | `:size_class` / `{:mob_size_class_changed, _}` (MOB-204) |
| What to keep clear of the fold or camera? | `:reserved_regions` / `{:mob_reserved_regions_changed, _}` (MOB-202) |
| Two views that adapt to the fold | `<Arrangement>` (MOB-203) |
| An effect that follows the fold angle | `{:mob_hinge_change, _}` (MOB-243), never in layout |

On devices with no hinge the message never arrives; this mirrors SwiftUI's
nil hinge.

### 6. Scene accessories are a companion tree, optional by contract

MOB-244 adds a companion tree: a subtree that belongs to the same screen
process but is presented on another display. It is a new concept for mob,
whose screens each render one tree into one window today.

- **Same process, separate tree.** Accessory content is declared inside the
  screen's `render/1`, on the node it belongs to (MOB-244 proposes a
  `<SceneAccessory>` element). It reads the same assigns, so the inner and
  outer displays never disagree about state. Availability arrives as
  `{:mob_scene_accessory_available, boolean}`, which is Apple's
  `onAvailabilityChange`.
- **Optional by contract.** The system decides when an accessory is shown;
  the UIKit header says "the app must remain fully functional without them".
  A screen must never require its accessory tree in order to work. The
  accessory renders nowhere on Android, on non-Duo iPhones, and whenever it
  isn't available.
- **Not a second window, and not the outer display's only content.** When the
  device is closed, the main tree runs on the outer display as normal.
  While it is open, the Duo accessory (`CameraCaptureAccessory`) is the only
  way onto the outer display. Per item 6 it needs full screen on the inner
  display and an active camera session, and Apple says to register it on
  the camera view. In mob terms it attaches to a `:camera_preview` node
  (`Mob.UI.camera_preview/1`, fed by the `mob_camera` plugin), not to an
  arbitrary container. MOB-244's "outer display is accessory-only"
  constraint is corrected to this.
- **Unverified:** whether `CameraCaptureAccessory` content accepts touches.
  27.0's only UIKit accessory is `externalNonInteractive`, and the
  teleprompter demo shows no touch input. MOB-244's "taps in the accessory
  reach the same screen pid" may describe a capability that doesn't exist.
- **Gating.** The generic `sceneAccessory`/`SceneAccessoryContent` API is
  iOS 27.0 (item 7) and `CameraCaptureAccessory` is 27.1. Each is gated at
  its use site with its own `@available` (see 8).

### 7. Multi-instance is one model, shared with iPad, landed on iPad first

MOB-245's multi-scene model (one screen process per scene under a
`Mob.Screens` supervisor keyed by scene id, plus `Mob.Test.screens/1`) is
not a Duo feature. It is iPad's multi-window model, which Duo inherits
(item 8). It should land and be verified on iPad on today's toolchain, then
Duo picks it up when 27.1 arrives. Two consequences follow from the sources:

- Requesting a new scene can fail on Duo: the outer display cannot create
  windows. The request path returns an error the screen can handle, and the
  affordance uses `UIWindowSceneActivationAction`, which hides itself when
  new windows aren't available.
- No 27.1 gate is needed for the activation API itself. It is iOS 15, below
  mob's iOS 17 floor.

The multi-instance model is also what Split View exercises. Two mob apps side
by side are two processes, each with its own BEAM, but they share the Mac's
network stack on a simulator, which is the per-app dist-port problem
`decisions/2026-10-01-ios-sim-dist-port-per-app.md` already solved.

### 8. Deployment target: keep the iOS 17 floor; gate Duo API at each use site

This is MOB-201's recommendation 1, adopted. Mob keeps
`arm64-apple-ios17.0`. Every 27.1-only symbol (`ReservedRegion`,
`ArrangementView`/`UIArrangementViewController`,
`onHingeChange`/`UIHingeInteraction`, `CameraCaptureAccessory`) is used only
behind `@available(iOS 27.1, *)` or `if #available(iOS 27.1, *)` at the call
site. iOS 27.0 API (`sceneAccessory`) gets `27.0`. On older systems each
primitive falls back as described above: `[]` regions, Apple's split rule
for `<Arrangement>`, no hinge messages, no accessory. MOB-201's option 2, a
`mob_ios_min: "27.1"` flag that raises the floor per app, was rejected:
it splits generated apps into two populations for no benefit the
`@available` gate doesn't already give, and it drops older iPhones that mob
supports.

Because the symbols are absent from the 27.0 SDK, `@available` alone does
not make the code compile there. The 27.1 call sites also need a
compile-time SDK guard so that mob still builds with Xcode 27.0 and 26.x.
MOB-201 owns the mechanism.

### 9. Android: a no-op seam now, with a mapping that is already known

The Android devices mob targets don't fold. Every primitive above ships on
Android anyway, as a defined no-op, so a screen written for Duo compiles and
runs there unchanged:

| Primitive | Android today | Future mapping (Jetpack WindowManager) |
|---|---|---|
| `:reserved_regions` | always `[]` | `FoldingFeature.bounds` → `frame`; `isSeparating` → `active`; `OcclusionType.FULL` vs `NONE` refines `kind` |
| `<Arrangement>` | Apple's split/overlay rule, no division | same rule, with the `FoldingFeature` band as the division |
| `{:mob_hinge_change, _}` | never sent | `FoldingFeature.State` (`FLAT`/`HALF_OPENED`) for `status`; the angle needs `Sensor.TYPE_HINGE_ANGLE` (not exercised) |
| `<SceneAccessory>` | renders nothing; availability never sent | no counterpart identified |
| `:size_class` | per MOB-204 (Compose `WindowSizeClass`) | Compose has three width buckets; MOB-204 decides the mapping onto mob's two values |

The message and assign shapes above are the contract both platforms
implement. Nothing in them is Apple-specific apart from the names of the
source APIs.

## Consequences

- **MOB-204 (`:size_class`, in flight).** Nothing here changes its contract.
  This record adds a rule for later code: layout reads `:size_class`, never
  `Mob.Device.orientation/0`. The outer display in landscape reads
  `{:compact, :compact}` (111461); the ticket lists only portrait cases.
- **MOB-206 (template plist, in flight).**
  - Duo is iPhone family 1 ("still an iPhone app"), so there is no
    `UIDeviceFamily` value 5 to add; the ticket's "Apple may have added 5"
    is answered.
  - The full-screen and vertical-bar behaviour comes from building with the
    27.1 SDK, not from a plist key (item 9).
  - A portrait lock in the plist constrains only the outer display; the
    inner display ignores supported orientations (item 1).
  - `UIRequiresFullScreen = true` is still honoured on Duo, but the app
    resizes on open and close anyway, and Apple says all apps take part in
    multitasking (item 9). So the doctor warning for "Duo-hostile" plists
    should say the app still resizes, not that it won't. Whether `true`
    keeps an app out of *Split View* on Duo, as it does on iPad, is not
    stated; leave it unverified.
- **MOB-202, MOB-203, MOB-243, MOB-244 and MOB-245** inherit the shapes and
  corrections above: the `active` flag and the narrower auto-honour scope;
  two children, `style`/`axes` and the aspect-ratio fallback; no hinge
  assign; the accessory bound to `:camera_preview` and optional; the
  activation API being iOS 15. Each ticket's own acceptance criteria still
  stand where this record doesn't contradict them.
- **Safe-area code must treat each side independently.** Duo's insets are
  asymmetric (item 10), and the root ignores the horizontal insets, so a
  screen padding with `assigns.safe_area` must use `left` and `right`
  separately. Any mob helper that assumes `left == right` is a Duo bug.
- **Nothing here is verified on a device.** Every Apple behaviour above comes
  from Apple's published material or, where noted, the 27.0 SDK headers.
  The first MOB-205 Duo-simulator session (Xcode 27.1) should check, in
  order: whether SwiftUI already displaces stacks (decision 4); the
  `ArrangementView` behaviour when closed (MOB-203); `lock_orientation/1` on
  the inner display; `UIRequiresFullScreen` with Split View; and touch
  input on `CameraCaptureAccessory`. MOB-209 then repeats them on hardware.
- **Docs.** `AGENTS.md` points to this record under "Device shapes".
  `common_fixes.md` has the "content painted into the crease" entry.
