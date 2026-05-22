# Background Execution

Mob runs the BEAM on the device, but mobile operating systems still control
when a backgrounded app may execute. A GenServer cannot assume it will keep
running forever after the user leaves the app unless the app uses one of the
platform-approved background mechanisms.

## The default model: wake, handle, suspend

For most server-driven work, use push notifications:

1. The app registers with APNs or FCM via `Mob.Notify.register_push/1`.
2. The device token is sent to your server.
3. Your server sends a notification through `mob_push`.
4. The OS delivers or stores the notification.
5. When the notification is delivered to a foreground app, or tapped from the
   background or killed state, Mob sends `{:notification, notif}` to the screen.

This model is reliable because APNs and FCM are the OS-approved wakeup paths.
It is not the same as keeping an Erlang distribution connection or WebSocket
open indefinitely while the app is backgrounded.

See [Push Notifications](push_notifications.md) for token registration,
payloads, and notification tap handling.

## iOS

iOS suspends normal apps shortly after they enter the background. When that
happens, BEAM schedulers stop running with the rest of the process. Timers,
GenServers, sockets, and distribution connections do not continue like they
would on a server.

iOS can wake an app through sanctioned mechanisms such as visible notification
taps, silent pushes, background fetch, `BGTaskScheduler`, location, Bluetooth,
audio, and other entitlement-backed modes. These wakeups are constrained by the
OS and usually provide a short execution window rather than an always-on
process.

Mob also exposes `Mob.Background.keep_alive/0` for apps that legitimately use
audio. It keeps iOS execution alive through the audio background mode. Do not
use this just to hide a server listener in the background; Apple expects the
declared background mode to match a user-visible app capability.

## Android

Android permits true long-running background work through a foreground service.
Mob maps `Mob.Background.keep_alive/0` to a foreground service on Android.
Foreground services must show a persistent notification; Android intentionally
makes always-running background work visible to the user.

Without a foreground service, recent Android versions restrict background
execution heavily. Use FCM for server-initiated wakeups and WorkManager-style
patterns for deferred work.

## Choosing a pattern

| Goal | Recommended path |
|---|---|
| Show or route a server event to a screen | Push notification via APNs / FCM |
| Refresh local state after a user taps a notification | Handle `{:notification, notif}` and fetch from your server |
| Run continuously while visible | Normal Mob screen / supervision tree |
| Run continuously in Android background | `Mob.Background.keep_alive/0` foreground service |
| Run continuously in iOS background | Only for legitimate background modes such as audio, location, or Bluetooth |
| Hold a hidden always-on iOS socket | Not a supported mobile OS model |

## Practical design

Design background flows as resumable work:

- Persist enough state locally with `Mob.State` or SQLite to resume after
  suspension or cold start.
- Treat network connections as disposable; reconnect after the app foregrounds
  or receives a notification.
- Make notification handlers idempotent, because a user may tap an old
  notification after the app has already synced.
- Use `Mob.Background.keep_alive/0` only when your app has a real foreground
  service or background audio/location/Bluetooth reason.

For the platform API details, see `Mob.Background` and
[Device Capabilities](device_capabilities.md).
