# Diagnostic stores share one hardened owner

- Date: 2026-09-30
- Status: accepted

## Context

Several subsystems exist so agents can debug a running app over dist:
- `Mob.Agent.Receipts`
- `Mob.Defect.Bus`
- `Mob.Invariant`
- `Mob.PostMortem.Registry`
- `Mob.RenderStats`
- `Mob.Event.Trace`

Each keeps its records in public named ETS tables that writers use directly,
with no mailbox on the hot path. Each carried its own hand-written owner process
and `start/0`. An Insider sweep, followed by targeted runtime probes, found that
the stores lost evidence silently.

**Not ready when `start/0` returned (confirmed).** `start/0` did
`if :ets.whereis(table) == :undefined, do: Owner.start()` and treated
`{:error, {:already_started, pid}}` as success. `GenServer.start/3` registers
the name *before* `init/1` creates the tables, so a second concurrent first
caller wrote to a table that did not exist yet. Out of 1,600 concurrent first
calls:
- `Receipts.recent/1` and `Bus.classes/1` raised `ArgumentError` 1,400 times.
- `Registry.mark_seen/1` raised 42 times.
- `Invariant.violation_count/0` returned `:undefined` 823 times.

`RenderStats.enable/0` had the same window, and dropped frames silently while
the table was missing.

**`reload/0` reset counters under existing rows (confirmed).** Setup replaced
the `:atomics` sequence counter every time. After `Receipts.Owner.reload()`:
- new receipts sorted below old ones
- the 256 bound failed (356 rows)
- `dropped` went back to 0

**Evidence died with its owner.** Owners were unlinked and unsupervised. An
owner that died took its tables, and all their history, with it. The next call
quietly recreated them empty. `Bus.Owner` also did subscriber bookkeeping, so a
bug there would wipe the defect history.

**Lost writes were invisible.** `Mob.Screen.Server` wrapped `Receipts.record/1`
in `rescue _ -> receipt`. A receipt lost to any of the above left no trace, so
"no receipt for this action" was ambiguous again.

**Mark before emit (from source).** Post-mortem sweeps called `mark_seen/1`
before `emit_*`. A failed emit left the artifact marked as seen and never
reported.

**`Event.Trace`'s table was owned by its caller (confirmed).** Tracing started
over `:rpc` vanished as soon as the call returned. The agentic guide's remote
`Bus.subscribe` example had the same mistake: it subscribed `:rpc`'s transient
process.

## Decision

**`Mob.Diag.Store`** is the one owner, used by every table-backed store through
a behaviour: `tables/0`, `state_vsn/0`, `new_state/1`, and optionally
`after_setup/0` and `health/1`. The owner is registered as
`Mob.Diag.Owner.<Store>`, started on first use and unlinked. It is deliberately
not the old `<Store>.Owner` name: an app that hot-pushes this over an older
`mob` still has those processes, and calling into one would crash.

- **Readiness.** `ensure/1` checks the flag table, which is created last. On a
  miss it makes a call to the owner, which queues behind `init/1`. The hot path
  is still a single `:ets.whereis/1`.
- **Idempotent, versioned state.** Setup creates only what is missing, and
  `new_state/1` receives the previous state so counters carry over. `state/1`
  compares the stored `vsn` with the code's `state_vsn/0` and re-runs setup when
  they differ. That covers the first write after a hot push that changed a
  state shape.
- **Heir.** Tables are created with `Mob.Diag.Heir` as their ETS heir. An owner's
  death hands its tables, rows intact and still writable, to the heir, and the
  next owner takes them back. The owner monitors the heir and re-points its
  tables if the heir restarts. If both die, the tables are recreated and counted
  as a `reset`.
- **Guarded writes.** `guard/3` wraps every write path:
  - Any failure is counted as `lost`, logged once, and followed by a repair.
  - The repair (a sync with the owner) happens only if a table is actually
    missing, so an unrelated failure never turns writes into owner calls.
  - The caller gets a fallback instead of an exception.
  - `Receipts.record/1`, `Bus.emit/1`, `Invariant.run/2`,
    `Registry.mark_seen/1` and `RenderStats`' frame store never raise.
- **Readback.** `Mob.Diag.health/0` returns counts and pids only, per store:
  owner, who holds each table, `lost`, `resets`, `owner_starts`, state version,
  and store-specific counts. It is read-only: it starts and repairs nothing, so
  it reports a broken store rather than hiding it.

**`Mob.Diag.Subscribers`** holds subscriber lists for the Bus (`:defect_bus`) and
Trace (`:event_trace`). It publishes each list to `:persistent_term` for the
write path to read, and monitors subscribers, including pids on other nodes. On
restart it re-monitors everything it finds published, so delivery continues and
pruning resumes. `Event.Trace` no longer has a table: tracing is on while the
tracer list is non-empty. `subscribe/2` takes a pid, for `:rpc` callers.
`Trace.start/0` is deprecated and does nothing.

**`Registry.emit_once/2`** records the id, runs the emit, and forgets the id if
the emit raises, counting it as lost. An artifact still on disk (a crash dump)
is retried by the next sweep. MetricKit and ApplicationExitInfo drains are
destructive, so for them the counted loss is the best available.

**`Defect.Bus` classes are capped at 256.** Past the cap, the least recently
seen class is evicted and counted (`class_evictions`).

Alternatives rejected:

- **Fixing the four `start/0` functions in place.** Five copies had already
  drifted from each other, and their ordering comments justified themselves by
  pointing at each other. One owner with one test suite is less code than five
  correct copies.
- **One process owning every store's tables.** A single failure would take every
  diagnostic down at once. Per-store owners keep a failure contained, and the
  shared heir only holds tables whose owner is gone.
- **A supervision tree.** `mob` is a library inside someone else's app and has
  none. An app that never records a receipt should start nothing.
- **Routing writes through the owner.** That puts a mailbox on the path of every
  dispatched event, which is what the stores were designed to avoid.

## Consequences

- A diagnostic answer can now be checked for completeness: `Mob.Diag.health/0`
  says whether a store has lost writes or been reset.
- The per-store `Owner` modules are gone. Tests that called
  `Mob.Agent.Receipts.Owner.reload/0` use `Mob.Diag.Store.reload/1`. The
  `@doc false` `start/0` functions on the stores are removed; every public entry
  point ensures readiness itself.
- Persistent-term keys changed (`{Mob.Diag.Store, store}` and
  `{Mob.Diag.Subscribers, topic}`). State from before this change is not carried
  over when an app hot-pushes onto it: counters start again once. The old owner
  processes keep running until the app restarts.
- A new diagnostic table must use `Mob.Diag.Store` rather than a hand-written
  owner (AGENTS.md pre-empt rule 17).
- Verified on the host:
  - `test/mob/diag/store_test.exs` fails with the readiness wait removed, the
    heir not re-appointed, the heir not reclaimed, no repair, repair on every
    failure, the version check removed, resets not counted, or health starting
    an owner.
  - The per-store tests fail on the receipts sequence reset, a missing class
    cap, a subscriber registry that forgets on restart, `emit_once` not
    forgetting a failed id, and `subscribe/2` ignoring its pid.
  - Removing the heir from `:ets.new` alone is equivalent: the setup that
    `ensure/1` runs next sets it with `setopts`.
