# Destructive post-mortem drains are journaled until observed

- Date: 2026-09-30
- Status: accepted
- Ticket: MOB-303

## Context

`Mob.PostMortem.Android.sweep/0` drains `ApplicationExitInfo` through
`:mob_nif.post_mortem_android_drain/0`, and the NIF advances
`<filesDir>/mob_post_mortem_appexit_marker.txt` when it returns an exit. The
drain is destructive: the OS hands each exit over once, and the capsule lives
only on that boot's in-memory `Mob.Defect.Bus`. iOS MetricKit
(`Mob.PostMortem.IOS`) has the same shape: the native queue is cleared as it
is drained, and MetricKit does not deliver a payload twice.

Seen on a Moto G (Android 15):
1. The BEAM crashes (`EXIT_SELF`).
2. The user reopens the app. Boot A sweeps in `on_start`, drains the exit, and
   the marker advances.
3. The developer runs `mix mob.connect`, which restarts the app by design and
   kills boot A.
4. Boot B drains nothing new.

The exit is gone from every surface anyone can reach. BEAM crash dumps are not
affected: the file stays on disk and every boot sweeps it again (see
`Mob.PostMortem.Registry`).

## Decision

**A journal, written before emit, cleared on observation.**
`Mob.PostMortem.Journal` keeps what the two destructive drains returned in
`mob_post_mortem_journal.etf` in `Mob.data_dir/0`:
- Each sweep journals its fresh entries first, then emits every journaled
  entry of its source followed by the fresh ones.
- Each emit goes through `Registry.emit_once/2`, so within one boot a re-sweep
  emits nothing twice.
- An entry leaves the journal once it has been observed on the bus.

The artifact ids the Registry already uses are the journal's keys. Crash dumps
are not journaled.

**Observed means this capsule was seen.** An entry counts as observed when:
- its capsule was handed to at least one subscriber when it was emitted, or
- `Mob.Defect.Bus.recent/1` returned that capsule.

Nothing else counts:
- Emitting it is not enough. On a boot nobody is attached to, emitting is
  exactly what happened before the capsule was lost.
- A subscriber that arrives later has seen nothing emitted before it. That
  includes one parked while its node was disconnected and then resumed.
- A later capsule reaching a subscriber says nothing about an earlier one.
- A `classes/1` row shows the class's first capsule, not this occurrence.

**The bus reports deliveries and returns; it keeps no observation state.**
- `Bus.emit_delivered/1` (`@doc false`) is `emit/1` that also returns how many
  subscribers the capsule was handed to. `emit/1` keeps its return value and
  does no extra work.
- The journal's sweep builds each capsule (`Defect.appexit_capsule/1`,
  `Defect.metrickit_capsule/1`) and emits it through `emit_delivered/1`. An
  entry delivered at emit is removed from the file at once. The rest are
  remembered as waiting, keyed by capsule id.
- `recent/1` passes the capsules it returns to `Journal.observed/1`. That
  function reads one `:persistent_term` flag, which is set only while this boot
  has waiting entries. If the flag is set, it makes one call with the capsule
  ids, and the waiting entries among them are removed from the file.

The bus depends on the journal through that one call, and only from a reader.
Nothing is added to the emit fanout.

**One node-local owner serialises the file.**
- Every read-modify-write of the file runs in `Mob.PostMortem.Journal`, a
  GenServer registered locally, started on first use with `GenServer.start`
  (`{:already_started, pid}` handled), and unlinked.
- It also holds the waiting set. The `:persistent_term` flag changes only when
  that set turns empty or non-empty, because a `:persistent_term` update scans
  every process.
- It is called by sweeps, and by `recent/1` while entries are waiting. It is
  never called by an emit.
- Calls have a 5 s timeout, and any exit is caught. A caller whose owner died
  or stalled logs a warning and carries on. A sweep still emits, unjournaled
  if the record step failed. The next caller starts a new owner.
- The file is the record, so the owner dying loses no evidence. It loses only
  this boot's chance to clear an entry through `recent/1`, and the next boot
  emits that entry again.

**Bounded, atomic, never fatal.**
- **Bound.** The journal keeps the newest 32 entries. The oldest are dropped
  past that, counted in the file (`Journal.read/1`'s `dropped`), and logged.
  A sweep still emits everything it drained, because the bound limits what is
  kept, not what is reported.
- **Atomic writes.** Each write goes to a temporary file, is `fsync`ed, and is
  renamed over the journal.
- **Corruption.** A journal that cannot be decoded, or decodes to the wrong
  shape, is treated as empty and logged. The sweep that finds it rewrites it,
  so the warning appears once.
- **No path.** If the data directory cannot be resolved, the sweep still emits,
  unjournaled.

Alternatives rejected:

- **An observation watermark on the bus.** This was the first version on this
  branch: delivery raised a high-water emit sequence to the capsule's own,
  `recent/1`, `classes/1` and `subscribe/1` raised it to the current one, and
  everything at or below it was cleared. Pre-merge review showed it unsound in
  two ways:
  - A subscriber parked by `Mob.Diag.Subscribers` (MOB-304) while its node is
    disconnected is resumed without having seen anything. A later delivery to
    it moved the watermark past an exit nobody saw.
  - `recent(5)` cleared exits it did not return, either because they were
    evicted from the ring or because they were past the limit.

  It also put an observation hook on the emit fanout.
- **A `:global.trans` lock.** Also in the first version. `:global`'s retry
  sleeps a random 125 ms or more, so 16 concurrent sweeps took 2.3–6 s on a
  laptop. Its node list (`[node()]`) is evaluated once: if `Node.start` runs
  inside the critical section (Android `Mob.Dist` starts distribution about
  3 s after boot, when sweeps run), the release targets `:nonode@nohost`, and
  every later sweep and observation hangs.
- **Keeping the waiting set in `:persistent_term`.** Readers could then
  intersect without a call. But every sweep with an unobserved entry would
  update it, and each update scans every process. The flag changes only when
  the set turns empty or non-empty.
- **Moving the marker advance to observation time, natively.** This needs a
  native change on both platforms, and MetricKit has no marker to move.
- **Persisting the Registry's seen-set.** Every boot would stop re-emitting
  crash dumps. That behaviour is deliberate (the Registry moduledoc says why)
  and would still not help an exit whose one emit nobody saw.

## Consequences

- "Each exit emitted exactly once across boots" becomes "until observed". An
  unobserved exit is emitted again on every boot until someone sees it, and a
  capsule's `id` differs between those emits. Its `fingerprint` and `evidence`
  do not.
- An agent that attaches after a restart reads the re-emitted exit with
  `Bus.recent/1`. Subscribing after that boot's sweep does not deliver it,
  because the Registry has already emitted it this boot.
- Every miss errs toward a duplicate on the next boot, never toward a loss.
  The misses are:
  - a `recent/1` that runs between a sweep's emit and its bookkeeping;
  - an owner that died with the waiting set;
  - a failed write.
- A send to a subscriber that died before its monitor pruned it counts as a
  delivery, as `send/2` cannot tell. The window is the time between the exit
  and the `:DOWN`.
- A journaled entry that stops matching `Mob.Defect`'s capsule clauses after
  an upgrade fails on every sweep, as a counted loss, until it ages out past
  the bound or is observed. Both platform modules gate shape before
  journaling, so only a change in those clauses can cause it.
- MetricKit entries carry `raw_json`, so a full journal can reach a few MB.
  It is rewritten only when a sweep adds entries or an observation clears
  them.
- The test seam is `sweep_with(nif, journal_path)` on both platform modules.
  The tests in `test/mob/post_mortem/android_test.exs` and `ios_test.exs` fail,
  each with its piece removed, when any of these is missing or swapped:
  - journaling;
  - clearing on delivery at emit;
  - observing in `recent/1`;
  - observing only what `recent/1` returned (versus everything waiting);
  - not observing in `subscribe/1`, `classes/1` or another sweep's delivery;
  - the decode rescue, the shape check and repair-on-corrupt;
  - the bound;
  - serialisation (no owner) and the owner itself (versus `:global.trans`);
  - the caught call exit;
  - restarting the owner after it died.
