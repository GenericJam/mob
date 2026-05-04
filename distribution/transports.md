# Phone-to-phone transport options

Reference table for the candidate transports between two Mob apps,
with the cross-platform reality of each. Companion to the chosen
direction in [`README.md`](README.md).

## The landscape

| Transport | iOS | Android | Throughput | Range | Cross-platform? | Verdict |
|---|---|---|---|---|---|---|
| Local Wi-Fi LAN (mDNS + HTTP) | ✓ | ✓ | High (Mb/s) | LAN scope | ✓ | **Phase 2 path** |
| Bluetooth Low Energy (BLE) | ✓ | ✓ | ~10 kbps practical | ~10 m | ✓ | **Phase 3 augment** |
| Wi-Fi Direct | ✗ | ✓ | High | ~50 m | ✗ | Skip |
| Wi-Fi Aware (NAN) | ✗ | newer | High | ~50 m | ✗ | Skip |
| Multipeer Connectivity | ✓ | ✗ | High | ~50 m | ✗ (iOS↔iOS) | Skip |
| AWDL | ✓ | ✗ | High | ~30 m | ✗ | Skip |
| Bluetooth Classic | iOS-MFi-only | ✓ | Mid | ~10 m | ✗ | Skip |

Cross-platform reality: **Wi-Fi LAN or BLE**. Everything else is
single-platform or requires Apple-specific licensing.

---

## Wi-Fi LAN (Phase 2)

The high-bandwidth, primary path. Both phones on the same network
(home Wi-Fi, job-site router, even one phone hotspotting the other).

**Discovery: mDNS (Bonjour / DNS-SD).**

- Advertise: `_my_app._tcp.local` with TXT records for `device_id`,
  `version`, optionally `pair_code` for in-progress pairing.
- Browse: ask for the same service type, get back a list of
  reachable peers with their IPs and ports.
- iOS: `NWBrowser` / `NetService` (NetService is deprecated but
  still works). Android: `NsdManager`.
- Both have BEAM-callable surface via NIFs; existing Erlang mDNS
  libs (e.g. `mdns_lite`) work but require care around the
  per-platform sandbox rules.

**Transport: HTTP/HTTPS.**

- Bandit binds to a free local port. The mDNS announce includes the
  port. Peer connects via `https://<peer-ip>:<port>/...`.
- TLS: self-signed cert tied to the device's stable identity (the
  bearer secret can be its CN). Both ends pin via mDNS — they only
  trust certs signed for the device_id they expected to pair with.
  Without this, anyone on the LAN could MITM.
- HTTP keep-alive within a session, but expect short-lived
  connections (peers wake up + send + sleep).

**Auth: bearer token from the pairing flow.**

- Same secret-per-device model the Phoenix backend already uses.
- Tokens are issued during pairing (out-of-band: QR, 6-char code).
  After that, the peer presents the token in `Authorization: Bearer`.
- Server side checks the token + verifies the request is coming from
  a paired device's IP.

**NAT traversal: not needed on LAN.** Both peers are on the same
broadcast domain. NAT only matters across the internet, where Phase
1 (relay-mediated) covers it.

**Sharp edges:**

- iOS Local Network permission (added iOS 14) — requires a plist key
  and the app must prompt the user the first time it tries mDNS.
  Skip the prompt and the OS silently returns no results.
- Android API levels < 26 have spotty mDNS support. Probably fine
  given mob_dev's API 26+ minimum, but worth checking.
- Hotspot weirdness: when one phone hotspots the other, the hotspot
  acts as the gateway and mDNS broadcasts may or may not flow
  depending on the carrier-OS combination. Test before assuming.
- Client cert pinning is non-trivial in HTTP libraries — mob would
  need to bundle this primitive so apps don't have to roll their own.

---

## Bluetooth Low Energy (Phase 3)

The "no shared network at all" path. Slow but always-available
between any two BLE-capable phones in proximity.

**Discovery: BLE advertising.**

- Each Mob app advertises a service UUID (mob-specific) with manufacturer
  data carrying device_id + a "I have outbox items" flag.
- Peers scanning for the same UUID get a list of nearby Mob devices.
- iOS: `CoreBluetooth` (`CBPeripheralManager` for advertising,
  `CBCentralManager` for scanning). Android:
  `BluetoothLeAdvertiser` + `BluetoothLeScanner`.

**Transport: GATT characteristics.**

- Mob defines a small GATT service with a few characteristics:
  - `inbox_count` (read): how many items the peer is offering me
  - `request_item` (write): I'm asking for item N
  - `data_chunk` (notify): server pushes a chunk of the requested item
- Reassemble chunks on the client side into the full payload.
- Practical throughput once you account for connection intervals and
  ATT MTU is ~10 kbps. A 5KB cut list takes a few seconds. A 50KB
  blob takes a minute.

**Auth: piggy-back on the same bearer-token model.**

- BLE itself has authentication primitives (LE Secure Connections),
  but they're tied to the OS's pairing UI and don't cleanly map to
  app-level identities.
- Easier path: app-level handshake on top of GATT. Peer asks for a
  challenge, signs it with the bearer token's HMAC, server verifies.
  Only after auth does the inbox become readable.

**Sharp edges:**

- iOS background BLE has strict rules. Advertising in the background
  works only with `bluetooth-peripheral` background mode + a
  reduced advertising payload. Scanning in the background works but
  with longer windows.
- Service UUIDs in iOS background mode get put into a system-managed
  scan list — the OS coalesces scans across apps to save battery.
  Latency is higher.
- iOS doesn't expose BLE addresses to apps for privacy; you can only
  identify peers by service UUID + manufacturer data. So the Mob
  app-level "who is this peer" identity has to be carried in the
  manufacturer data (or in the GATT handshake post-connection).
- Android needs `BLUETOOTH_ADVERTISE` + `BLUETOOTH_CONNECT` +
  `BLUETOOTH_SCAN` runtime permissions on API 31+.
- Multi-platform interop (iOS app talks to Android app) needs the
  service UUID and characteristic UUIDs to match exactly. Easy to
  get wrong because the iOS framework normalizes UUIDs to
  uppercase.

**Pairing without a code (the future-cool feature):**

Two phones held near each other can detect each other via BLE
proximity (RSSI-based). One taps "pair via tap." Both broadcast a
short-lived pair-token. The OS-side BLE pairing handshake confirms
the proximity is real (anti-relay). Mob then bootstraps the
bearer-token exchange over the new GATT connection. No QR, no typed
code — just hold the phones together.

This is the killer Phase 3 feature for framers swapping cuts on a
job site. Worth the implementation cost because the alternative
(fish a phone out of a tool belt, pull up a code, type it on a
gloved hand) is awful UX.

---

## Why we ruled out the rest

**Wi-Fi Direct, Wi-Fi Aware (NAN):** Android-only. iOS doesn't
expose them.

**Multipeer Connectivity:** iOS-only. Doesn't help iOS↔Android.

**AWDL:** iOS-only, Apple-internal protocol AirDrop uses. Not
exposed to third-party apps cleanly.

**Bluetooth Classic:** iOS only allows third-party apps to talk to
MFi-licensed accessories over Bluetooth Classic. Not viable for
phone-to-phone.

**Custom IP-multicast on LAN:** could work but mDNS already covers
the discovery layer and gives us TXT records for free. Reinventing
discovery is a distraction.

**Erlang distribution:** ambient-authority security model is the
wrong fit for user-to-user communication. See main `README.md` for
why we keep it for dev-loop only.

---

## Useful prior art to study before building

- **Syncthing** — peer-to-peer file sync, mDNS discovery + TLS-pinned
  HTTPS. Closest precedent to the Phase 2 design we want.
- **Briar** — peer-to-peer messenger over BLE / Tor / Wi-Fi. Hard
  problems solved (delayed delivery, multi-transport).
- **Bonjour Sleep Proxy** — Apple's mDNS-on-the-LAN with sleep-aware
  semantics. Probably not directly applicable but the ideas around
  "peer is dormant, defer delivery" map well.
- **NS-3 / mob mesh research** — for the day we want true mesh
  (multi-hop), there's a body of work on BLE mesh routing that's
  worth not reinventing.

---

## Open questions to resolve at implementation time

- **Persistent peer identity across IP changes.** Bearer secret
  works but isn't a network identity. If a peer's IP changes
  mid-session (DHCP renewal, switching from Wi-Fi to cell), the
  receiver needs to recognize them as the same paired device. mDNS
  re-announce + token check handles this, but there's a small race
  window.
- **Outbox semantics when offline.** When a peer is unreachable,
  cuts queue locally. How long? Disk-backed? Encryption at rest?
- **Multi-device-per-user.** What if a framer has both a phone and a
  tablet? Are they separate paired devices, or a logical "user"
  with two device endpoints? Affects schema (mostly Phase 1 backend
  but bleeds into Phase 2 routing).
- **Group sends.** "Send this cut list to everyone on the crew."
  Simple fan-out for now. Real groups want presence + permission UI
  — defer until use cases force it.
