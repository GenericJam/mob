# Permissions

Single source of truth for the OS-level permissions Mob exposes, the
manifest / `Info.plist` entries each one requires, and the
platform-specific gotchas that aren't covered by the runtime API alone.

If you're hitting "the dialog never appears" or "I called the NIF and
nothing happened", this is the first place to look.

## TL;DR

* Call `Mob.Permissions.request(socket, :capability)` from your screen.
* The result arrives as `handle_info({:permission, :capability, :granted | :denied}, socket)`.
* iOS additionally needs the matching `NS*UsageDescription` key in `ios/Info.plist`. Without it, the dialog is silently suppressed and you get nothing — no event, no error.
* Android additionally needs the matching `uses-permission` line in `AndroidManifest.xml`. The `mob.new` template ships most of these already; if you added a feature after generating the project, double-check.

## The per-capability table

| `Mob.Permissions` cap   | iOS `Info.plist` key                                            | Android `uses-permission`                                                                | Notes |
|-------------------------|-----------------------------------------------------------------|-------------------------------------------------------------------------------------------|-------|
| `:camera`               | `NSCameraUsageDescription`                                       | `android.permission.CAMERA`                                                              | Registered by the `mob_camera` plugin (see below). Required by `MobCamera`. `CameraPreview` *also* needs the plist key but does not call `Mob.Permissions.request/2` — request explicitly before mounting it. |
| `:microphone`           | `NSMicrophoneUsageDescription`                                   | `android.permission.RECORD_AUDIO`                                                        | Required by `Mob.Audio.start_recording/2` and by `MobCamera.capture_video/2`. |
| `:photo_library`        | `NSPhotoLibraryUsageDescription`                                 | API 33+: `READ_MEDIA_IMAGES` + `READ_MEDIA_VIDEO`. API ≤32: `READ_EXTERNAL_STORAGE`.       | Required by `MobPhotos.pick/2` (`mob_photos` plugin). |
| `:location`             | `NSLocationWhenInUseUsageDescription`                            | `ACCESS_FINE_LOCATION` (high accuracy) and/or `ACCESS_COARSE_LOCATION` (low accuracy).    | See [iOS notes below](#ios-location-extras) — the dialog timing is unusual. |
| `:notifications`        | (none — handled by `UNUserNotificationCenter`)                   | API 33+: `android.permission.POST_NOTIFICATIONS`                                          | iOS shows the dialog the first time `request/2` runs. Android API ≤32 doesn't need a permission at all (notifications are user-controllable in Settings). |

The permission registry is **extensible**: plugins can register the
capabilities they own. As of 0.7.0, `:camera` is registered by the
`mob_camera` plugin — activate it (`{:mob_camera, "~> 0.1"}` in deps +
`config :mob, :plugins, [:mob_camera]` in `mob.exs`) before requesting
`:camera`. The other rows above (`:microphone`, `:photo_library`,
`:location`, `:notifications`) are registered by core. The
`Mob.Permissions.request/2` API itself is unchanged regardless of who
registered the capability.

Capabilities that need **no runtime permission** on either platform and
do not appear in the table:

* `Mob.Haptic`, `Mob.Clipboard`, `Mob.Share`, `Mob.Files.pick/2`,
  `Mob.Toast`, `Mob.Alert`, `Mob.WebView`, `Mob.Motion`, `MobBiometric`
  (ships in the `mob_biometric` plugin; uses biometric prompt UI but does
  not require a permission grant),
  `Mob.Storage` (app-local paths only).

Capabilities that need an `Info.plist` or manifest entry **without** going
through `Mob.Permissions.request/2`:

| Operation                                                         | iOS `Info.plist` key            | Android |
|-------------------------------------------------------------------|---------------------------------|---------|
| `Mob.Storage.Apple.save_to_photo_library/2`                             | `NSPhotoLibraryAddUsageDescription` | Same `READ_MEDIA_*` family as `:photo_library` on API 33+. |
| `Mob.Audio.play/2` (no permission)                                | none                            | none    |
| `MobCamera.start_preview/2` (no permission for the *preview*; capture still needs `:camera`) | `NSCameraUsageDescription` | `CAMERA` |

## What the `mob.new` template ships by default

If you generate a fresh project with `mix mob.new`, the template emits:

* **`ios/Info.plist`** — `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`. Nothing else.
* **`android/app/src/main/AndroidManifest.xml`** — `CAMERA`, `RECORD_AUDIO`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_EXTERNAL_STORAGE` (API ≤32 only), `POST_NOTIFICATIONS`, `VIBRATE`, `FOREGROUND_SERVICE`, `INTERNET`, `RECEIVE_BOOT_COMPLETED`.

So out-of-the-box your project covers camera + microphone on both
platforms, plus everything Android needs for the other capabilities.
**Anything iOS-side beyond camera + mic needs you to add the
`Info.plist` key yourself** before the first time you call that
capability. The most common ones to add:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>MyApp shows your location to ...</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>MyApp lets you pick photos from your library.</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>MyApp saves captures to your photo library.</string>
```

If you ship without the key, iOS won't even log the missing-key error
in any obvious place — the dialog just silently doesn't appear, and
the underlying `request*Authorization` call no-ops. Symptom looks
identical to "the user denied permission" except no `denied` event
ever arrives.

## iOS-specific notes

### iOS location extras

Apple's `CLLocationManager` couples permission and updates more
tightly than the other capabilities. Mob exposes both paths:

1. `Mob.Permissions.request(socket, :location)` calls
   `requestWhenInUseAuthorization` on a dedicated `CLLocationManager`
   and reports the user's actual choice as `{:permission, :location,
   :granted | :denied}` once the dialog is dismissed (or immediately
   if the permission was previously decided).

2. `MobLocation.get_once/1` and `MobLocation.start/2` (`mob_location`
   plugin) *also*
   trigger the dialog if `request/2` wasn't called yet. The dialog
   is one-shot per app install — subsequent calls short-circuit
   with the cached authorization.

3. If the user denies, two events flow:
   - `Mob.Permissions.request/2`'s caller hears `{:permission,
     :location, :denied}`.
   - `MobLocation.get_once/1`/`start/2`'s caller hears
     `{:location, :error, :permission_denied}` (via the
     `locationManagerDidChangeAuthorization:` callback). This means
     a screen that skipped `request/2` and went straight to
     `get_once` still has a way to break out of the "waiting for
     fix…" state.

4. The `Allow Once` button on iOS counts as `:granted` for the
   current run of the app. The next launch will prompt again.

5. Authorization can change mid-session — the user pops out to
   Settings and revokes. The delegate fires
   `{:location, :error, :permission_denied}` when that happens;
   surface it in your screen if you care about long-running tracking
   sessions.

### Camera + microphone

These go through `AVFoundation`'s `requestAccessForMediaType`, which
fires the dialog at `request/2` time. No additional gotchas — make
sure the plist key is present, the dialog appears, you get a typed
`{:permission, :camera | :microphone, ...}` event.

### Photo library

`PHPhotoLibrary.requestAuthorizationForAccessLevel:PHAccessLevelReadWrite`
is what `:photo_library` invokes. iOS treats
`PHAuthorizationStatusLimited` (the user picked "Selected Photos…")
as `:granted` from your screen's perspective — the rest of `MobPhotos`
deals with the limited-access set transparently.

### Notifications

Uses `UNUserNotificationCenter requestAuthorizationWithOptions:`. Asks
for alert, sound, and badge in one shot. The current implementation
returns `:granted` if the user granted any of the three.

## Android-specific notes

### Foreground vs background location

Mob only requests *foreground* location (`ACCESS_FINE_LOCATION` /
`ACCESS_COARSE_LOCATION`). If your app needs to keep tracking while
backgrounded, you need to additionally declare
`ACCESS_BACKGROUND_LOCATION` in the manifest and request it through
a custom flow — `Mob.Permissions.request/2` doesn't surface that
capability today.

### Notifications on Android ≤ 12

Pre-API-33, posting a notification does not require a runtime
permission grant — the user controls it via Settings. The
`{:permission, :notifications, :granted}` event will still fire from
`request/2` so your screen code stays portable.

### Storage and photos

API 33+ replaced the single `READ_EXTERNAL_STORAGE` permission with
per-media-type permissions (`READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`).
The `mob.new` template declares all of them so the photo picker works
across API levels. Saving with `Mob.Storage.Apple.save_to_photo_library/2`
uses `MediaStore`, which doesn't require a permission on API 29+ at
all — the manifest declarations are only for the read path.

## Re-requesting after denial

Calling `Mob.Permissions.request/2` again *after* the user denied
does **not** re-show the dialog on either platform — that's an OS
restriction. The event still arrives (with `:denied`), so your screen
can re-render an explanation. To actually re-prompt the user, they
have to go through system Settings:

* iOS: Settings → MyApp → \<capability\>
* Android: Settings → Apps → MyApp → Permissions → \<capability\>

A common UX is: on `:denied`, show a "Permission needed — open
Settings" CTA. `Mob.OpenUrl.open/2` with the appropriate scheme
(`"app-settings:"` on iOS, `Intent.ACTION_APPLICATION_DETAILS_SETTINGS`
on Android — surfaced via `Mob.System.open_app_settings/1` if your
project has it; otherwise call the manifest-permitted scheme directly)
will jump straight to the right settings page.

## Diagnosing a stuck request

Symptom: you called `Mob.Permissions.request/2` (or a capability
function), no dialog appears, no `:permission`/`:error` event ever
arrives.

Run through this in order:

1. **iOS plist key present?** Open `ios/Info.plist` (or the rendered
   bundle inside the `.app`) and confirm the `NS*UsageDescription`
   for the capability is there. The single most common cause.
2. **Android manifest entry present?** Open
   `android/app/src/main/AndroidManifest.xml`. If you added the
   feature post-`mob.new`, the entry may be missing.
3. **Already denied at the OS level?** iOS: Settings →
   MyApp → \<cap\>. Android: Settings → Apps → MyApp →
   Permissions. A previously-denied permission won't re-prompt;
   `request/2` still fires the `:denied` event, so check your
   `handle_info({:permission, :cap, :denied}, _)` clause exists.
4. **The screen process actually still alive?** If your screen
   crashed before `handle_info/2` ran, the message is lost. Check
   `adb logcat` or the iOS device console for a crash earlier in the
   pipeline.
5. **You're calling `request/2` from a non-screen process.**
   `enif_send` targets the calling pid; if a Task or `spawn` ran the
   request, its inbox is where the event went. Always request from
   the screen GenServer.

## Cross-platform pattern

```elixir
def mount(_params, _session, socket) do
  # Cheap and idempotent on both platforms. Safe to call even if
  # you're not yet ready to use the capability — the response
  # informs whether the action button below should be enabled.
  socket = Mob.Permissions.request(socket, :location)
  {:ok, Mob.Socket.assign(socket, permission: :pending)}
end

def handle_info({:permission, :location, :granted}, socket) do
  {:noreply, Mob.Socket.assign(socket, permission: :granted)}
end

def handle_info({:permission, :location, :denied}, socket) do
  # Render a "needs permission — open Settings" CTA.
  {:noreply, Mob.Socket.assign(socket, permission: :denied)}
end
```
