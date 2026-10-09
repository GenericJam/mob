# A physical iPhone's node host can be set by the connecting tool

- Date: 2026-10-09
- Status: accepted
- Linear: MOB-428

## Context

mob_ci's `deploy:ios_device` cell (MOB-415) built, signed and installed on
Kevin's wired iPhone SE, then never reached the node. Once mob_dev could find
the phone's USB link-local address again (the first cause, fixed in mob_dev
0.7.18), the connect still timed out waiting for `mob428_ios@169.254.1.100`.

`mob_beam.m` names a device build's node after the first address it finds
in this order: WiFi/LAN, USB link-local, loopback. WiFi first is deliberate:
the name is fixed at startup, and a node named after the cable's address is
stranded when the cable is pulled. The phone's `mob_diag_host_ip.txt` said
`192.168.0.185`: its WiFi was a network the Mac (10.0.0.71, 192.168.50.1)
has no route to. The phone's EPMD binds 0.0.0.0 and answered over the cable,
but distribution dials the host in the node name, so `…@192.168.0.185` was
unreachable and `…@169.254.1.100` did not exist.

Nothing on the Mac can fix that: the node's host is an IP literal, so no
hosts entry or resolver applies, and routing the WiFi address over the USB
interface needs root.

## Decision

The tool that launches the app says which of the phone's addresses to use.
`MOB_NODE_HOST` (passed by `devicectl device process launch` as
`DEVICECTL_CHILD_MOB_NODE_HOST`) is taken when it is one of the phone's own
IPv4 addresses; otherwise the order is unchanged. mob_dev's `mix
mob.connect` relaunches a physical iPhone with the address it resolved the
phone at (`MobDev.Tunnel.setup/1`) and waits for exactly that node.

- The choice is `mob_choose_node_host/4` in `ios/mob_node_host.h`, pure over a
  `getifaddrs()` list, so `test/native/node_host_test.c` runs the code
  `mob_beam.m` runs.
- An address the phone doesn't hold is ignored rather than trusted: a node
  named after someone else's IP is unreachable by construction.
- `mix mob.deploy`'s own relaunch is unchanged (it does not wait on a
  node); the override only comes from a tool that is about to dial the node.

## Consequences

- A wired iPhone connects whatever network its WiFi is on. Pulling the cable
  of a node launched this way strands it (the trade WiFi-first avoided); it
  is a connect-time launch, and the next connect relaunches it.
- mob_dev < 0.7.18 sends no override and mob < 0.9.16 ignores it: either
  side alone behaves as before.
- Simulator builds are untouched (always 127.0.0.1).
