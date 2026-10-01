# Remote subscribers park on disconnect

- Date: 2026-09-30
- Status: accepted
- Linear: MOB-304

## Context

`Mob.Diag.Subscribers` (0.9.5) monitored every subscriber and pruned it on any
`:DOWN`, including `:noconnection` for a pid on another node. That is the
common case for the diagnostic streams: a host shell subscribes to
`Mob.Defect.Bus` or `Mob.Event.Trace` on a device.

Host↔device connections drop routinely:
- Over `adb` only epmd is reverse-forwarded; distribution ports are forwarded
  host→device. The device cannot dial the host, so a dropped connection stays
  down until the host re-dials.
- `global`'s `prevent_overlapping_partitions` drops a host↔device connection
  when a third node (a short-lived `:rpc` node, say) leaves.

Verified on a Moto G (Android 15): a watcher subscribed to both topics from a
short-lived rpc node. The rpc node exited, both topics went from 1 to 0, the
watcher reconnected (`Node.ping` → `:pong`), and the next defect was not
delivered. The still-alive subscriber got no signal that it had been dropped.
`mob` 0.9.4 never pruned, and leaked dead pids instead.

## Decision

A `:noconnection` `:DOWN` **parks** the subscriber instead of pruning it:

- It leaves the published list, so emits never `send/2` to it. A send to an
  unconnected node dials it, which over `adb` cannot succeed, and would put a
  connection attempt on the path of every dispatched event.
- Its topics and meta (Trace filters) are kept in the registry, keyed by pid,
  with a deadline.
- The registry calls `:net_kernel.monitor_nodes(true, node_type: :all)` —
  `:all` so a shell connected as a hidden node is covered too. On
  `{:nodeup, node, _}` it monitors that node's parked pids again and
  republishes them. A pid that died meanwhile answers the new monitor with
  `:noproc`, which prunes it.
- A `:DOWN` handled after its node has already reconnected (so that node's
  `:nodeup` found nothing parked) re-monitors instead of parking.
- A parked subscriber whose node has not returned within
  `config :mob, :subscriber_park_ms` (default 10 minutes) is dropped.
- `subscribe/3` of a parked pid unparks it with all its topics.
  `unsubscribe/2` and `clear/1` remove parked entries too.

Parked entries live **only in `:persistent_term`** (`{Mob.Diag.Subscribers,
:parked}`), written on every change beside the published lists, not in the
registry's state:
- A registry that dies while a subscriber is parked would otherwise lose it
  silently, which is the defect being fixed. The next instance keeps each
  entry's deadline, and unparks at once any whose node reconnected while no
  registry was running (its `:nodeup` went to nobody). `monitor_nodes` is
  subscribed before that check, so a node arriving in between is not missed.
  A pid found both published and parked (its predecessor was killed
  mid-park) stays parked, so the new instance does not dial its node.
- The registry's state keeps the 0.9.5 shape, so a registry 0.9.5 started
  keeps running after a hot push onto this code. It never subscribed to node
  events, so parking subscribes first if this process has not (a process
  dictionary flag: each `monitor_nodes/2` call adds a subscription).

Parking writes the parked entry before unpublishing, and unparking republishes
before removing it, so `health/0` may count a subscriber in both for an
instant but never in neither.

`Mob.Diag.health/0`'s `subscribers` section adds `parked: %{topic => count}`
beside `topics`.

Alternatives rejected:

- **Never prune remote pids (0.9.4).** Leaks every shell that ever subscribed,
  and keeps sending to nodes that are gone.
- **Keep parked pids on the published list.** Every emit would dial an
  unreachable node.
- **Make the subscriber re-subscribe on reconnect.** The subscriber gets no
  signal that it was dropped; a shell watching for defects just goes quiet.
- **Buffer and replay what was emitted while parked.** Unbounded memory on the
  device for a subscriber that may never return. `Bus.recent/1` already holds
  the newest capsules.

## Consequences

- A host shell that re-dials the device keeps receiving without subscribing
  again. Events emitted while it was disconnected are not replayed.
- A shell whose node restarted under the same name is not confused with the
  old one: the old pid's creation differs, so the new monitor answers
  `:noproc` and prunes it.
- Verified on the host with a real second node (`:peer`, stdio control
  channel) in `test/mob/diag/subscribers_test.exs`: park and resume with the
  filter intact and nothing sent while parked, prune of a pid that died while
  parked, grace-period drop, survival of a registry kill, pick-up of a node
  that reconnected while the registry was down, a hidden node, and a registry
  that predates this code. Each fails with its part of the fix removed.
- Those tests `:global.sync/0` on both nodes before disconnecting. A
  disconnect in the middle of `global`'s handshake with a new node is
  re-dialled by the handshake's pending messages (traced: `init_connect_ack`
  from our `global` auto-connected), which unparks the subscriber: a few
  failures in 400 runs of the file without the sync, none in 480 with it.
