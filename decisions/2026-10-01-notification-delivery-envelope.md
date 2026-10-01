# Notifications reach the BEAM as one JSON envelope, decoded by the router

- Date: 2026-10-01
- Status: accepted
- Issues: MOB-315 (iOS arrival vs tap), MOB-316 (Android raw tuple), MOB-178
  (iOS cold-launch tap)

## Context

Three gaps, one cause: each platform built its own notification message.

* The iOS delegate built an atom-keyed map in Objective-C and sent the same
  `{:notification, %{id, source: :local, data}}` from `willPresent` (arrived in
  the foreground) and `didReceive` (tapped). A screen could not tell an arrival
  from a tap. It also always said `source: :local` and left out title and body.
* Android sent the raw `{:mob_launch_notification, json}` straight to the pid
  mob_notify registered, normally a screen. Only `Mob.Router` decoded that tag,
  so the screen dropped the tap. With nothing registered, a warm tap was
  stored for "the next boot" and lost.
* iOS installed its delegate when mob_notify first ran, after the BEAM was up.
  iOS hands the tap that launched the app only to a delegate set before
  `didFinishLaunching` returns, so that tap was lost.
  `mob_set_launch_notification_json`, documented for the app delegate to call,
  had no caller.

## Decision

**One envelope.** Native code on both platforms serialises a notification to
the JSON object `{"id","title","body","source","presentation","action","data"}`
and hands it to the `:mob_screen` router as
`{:mob_notification, json, target}`, where `target` is the pid registered
through mob_notify, or `nil`. The router decodes it with
`Mob.Notification.decode/1` and sends `{:notification, map}` to `target` while
it is alive, otherwise to the current screen. The shape is defined once, in
Elixir, where it is tested. `presentation` is `"foreground"` or `"tap"`; a
missing one means a tap, which keeps app-owned Android code that predates the
field correct.

**One fallback.** When the router cannot take the envelope yet (erts not up, or
`:mob_screen` not registered), native appends it to a FIFO that replaces the
old single launch slot: a foreground arrival during boot must not displace the
tap that launched the app. Each `take_launch_notification` pops one envelope;
the router drains the FIFO in `init/1`, right after registering, and delivers
what it took from `init/1` once the root screen has mounted, so a notification
sent live while the root mounts (it waits in the mailbox) cannot overtake
them. A store that lands
after that drain happened after erts came up and after the registration, so
native's checks after the store (erts up? router registered?) find the router
and send `:mob_notification_stored`, and the router drains again. Each pop is
atomic: whichever drain comes first gets the envelope and the other finds
nothing, so it is delivered once. The FIFO holds 16; past that (a router that
never starts) the newest envelope is dropped and logged, keeping the launching
tap. It is guarded by a lock that works before erts does (`os_unfair_lock` on
iOS, an atomic spinlock in Zig), not an `ErlNifMutex` created in `nif_load`: a
foreground arrival can now store while erts is starting, which the old
"nothing touches the slot before nif_load" argument for an unguarded store did
not allow for.

A stored envelope does not keep its target: the router delivers it to the
current screen. The stored ones are the launching tap, whose registration (if
any) belonged to a previous boot, and those that arrived during boot, before
any screen could have registered for them.

**The router is required.** Delivery goes through `:mob_screen`, so an app
must start a root screen (`Mob.Screen.start_root`, which every generated app
does) to receive notifications. Before, the iOS delegate sent its unlabelled
map straight to the registered pid, so a process registered with mob_notify
in an app with no root screen heard notifications on iOS only. Such an app
now gets them stored until the FIFO fills; push tokens still go straight to
the registered pid.

**iOS delegate at launch.** `mob_init_ui()`, which the generated app delegate
already calls from `didFinishLaunching`, installs mob's delegate unless the app
set its own. Existing apps get the cold-launch tap with a mob update; no
template change is needed. The delegate then receives the launching tap in
`didReceiveNotificationResponse`. The scene's
`connectionOptions.notificationResponse` carries the same response and is
deliberately not read, since forwarding both would deliver the tap twice.
mob_notify's first call still makes mob's delegate the center's delegate,
replacing an app's own, as it did before.

**Android arrival.** The generated `NotificationReceiver` reports an arrival
only while `MainActivity` is between `onResume` and `onPause`, which is when
iOS calls `willPresent`. Both cold and warm taps go through
`mob_deliver_notification` with `MobNotifyHub.notifyPid`. `onCreate` skips
re-creation from saved state and relaunch from Recents, which replay the
launching intent: with delivery to a running BEAM, they would repeat the tap.

## Alternatives rejected

* **Decode on Android natively** (Zig `std.json` to terms), matching iOS. That
  is three implementations of one shape: Objective-C, Zig, and the router's
  launch-path decoder. The divergence among them is the bug being fixed.
* **Send the envelope to the target and decode in `Mob.Screen.Server`.** A
  process that is not a screen (mob_notify allows `register_push` from any
  process) would get raw JSON.
* **Call `mob_set_launch_notification_json` from the scene delegate**, as
  MOB-178 suggested. With the delegate installed at launch that delivers the
  launching tap twice. The hook stays for apps that receive notifications by
  some other route.

## Consequences

* Every notification passes through the router: one message, rare, not a
  per-render path (`2026-08-29-router-off-the-hot-path.md`).
* A payload that does not decode is logged and dropped. Before, the launch path
  delivered an empty `%{source: :local, data: %{}}`.
* iOS `data` loses `aps` (it was `nil`, since dictionaries were not converted)
  and gains nested values, booleans, and floats as JSON decodes them. Values
  JSON cannot carry (`NSDate`, `NSData`) are dropped.
* An app with no mob_notify registration now gets arrivals and taps at the
  current screen on both platforms. Before, iOS installed no delegate at all,
  and Android stored warm taps and never delivered them.
* Android pushes that the tray displays for FCM on its own carry no mob payload
  and still reach no screen; that is a separate gap.
