# A phone runs one mob app with distribution at a time

- Date: 2026-11-27
- Status: accepted
- Tickets: MOB-371

## Context

Two agents drove two mob apps (MishkaIosDemo and WebrtcSpike) on the same
iPhone. Each `mix mob.connect` stopped the other agent's app, which looked like
a crash with no report, and a launch while the other app ran stopped on "port
9101 (default) is already in use". MOB-371 proposed giving each app its own
dist port (walk forward from 9101, as simulators do since MOB-139), and the
first idea for the EPMD on 4369 was to let a second app register with the
first app's EPMD instead of starting its own.

Neither holds up on iOS:

- **OTP's EPMD exits the process when 4369 is taken.** `epmd_srv.c` `run()`
  handles `EADDRINUSE` with `epmd_cleanup_exit(g, 0)`, which calls `exit(0)`.
  In-process on iOS, that quits the whole app: no crash report, no startup
  error. A second app on its own dist port would get past the port check and
  then vanish here.
- **A background app's EPMD is frozen.** Measured on an iPhone 13: WebrtcSpike
  in the foreground answered an EPMD NAMES request in 47 ms. After Safari came
  forward, the port still accepted connections but no reply came after 2, 15
  or 30 s (8 s receive timeout each). iOS suspends the app, EPMD thread
  included. `erl_epmd` waits 10 s for a registration reply, so a second app
  registering there would fail to start distribution and the BEAM would stop.

So the only mob app reachable on a phone is the one in the foreground that owns
4369. Ports don't change that.

## Decision

- **Physical devices keep dist port 9101.** With one app running distribution
  per phone, a fixed port is enough; walking forward would only move the
  failure to the silent `exit(0)`.
- **A launch that finds 4369 held stops on the startup error screen**, before
  the dist port check, so the message names the actual cause (another mob
  app's EPMD) instead of port 9101. It goes to
  `Documents/mob_diag_dist_port.txt` as well. "Held" is a probe bind on
  `INADDR_ANY:4369`, where the in-process EPMD listens (`mob_epmd_held` in
  `ios/mob_dist_port.h`, host-tested).
- **An app that owns distribution** (`-name`/`-sname` in its init args) is not
  stopped, but mob doesn't start its EPMD when 4369 is held, because that
  would quit the app. It keeps distribution only if it brings its own EPMD
  setup (`-start_epmd false`, `-epmd_module`).
- **mob_dev passes an explicit `--dist-port` to a physical iPhone**
  (`DEVICECTL_CHILD_MOB_DIST_PORT`), as it already did for simulators and
  Android. It keeps stopping the other mob apps it installed before a launch
  (`mob_dev` `decisions/2026-09-06-mob-dev-kills-only-what-it-installed.md`),
  since that is what makes the launched app reachable, and now prints which
  apps it stopped.

## Consequences

- Agents sharing one iPhone take turns: each launch through mob_dev stops the
  other agent's app, and says so in the launching agent's output. A per-device
  lease in mob_dev, which would refuse instead of stopping another agent's app,
  was considered and not done here.
- Two apps launched together can still both start an EPMD, and the second
  exits: the window runs from the probe to the EPMD thread's bind, across the
  node-host lookup, code-version selection and log redirect in between. The
  real fix for that is an OTP patch that makes EPMD return instead of
  `exit`ing; not worth a runtime rebuild for a window that narrow.
- iPad Split View can show two apps in the foreground at once. The second mob
  app still stops on the error screen.
- `decisions/2026-10-01-ios-sim-dist-port-per-app.md` keeps "Physical devices
  keep 9101"; this record supplies the reason it gave only implicitly (one
  app per device).
