# iOS reads the private dist cookie from the beams dir, like Android

- Date: 2026-10-01
- Status: accepted
- Tickets: MOB-348 (follow-up to MOB-49, `decisions/2026-09-30-private-dist-cookie-and-loopback-listeners.md`)

## Context

MOB-49 gave each app a private distribution cookie. Android's `Mob.Dist` reads
it from `$MOB_BEAMS_DIR/mob_dist_cookie`, which mob_dev writes on deploy, so
any later launch of the app keeps it. iOS read it only from `MOB_DIST_COOKIE`
in the launch environment, which mob_dev passes only when it launches the app
itself. Tapping the icon, `xcrun simctl launch`, agent-device `open
--relaunch` (so every relaunching `mix mob.smoke` flow) and an OS relaunch all
got a random cookie: the node registered in EPMD but nothing could connect.

## Decision

- **Same order as Android: env, then the file, then random.**
  `ios/mob_dist_cookie.h` (header-only C, used by `mob_beam.m`) takes
  `MOB_DIST_COOKIE` first, then `<beams_dir>/mob_dist_cookie`, then an unlogged
  random cookie for this launch. `MOB_DIST_COOKIE=mob_secret`, the public
  pre-MOB-49 cookie, is ignored, as Android's `Mob.Dist` ignores it, so no
  shared public cookie is ever used.
- **Only mob_dev's format is accepted from the file:** 64 lowercase hex
  characters, optionally followed by whitespace. Anything else (an empty file,
  `mob_secret`, a truncated write) falls through to the random cookie, as
  Android's `valid_cookie?/1` does.
- **mob_dev writes the file on every filesystem deploy to iOS**
  (`MobDev.DistCookie.write_app_file!/2`), the same deploys that put BEAMs on
  disk:
  - Simulator: every deploy, into the runtime beams dir on the Mac. Written
    after the BEAM sync, since a `--native` build's runtime rsync (`--delete`)
    removes it.
  - Physical iPhone: into the staging dir copied to `Documents/otp/<app>/`,
    which `mob_beam.m` prefers over the bundle once it exists. That is
    `--native` and any deploy to a device that isn't connected over dist; a
    connected device is only hot-loaded (mob_dev's `persistable?/1`: a
    devicectl replace has no undo) and gets no file. Since reading the file
    needs this `mob_beam.m`, which only a `--native` build installs, every
    device that can read it has been given it, unless it was built some other
    way (Xcode).
  The cookie is written inside a fresh `0700` directory, made `0600`, then
  renamed into place, so no other user can open it at any point.
- **`mob_beam.m` logs the source, never the value:** `[MobBeam] dist cookie:
  MOB_DIST_COOKIE`, `… <path>`, or `… random for this launch …; mob_dev can't
  connect — run mix mob.deploy`. The last line is what makes an unreachable
  node diagnosable from the system log.

## Consequences

- An iOS app deployed by mob_dev stays reachable when relaunched outside it,
  with the same cookie `mix mob.connect` uses, as long as the launch finds the
  BEAMs it was deployed with. A simulator launch without `MOB_SIM_RUNTIME_DIR`
  only looks in `~/.mob/runtime/ios-sim` (then `/tmp/otp-ios-sim`), so a
  project deployed to a custom `MOB_SIM_RUNTIME_DIR` can't be relaunched that
  way at all, cookie or not; that was already true and is unchanged here.
- An app built against this mob but deployed by an older mob_dev has no file
  and keeps today's behaviour (random unless launched by mob_dev).
- On the simulator the cookie sits in a second file under `~/.mob/`, readable
  only by the Mac user, who can already read `~/.mob/dist_cookies/`. On a
  physical iPhone it is in the app's own container, and so in device backups,
  as Android's copy is in the app's private storage. Development builds only:
  `MOB_RELEASE` builds start no distribution and read no cookie.
- The cookie's lookup, precedence and validation are covered on the host
  (`test/native/dist_cookie_test.c`). The deploy writing the file and a
  relaunch without `MOB_DIST_COOKIE` connecting were verified on a simulator
  and on a physical iPhone SE.
