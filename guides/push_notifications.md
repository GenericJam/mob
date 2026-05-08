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
Mob.Notify.schedule(socket,
  id:    "reminder_1",
  title: "Time to check in",
  body:  "Open the app to see today's updates",
  at:    ~U[2026-06-01 09:00:00Z],
  data:  %{screen: "reminders"}
)

# After a delay
Mob.Notify.schedule(socket,
  id:           "cooldown",
  title:        "Cooldown complete",
  body:         "Ready to go again",
  delay_seconds: 3600
)
```

### Cancelling

```elixir
Mob.Notify.cancel(socket, "reminder_1")
```

### Receiving

All app states deliver the same message:

```elixir
def handle_info({:notification, %{id: id, data: data, source: :local}}, socket) do
  case data["screen"] do
    "reminders" -> {:noreply, Mob.Socket.push_screen(socket, MyApp.RemindersScreen)}
    _           -> {:noreply, socket}
  end
end
```

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
    {:noreply, Mob.Notify.register_push(socket)}
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
restore. Re-registering on each launch with `Mob.Notify.register_push/1` keeps
your stored token current.

#### 3. Handle received notifications

All three delivery scenarios deliver the same message to your screen:

```elixir
def handle_info({:notification, notif}, socket) do
  # notif has string keys: "title", "body", "data", "source"
  # notif["source"] is "push" for remote or "local" for scheduled
  case get_in(notif, ["data", "screen"]) do
    "chat"    -> {:noreply, Mob.Socket.push_screen(socket, MyApp.ChatScreen)}
    "inbox"   -> {:noreply, Mob.Socket.push_screen(socket, MyApp.InboxScreen)}
    _         -> {:noreply, socket}
  end
end
```

**Delivery scenarios:**

| App state | What happens |
|-----------|-------------|
| **Foreground** | OS does not show a system notification. `{:notification, notif}` arrives directly. |
| **Background** (home button pressed) | OS shows the notification in the tray. When tapped, the app foregrounds and `{:notification, notif}` arrives. |
| **Killed** (fully closed) | OS shows the notification. When tapped, the app launches and `{:notification, notif}` arrives once BEAM has booted. |

You don't need separate code paths — the same `handle_info` clause handles all three.

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

## Further reading

- [`mob_push` on HexDocs](https://hexdocs.pm/mob_push) — full server-side documentation: credential setup, all payload options, notification appearance, token lifecycle
- [`Mob.Notify`](Mob.Notify.html) — schedule/cancel local notifications, register for push
- [`Mob.Permissions`](Mob.Permissions.html) — request OS permission
