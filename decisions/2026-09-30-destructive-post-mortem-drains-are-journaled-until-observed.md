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

**Observed means the bus says so.** An entry counts as observed when:
- its capsule reached at least one subscriber when it was emitted, or
- a reader asked the bus after it was emitted: `recent/1`, `classes/1` or
  `subscribe/1`.

Emitting it is not enough. On a boot nobody is attached to, emitting is exactly
what happened before the capsule was lost.

**The bus keeps a watermark and makes one call.** `Mob.Defect.Bus` keeps the
highest emit sequence observed, in an `:atomics` cell in its store state
(`state_vsn` 2):
- A delivery raises the watermark to the capsule's own sequence.
- A read or a subscribe raises it to the current one.

The bus then calls `Mob.PostMortem.Journal.observed/1` with the watermark. With
nothing pending that is one `:persistent_term` read, and an emit that reaches
no subscriber does neither. The journal records each emitted entry against the
bus sequence read right after its emit. That is at or past the capsule's own
sequence, so it errs toward keeping an entry, never toward clearing one early.
It clears entries at or below the watermark.

The sweep also checks the watermark once after it registers what it emitted.
A capsule delivered during its own emit was observed before it was pending,
and the watermark is the only record of that.

The watermark is sound because a subscriber only receives capsules emitted
after its `subscribe`, and that `subscribe` already observed everything
before it. `subscribe` reads the sequence after publishing the new list, so a
concurrent emit that missed the list is below that read.

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
- **Serialised.** Every read-modify-write of the file and the pending set takes
  one node-local `:global.trans` lock. Two concurrent sweeps, or a sweep and a
  reader, would otherwise each write back what they read.

Alternatives rejected:

- **The bus exposes only an observation counter, and a sweep compares against
  it.** This keeps the bus free of any post-mortem call. But the observation
  has to reach disk in the boot where it happens. With the counter alone, a
  developer who reads the capsule in boot A and then restarts the app sees it
  again in boot B, because boot A never swept after the read. That is a
  smaller version of the same false signal.
- **The bus calls a generic observer hook registry.** This is a second
  subscriber mechanism with one user. The single named call is less code and
  says what it is for.
- **Moving the marker advance to observation time, natively.** This needs a
  native change on both platforms, and MetricKit has no marker to move.
- **Persisting the Registry's seen-set.** Every boot would stop re-emitting
  crash dumps. That behaviour is deliberate (the Registry moduledoc says why)
  and would still not help an exit whose one emit nobody saw.
- **A `Mob.Diag.Store` owner for the pending set.** Pending entries change a
  few times per boot. A `:persistent_term` entry, written under the same lock
  as the file, costs nothing on the bus's hot path and needs no process.

## Consequences

- "Each exit emitted exactly once across boots" becomes "until observed". An
  unobserved exit is emitted again on every boot until someone attaches, and
  a capsule's `id` differs between those emits. Its `fingerprint` and
  `evidence` do not.
- A capsule the bus failed to record (counted as `lost` in
  `Mob.Diag.health/0`) can still be cleared by a later observation. An
  observation reads the sequence, not the ring.
- A journaled entry that stops matching the emit function's shape after an
  upgrade fails on every sweep, as a counted loss, until it ages out past the
  bound or the journal is observed. Both platform modules gate shape before
  journaling, so only a change in `Mob.Defect`'s emit clauses can cause it.
- MetricKit entries carry `raw_json`, so a full journal can reach a few MB.
  It is rewritten only when a sweep adds entries or an observation clears
  them.
- The test seam is `sweep_with(nif, journal_path)` on both platform modules.
  The tests in `test/mob/post_mortem/android_test.exs` and `ios_test.exs`
  fail, each in isolation, when any of these is removed:
  - journaling;
  - observing on fanout, `recent`, `classes` or `subscribe`;
  - the post-emit watermark check;
  - per-sequence clearing (replaced by a sticky flag);
  - the decode rescue;
  - the shape check;
  - repair-on-corrupt;
  - the bound;
  - the lock.
