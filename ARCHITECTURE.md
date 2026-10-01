# Mob — Architecture

## Deploy model

### Initial deploy (`mix mob.deploy --native`)

Requires USB. Does a full push:
- Compiles native code (APK for Android, iOS app bundle)
- Installs the app on the device via adb / xcrun
- Copies the compiled BEAMs to the device
- Starts the BEAM runtime

USB is only required for this step. Once the base app is installed and the
BEAM is running, all subsequent updates go through Erlang distribution.

### Subsequent deploys (`mix mob.deploy`)

No USB required (unless the device isn't already connected via dist). Does a
lightweight push:
- Compiles BEAMs
- Saves them to the mob_dev server
- mob_dev distributes the updated modules to connected devices via Erlang
  distribution (`:rpc.call` / `nl/1`)

If no device is connected via dist yet, fall back to USB push (same as
`--native` minus the native build step).

## Erlang distribution

Distribution is the backbone of the development loop. Once the base app is
installed, the BEAM node on the device connects to (or accepts a connection
from) the Mac's node and stays connected. All code updates, log streaming,
and remote inspection go through this channel.

Node naming convention:
- Android: `mob_demo_android@127.0.0.1` (USB tunnel via `adb forward`)
- iOS simulator: `mob_demo_ios@127.0.0.1` (simulator shares Mac network stack)
- iOS physical: device's USB, WiFi, or Tailscale IP
- Android wireless: device's LAN IP (future)

Cookie: a private 256-bit cookie per app, generated and kept by `mob_dev`
under `~/.mob/dist_cookies/`. Android reads it from the app's private storage,
where `mix mob.deploy` / `mix mob.connect` write it; iOS receives it in the
launch environment. Distribution is excluded from iOS release builds.

Listeners: Android and the iOS simulator bind distribution to loopback only
(the Mac reaches Android through `adb forward`). A physical iPhone's EPMD and
dist port still listen on every interface, since the Mac reaches it over
USB, WiFi or Tailscale; the private cookie is what protects it.

## Connection lifecycle

```
USB (once)
  └─ mix mob.deploy --native   → installs APK/IPA + BEAMs, starts BEAM
  └─ mix mob.connect           → sets up port forward, joins Erlang cluster

WiFi / dist (ongoing)
  └─ mix mob.deploy            → compile + push BEAMs via dist
  └─ mix mob.watch             → auto-push on file save via dist
  └─ mob_dev dashboard         → live logs, deploy buttons, device status
```

## mob_dev server role

The mob_dev server (`mix mob.server`) is the Mac-side hub:
- Discovers connected devices (adb + xcrun simctl)
- Streams logs from all connected devices
- Holds the latest compiled BEAMs and distributes them to devices via dist
- Provides a dashboard UI for deploy, log filtering, and device status

It is intentionally a dev-only tool — not shipped with the app, not running
on the device.
