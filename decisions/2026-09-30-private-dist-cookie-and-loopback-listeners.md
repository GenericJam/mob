# Development distribution: a private cookie per app, loopback listeners where possible

- Date: 2026-09-30
- Status: accepted
- Issue: MOB-49. Tooling side: `mob_dev/decisions/2026-09-30-private-dist-cookie-for-every-platform.md`

## Context

Every development build was an Erlang node protected by `mob_secret`, a cookie
published in this repository and embedded in every generated app. Anyone who
could reach the dist port could authenticate and run arbitrary code in the app
(`:os.cmd/1` included):

- **Physical iPhone**: the in-process EPMD and the dist port listen on every
  interface, and the node is named at its WiFi/Tailscale address.
- **iOS simulator**: shares the Mac's network stack, so its dist port listened
  on the Mac's WiFi address too.
- **Android**: `Mob.Dist` started distribution with OTP's default listener,
  which binds every interface, so the phone's WiFi address reached it. Other
  apps on the phone could also reach it on loopback. Confirmed on 2026-09-30:
  `elixir --cookie mob_secret` connected to an Android app's node.

## Decision

1. **Cookie.** mob_dev keeps one random 256-bit cookie per app on the Mac and
   hands it to the app at deploy/connect time. iOS reads `MOB_DIST_COOKIE` from
   the launch environment before `erl_start`; a launch without it (Xcode, home
   screen) generates an unlogged random cookie. (Amended by MOB-348: iOS now
   falls back to `$MOB_BEAMS_DIR/mob_dist_cookie` before the random cookie; see
   `2026-10-01-ios-dist-cookie-file.md`.) Android's `Mob.Dist` reads
   `$MOB_BEAMS_DIR/mob_dist_cookie` from the app's private storage. A custom
   `:cookie` passed to `Mob.Dist.ensure_started/1` still wins (the OTA example
   in its docs), but `:mob_secret` is treated as no cookie, since every
   generated app passes it; without a managed cookie the node gets a random one.
2. **Listeners.** Android binds distribution to `127.0.0.1`
   (`inet_dist_use_interface`): `adb forward`, the only path the Mac uses,
   connects to the device's loopback. The iOS simulator does the same, since it
   is named `@127.0.0.1` and reached through the Mac's own loopback.
3. **Physical iPhone keeps listening on every interface.** The Mac reaches it
   over USB link-local, WiFi or Tailscale, chosen at launch, and there is no
   tunnel to hide it behind. Restricting it means picking an interface or
   adding a tunnel (iproxy), which is a product decision about which
   connection modes stay supported, so it is split into MOB-323; the private
   cookie is what protects it until then.

## Consequences

- The generated `cookie: :mob_secret` argument is now inert. mob_new's
  templates keep passing it until their mob floor includes this change
  (MOB-324), so a project generated today still runs against an older mob,
  where `:cookie` is required.
- An app built against this mob needs a mob_dev that writes the cookie;
  with an older mob_dev the node gets a random cookie and cannot be attached.
- An app built against an older mob still uses `mob_secret`. mob_dev falls back
  to it, with a warning, until the app is redeployed (`--native` for iOS).
- Other apps on an Android phone can still connect to the loopback listener;
  without the cookie the handshake fails.
