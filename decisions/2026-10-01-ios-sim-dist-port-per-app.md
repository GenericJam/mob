# iOS simulator apps pick a free dist port per app and simulator

- Date: 2026-10-01
- Status: accepted
- Tickets: MOB-139

## Context

`mob_beam.m` took the dist port from `MOB_DIST_PORT` and otherwise used 9101.
`mix mob.deploy` and `mix mob.connect` pass a per-app port, but every other
launch passes nothing: tapping the icon, `xcrun simctl launch`, agent-device
`open --relaunch` (and so `mix mob.smoke` flows that relaunch). Simulators
share the Mac's network stack, so the second mob simulator app launched that
way failed to listen on 9101 and the BEAM halted about a second after
"Starting BEAM…". The only trace was `Documents/beam_stdout.log`:
`Protocol 'inet_tcp': register/listen error: eaddrinuse`. No os_log line, no
crash report, no on-screen error. With several agents sharing one Mac's
simulators this happened routinely.

## Decision

- **Port resolution lives in `ios/mob_dist_port.h`**, header-only C with no
  Foundation, so `test/native/dist_port_test.c` compiles and runs the shipped
  code on the host against real loopback sockets.
- **`MOB_DIST_PORT` still pins the port.** It is what mob_dev passes, and an
  explicit port is a request, not a hint.
- **Simulator without `MOB_DIST_PORT`: mob_dev's derivation, then the first
  port that binds.** The base is `9100 + crc32("<app>@<SIMULATOR_UDID>") rem
  800`, the same as `MobDev.Tunnel.base_port/2`, and the walk covers the same
  800-port window as `MobDev.Tunnel.assign_dist_port/3`. "In use" means a
  probe `bind` on 127.0.0.1 with `SO_REUSEADDR` fails, which is what
  `inet_tcp_dist` listens with, so the probe fails exactly when the BEAM would.
  The BEAM gets `inet_dist_listen_min` = the chosen port and
  `inet_dist_listen_max` = the window end, so a port taken between the probe
  and the listen moves it on instead of halting it.
- **A port that is taken is reported, not handed to the BEAM.** A pinned port
  that won't bind, or a full window, logs `[MobBeam] ERROR: …` (naming the
  port, `lsof -nP -iTCP:<port> -sTCP:LISTEN` and `epmd -names`), writes
  `Documents/mob_diag_dist_port.txt`, shows the startup error screen, and does
  not start the BEAM. Starting it without distribution would leave a running
  app that no tool can reach, which reads as a different bug.
- **Physical devices keep 9101.** Each device has its own network stack and
  its own in-process EPMD; tools read the port from that EPMD. The busy check
  applies there too (an occupied 9101 is reported the same way).

## Why not port 0 (let the OS choose)

Tools find a simulator node through the Mac's EPMD, so any port would connect.
But mob_dev keeps its dist ports in 9100..9899 and its bookkeeping (stale
forward cleanup, the collision walk) assumes that window; an ephemeral port in
the 49152+ range would sit outside it and change from launch to launch. The
derived port is stable per app and simulator, and matches what mob_dev would
have chosen when nothing else holds it.

## Consequences

- A simulator app launched any way registers in EPMD on its own port and
  `mix mob.connect` finds it.
- The derivation is duplicated in C and Elixir (mob_dev). The native test pins
  the C side to `erlang:crc32/1` vectors; a change to mob_dev's window or key
  needs the same change here.
- Port resolution, the busy check and the error path are covered on the host;
  the log line, the error screen and the skipped `erl_start` were verified on a
  simulator, not by an automated test.
