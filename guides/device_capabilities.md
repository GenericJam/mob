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

## Camera preview

Display a live camera feed inline (no OS permission dialog for preview):

```elixir
def mount(_params, _session, socket) do
  socket = Mob.Camera.start_preview(socket, facing: :back)
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
  Mob.Camera.stop_preview(socket)
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

## iOS Foundation Models

Generates text with Apple's on-device Foundation Models framework.
Requires an eligible physical device with Apple Intelligence enabled; the iOS
simulator reports this capability as unavailable.

Apple docs:
[Foundation Models](https://developer.apple.com/documentation/foundationmodels) and
[Adding intelligent app features with generative models](https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models).

```elixir
socket =
  Mob.IOS.FoundationModels.generate_text(socket, "Turn this note into a short action list",
    instructions: "Return compact plain text.",
    temperature: 0.2,
    maximum_response_tokens: 240
  )

def handle_info({:foundation_models, :generated_text, %{text: text}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :result, text)}
end

def handle_info({:foundation_models, :error, %{reason: reason}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :error, reason)}
end
```

## iOS Vision text recognition

Recognizes text in a local image file with Apple's Vision framework. Combine
with `Mob.Photos.pick/2` to OCR a user-selected image.

Apple docs:
[VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest).

```elixir
socket =
  Mob.Photos.pick(socket, max: 1, types: [:image])

def handle_info({:photos, :picked, [%{path: path} | _]}, socket) do
  socket =
    Mob.IOS.Vision.recognize_text(socket, path,
      recognition_level: :accurate,
      uses_language_correction: true
    )

  {:noreply, socket}
end

def handle_info({:vision, :recognized_text, %{text: text}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :ocr_text, text)}
end
```

## iOS Speech transcription

Transcribes an existing audio file with Apple's Speech framework. Use
`Mob.Audio` to record microphone input first, then transcribe the saved
recording path.

Apple docs:
[SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer) and
[SFSpeechURLRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechurlrecognitionrequest).

```elixir
socket = Mob.Audio.start_recording(socket, format: :aac, quality: :high)
socket = Mob.Audio.stop_recording(socket)

def handle_info({:audio, :recorded, %{path: path}}, socket) do
  socket =
    Mob.IOS.Speech.transcribe_audio(socket, path,
      locale: "en-US",
      requires_on_device_recognition: false
    )

  {:noreply, socket}
end

def handle_info({:speech, :transcribed_audio, %{text: text}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :transcript, text)}
end
```

Speech recognition requires iOS speech authorization. If
`requires_on_device_recognition` is true, iOS may reject locales that do not
support local recognition.

### iOS native intelligence testing

| Capability | iOS simulator | Physical iPhone |
|---|---:|---:|
| `Mob.IOS.FoundationModels.generate_text/3` | No. The simulator does not provide the on-device system language model. | Yes, on Apple Intelligence-capable devices with Apple Intelligence enabled and the model ready. |
| `Mob.IOS.Vision.recognize_text/3` | Yes. Pass a readable image path in the simulator app container or pick a simulator photo. | Yes. |
| `Mob.IOS.Speech.transcribe_audio/3` | Usually yes for file transcription, subject to simulator Speech authorization and runtime locale/service availability. | Yes, subject to Speech authorization and locale support. |

The lightest simulator smoke test is:

1. Build a Mob app that exposes a screen with `Mob.Photos.pick/2` and calls
   `Mob.IOS.Vision.recognize_text/3` with the selected photo path.
2. Add a photo with readable text to the simulator photo library, select it in
   the picker, and confirm OCR returns the expected text.
3. Build two audio actions: one calls `Mob.Audio.start_recording/2`; the other
   calls `Mob.Audio.stop_recording/1`. Pass the recorded file path from
   `{:audio, :recorded, %{path: path}}` to `Mob.IOS.Speech.transcribe_audio/3`.
4. Confirm Foundation Models returns the expected simulator-unavailable error.

For path-based debugging in a simulator app that is already installed, the
useful setup commands are:

```sh
SIM_ID="booted"
BUNDLE_ID="com.example.my_mob_app"
CONTAINER="$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE_ID" data)"

cp ./ocr_fixture.png "$CONTAINER/Documents/ocr_fixture.png"
```

Then pass the copied path to the app:

```elixir
image_path = "/path/from/xcrun/simctl/get_app_container/Documents/ocr_fixture.png"
Mob.IOS.Vision.recognize_text(socket, image_path)
```

For Speech, recording inside the Mob app is the most representative smoke test:

```elixir
socket = Mob.Audio.start_recording(socket)
socket = Mob.Audio.stop_recording(socket)

def handle_info({:audio, :recorded, %{path: path}}, socket) do
  {:noreply, Mob.IOS.Speech.transcribe_audio(socket, path)}
end
```

### Scope and follow-up ideas

This first bridge includes plain Foundation Models text generation, Vision OCR
from a local image path, and Speech transcription from a local audio file.

Not included yet: Foundation Models structured generation with `@Generable`,
streaming partial Foundation Models responses, tool calling, multi-turn session
persistence, Vision requests beyond text recognition, live Speech recognition,
custom Speech language models, Natural Language framework features, image
generation, Private Cloud Compute-backed server features, and Android ML Kit or
platform-equivalent implementations.

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

See the [Push Notifications guide](push_notifications.md) for the full walkthrough — server setup, credential configuration, token handling, delivery lifecycle, and appearance options.

Quick reference:

```elixir
# After :notifications permission is granted:
{:noreply, Mob.Notify.register_push(socket)}

# Receive the device token — store it server-side with the platform:
def handle_info({:push_token, platform, token}, socket) do
  MyApp.PushTokens.upsert(socket.assigns.user_id, token, platform)
  {:noreply, socket}
end

# Receive push notifications (foreground, background tap, or killed → tapped):
def handle_info({:notification, notif}, socket) do
  # notif["source"] == "push", notif["data"] contains your custom payload
  {:noreply, socket}
end
```

To send from your server, add [`mob_push`](https://hexdocs.pm/mob_push) to your server dependencies.

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
