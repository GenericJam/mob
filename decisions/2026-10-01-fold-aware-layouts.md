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
   iPhone app" (111461), so there is no new idiom. No source states a
   `UIDeviceFamily` value for Duo; that it is plain iPhone family 1 is an
   inference, unverified until a 27.1 SDK or a built Duo app can be checked.
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
   when there is one. Where an arrangement may sit is stated three
   slightly different ways. The documentation article says to avoid placing
   one "inside a navigation split view, list, scroll view". 111463 says not
   to put navigation containers such as `NavigationSplitView`s *inside* an
   arrangement, and not to put an arrangement inside `List`/`ScrollView`.
   The HIG says to place navigation containers, including navigation split
   views, "around it rather than within it". 111463's own sample puts an
   `ArrangementView` inside a `NavigationStack`.
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
   `API_AVAILABLE(ios(27.0))`. The only constructor in its UIKit header is
   `externalNonInteractive(sceneConfiguration:)`, for non-interactive
   content "when an external display is connected", and it takes a
   `UISceneConfiguration`. The header's own description: "the app must
   remain fully functional without them." `CameraCaptureAccessory` is
   **absent** from the 27.0 SDK. It is expected to be 27.1 API, but its
   availability annotation has not been seen.
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
   bars and toolbars lay out vertically on the side. Apple attributes this
   to SDK linkage and names no plist opt-in for it. Whether 27.1 adds any
   plist metadata is unverified. "iPhone Duo will continue to honor the
   `UIRequiresFullScreen` key, but your app will still resize when someone
   opens or closes" it. 111464: "All apps participate in multitasking on
   iPhone Duo."
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
instead of rotating. Because of this, decision 1 leaves
`lock_orientation/1` on the inner display as unverified rather than
concluding anything.

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
`Mob.Device.lock_orientation/1` keeps working on other devices. **What it
does on Duo's inner display is unverified.** Item 1 says the inner display
ignores an app's *supported* orientations. But the HIG says a game "can
choose to lock to either portrait or landscape orientation" on Duo, and
mob's lock also issues a geometry request (`nif_device_lock_orientation` in
`ios/mob_nif.m`), which item 1 does not cover. Whatever it does there, it
is not a layout tool. MOB-165 already found that `lock_orientation/1`
returns `:ok` when it had no effect, so check it on the inner display.

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
  takes size class, aspect ratio and active divisions together (item 4),
  and Apple recommends it alongside split views and navigation stacks as
  the system-provided way to handle the fold (documentation article). A mob
  reimplementation would drift from it with every iOS release. The
  wrapper's job is to pass Apple's model through, not to reinvent it.
- **Shape.** The element takes exactly two children, primary and then
  secondary, in the same way `:anchored` takes trigger and then panel
  (`decisions/2026-09-12-ios-anchored-is-a-root-overlay.md`). Props follow
  Apple's names: `style: :split | :overlay` (Apple's default is split) and
  `axes: :horizontal | :vertical | :both`. Taps in either child go to the
  owning screen's pid, like taps anywhere else. MOB-203's draft API
  (`primary=`/`secondary=` props, `mode=`) is replaced by this.
- **Placement rules are checked, not just documented.** MOB-203 should
  reject an `<Arrangement>` inside a `Scroll` or `List` at render time; all
  three Apple sources agree on that (item 4). The navigation rules follow
  from mob's structure. Mob's navigation (stacks, and `Mob.App.tab_bar/1`)
  is declared at the app level, outside any screen's render tree. So an
  `<Arrangement>` always sits *inside* navigation and never wraps it. That
  is the arrangement 111463's sample uses with `NavigationStack`. Apple's
  sources disagree about an arrangement inside a *navigation split view*,
  but mob has no split-view navigation container, so the question doesn't
  arise.
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

### 4. The fold is honoured automatically at the root by default; `respect_fold: false` opts out

**Decision: the default is on, the lever is `respect_fold: false`, and the
scope is narrower than MOB-202 proposed. The mechanism is provisional.**
This record decides the default and the opt-out, not the geometry. MOB-202
has to specify the geometry, and the 27.1 simulator has to show it working,
before the default ships.

Scope:

- Only when the screen's root is a non-scrolling layout container
  (`Column`, `Row`, `Box`), and only for an **active** division. Its goal is
  that no direct child of that root straddles the division.
- An inactive division (the device fully open) changes nothing. What the
  closed device's outer display reports, an inactive division or none at
  all, is unverified; either way nothing changes.
- A root `Scroll` or `List` is **not** fold-honoured.
- Occlusions are **not** auto-honoured; they reach screens through
  `:reserved_regions`, the same way safe-area insets do.
- Setting `respect_fold: false` on the root turns auto-honour off for
  screens that mean to paint across the crease, such as games, canvases,
  full-bleed media and camera viewfinders.

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

Why only direct children, and nothing more ambitious:

- The HIG says to "move only what's necessary" and to "favor small
  adjustments over rearrangement". Re-flowing a whole screen into two panes
  is what `<Arrangement>` is for. Nested containers and overlays
  (`:anchored` panels) are outside the automatic layer and must use
  `:reserved_regions` themselves.

**What MOB-202 must specify before the default ships:**

1. Which region a displaced child moves to. 111463 says the content's
   purpose decides, and that alerts go to the trailing side in book pose
   and controls to the bottom when the device stands on a table. A default
   rule is needed.
2. A band parallel to the root's main axis, such as a `Column` across a
   vertical fold. Moving children along the main axis can't clear it.
3. A child larger than either region (a fixed width or height), which
   can't avoid the band without being resized.
4. All of it confirmed on the 27.1 simulator in every pose: book, tent,
   laptop and rotated.

**Triggers for revisiting this:**

- 27.1 SwiftUI may already displace plain stacks hosted in a
  `UIHostingController`. Apple says "framework-provided views and
  containers automatically adjust", but also that custom views need
  reserved regions, and neither source covers bare `VStack`s. If the
  simulator shows it does, mob adds no layer of its own, and
  `respect_fold: false` maps onto whatever opt-out SwiftUI has, or goes
  away.
- If MOB-202 cannot make cases 2 and 3 predictable, the default becomes
  opt-in (the alternative below), and a new record supersedes this one.

**Alternative recorded and rejected for now:** opt-in with
`respect_fold: true`, or no automatic behaviour at all, leaving everything
to `<Arrangement>` and `:reserved_regions`. That is more honest about the
cost, because auto-honour can move content the author placed deliberately.
It was rejected because the failure modes are asymmetric. A wrongly
honoured fold moves content, and one prop turns that off. A wrongly ignored
fold puts unreadable, untappable controls in the crease of every naive app,
and the author doesn't know there is a prop to look for.

**Misuse to watch for, once it ships:** `respect_fold: false` on an ordinary
text-and-controls screen, usually copied from a canvas example, will be the
usual cause of "content painted into the crease". `common_fixes.md` has the
entry.

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
  `<SceneAccessory>` element). It reads the same assigns, so the main and
  accessory displays never disagree about state. Availability arrives as
  `{:mob_scene_accessory_available, boolean}`, which is Apple's
  `onAvailabilityChange`.
- **One element, an explicit kind.** Apple has two different accessories
  (item 7):
  - The Duo **camera-capture** accessory (`CameraCaptureAccessory`), a
    SwiftUI modifier on the camera UI.
  - The generic **external-display** accessory (`UISceneAccessory`), which
    is non-interactive and backed by a `UISceneConfiguration`, so it is a
    scene the system connects.

  `<SceneAccessory>` therefore takes a `kind:`. MOB-244 implements
  `:camera_capture`, the Duo case. `:external_display` is a recognised
  future kind. It belongs with MOB-245's scene work because it needs a
  scene delegate, and it is out of MOB-244's scope.
- **Optional by contract.** The system decides when an accessory is shown;
  the UIKit header says "the app must remain fully functional without them".
  A screen must never require its accessory tree in order to work. The tree
  renders nowhere whenever its kind isn't available, which means always for
  `:camera_capture` on Android and on iPhones without a second display.
- **Not an app instance the screen requests, and not the outer display's
  only content.** When the device is closed, the main tree runs on the outer
  display as normal. While it is open, `CameraCaptureAccessory` is the only
  way onto the outer display that Apple describes. Per item 6 it needs full
  screen on the inner display and an active camera session. Apple registers
  it "on the same view as your camera UI"; its sample attaches it to the
  whole `CameraView`, not to a preview leaf. In mob terms
  `<SceneAccessory kind={:camera_capture}>` attaches to the container that
  holds the screen's camera UI, typically the parent of a `:camera_preview`
  node (`Mob.UI.camera_preview/1`, fed by the `mob_camera` plugin), and is
  visible only while that container is. MOB-244's "outer display is
  accessory-only" constraint is corrected to this.
- **Unverified:** whether `CameraCaptureAccessory` content accepts touches.
  27.0's only UIKit accessory is `externalNonInteractive`, and the
  teleprompter demo shows no touch input. MOB-244's "taps in the accessory
  reach the same screen pid" may describe a capability that doesn't exist.
- **Gating.** The generic `sceneAccessory`/`SceneAccessoryContent` API is
  iOS 27.0 (item 7). `CameraCaptureAccessory` is expected to be 27.1. Each
  is gated at its use site with its own `@available` (see 8), and the 27.1
  annotation is confirmed against the 27.1 SDK when it is installed.

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
`onHingeChange`/`UIHingeInteraction`, and `CameraCaptureAccessory`, whose
exact annotation is still to be confirmed) is used only
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

### 9. Android: a no-op seam now, with a candidate mapping

Mob's Android implementation isn't fold-aware, and none of the devices in
its verified pool fold. Every primitive above ships on Android anyway, as a
defined no-op, so a screen written for Duo compiles and runs there
unchanged.

The right-hand column is a **candidate**, read from the Jetpack WindowManager
reference. It shows that the contract can be filled on Android, not how it
will be:

| Primitive | Android today | Candidate mapping |
|---|---|---|
| `:reserved_regions` | always `[]` | `FoldingFeature.bounds` → `frame`; `isSeparating` → `active` |
| `<Arrangement>` | Apple's split/overlay rule, no division | same rule, with a separating `FoldingFeature` band as the division |
| `{:mob_hinge_change, _}` | never sent | `FoldingFeature.State` gives only `FLAT`/`HALF_OPENED` (→ `:fully_open`/`:partially_open`); the angle would need `Sensor.TYPE_HINGE_ANGLE` |
| `<SceneAccessory>` | renders nothing; availability never sent | no counterpart identified |
| `:size_class` | per MOB-204 (Compose `WindowSizeClass`) | per MOB-204 |

Open questions for whoever implements it:

- `isSeparating` and `occlusionType` (`NONE`/`FULL`) are independent on
  Android. A hinge between two panels is both separating and fully
  occluding, while mob's `kind` is a single value. Either a division
  carries an `occluding` flag, or one feature becomes two regions.
- `FoldingFeature.State` has no closed value, only `FLAT` and `HALF_OPENED`.
  So `:closed` must come from somewhere else (the hinge-angle sensor or
  display state), or Android never sends it.
- Android's window size classes have more buckets than iOS's two: compact,
  medium and expanded, plus large and extra-large behind an opt-in. MOB-204
  owns the mapping.

The message and assign shapes above are the contract both platforms
implement. None of them are specific to Apple beyond the names of the
source APIs.

## Consequences

- **MOB-204 (`:size_class`, in flight).** Nothing here changes its contract.
  This record adds a rule for later code: layout reads `:size_class`, never
  `Mob.Device.orientation/0`. The outer display in landscape reads
  `{:compact, :compact}` (111461); the ticket lists only portrait cases.
- **MOB-206 (template plist, in flight).**
  - The ticket asks whether Apple added a `UIDeviceFamily` value 5 for Duo.
    Nothing published says so: Apple calls a Duo app "still an iPhone app"
    and names no new family. Keep `[1, 2]`, and confirm on the 27.1 SDK.
  - Apple ties the full-screen and vertical-bar behaviour to building with
    the 27.1 SDK and names no plist opt-in for it (item 9).
  - A portrait lock in the plist won't keep the inner display in portrait:
    the inner display doesn't honour supported orientations (item 1).
  - `UIRequiresFullScreen = true` is still honoured on Duo, but the app
    resizes on open and close anyway, and Apple says all apps take part in
    multitasking (item 9). So the doctor warning for "Duo-hostile" plists
    should say the app still resizes, not that it won't. Whether `true`
    keeps an app out of *Split View* on Duo, as it does on iPad, is not
    stated; leave it unverified.
- **MOB-202, MOB-203, MOB-243, MOB-244 and MOB-245** inherit the shapes and
  corrections above:
  - MOB-202: the `active` flag; the narrower, provisional auto-honour and
    the open cases it must settle.
  - MOB-203: two children, `style`/`axes`, and the aspect-ratio fallback.
  - MOB-243: no hinge assign.
  - MOB-244: a `kind:`, attached to the camera UI container, and optional.
  - MOB-245: the activation API is iOS 15.

  Each ticket's own acceptance criteria still stand where this record
  doesn't contradict them.
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
  The MOB-201 slice reports that GitHub's preview `xcode-27` runner image
  has Xcode 27.1 (27A9269) with the 27.1 SDK, but only the iOS 27.0
  simulator runtime. If that holds, CI can compile the 27.1 call sites but
  can't run a Duo simulator. That report wasn't checked here.
- **Docs.** `AGENTS.md` points to this record under "Device shapes".
  `common_fixes.md` has the "content painted into the crease" entry.
