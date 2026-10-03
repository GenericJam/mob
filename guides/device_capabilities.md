# Device Capabilities

All device APIs in Mob follow a consistent pattern: call the function from a callback (returning the socket unchanged), then handle the result in `handle_info/2`. APIs never block the screen process.

Since 0.7.0, several capabilities ship as first-party **plugins** rather than in core: `MobCamera` (`mob_camera`), `MobPhotos` (`mob_photos`), `MobLocation` (`mob_location`), `MobBiometric` (`mob_biometric`), `MobScanner` (`mob_scanner`), and `MobNotify` (`mob_notify`). Activating one is the same two steps for each — add the dep, list it in `mob.exs`:

```elixir
# mix.exs
{:mob_camera, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_camera]
```

See the [Plugins guide](plugins.md). Everything else on this page (haptics, clipboard, share, files, audio, motion, storage, web view, alerts) is core.

## Permissions

Some capabilities require an OS permission before they can be used. Request permissions via `Mob.Permissions.request/2`. The result arrives asynchronously:

```elixir
def mount(_params, _session, socket) do
  socket = Mob.Permissions.request(socket, :camera)
  {:ok, socket}
end

def handle_info({:permission, :camera, :granted}, socket) do
  {:noreply, Mob.Socket.assign(socket, :camera_ready, true)}
end

def handle_info({:permission, :camera, :denied}, socket) do
  {:noreply, Mob.Socket.assign(socket, :camera_ready, false)}
end
```

**Capabilities that require permission:** `:camera`, `:microphone`, `:photo_library`, `:location`, `:notifications`

**No permission needed:** haptics, clipboard, share sheet, file picker.

> **`Mob.Permissions.request/2` is only half the picture.** Each
> permission-gated capability also needs an `Info.plist` usage
> description (iOS) and `AndroidManifest.xml` `uses-permission` entry
> (Android). The default `mix mob.new` template covers camera +
> microphone on iOS and most capabilities on Android, but leaves
> location, photo library, etc. for you to add explicitly. See
> [permissions](permissions.html) for the per-capability table, the
> iOS-specific gotchas, and a diagnostic checklist for "the dialog
> never appears".

## Haptic feedback

`Mob.Haptic.trigger/2` fires synchronously (no `handle_info` needed) and returns the socket:

```elixir
def handle_info({:tap, :purchase}, socket) do
  socket = Mob.Haptic.trigger(socket, :success)
  {:noreply, socket}
end
```

Feedback types: `:light`, `:medium`, `:heavy`, `:success`, `:error`, `:warning`

iOS uses `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`. Android uses `View.performHapticFeedback`.

## Clipboard

`Mob.Clipboard.get/1` dispatches to the main thread synchronously (same model as `safe_area/0`); no `handle_info` needed. `put/2` is fire-and-forget.

```elixir
# Write to clipboard
def handle_info({:tap, :copy}, socket) do
  socket = Mob.Clipboard.put(socket, socket.assigns.code)
  {:noreply, socket}
end

# Read from clipboard — result returned synchronously
def handle_info({:tap, :paste}, socket) do
  case Mob.Clipboard.get(socket) do
    {:clipboard, :ok, text} -> {:noreply, Mob.Socket.assign(socket, :pasted_text, text)}
    {:clipboard, :empty}    -> {:noreply, socket}
  end
end
```

## Share sheet

Opens the platform's native share sheet (iOS: `UIActivityViewController`, Android: `ACTION_SEND` via `Intent.createChooser`). Fire-and-forget — no response arrives in the BEAM.

```elixir
def handle_info({:tap, :share}, socket) do
  socket = Mob.Share.text(socket, "Check out this app! https://example.com")
  {:noreply, socket}
end
```

Plain text only. URLs go inside the text; iOS auto-detects and offers URL-appropriate share targets. If you need multi-part sharing (title/url/image separately), file a ticket describing the use case.

## Camera

`MobCamera` ships in the `mob_camera` plugin (which also registers the `:camera` permission) — add the dep + activate in `mob.exs`. Requires `:camera` permission (and `:microphone` for video).

```elixir
# Capture a photo
socket = MobCamera.capture_photo(socket)
socket = MobCamera.capture_photo(socket, quality: :medium)

# Record a video
socket = MobCamera.capture_video(socket)
socket = MobCamera.capture_video(socket, max_duration: 30)

# Results:
def handle_info({:camera, :photo, %{path: path, width: w, height: h}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :photo_path, path)}
end

def handle_info({:camera, :video, %{path: path, duration: seconds}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :video_path, path)}
end

def handle_info({:camera, :cancelled}, socket) do
  {:noreply, socket}
end
```

`path` is a local temp file. Copy it to a permanent location before the next capture.

## Photos

Browse and pick from the photo library. `MobPhotos` ships in the `mob_photos` plugin. Requires `:photo_library` permission.

```elixir
socket = MobPhotos.pick(socket)
socket = MobPhotos.pick(socket, max: 5)  # pick up to 5

def handle_info({:photos, :picked, photos}, socket) do
  # photos is a list of %{path: path, width: w, height: h} maps
  {:noreply, Mob.Socket.assign(socket, :photos, photos)}
end

def handle_info({:photos, :cancelled}, socket) do
  {:noreply, socket}
end
```

## Files

Open the system file picker:

```elixir
socket = Mob.Files.pick(socket)
socket = Mob.Files.pick(socket, types: ["public.pdf", "public.text"])  # iOS UTI strings
socket = Mob.Files.pick(socket, types: ["application/pdf", "text/plain"])  # Android MIME types

def handle_info({:files, :picked, files}, socket) do
  # files is a list of %{path: path, name: name, size: bytes} maps
  {:noreply, Mob.Socket.assign(socket, :files, files)}
end
```

> **Platform note:** `types` uses iOS UTI strings on iOS (`"public.pdf"`) and MIME type strings on Android (`"application/pdf"`). To support both platforms with the same call, pass both forms — the platform ignores strings it doesn't recognise. See [Platform-specific props](components.md#platform-specific-props) for a cleaner pattern.

## Camera preview

Display a live camera feed inline (no OS permission dialog for preview). The `<CameraPreview>` render-tree node lives in core, but the preview session API is `MobCamera` (`mob_camera` plugin):

```elixir
def mount(_params, _session, socket) do
  socket = MobCamera.start_preview(socket, facing: :back)
  {:ok, socket}
end

def render(assigns) do
  ~MOB"""
  <Column>
    <CameraPreview facing={:back} weight={1} />
    <Button text="Flip" on_tap={{self(), :flip}} />
  </Column>
  """
end

def terminate(_reason, socket) do
  MobCamera.stop_preview(socket)
  :ok
end
```

The `:camera_preview` component requires an active preview session — call `start_preview/2` before mounting and `stop_preview/1` in `terminate/2`.

## Audio recording

Requires `:microphone` permission.

```elixir
socket = Mob.Audio.start_recording(socket)
socket = Mob.Audio.start_recording(socket, format: :aac, quality: :medium)
socket = Mob.Audio.stop_recording(socket)

def handle_info({:audio, :recorded, %{path: path, duration: seconds}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :recording, path)}
end

def handle_info({:audio, :error, reason}, socket) do
  {:noreply, Mob.Socket.assign(socket, :error, reason)}
end
```

Recording formats: `:aac` (default), `:wav`. Quality: `:low`, `:medium` (default), `:high`.

## Audio playback

No permission needed. Plays local files or remote URLs.

```elixir
socket = Mob.Audio.play(socket, "/path/to/clip.m4a")
socket = Mob.Audio.play(socket, path, loop: true, volume: 0.8)
socket = Mob.Audio.stop_playback(socket)
socket = Mob.Audio.set_volume(socket, 0.5)  # adjust without stopping

def handle_info({:audio, :playback_finished, %{path: path}}, socket) do
  {:noreply, socket}
end

def handle_info({:audio, :playback_error, %{reason: reason}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :error, reason)}
end
```

iOS uses `AVAudioPlayer` / `AVPlayer`. Android uses `MediaPlayer`.

## Location

`MobLocation` ships in the `mob_location` plugin. Requires `:location` permission.

```elixir
# Single fix
socket = MobLocation.get_once(socket)

# Continuous updates
socket = MobLocation.start(socket)
socket = MobLocation.start(socket, accuracy: :high)  # :high | :balanced | :low
socket = MobLocation.stop(socket)

def handle_info({:location, %{lat: lat, lon: lon, accuracy: acc, altitude: alt}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :location, %{lat: lat, lon: lon})}
end

def handle_info({:location, :error, reason}, socket) do
  {:noreply, Mob.Socket.assign(socket, :location_error, reason)}
end
```

iOS uses `CLLocationManager`. Android uses `FusedLocationProviderClient`.

## Motion (accelerometer / gyroscope)

```elixir
socket = Mob.Motion.start(socket)
socket = Mob.Motion.start(socket, interval_ms: 100)
socket = Mob.Motion.stop(socket)

def handle_info({:motion, %{ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :motion, %{ax: ax, ay: ay, az: az})}
end
```

## Biometric authentication

`MobBiometric` ships in the `mob_biometric` plugin.

```elixir
socket = MobBiometric.authenticate(socket, reason: "Confirm your identity")

def handle_info({:biometric, :success}, socket) do
  {:noreply, Mob.Socket.assign(socket, :authenticated, true)}
end

def handle_info({:biometric, :failure, reason}, socket) do
  {:noreply, socket}
end
```

iOS uses Face ID / Touch ID. Android uses `BiometricPrompt`.

## QR / barcode scanner

`MobScanner` ships in the `mob_scanner` plugin. Activate `mob_camera` alongside it — `mob_camera` owns the `:camera` permission the scanner needs (`config :mob, :plugins, [:mob_camera, :mob_scanner]`).

```elixir
socket = MobScanner.scan(socket)

def handle_info({:scan, :result, %{type: type, value: value}}, socket) do
  # type: :qr | :ean | :upc | etc.
  {:noreply, Mob.Socket.assign(socket, :scanned, value)}
end

def handle_info({:scan, :cancelled}, socket) do
  {:noreply, socket}
end
```

## Notifications

`MobNotify` ships in the `mob_notify` plugin — see [its docs](https://hexdocs.pm/mob_notify) for the full API. Delivery (the `{:notification, ...}` and `{:push_token, ...}` messages below) is unchanged core behavior.

Requires `:notifications` permission.

### Local notifications

```elixir
# Schedule
MobNotify.schedule(socket,
  id:    "reminder_1",
  title: "Time to check in",
  body:  "Open the app to see today's updates",
  at:    ~U[2026-04-16 09:00:00Z],   # or delay_seconds: 60
  data:  %{screen: "reminders"}
)

# Cancel
MobNotify.cancel(socket, "reminder_1")

# Receive in handle_info. :foreground = arrived while the app was open,
# :tap = opened by the user (from foreground, background, or a cold launch).
# Full shape: Mob.Notification.
def handle_info({:notification, %{presentation: :tap, id: id, data: data}}, socket) do
  {:noreply, socket}
end
```

### Push notifications

See the [Push Notifications guide](push_notifications.md) for the full walkthrough — server setup, credential configuration, token handling, delivery lifecycle, and appearance options.

Quick reference:

```elixir
# After :notifications permission is granted:
{:noreply, MobNotify.register_push(socket)}

# Receive the device token — store it server-side with the platform:
def handle_info({:push_token, platform, token}, socket) do
  MyApp.PushTokens.upsert(socket.assigns.user_id, token, platform)
  {:noreply, socket}
end

# Receive push notifications (foreground arrival, background tap, or killed → tapped):
def handle_info({:notification, %{source: :push} = notif}, socket) do
  # notif.presentation is :foreground or :tap; notif.data holds your custom keys
  {:noreply, socket}
end
```

To send from your server, add [`mob_push`](https://hexdocs.pm/mob_push) to your server dependencies.

## Deep links

An app can be opened by a URL with its own scheme: a link tapped in another
app, a QR code read by the camera or a scanner app. Declare the schemes in
`mob.exs`; the native build (mob_dev 0.7.12 or later) adds an intent filter to
the Android main activity and a `CFBundleURLTypes` entry to the iOS bundle.
A change needs a native rebuild (`mix mob.deploy --native`).

```elixir
# mob.exs
config :mob_dev, url_schemes: ["myapp"]
```

On Android, `MainActivity` must also be `android:launchMode="singleTask"` in
`android/app/src/main/AndroidManifest.xml`; the build refuses `url_schemes`
without it. With the template's `singleTop`, a link opened from another app's
task (a QR scanner, a browser that doesn't ask for a new task) starts a
second `MainActivity` in that task, and two activities then drive one BEAM's
UI; `singleTask` hands the link to the existing one's `onNewIntent`. The cost,
and the reason it isn't the default: reopening the app from its launcher icon,
or a link reaching the running app, then finishes any activity stacked above
`MainActivity` (a file picker, a share target, an in-app scanner), whose
result comes back cancelled.

Each URL arrives as `{:link, link}`, at the screen showing (full shape:
`Mob.Link`). `source` is `:launch` when the link arrived before the app had
finished starting: it opened the app, or came in while the app was starting,
and it waited until the root screen had mounted (it arrives once).
`source` is `:running` when the app was already running.

```elixir
def handle_info({:link, %{url: url}}, socket) do
  case URI.parse(url) do
    %URI{scheme: "myapp", host: "thread", query: query} when is_binary(query) ->
      %{"id" => id} = URI.decode_query(query)
      {:noreply, Mob.Socket.push_screen(socket, MyApp.ThreadScreen, %{id: id})}

    _ ->
      {:noreply, socket}
  end
end
```

Any app on the device can open a link with anything in it, so treat it as
untrusted input. To handle links in one place rather than in whichever screen
is showing, register a process (it can be registered before the root screen
starts, so it also gets the link that launched the app):

```elixir
# In the init/1 of a GenServer your app starts from on_start/0:
Mob.Link.register(self())
```

Try it without a QR code:

```bash
adb shell am start -a android.intent.action.VIEW -d 'myapp://thread?id=42'
xcrun simctl openurl booted 'myapp://thread?id=42'
```

### Apps generated before mob_new 0.6.4

The native files that forward the URL are app-owned, so an older app adds the
calls itself. Android, in `MainActivity.kt`:

```kotlin
// onCreate, inside the same guard as the notification tap, so re-creation
// from saved state and relaunch from Recents don't replay the link:
if (savedInstanceState == null &&
    (intent.flags and android.content.Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
) {
    deliverNotificationTap(intent)
    deliverLink(intent)
}

override fun onNewIntent(intent: android.content.Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    deliverNotificationTap(intent)
    deliverLink(intent)
}

private fun deliverLink(intent: android.content.Intent?) {
    if (intent?.action != android.content.Intent.ACTION_VIEW) return
    val uri = intent.data ?: return
    val scheme = uri.scheme
    if ("content".equals(scheme, ignoreCase = true) || "file".equals(scheme, ignoreCase = true)) return
    MobBridge.nativeDeliverLink(uri.toString())
}
```

`MobBridge.kt` declares `@JvmStatic external fun nativeDeliverLink(url: String)`
beside `nativeDeliverNotification`, and `beam_jni.c` forwards it:

```c
JNIEXPORT void JNICALL
Java_com_example_myapp_MobBridge_nativeDeliverLink(JNIEnv* env, jclass cls, jstring url) {
    const char* cu = (*env)->GetStringUTFChars(env, url, NULL);
    mob_deliver_link(cu);
    (*env)->ReleaseStringUTFChars(env, url, cu);
}
```

Remove an intent filter you declared by hand for a scheme that's now in
`url_schemes`, and make `MainActivity` `singleTask` (above).

iOS, in `AppDelegate.m`'s `SceneDelegate` (a scene-based app never gets
`application:openURL:options:`):

```objc
// at the end of scene:willConnectToSession:options:
for (UIOpenURLContext *ctx in connectionOptions.URLContexts) {
    if (!ctx.URL.isFileURL) mob_deliver_link(ctx.URL.absoluteString.UTF8String);
}

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
    for (UIOpenURLContext *ctx in URLContexts) {
        if (!ctx.URL.isFileURL) mob_deliver_link(ctx.URL.absoluteString.UTF8String);
    }
}
```

## Storage

App-local file storage using named locations instead of raw paths. No permission needed.

```elixir
# Resolve a location to its absolute path
path = Mob.Storage.dir(:documents)   # persists, user-visible on iOS
path = Mob.Storage.dir(:cache)       # persists until OS needs space
path = Mob.Storage.dir(:temp)        # ephemeral, may be purged any time
path = Mob.Storage.dir(:app_support) # persists, hidden from user, backed up on iOS

# File operations
{:ok, files} = Mob.Storage.list(:documents)       # returns full paths
{:ok, meta}  = Mob.Storage.stat("/path/to/file")  # %{name, path, size, modified_at}
{:ok, path}  = Mob.Storage.write("/path/file.txt", "contents")
{:ok, data}  = Mob.Storage.read("/path/file.txt")
{:ok, dest}  = Mob.Storage.copy("/path/src.txt", :documents)  # keeps basename
{:ok, dest}  = Mob.Storage.move("/path/src.txt", "/path/dest.txt")
:ok          = Mob.Storage.delete("/path/file.txt")

ext = Mob.Storage.extension("/tmp/clip.mp4")  # => ".mp4"
```

All operations that can fail return `{:ok, value} | {:error, posix}`. `dir/1` raises on an unknown location atom.

For saving to the native media library (Camera Roll, Downloads), see `Mob.Storage.Apple` and `Mob.Storage.Android`.

## WebView

Embed a native web view and communicate with it over a JS bridge. No permission needed.

```elixir
def render(assigns) do
  ~MOB"""
  <WebView url="https://example.com" allow={["https://example.com"]} show_url={true} weight={1} />
  """
end

# Send a message to Elixir from JS:
#   window.mob.send({ event: "clicked", id: 42 })
def handle_info({:webview, :message, %{"event" => "clicked", "id" => id}}, socket) do
  {:noreply, socket}
end

# A navigation attempt was blocked by the allow: whitelist
def handle_info({:webview, :blocked, url}, socket) do
  {:noreply, socket}
end
```

Push a message from Elixir into the page (calls `window.mob.onMessage` handlers):

```elixir
socket = Mob.WebView.post_message(socket, %{type: "update", value: 42})
```

Evaluate arbitrary JavaScript and receive the result:

```elixir
socket = Mob.WebView.eval_js(socket, "document.title")
# Result arrives as:
def handle_info({:webview, :eval_result, result}, socket) do
  {:noreply, socket}
end
```

Props: `:url` (required), `:allow` (list of URL prefixes — blocks others), `:show_url` (native URL bar), `:title` (static label overriding `:show_url`), `:width`, `:height`.

> **Platform note:** WebView is supported on both iOS and Android.

## Alerts and toasts

`Mob.Alert` shows native dialogs and status messages. No permission needed.

### Alert dialog

Centered modal for confirmations and errors (iOS: `UIAlertController(.alert)`, Android: `AlertDialog`).

```elixir
def handle_info({:tap, :delete}, socket) do
  Mob.Alert.alert(socket,
    title:   "Delete item?",
    message: "This cannot be undone.",
    buttons: [
      [label: "Delete", style: :destructive, action: :confirmed_delete],
      [label: "Cancel", style: :cancel]
    ]
  )
  {:noreply, socket}
end

def handle_info({:alert, :confirmed_delete}, socket) do
  {:noreply, do_delete(socket)}
end

def handle_info({:alert, :dismiss}, socket) do
  {:noreply, socket}
end
```

Dismissing without tapping a button (e.g. Android back gesture) sends `{:alert, :dismiss}`.

### Action sheet

Bottom-anchored list for choosing between actions (iOS: `UIAlertController(.actionSheet)`, Android: list dialog).

```elixir
Mob.Alert.action_sheet(socket,
  title:   "Share photo",
  buttons: [
    [label: "Save to Photos", action: :save],
    [label: "Copy link",      action: :copy],
    [label: "Cancel",         style: :cancel]
  ]
)

def handle_info({:alert, :save}, socket), do: {:noreply, save_photo(socket)}
def handle_info({:alert, :copy}, socket), do: {:noreply, copy_link(socket)}
def handle_info({:alert, :dismiss}, socket), do: {:noreply, socket}
```

### Toast

Ephemeral status message with no callback.

```elixir
Mob.Alert.toast(socket, "Saved!")
Mob.Alert.toast(socket, "File uploaded", duration: :long)
```

Duration: `:short` (default, ~2 s) or `:long` (~4 s). iOS renders a floating label overlay; Android uses `Toast`.

### Button options

| Key | Values | Default |
|-----|--------|---------|
| `:label` | string | `""` |
| `:style` | `:default`, `:cancel`, `:destructive` | `:default` |
| `:action` | atom — delivered as `{:alert, atom}` to `handle_info/2` | `:dismiss` |
