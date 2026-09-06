# Tests wait for events, not durations

Date: 2026-09-06
Status: accepted
Ticket: MOB-154 (with MOB-119, MOB-123)

## Context

A 1-in-20 flake corrupted a mutation-testing verdict, and a day later sent a
bisect down the wrong path: a real failure and a flake appeared in the same
run, and the flake was investigated first. That is the actual cost of a noisy
suite — not the red build, but the hours spent trusting it.

Three mechanisms were behind it.

**A globally-named singleton owned by whichever test started it.**
`Mob.ComponentRegistry` is named and owns a named ETS table. Two `async: true`
modules each called `start_supervised({Mob.ComponentRegistry, []})` and
tolerated `{:error, {:already_started, _}}`. Whichever test won the race owned
it, and ExUnit tore the process — and its table — down when that test ended,
while a concurrent test in the other module was still using it. The loser died
on `:ets.lookup` against a table that no longer existed.

**Check-then-act across a process boundary.** `on_exit(fn -> if
Process.alive?(pid), do: GenServer.stop(pid) end)` appeared 19 times across 11
modules.
Since MOB-112 the screen owner is linked to the test process, which ExUnit
exits with `:shutdown` at test end — so the owner is dying concurrently with
the callback trying to stop it. Thirteen more modules had each independently
written a correct private `stop_safely/1`, byte for byte identically, which is
a fair signal it belonged somewhere shared.

**Fixed durations standing in for synchronisation.** `Process.exit(pid, :kill)`
followed by `Process.sleep(10)` followed by an assertion that requires the
process to be gone.

## Decision

**A test waits for the event it depends on, never for a duration it hopes is
long enough.** `Process.monitor` plus a `:DOWN`, or `assert_receive`. A monitor
is not a tighter bet than a sleep — the `:DOWN` cannot arrive before the
process is gone, so there is nothing left to race.

Shared state that outlives a single test is owned by the **run**, not by
whichever test got there first. `Mob.ComponentRegistry` now starts in
`test_helper.exs`, so both setups take the `:already_started` branch, nobody
owns it, and nobody can tear it down mid-flight. Sharing is safe because every
entry is keyed by a per-test `screen_pid`.

`Mob.Test.ProcessHelpers` is where these live: `stop_if_running/2` (named),
`stop_pid/2` (pid), `await_exit/2` (block until actually gone, raising rather
than continuing on timeout — a helper that returns quietly on timeout leaves
the caller asserting against a live process, which is the situation being
avoided).

### Not every sleep is a bug

All 35 `Process.sleep` calls were classified rather than swept. Twelve were
`Process.sleep(:infinity)` — a stub process parked until something kills it,
not a wait at all. That left 23 finite sleeps, now 8:

**Removed because there was never anything to wait for (5).** A `GenServer.call`
from the same process that sent the earlier messages is already a barrier:
Erlang orders messages pairwise between two processes, so every `send` is ahead
of the `call` in the mailbox and has been handled before the reply comes back
(`event/integration_test.exs` ×3, `nav/screen_nav_test.exs`). And
`Trace.broadcast/3` folds over the table *in the calling process*, so its
cleanup is done by the time `dispatch/4` returns `:ok` (`event/trace_test.exs`).
These sleeps were guarding against nothing.

**Replaced with the real barrier (8).** A ready-message where the test was
waiting on another process to reach a known point (`trace_test.exs`,
`device_test.exs`); `Logger.flush/0` where it was waiting on handlers to drain
(`native_logger_test.exs` ×2, `theme_host_test.exs` ×2); a monitor where it was
waiting for an exit.

**Replaced with a bounded poll (3).** `device_test.exs` (×2) and
`native_component_examples_test.exs` wait for a GenServer to
process a `:DOWN` sent by a *monitor*, not by the test. Pairwise ordering does
not help here — the test never sent that message, so a `call` orders nothing
against it. `ProcessHelpers.eventually/2` polls with a deadline: it returns as
soon as the state is right rather than always paying the worst case, and it
fails with "condition still false after Nms" instead of letting the next
assertion report something confusing.

**Kept, deliberately (8).** Three in `render_stats_test.exs` are the subject
under test — it measures elapsed time, so time must actually elapse. Three are
the backoff *inside* a poll loop that has its own deadline (`eventually/2`
itself, `migration_test.exs`, `reset_transition_test.exs`). One is a `@doc`
example, quoting the bad pattern in order to name it. One remains a genuine
bet: `router_hot_path_test.exs:206` waits for a message the *screen* sent to
the router, and the test is neither party, so it has no ordering guarantee to
lean on. It is left as a sleep and recorded here rather than disguised.

One honest caveat about the `Logger.flush/0` swaps: with the barrier deleted
outright those tests still passed 8 times out of 8 on this machine, so the wait
is not demonstrably load-bearing here. `flush/0` is kept because it is the
correct primitive and costs nothing when there is nothing pending, whereas the
sleep it replaced was a guess that cost 300ms per run. That is a reason, not a
measurement, and is stated as such.

## Consequences

- `mix mob.flake` runs the suite repeatedly and reports which tests are
  non-deterministic. Its green output says explicitly that a 1-in-17 flake
  survives 20 green runs about 30% of the time, because "I ran it 20 times" is
  the reasoning that let this persist.
- **The registry race is fixed by construction, not by demonstration.** It did
  not reproduce here in 25 full-suite runs or 40 concentrated ones, so there is
  no before-and-after to show. The mechanism is provable by reading the code
  and it was observed once on this machine; the fix removes the ownership that
  makes it possible. That is weaker evidence than a reproduction and is stated
  as such.

- **Tightening `stop_pid/2` broke three tests, and only under a full run.**
  Making the timeout raise meant replacing a blanket `:exit, _ -> :ok` with
  enumerated clauses. The enumeration was wrong: a linked owner dying while
  ExUnit tears the test down exits with `{{:shutdown, {:sys, :terminate, _}},
  {GenServer, :stop, _}}`, which matched none of them. It passed every file run
  on its own and failed 3 tests in one full run and 4 in the next. The fix is
  to invert the logic — special-case only the timeout, treat every other exit
  as "already gone" — because "did it stop" has one interesting answer and an
  open-ended set of uninteresting ones. Enumerating the uninteresting set is a
  bet on having seen every shutdown shape, which is the same class of mistake
  as betting on a duration.
