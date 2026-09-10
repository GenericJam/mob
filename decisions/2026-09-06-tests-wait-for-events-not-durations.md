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
Process.alive?(pid), do: GenServer.stop(pid) end)` appeared 14 times across 6
modules (12 with `GenServer.stop`, 2 with `Agent.stop`).
Since MOB-112 the screen owner is linked to the test process, which ExUnit
exits with `:shutdown` at test end — so the owner is dying concurrently with
the callback trying to stop it. Thirteen more modules had each independently
written a correct private helper — twelve named `stop_safely/1` and identical,
one named `safe_stop/1` and nested inside a `describe` — which is a fair signal
it belonged somewhere shared.

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

All 35 `Process.sleep` calls were classified rather than swept. Twelve are
`Process.sleep(:infinity)` — mostly a stub process parked until something kills
it, which is not a wait at all. That leaves **23 finite sleeps on master**, of
which **17 were dealt with and 6 kept**. This PR adds 2 of its own (the backoff
inside `eventually/2`, and a `@doc` example quoting the bad pattern), so the
tree now has 8.

The 17 fall into three kinds. Some had **nothing to wait for**: a
`GenServer.call` from the same process that sent the earlier messages is
already a barrier, because Erlang orders messages pairwise between two
processes, so every `send` is ahead of the `call` in the mailbox
(`event/integration_test.exs`). `Trace.broadcast/3` likewise folds over its
table *in the calling process*, so cleanup is done by the time `dispatch/4`
returns `:ok`. Some were **replaced with the real barrier** — a ready-message
where the test waited on another process to reach a known point,
`Logger.flush/0` where it waited on handlers to drain, a monitor where it
waited for an exit. Three were **replaced with a bounded poll**
(`eventually/2`) for the one shape where pairwise ordering genuinely does not
help: a GenServer processing a `:DOWN` sent by a *monitor* rather than by the
test.

The 6 kept: three in `render_stats_test.exs` are the subject under test (it
measures elapsed time, so time must pass), two are the backoff inside a poll
loop that has its own deadline (`migration_test.exs`,
`reset_transition_test.exs`), and one is a genuine bet —
`router_hot_path_test.exs:206` waits for a message the *screen* sent to the
router, and the test is neither party. It is left as a sleep and recorded here
rather than disguised.

### Pairwise ordering is not a general licence

The `GenServer.call` argument above holds only when the messages and the call
have the same sender *and* the same recipient, and the recipient does not
forward. `nav/screen_nav_test.exs` looked like that case and is not: `send(pid,
:pop_test)` goes to the **owner**, which forwards to the screen, which may send
`{:nav_action, ...}` back to the owner. The test is party to none of those
hops. Deleting its sleep on the pairwise argument left a test that could no
longer fail: with the regression it exists to catch injected, it passed 3 runs
out of 3.

The barrier that works there is to sync with the *screen* first. Once the
screen's `handle_info` has returned, anything it sent the owner is already in
the owner's mailbox, so a later call from the test queues behind it. With that
in place the injected regression fails the test, as it should.

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

- **I asserted counts twice and was wrong both times.** The first draft said the
  check-then-act idiom appeared "19 times across 11 modules"; the grep that
  produced it counted five *comment lines describing the idiom* as instances of
  it. The real figure is 14 across 6. A second draft said 15 sleeps were removed
  and 8 remained; that subtracted the wrong way and silently counted two sleeps
  this PR itself added as survivors. The real split is 17 dealt with, 6 kept, 2
  new. In a change titled "make the test suite tell the truth", both errors are
  the same class as the bug being fixed: a plausible number nobody re-derived.
  Every count in this record is now produced by a script over `git show
  master:<file>` and the working tree, not by reading a grep total.

- **I tried to measure the improvement under load and the instrument was not
  trustworthy.** Running four full suites concurrently on one laptop, master
  against this branch interleaved so both saw identical conditions, gave master
  19/20 failing and the branch 2/20. Re-run later, the same comparison gave
  master 8/20 and the branch 20/20 — for code that had barely changed between
  the two measurements. A result that swings that far for the same input is a
  property of the harness, not of the branch, so **no flake-rate improvement is
  claimed here.** Sequentially, which is how CI runs, master and this branch are
  both 25/25 green: no measurable difference either way. The registry fix
  therefore remains argued from the code, not demonstrated, exactly as stated
  above.

- **The load harness did earn its keep once.** It surfaced
  `Mob.StorageTest "delete/1 removes the file"` failing with `{:error, :enoent}`
  on a file the test had just written. `System.unique_integer/1` is unique per
  VM, so two concurrent `mix test` runs generate the same temp directory name
  and each `on_exit` deletes the other's fixtures. That is a real bug, not a
  harness artefact — a CI matrix on one box hits it — and
  `ProcessHelpers.tmp_path/1` now includes the OS pid.

- **`component_server_test.exs:309` is load-sensitive on both branches** and is
  not addressed here: it waits 500ms for a `:DOWN` and an oversubscribed machine
  exceeds that. Filed separately rather than folded in, because widening the
  timeout is the tempting wrong fix.

- **Twice I watched a failure go past and lost it**, because the loop running
  the suite only kept the summary line. Both were unreproducible afterwards.
  `mix mob.flake` now writes the full log of every failing run to
  `_build/.../mob_flake/run-N.log` and prints the path. A rare failure may not
  come back; the artefact is the difference between a lead and a rumour.

