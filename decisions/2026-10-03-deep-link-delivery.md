# Opened links reach the BEAM through the router, like notifications

- Date: 2026-10-03
- Status: accepted
- Issues: MOB-379

## Context

mob had no way to hand an app the URL it was opened with: an Android
`ACTION_VIEW` intent with a custom scheme, an iOS scene URL context. Operator
needed `operator://` links (QR codes scanned with any app) and routed them
through the notification channel: its `MainActivity` wrapped the URI in a fake
notification-tap envelope (`data.operator_link`) and called
`nativeDeliverNotification`, because that path already held a cold-launch tap
until the root screen mounted. Every screen then matched
`{:notification, %{data: %{operator_link: link}}}`, plugins that dispatch on
notifications (`Mob.Plugins.dispatch_notification/1`) saw taps that never
happened, and every app needing links would have repeated the trick.

## Decision

**Same path as notifications, its own message.** Native hands each URL to the
`:mob_screen` router through one C entry on both platforms,
`mob_deliver_link(const char *url)` (`mob_beam.h`), as `{:mob_link, url}`.
When the router isn't registered yet (the link that cold-launched the app) the
URL waits in a FIFO the router drains in `init/1` with
`:mob_nif.take_launch_link/0` and delivers once the root screen has mounted;
a store that misses that drain pokes the router with `:mob_link_stored`. That
is the mechanism and the reasoning of
`2026-10-01-notification-delivery-envelope.md`, including "delivered once":
each take pops one entry under a lock that works before erts does. The FIFO is
a queue type shared with notifications (`ios/mob_stored_queue.h`,
`android/jni/mob_stored_queue.zig`, each with host tests), one instance per
kind, so a full notification queue cannot crowd out a link or the reverse.

**Screens receive `{:link, %{url: url, source: source}}`** (`Mob.Link`). The URL
is passed as the platform gave it. mob doesn't parse it: what a URL means is
the app's business, and `URI.parse/1` is one line in the screen.

**`source` is the router's view, not native's.** `:launch` means the link was
stored and taken from the FIFO, so it arrived before the router ran (it
started the app, or came in while the app was starting); `:running` means the
router took it live. Native can't say this reliably: Android's `onCreate` runs
for the activity that a running process re-creates as well as for a cold
start, and on iOS the BEAM may already be up when the scene connects.

**Registration is Elixir-side and this boot's.** `Mob.Link.register/1` stores
the pid in `:persistent_term` (a local pid is an immediate, so replacing or
erasing it does not make the runtime scan every process). The router checks it
on every delivery, stored links included, and falls back to the current screen
when it is unset or dead. Notifications differ: their target comes from native
(mob_notify's registration), and a stored envelope has none because that
registration belonged to a previous boot. A link registration can be made in
`on_start/0`, before the root screen starts, so a process registered there gets
the link that launched the app.

**Native forwarding lives in the app's files** (mob_new templates):

- Android `MainActivity` forwards `ACTION_VIEW` intents with data, except
  `content:` and `file:` URIs (documents, `Mob.Files.take_opened_document/0`),
  through `MobBridge.nativeDeliverLink` and a `beam_jni.c` stub. `onCreate`
  forwards inside the notification tap's guard (not re-created from saved
  state, not relaunched from Recents), since both replay the launching intent;
  `onNewIntent` forwards the rest. An app with `url_schemes` makes its
  `MainActivity` `singleTask` (mob_dev refuses the setting otherwise), so a
  link opened from another app's task reaches the one instance instead of
  starting a second `MainActivity` there. The template stays `singleTop`:
  `singleTask` also finishes the activities above `MainActivity` whenever the
  app is reopened from its launcher icon, a cost an app without links
  shouldn't pay (mob_new's `decisions/` has the record).
- iOS `SceneDelegate` forwards `connectionOptions.URLContexts` in
  `scene:willConnectToSession:options:` and the contexts of
  `scene:openURLContexts:`, skipping file URLs: those are documents, which
  an app that declares document types hands to `mob_handle_opened_url`
  itself (the template declares none). A scene-based app never gets
  `application:openURL:options:`.
- The scheme itself is declared by mob_dev from `config :mob_dev, url_schemes:`
  in `mob.exs` (mob_dev's `decisions/2026-10-03-url-schemes.md`).

## Alternatives rejected

- **Keep riding the notification channel.** It works, but it makes links look
  like notification taps to every consumer of `{:notification, _}`, including
  plugins, and each app has to reinvent the envelope.
- **Build `%URI{}` or a params map natively.** Two more implementations of one
  shape, the divergence the notification envelope decision removed.
- **Send straight to a registered pid from native.** The registration would
  have to live natively (a pid crossing JNI as a long), only to repeat what the
  router already does.
- **One FIFO with tagged entries for both kinds.** A burst of one kind would
  drop the other's launching entry; two small queues cost nothing.

## Consequences

- An app gets links after a native rebuild with mob 0.9.11 and native files
  that call `mob_deliver_link` (mob_new 0.6.4 templates, or the port described
  in the device capabilities guide).
- A screen that defines its own `handle_info/2` clauses and no catch-all crashes
  on a `{:link, _}` it doesn't match, and the router restarts it, as with any
  unexpected message.
- Up to 16 links wait for a router that never starts; later ones are dropped
  and logged, keeping the first.
- Universal links (`NSUserActivity`) and verified Android App Links are not
  declared by the build. An Android app that adds an `https` intent filter by
  hand gets those URLs through the same `MainActivity` forwarding; iOS
  universal links need the scene delegate's `continueUserActivity`, which the
  template doesn't implement.
