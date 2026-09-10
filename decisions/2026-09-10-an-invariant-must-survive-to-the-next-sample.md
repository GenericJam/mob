# An invariant must survive to the next sample

Date: 2026-09-10
Status: accepted
Ticket: MOB-156 (epic MOB-149, phase 2)

## Context

The framework can assert things application code cannot: that no component
outlives the screen that owns it, that no dead screen sits in a navigation
stack. It has the handles; the app does not. Each check is a few microseconds
and each guards a class of bug recent releases kept re-fixing — three of the
four agents surveyed in MOB-149 named the component-ownership/handle-leak class
independently, which is why it leads.

The hazard is not writing the checks. It is that **every check reads live state
from processes that are concurrently changing.** A screen mid-teardown has a
dead pid and components that have not yet been reaped; a check sampling that
instant sees a leak that resolves itself microseconds later. Report it and you
produce a defect nobody can reproduce, which is worse than reporting nothing:
it teaches the reader to ignore the channel, and then the real one arrives.

## Decision

**The first sighting of a violation is held as a candidate. It is recorded only
if the same violation is still there at the next sampling of that point, and
only once it is at least 50ms old.**

The first version re-ran the check immediately instead, back to back in the same
process, and that was measured filtering nothing: the gap between two calls is
about a microsecond and the transients it was written for last tens to hundreds,
so it suppressed ~0% of them. Two evaluations a microsecond apart cannot
disagree, which made the rule an assertion about nothing — and the shipped check
reported a confirmed `:critical` on **60 of 60 healthy teardowns**, the exact
outcome this design exists to prevent.

Deferring to the next sample gives real separation at no latency cost. The age
floor is needed on top because sampling points are event-driven: the router
stops screens in a tight loop, so during a multi-screen reset "the next sample"
can arrive in under a millisecond and a component still being reaped is seen
twice. With the deferral alone, healthy teardowns still produced about one
confirmed violation in sixty; with the floor, zero.

Sameness is by fingerprint over the violation's details, so a *different*
transient at the next sample does not confirm the first.

That makes the checks a contract rather than a convenience: a check must be
*deterministic over stable state*. One that samples something genuinely
time-varying — a queue length, a timestamp — cannot be expressed here and should
not be. The confirmation run's details are the ones recorded, because the second
evaluation is the one that decided.

**A diagnostic may never affect what it observes.** A check that raises is
reported as a violation of `:invariant_check_failed` rather than propagating,
one broken check does not stop the others, and the `terminate/2` call site is
wrapped again on top of that. `Mob.Agent.Receipts` learned this the hard way in
MOB-155, where the receipt write could crash the screen it was recording.

**Two checks ship, not ten.** MOB-156 names ten. Two are observable from the
BEAM today; the other eight need hooks that do not exist — a handle high-water
mark nobody records, a `-1` sentinel produced natively and never surfaced, a
handler generation token that has not been invented. They are listed in
`Mob.Invariant.Builtins.unimplemented/0` **as data, with what each needs**, and
a test asserts none of them is ever silently registered. A registry advertising
ten checks and running two is the kind of overclaim this epic keeps having to
retract.

## Evidence

Both directions were checked, which for an invariant means more than a passing
test — an invariant that holds is indistinguishable from one that cannot fire.

**It holds on healthy code.** A real `Mob.ComponentServer` monitors its screen
and stops when the screen dies, so after an ordinary teardown there is no live
component under a dead owner. The check reports `:ok`, and a probe confirms the
registry is empty rather than the check being blind.

**It fires on an injected regression.** Disabling the `{:DOWN, ...}` clause in
`Mob.ComponentServer` — the exact mechanism the invariant guards — leaves the
component alive under a dead owner. The first sample holds a candidate and the
second reports it, with the component's id and module. Restoring the clause
returns it to `:ok`.

**It does not fire on healthy teardowns.** 60 consecutive teardowns, each with
three components carrying a queued prop backlog so they are mid-reap when the
next screen stops: **0 confirmed violations**, and the registry settles empty.
That scenario produced 60 out of 60 with the back-to-back rule.

**Cost, measured, since these ship in release builds** per
`2026-09-04-defect-reports-are-a-shipped-feature.md`. Through `run/2`, which is
what a sampling point actually does — the check, the candidate bookkeeping, and
the record on confirmation:

| registry contents | µs per sample |
|---|---|
| empty | 1.6 |
| 100 live components | 7.0 |
| 1000 live components | 62.6 |
| 100 **orphaned** | 16.2 |
| 1000 **orphaned** | 81.6 |

An earlier version cost 1764µs at 1000 orphans, because it built a map with two
`inspect/1` calls for *every* orphan and only then kept eight — slowest exactly
when a leak was largest, inside `terminate/2`, on the router's synchronous stop
path. It now takes eight first, and reads the registry with a match spec rather
than `tab2list/1`, which was also copying the `{pid, key}` reverse index.

It fires once per screen teardown, not per frame. `Mob.Invariant.cost_us/2`
re-measures one pass of each check on the device that matters; it does not
include the candidate bookkeeping, so the table above is the number to budget
against.

## Consequences

- `:on_screen_stop` samples while the stopping screen is **still alive** — it is
  running its own `terminate/2`. So `orphaned_component` never sees the screen
  that is stopping; it sees leaks left by screens that stopped earlier, one
  teardown later. That is a real property of the sampling point and is
  documented rather than papered over; a check written expecting otherwise would
  silently never fire.
- The registry and violation tables are owned by `Mob.Invariant.Owner`, an
  unlinked GenServer, for the reason MOB-155 discovered: an ETS table created
  from a screen callback dies with that screen, so an ordinary navigation pop
  would take the registry with it.
- Built-ins install from the owner's `init/1`, because `mob` has no supervision
  tree of its own. Note this is **not** opt-in: `Mob.Screen.Server.terminate/2`
  samples unconditionally, so every mob app starts the owner and installs the
  built-ins on its first screen teardown. An earlier draft of this record
  claimed an app that never touches an invariant pays nothing; that was true of
  the design before the `terminate/2` wiring landed in the same change.

- **`dead_screen_in_nav` is registered for `:periodic`, and nothing drives
  `:periodic` yet.** It is reachable only by an explicit
  `Mob.Invariant.run(:periodic, %{router: pid})`. It is not moved to
  `:on_screen_stop` on purpose: that sampling point runs inside the screen the
  router is synchronously stopping, so a check that calls back into the router
  would deadlock until both five-second timeouts expire and the router then
  kills the screen. Driving `:periodic` belongs with the defect bus in MOB-159.

- **A check must not call the router from `:on_screen_stop`**, for the reason
  above. `register/2` is public, so this is a trap worth stating rather than
  leaving to be discovered.
- Violations are bounded at 128 and carry **no application state** — pids,
  module names and counts only, the same rule receipts follow.
- Nothing consumes violations yet. There is no defect bus; `violations/1` is the
  read surface. Wiring them to a sink is MOB-159's job.
