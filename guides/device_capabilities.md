# Device Capabilities

All device APIs in Mob follow a consistent pattern: call the function from a callback (returning the socket unchanged), then handle the result in `handle_info/2`. APIs never block the screen process.

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

## Haptic feedback

`Mob.Haptic.trigger/2` fires synchronously (no `handle_info` needed) and returns the socket:

```elixir
def handle_event("tap", %{"tag" => "purchase"}, socket) do
  socket = Mob.Haptic.trigger(socket, :success)
  {:noreply, socket}
end
```

Feedback types: `:light`, `:medium`, `:heavy`, `:success`, `:error`, `:warning`

iOS uses `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`. Android uses `View.performHapticFeedback`.

## Clipboard

```elixir
# Write to clipboard
def handle_event("tap", %{"tag" => "copy"}, socket) do
  socket = Mob.Clipboard.write(socket, socket.assigns.code)
  {:noreply, socket}
end

# Read from clipboard — result arrives in handle_info
def handle_event("tap", %{"tag" => "paste"}, socket) do
  socket = Mob.Clipboard.read(socket)
  {:noreply, socket}
end

def handle_info({:clipboard, :read, text}, socket) do
  {:noreply, Mob.Socket.assign(socket, :pasted_text, text)}
end
```

## Share sheet

Opens the platform's native share sheet (iOS: `UIActivityViewController`, Android: `ACTION_SEND`):

```elixir
def handle_event("tap", %{"tag" => "share"}, socket) do
  socket = Mob.Share.sheet(socket, text: "Check out this app!", url: "https://example.com")
  {:noreply, socket}
end
```

Options: `:text`, `:url`, `:title`

## Camera

Requires `:camera` permission (and `:microphone` for video).

```elixir
# Capture a photo
socket = Mob.Camera.capture_photo(socket)
socket = Mob.Camera.capture_photo(socket, quality: :medium)

# Record a video
socket = Mob.Camera.capture_video(socket)
socket = Mob.Camera.capture_video(socket, max_duration: 30)

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

Browse and pick from the photo library. Requires `:photo_library` permission.

```elixir
socket = Mob.Photos.pick(socket)
socket = Mob.Photos.pick(socket, max: 5)  # pick up to 5

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
```

## Audio recording

Requires `:microphone` permission.

```elixir
socket = Mob.Audio.record(socket)
socket = Mob.Audio.record(socket, format: :aac, max_duration: 120)
socket = Mob.Audio.stop_recording(socket)

def handle_info({:audio, :recorded, %{path: path, duration: seconds}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :recording, path)}
end
```

## Location

Requires `:location` permission.

```elixir
# Single fix
socket = Mob.Location.get_once(socket)

# Continuous updates
socket = Mob.Location.start(socket)
socket = Mob.Location.start(socket, accuracy: :high)  # :high | :balanced | :low
socket = Mob.Location.stop(socket)

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

```elixir
socket = Mob.Biometric.authenticate(socket, reason: "Confirm your identity")

def handle_info({:biometric, :success}, socket) do
  {:noreply, Mob.Socket.assign(socket, :authenticated, true)}
end

def handle_info({:biometric, :failure, reason}, socket) do
  {:noreply, socket}
end
```

iOS uses Face ID / Touch ID. Android uses `BiometricPrompt`.

## QR / barcode scanner

```elixir
socket = Mob.Scanner.scan(socket)

def handle_info({:scan, :result, %{type: type, value: value}}, socket) do
  # type: :qr | :ean | :upc | etc.
  {:noreply, Mob.Socket.assign(socket, :scanned, value)}
end

def handle_info({:scan, :cancelled}, socket) do
  {:noreply, socket}
end
```

## Notifications

See also [Mob.Notify](Mob.Notify.html) for the full API.

Requires `:notifications` permission.

### Local notifications

```elixir
# Schedule
Mob.Notify.schedule(socket,
  id:    "reminder_1",
  title: "Time to check in",
  body:  "Open the app to see today's updates",
  at:    ~U[2026-04-16 09:00:00Z],   # or delay_seconds: 60
  data:  %{screen: "reminders"}
)

# Cancel
Mob.Notify.cancel(socket, "reminder_1")

# Receive in handle_info (all app states: foreground, background, relaunched):
def handle_info({:notification, %{id: id, data: data, source: :local}}, socket) do
  {:noreply, socket}
end
```

### Push notifications

Register for push tokens and forward them to your server. A server-side push library (`mob_push`) is planned but not yet published — for now, use a standard APNs/FCM client library with the tokens you receive.

```elixir
# After :notifications permission is granted:
Mob.Notify.register_push(socket)

# Receive the device token:
def handle_info({:push_token, :ios,     token}, socket) do
  MyApp.Server.register_token(:ios, token)
  {:noreply, socket}
end

def handle_info({:push_token, :android, token}, socket) do
  MyApp.Server.register_token(:android, token)
  {:noreply, socket}
end

# Receive push notifications:
def handle_info({:notification, %{title: t, body: b, data: d, source: :push}}, socket) do
  {:noreply, socket}
end
```
