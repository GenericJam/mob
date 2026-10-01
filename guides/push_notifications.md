# Push Notifications

Mob supports both **local notifications** (scheduled on-device) and **remote push notifications** (sent from your server). Both deliver the same `{:notification, notif}` message to your screen process, regardless of whether the app was in the foreground, backgrounded, or fully killed when the notification arrived.

## Overview

| | Local | Push |
|---|---|---|
| Scheduled by | The device itself | Your server |
| Requires internet | No | Yes |
| Requires server | No | Yes (+ credentials) |
| Works when killed | Yes (OS delivers on schedule) | Yes (OS wakes on arrival) |
| Requires permission | Yes (`:notifications`) | Yes (`:notifications`) |

The device-side API (`MobNotify`) ships in the `mob_notify` plugin — add the
dep and activate it in `mob.exs` (see the [Plugins guide](plugins.md)):

```elixir
# mix.exs
{:mob_notify, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_notify]
```

Delivery is core behavior: `{:notification, notif}` and
`{:push_token, platform, token}` arrive in your screen's `handle_info/2`
(the shape is below and in `Mob.Notification`). The server side is the
separate [`mob_push`](https://hexdocs.pm/mob_push) package.

---

## Local notifications

Schedule a notification to fire at a specific time or after a delay.

### Requesting permission

```elixir
def on_mount(socket) do
  socket = Mob.Permissions.request(socket, :notifications)
  {:ok, socket}
end

def handle_info({:permission, :notifications, :granted}, socket) do
  {:noreply, Mob.Socket.assign(socket, :notify_ok, true)}
end

def handle_info({:permission, :notifications, :denied}, socket) do
  {:noreply, socket}
end
```

### Scheduling

```elixir
# At a specific time
MobNotify.schedule(socket,
  id:    "reminder_1",
  title: "Time to check in",
  body:  "Open the app to see today's updates",
  at:    ~U[2026-06-01 09:00:00Z],
  data:  %{screen: "reminders"}
)

# After a delay
MobNotify.schedule(socket,
  id:           "cooldown",
  title:        "Cooldown complete",
  body:         "Ready to go again",
  delay_seconds: 3600
)
```

### Cancelling

```elixir
MobNotify.cancel(socket, "reminder_1")
```

### Receiving

Every notification arrives as `{:notification, notif}`, where `notif` is a
`Mob.Notification` map:

```elixir
%{
  presentation: :tap,          # or :foreground
  action: "default",           # nil for :foreground
  source: :local,              # or :push
  id: "reminder_1",
  title: "Time to check in",
  body: "Open the app to see today's updates",
  data: %{screen: "reminders"} # atom keys at the top level
}
```

`presentation` tells an arrival from a tap:

* `:foreground` — the notification arrived while the app was in the
  foreground. The OS still shows its banner. Refresh state, don't navigate.
* `:tap` — the user opened it, whether the app was in the foreground, in the
  background, or killed. Navigate here.

```elixir
def handle_info({:notification, %{presentation: :tap, data: data}}, socket) do
  case data[:screen] do
    "reminders" -> {:noreply, Mob.Socket.push_screen(socket, MyApp.RemindersScreen)}
    _           -> {:noreply, socket}
  end
end

def handle_info({:notification, %{presentation: :foreground}}, socket) do
  {:noreply, socket}
end
```

`action` is `"default"` for a tap on the notification itself. An app that
registers its own iOS notification categories also sees `"dismiss"` and its
own action identifiers there.

**Which process receives it.** The process that registered through
`mob_notify` (`MobNotify.register_push/1`; on iOS also `MobNotify.schedule/2`)
while it is alive, otherwise the screen currently showing. A tap that
launched the app goes to the root screen once it has mounted, exactly once.

---

## Push notifications

Push notifications are sent from your server to the device. Mob handles the
app-side registration and delivery. You use
[`mob_push`](https://hexdocs.pm/mob_push) on the server side to send them.

### Architecture

```
Your server ──mob_push──► APNs / FCM ──► Device OS ──► Mob ──► {:notification, notif}
```

1. The app registers for push and receives a device token
2. Your app forwards the token to your server and stores it
3. When you want to notify a user, call `MobPush.send/3` from your server
4. The OS delivers the notification — Mob sends `{:notification, notif}` to your screen

### Installing mob_push on your server

Add to your server's `mix.exs`:

```elixir
{:mob_push, "~> 0.2"}
```

Then run `mix mob_push.install` for interactive credential setup, or configure
manually in `config/runtime.exs`:

```elixir
# iOS (APNs)
config :mob_push, :apns,
  key_id:    System.get_env("APNS_KEY_ID"),
  team_id:   System.get_env("APNS_TEAM_ID"),
  bundle_id: System.get_env("APNS_BUNDLE_ID", "com.example.myapp"),
  key_file:  System.get_env("APNS_KEY_FILE", "/path/to/AuthKey_XXXXXXXXXX.p8"),
  env:       if(config_env() == :prod, do: :production, else: :sandbox)

# Android (FCM)
config :mob_push, :fcm,
  project_id:          System.get_env("FCM_PROJECT_ID"),
  service_account_key: System.get_env("FCM_SERVICE_ACCOUNT_KEY", "/path/to/sa.json")
```

See the [mob_push docs](https://hexdocs.pm/mob_push) for the full credential
walkthrough (Apple Developer portal + Firebase console).

### App-side setup

Push registration needs a few host-app pieces the build can't fully automate:
the FCM `<service>` entry in `AndroidManifest.xml` plus a `google-services.json`
on Android, and the APNs token-forwarding hook in the `AppDelegate` on iOS.
The `mob_notify` plugin declares these as `host_requirements`, so every
`mix mob.deploy --native` prints exactly what's missing — follow the printed
snippets if registration silently yields no token.

#### 1. Request permission and register

```elixir
defmodule MyApp.HomeScreen do
  use Mob.Screen

  @impl Mob.Screen
  def on_mount(socket) do
    socket = Mob.Permissions.request(socket, :notifications)
    {:ok, socket}
  end

  @impl Mob.Screen
  def handle_info({:permission, :notifications, :granted}, socket) do
    # Register with APNs / FCM — token arrives asynchronously
    {:noreply, MobNotify.register_push(socket)}
  end

  def handle_info({:permission, :notifications, :denied}, socket) do
    {:noreply, socket}
  end
end
```

#### 2. Receive and store the token

```elixir
def handle_info({:push_token, platform, token}, socket) do
  # Send the token to your server and store it with the user
  MyApp.PushTokens.upsert(socket.assigns.user_id, token, platform)
  {:noreply, socket}
end
```

`platform` is `:ios` or `:android`. Each user may have multiple tokens (multiple
devices). Store the platform alongside the token — you need it when calling
`MobPush.send/3`.

Tokens can change: the OS may issue a new token after an app reinstall or backup
restore. Re-registering on each launch with `MobNotify.register_push/1` keeps
your stored token current.

#### 3. Handle received notifications

Pushes arrive as the same `Mob.Notification` map as local notifications, with
`source: :push` (see [Receiving](#receiving)). `data` holds your payload's
custom keys; on iOS, APNs' own `aps` dictionary is left out (its alert is in
`title` and `body`).

```elixir
def handle_info({:notification, %{presentation: :tap, data: data}}, socket) do
  case data[:screen] do
    "chat"    -> {:noreply, Mob.Socket.push_screen(socket, MyApp.ChatScreen)}
    "inbox"   -> {:noreply, Mob.Socket.push_screen(socket, MyApp.InboxScreen)}
    _         -> {:noreply, socket}
  end
end
```

**Delivery scenarios:**

| App state | What happens |
|-----------|-------------|
| **Foreground** | iOS shows its banner and `{:notification, %{presentation: :foreground}}` arrives; tapping the banner delivers a second message with `presentation: :tap`. Android: a push reaches mob in the foreground only through an app-owned `MobFirebaseService` (see the upgrade step below); FCM documents that it shows no tray banner for a push it hands to that service. |
| **Background** (home button pressed) | OS shows the notification. When tapped, the app foregrounds and `{:notification, %{presentation: :tap}}` arrives. |
| **Killed** (fully closed) | OS shows the notification. When tapped, the app launches and `{:notification, %{presentation: :tap}}` arrives at the root screen once it has mounted. |

Match on `presentation` when an arrival and a tap need different handling.

> **Android pushes.** Mob delivers what reaches the app through its
> `NotificationReceiver` (local notifications) and `MainActivity` (taps that
> carry `mob_notification_json`). `mob_push` puts that key in the FCM `data`
> block of every visible push so that `MainActivity` can rebuild the
> notification when the user taps it in the tray; FCM documents copying the
> `data` block into the launch intent's extras for such a tap (not verified on
> a device for this guide). A push sent without that key (another sender, the
> Firebase console) carries no mob payload, so its tap reaches the app without
> a `{:notification, _}`.

#### Upgrading an app with its own `MobFirebaseService`

Apps generated by mob_new 0.1.45–0.4.10 own a `MobFirebaseService` whose
`onMessageReceived` hands a push that arrives in the foreground to
`MobBridge.nativeDeliverNotification`. Its JSON has no `presentation`, and a
missing `presentation` means `:tap`, so a screen that navigates on taps would
navigate on every push that arrives while the app is open. Mark it as an
arrival before the call:

```kotlin
val json = JSONObject(
    message.data["mob_notification_json"] ?: run {
        val notif = message.notification ?: return
        JSONObject().apply {
            put("title", notif.title ?: "")
            put("body", notif.body ?: "")
            put("source", "push")
            put("data", JSONObject())
        }.toString()
    }
).put("presentation", "foreground").toString()
MobBridge.nativeDeliverNotification(pid, json)
```

### Sending from your server

```elixir
# Basic notification
MobPush.send(token, :ios, %{
  title: "New message",
  body:  "Alice: Hey, are you free tonight?"
})

# With data payload for navigation
MobPush.send(token, :android, %{
  title: "New message",
  body:  "Alice: Hey, are you free tonight?",
  data:  %{screen: "chat", thread_id: "42"}
})

# iOS — subtitle, badge, sound
MobPush.send(token, :ios, %{
  title:    "3 new messages",
  body:     "Alice, Bob and 1 other",
  subtitle: "in #general",
  badge:    3,
  sound:    "default"
})

# Android — custom icon, accent color, notification channel
MobPush.send(token, :android, %{
  title: "New message",
  body:  "Alice: Hey!",
  data:  %{screen: "chat"},
  android: %{
    "notification" => %{
      "icon"       => "ic_notification",
      "color"      => "#FF6200EE",
      "channel_id" => "messages"
    },
    "priority" => "high"
  }
})
```

### Fan-out to multiple devices

```elixir
def notify_user(user_id, payload) do
  user_id
  |> MyApp.PushTokens.list()
  |> Enum.each(fn %{token: token, platform: platform} ->
    case MobPush.send(token, platform, payload) do
      :ok ->
        :ok
      {:error, reason} when reason in [:device_token_expired, :device_token_not_found] ->
        MyApp.PushTokens.delete(token)
      {:error, reason} ->
        Logger.warning("Push failed for #{platform}/#{user_id}: #{inspect(reason)}")
    end
  end)
end
```

### Android: notification channels (Android 8+)

Android 8+ requires a notification channel to be created by the app before a
notification can use it. Create channels in your `MainActivity.onCreate`:

```kotlin
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
    val channel = NotificationChannel(
        "messages",
        "Messages",
        NotificationManager.IMPORTANCE_HIGH
    ).apply { description = "New message notifications" }
    getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
}
```

Then reference the channel ID in your server payload: `"channel_id" => "messages"`.
If the channel doesn't exist on the device, Android silently drops the notification.

### iOS: APNs environments

APNs has separate sandbox and production environments. Use `:sandbox` for Xcode /
TestFlight development builds and `:production` for App Store / TestFlight production
builds. A token from one environment is not valid in the other — sending to the wrong
environment returns `{:error, {:apns_error, "BadDeviceToken"}}`.

---

## Silent pushes and OS-triggered handlers

Everything above covers user-visible notifications — the ones with a
title and body that show in the tray. There's a second, silent variant
you'd use for waking the app to run code without showing anything:
sync data, refresh a cache, respond to a peer signal. That's what the
[`mob_wake`](https://hexdocs.pm/mob_wake) plugin is for, and it uses
the same `mob_push` send-side pipeline with a specific payload shape:

```elixir
# Device — register the handler once at boot
Mob.Wake.register(:sync_notes, :push, {MyApp.Sync, :run_sync})

# Server — send a silent push that fires that handler
payload = MobWake.wake_payload(:sync_notes, data: %{"peer" => "abc"})
MobPush.send(ios_token, :ios, payload)
```

`mob_wake`'s moduledoc covers the three-device-state matrix (foreground,
backgrounded, force-quit) and lays out the iOS-specific first-time
setup — the App ID Push capability, the provisioning profile
regeneration, and the AppDelegate dispatch handler that mob_new ships
in its template (MOB-271).

## Further reading

- [`mob_push` on HexDocs](https://hexdocs.pm/mob_push) — full server-side documentation: credential setup, all payload options, notification appearance, token lifecycle
- [`MobNotify`](https://hexdocs.pm/mob_notify) — schedule/cancel local notifications, register for push (ships in the `mob_notify` plugin)
- [`MobWake`](https://hexdocs.pm/mob_wake) — OS-triggered background handlers via scheduler firings and silent pushes; complements the user-visible flow above
- [`MobBackground`](https://hexdocs.pm/mob_background) — keep the app alive continuously while backgrounded (a different concern than push wake)
- [`Mob.Permissions`](Mob.Permissions.html) — request OS permission
