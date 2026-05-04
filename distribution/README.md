# Distribution and peer-to-peer in Mob apps

Working notes on how Mob apps will eventually talk to each other.
The chosen direction is **every app runs both an HTTP server and a
client** — no Erlang distribution between user devices, no central
server required for the actual data transfer. Bluetooth is an opt-in
augmentation for cases where there's no shared network at all.

> **Status:** design only. Nothing here is shipped. SquareTriangle
> is the toy example currently exercising the server-mediated path
> (`square_triangle_hub` Phoenix backend) so we can find UX edges
> without solving networking simultaneously.

---

## Why not Erlang distribution

Erlang distribution is **ambient authority**: once two nodes connect
via a shared cookie, either side can `:rpc.call` arbitrary
modules/functions on the other. There's no built-in way to partition
"this peer can see my cut list but nothing else" — you'd be
hand-rolling a guard around every callable module, fighting the
default rather than building on it.

Distribution also requires reliable network connectivity and a known
node name. On a job site with bad cell signal — the actual target
use case for apps like SquareTriangle — neither holds.

We keep Erlang distribution for the **dev loop** (`mix mob.connect`
attaches a laptop IEx to a phone-running BEAM). That's the right tool
for that job. It's not the right tool for **user-to-user**
communication.

---

## Why "every app is a server and a client"

The Plex / Syncthing / AirDrop / Briar pattern. Each Mob app runs a
small HTTP server bound to all interfaces. Peer apps discover each
other via mDNS on the LAN, then talk over plain HTTP. A few good
properties fall out:

- **Cross-platform.** HTTP works iOS↔Android, Android↔Android,
  iOS↔iOS without picking a bespoke transport.
- **Network-mode-agnostic.** Same code path works on cell, on a
  job-site Wi-Fi, on one phone hotspotting the other.
- **Capability-shaped by default.** Each request carries a token
  (the per-device bearer secret + invite-derived pairing). HTTP is
  built around routes-and-auth; capabilities map naturally.
- **Easy to test.** `curl` works. No need to embed a special test
  harness for the dist protocol.
- **Same protocol both ways.** The endpoints SquareTriangleHub
  exposes today are exactly the same shape an app needs to expose to
  receive cuts directly. Server and clients become symmetric.

The one thing this model **can't replace**: waking a backgrounded app
on a phone the user isn't currently looking at. APNs and FCM are the
only ways to do that. So even peer-to-peer apps need a tiny server
for the "ping the recipient" notification — but the actual data
transfer can be P2P, and with a foregrounded app, even the ping can
be done locally (BLE advertising, mDNS announce).

---

## Phased plan

### Phase 1 — server-mediated (current)

**Status:** in progress (`square_triangle_hub`). Pure Phoenix + Cloudflare
tunnel. Both clients talk to a central relay; relay handles auth,
inbox, push dispatch.

**Use:** prototype features, find UX edges, ship the v1 of any new
app without solving networking simultaneously.

**Limit:** requires both peers to have connectivity to the relay.
Doesn't work on a job site with no cell signal.

---

### Phase 2 — peer-to-peer over local network

**The big one.** Each Mob app runs its own Bandit-backed HTTP server.
Mob ships:

- `Mob.Server` — small wrapper around Bandit + a Plug pipeline. Apps
  declare their endpoints (the same shape Phoenix uses) and Mob
  handles port allocation, lifecycle, TLS-on-LAN (self-signed).
- `Mob.Discovery` — mDNS announce + browse. Apps register a service
  type (`_squaretriangle._tcp.local`) and Mob handles the
  announcement and the peer-resolution side.

The protocol stays the same as Phase 1 — same `/api/cuts`, same
bearer-token auth. Only the endpoint URL changes (peer's
mDNS-discovered IP:port instead of `square.boltbrain.ca`). The
Phase 1 backend doesn't go away — it becomes the fallback when the
peer isn't on the same LAN.

**Send-cut flow becomes:**

1. Try mDNS to find the paired device. If found, POST cut directly.
2. If no mDNS response within 2 seconds, POST cut to the
   `square_triangle_hub` relay as today. Relay queues for the recipient.
3. Optionally fire APNs/FCM via the relay either way (so the
   recipient's app foregrounds and can pull from local outbox).

**Shipping:** ~1–2 weeks of focused work. mDNS is an existing problem
domain (well-trodden libs); Bandit is already a dep.

---

### Phase 3 — Bluetooth Low Energy

For when there's **no** shared network. Two phones on the same job
site, no Wi-Fi router, no hotspot, no cell signal worth using.

**Use cases:**

- Presence: "is anyone I'm paired with within range?"
- Tiny-payload sync: cut list IDs, pairing handshake.
- Pairing-via-tap-phones-together: no QR or code, just hold the
  phones near each other for a moment.

**Not the high-bandwidth path.** BLE on iOS realistically gives you
~10 kbps after Apple's connection-interval rules; it's not going to
deliver a 50KB cut list bundle. Use BLE for "wake up the other phone
and tell it where to fetch from" once shared Wi-Fi is back, OR for
genuinely tiny cut-list IDs that fit in a few BLE characteristic
writes.

**Why this is its own package (`mob_ble`?):**

- Native plumbing surface — Bluetooth permission strings, background
  modes, service UUIDs registered in the bundle. Invasive even when
  unused.
- iOS background BLE rules are restrictive (the system manages
  scanning windows; advertise-while-backgrounded works only with the
  right plist keys).
- Most Mob apps don't need this. Same opt-in argument as `mob_push`
  vs `mob` core.

**Shipping:** multi-month — wait for a real user request. Not on the
critical path.

---

## What changes in mob core for Phase 2

Just a sketch of the API surface, to be revised when actually building:

```elixir
# In an app's MyApp.App.on_start:

Mob.Server.start(
  port: :auto,                 # or fixed
  routes: MyApp.Endpoint,      # a Plug
  tls: :lan_self_signed        # generate a cert valid for the LAN
)

Mob.Discovery.announce(
  service: "_my_app._tcp.local",
  metadata: %{device_id: device_id}
)

# Sender side:

case Mob.Discovery.find_paired(peer_device_id) do
  {:ok, {host, port}} ->
    HTTPClient.post("https://#{host}:#{port}/api/cuts", payload, auth: token)

  :not_found ->
    HTTPClient.post("https://hub.example.com/api/cuts", payload, auth: token)
end
```

Two new modules in mob (`Mob.Server`, `Mob.Discovery`) and a small
HTTP client helper that wraps `req` with bearer-auth. Apps write
their endpoints exactly like a Phoenix app.

---

## On the C-NIF-as-distribution-node alternative

A C NIF that speaks the dist protocol but exposes only an explicit
capability surface (vs ambient distribution authority) is
architecturally clean — see the abandoned exploration earlier in the
session log. Skipped because:

- HTTP starts capability-shaped already (routes + tokens). The
  C-NIF approach reinvents capability semantics on top of an
  ambient-authority protocol.
- Multi-month implementation cost (NIF complexity, BLE/mDNS pieces
  still needed for transport, dist-protocol details).
- Doesn't actually solve the offline / no-network problem any
  better than the HTTP-over-mDNS approach.

Captured for completeness; not on the roadmap.

---

## Reading order for the rest of these notes

- [`transports.md`](transports.md) — cross-platform transport
  options table, why we chose Wi-Fi LAN + BLE.
- This README is the authoritative direction. If something here
  contradicts a future doc, fix the future doc.
