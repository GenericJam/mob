# Why the BEAM?

## Your app is a distributed system whether you like it or not

A mobile app talks to a server, handles push notifications while in the
background, manages local state, streams data, processes user input — all
concurrently, all the time. Most frameworks pretend this isn't true and make you
assemble it from callbacks, promises, state machines, and background workers.
You spend more time wiring concurrency plumbing than building your app.

The BEAM was designed in 1986 for telephone exchanges — systems that handle
millions of concurrent connections, never go down, and update themselves while
running. It didn't get these properties by accident. They are the entire point.
When you run the BEAM on a phone, you get all of it.

## What that actually means

**Concurrency that doesn't hurt.** Every screen is a `GenServer`. Every
background task is a supervised process. You don't choose between async/await
patterns and state machines — you just write functions that send messages.
Ten thousand concurrent processes on a phone costs less than one thread in most
runtimes.

**Fault isolation by default.** A crash in one screen cannot corrupt another.
The supervisor restarts it. You don't write defensive code everywhere — you let
things crash and write recovery logic once, at the top of the tree.

**Hot code loading.** Push new BEAM files to a running app and the code changes
in place — no restart, no lost state, no user impact. This works in development
(see `mix mob.deploy`) and it works in production via OTA update. No App Store
review required for Elixir changes.

**Distribution is a first-class primitive.** This is the one that changes what
apps are possible.

## Mob.Cluster: phones as nodes

In the BEAM, every running instance is a *node*. Nodes connect to each other
over Erlang distribution and immediately share the full OTP primitive set:
remote procedure calls, message passing to a pid on another machine, distributed
process registries, global GenServers.

Two Mob apps that share a cookie become a cluster:

```elixir
Mob.Cluster.join(:"their_app@192.168.1.42", cookie: :session_token)

# Now this works, across devices, over WiFi, with no server:
:rpc.call(:"their_app@192.168.1.42", TheirApp.GameServer, :move, [:left])
GenServer.call({MyServer, :"their_app@192.168.1.42"}, :get_state)
```

This is not a protocol you built. It is not a WebSocket layer. It is Erlang
distribution — the same thing that has been running telecoms switches, trading
systems, and WhatsApp's backend (two million connections per server, in 2012,
on hardware that would embarrass a modern phone) for decades.

The implications for mobile:

- **Multiplayer without a server.** Two phones, local network, no backend. Real
  state synchronisation, not eventual consistency hacks.
- **Handoff.** Start something on one device, continue on another. The state
  is already there — it's just a pid on a different node.
- **Collaborative apps.** Shared documents, live cursors, multi-user canvases —
  built with the same primitives you use for everything else, not a specialised
  CRDT library bolted on.
- **Device as a node in your backend cluster.** The phone is not a client
  polling an API. It is a peer in your OTP supervision tree. Your server can
  call functions on the device as easily as the device calls functions on the
  server.

## The update story

Most apps treat an update as a full binary replacement — compile, submit, review,
release, hope users install it. Because the BEAM separates code from state, you
can push new modules to a running app and they take effect immediately. The
running processes pick up the new code on their next function call. No restart.
No lost session. No App Store wait for Elixir changes.

Combined with on-demand distribution (start a cluster connection, receive new
BEAMs, disconnect), OTA updates become a first-class feature rather than a
platform workaround.

## Battery consumption

The BEAM has a reputation for being hard on mobile batteries. The numbers below
are measured on real hardware. All runs use the same conditions within each
mode so the results are directly comparable.

### iOS (physical iPhone, screen on)

| Mode | Start | End (30 min) | Drain | Rate |
|------|-------|--------------|-------|------|
| Default (Nerves tuning) | 100% | 99% | 1% | ~2%/hr |
| Untuned BEAM | — | — | — | — |

_Untuned run pending. Table will be updated._

**How to read this:** the BEAM with Nerves tuning costs ~2%/hr on a physical
iPhone with the screen on at minimum brightness — most of which is the screen
itself. The untuned row will show how much worse it gets without scheduler
tuning, which is what gives the BEAM its battery reputation.

### iOS (physical iPhone, screen off, background)

Measured on a physical iPhone with the screen off the entire run, BEAM kept
alive via Mob's iOS background-audio keep-alive. Battery read every ~10 s via
`mob_nif:battery_level/0`; precise final reading via `ideviceinfo` (USB
connected briefly at end). 180/180 probe samples succeeded, zero reconnects.

| Run | Start | End (30 min, gauge) | End (30 min, precise) | Rate |
|-----|-------|---------------------|------------------------|------|
| Default (Nerves tuning) — run 1 | 100% | 100% | 100% | ~0%/hr |
| Default (Nerves tuning) — run 2 | 100% | 100% | 99%  | ≤2%/hr |

Two independent 30-minute screen-off runs both came in at or below the gauge's
5% precision floor. The precise `ideviceinfo BatteryCurrentCapacity` reads were
100% on the first run and 99% on the second — the upper bound is therefore
about 2%/hr, but both runs are consistent with essentially zero overhead beyond
what the OS itself draws while the screen is off. With Nerves tuning keeping
the schedulers parked, running the BEAM for half an hour costs at most one
percentage point of battery.

### Android (screen off, background)

Measured on two Motorola phones with the screen off the entire run, BEAM kept
alive via Mob's Android foreground service. Battery read every ~10 s by
`adb shell dumpsys battery` (1% resolution + raw mAh).

| Device | ABI | Start | End | Drain | Rate |
|--------|-----|-------|-----|-------|------|
| Moto E | armeabi-v7a (32-bit) | 2834 mAh (98%) | 2805 mAh (96%) | 29 mAh / 2% (31 min) | ~56 mAh/hr (~3.9 %/hr) |
| Moto G | arm64-v8a (64-bit)   | 4726 mAh (94%) | 4652 mAh (93%) | 74 mAh / 1% (31 min) | ~143 mAh/hr |
| No BEAM (native baseline, Moto G) | arm64-v8a | — | — | — | ~200 mAh/hr |

Both BEAM runs sit between the no-BEAM baseline and zero — confirming the BEAM
isn't sitting on its hands burning power. Cross-device comparisons are imperfect
(different SoCs, battery sizes, and OS revisions), but the order of magnitude is
the point: with Nerves-tuned schedulers, the screen-off BEAM is well below
native idle, not above it.

The 32-bit Moto E run is the first end-to-end validation of `armeabi-v7a` on
real hardware: the BEAM completed startup, ran continuously through screen-off
for 31 minutes, and remained reachable over Erlang distribution the whole time.

**Methodology:** `mix mob.battery_bench_ios` builds and installs the app, connects to
the device BEAM over WiFi, reads battery every 10 seconds via `mob_nif:battery_level/0`,
and reports drain and rate. The 30-minute duration is the default; longer runs give
better rate estimates. Battery is read via `ideviceinfo` at start and end (USB
connected briefly for reads only) for 1% precision. The screen-on row was measured
at minimum brightness with the screen forced on; the screen-off row uses
`Mob.Background` audio keep-alive so the BEAM keeps running after the device
locks. Android uses `mix mob.battery_bench_android` with `adb shell dumpsys
battery` for per-second mAh readings.

**Resolution note:** `UIDevice.batteryLevel` reports in 5% increments on real
hardware (an iOS privacy measure). The actual drain may be finer; when USB is
connected `ideviceinfo BatteryCurrentCapacity` gives 1% resolution and is the
authoritative reading.

## The honest trade-off

The BEAM is not free. You are writing Elixir, not JavaScript or Swift. The
ecosystem is smaller. Some things that are trivial in React Native — a particular 
animation library, a specific native SDK wrapper — require more work. But the things that 
are impossible on React Native are possible now.

What you are buying is a runtime that was engineered for exactly the problem
mobile apps have: high concurrency, fault tolerance, live updates, distributed
state. You are not adapting a web runtime or a game engine to the mobile
problem. You are using a tool that was built for it, forty years before the
iPhone existed.

If your app is a thin wrapper around an API with a few screens, the trade-off
probably isn't worth it. If your app has meaningful real-time behaviour, local
state that matters, multi-user interaction, or a need to update without
resubmitting to an app store — the BEAM earns its place.
