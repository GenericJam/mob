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
  random cookie for this launch. No shared public cookie is ever used.
- **Only mob_dev's format is accepted from the file:** 64 lowercase hex
  characters, optionally followed by whitespace. Anything else (an empty file,
  `mob_secret`, a truncated write) falls through to the random cookie, as
  Android's `valid_cookie?/1` does.
- **mob_dev writes the file on every iOS deploy** (`MobDev.DistCookie.write_app_file!/2`):
  - Simulator: into the runtime beams dir on the Mac
    (`~/.mob/runtime/ios-sim/<app>/`), which is the `beams_dir` `mob_beam.m`
    resolves. Written after the BEAM sync, since a `--native` build's runtime
    rsync (`--delete`) removes it.
  - Physical iPhone: into the staging dir copied to `Documents/otp/<app>/`,
    which `mob_beam.m` prefers over the bundle once it exists.
  The file is created `0600` before the cookie is written, then renamed into
  place.
- **`mob_beam.m` logs the source, never the value:** `[MobBeam] dist cookie:
  MOB_DIST_COOKIE`, `… <path>`, or `… random for this launch …; mob_dev can't
  connect — run mix mob.deploy`. The last line is what makes an unreachable
  node diagnosable from the system log.

## Consequences

- An iOS app deployed by mob_dev stays reachable however it is relaunched,
  with the same cookie `mix mob.connect` uses.
- An app built against this mob but deployed by an older mob_dev has no file
  and keeps today's behaviour (random unless launched by mob_dev).
- On the simulator the cookie sits in a second file under `~/.mob/`, readable
  only by the Mac user, who can already read `~/.mob/dist_cookies/`. On a
  physical iPhone it is in the app's own container, and so in device backups,
  as Android's copy is in the app's private storage. Development builds only:
  `MOB_RELEASE` builds start no distribution and read no cookie.
- The cookie's lookup, precedence and validation are covered on the host
  (`test/native/dist_cookie_test.c`); the deploy writing the file and the node
  accepting it were verified on a simulator.
