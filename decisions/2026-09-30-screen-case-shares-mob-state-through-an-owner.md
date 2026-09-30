# `Mob.ScreenCase` shares `Mob.State` through an owner process

- Date: 2026-09-30
- Status: accepted

## Context

`Mob.ScreenCase` makes `Mob.State` available to screen tests, because many
screens read it in `mount/3`. Its setup did this per test:

    if Process.whereis(Mob.State) == nil do
      # throwaway MOB_DATA_DIR, then
      start_supervised!(Mob.State)
    end

`Mob.State` is one globally named process over a globally named `:dets` table,
and screen-test modules run `async: true`. On `master` the full suite failed
with `{:already_started, pid}` in `Mob.ScreenCaseTest` / `Mob.AnchoredTest` in
4 of 10 runs. Insider's static candidate scan reported the files clean. It does
not model globally registered processes, and it only interprets test sources,
not the `lib/` case template. Logging every setup and every `Mob.State.init/1`
caught a failing run: an `AnchoredTest` test and a `ScreenCaseTest` test both
saw `nil` 0.9 ms apart. The `AnchoredTest` supervisor registered the store, and
the `ScreenCaseTest` start failed 3.3 ms after the first check.

The same log showed a second hazard. Tests that found the store running shared
one that belonged to a test in the other module, and ExUnit stops a supervised
child when its owning test ends, whether or not anyone else is still using it.
The log could not pin down whether that happened mid-test in the failing run.

Because `Mob.ScreenCase` is in `lib/`, any app with two or more async
screen-test modules can hit both problems.

## Decision

Setup checks out a store from `Mob.ScreenCase.StateOwner`, a lazily started,
unlinked, locally registered process. It handles every checkout and check-in in
turn, which removes the race:

- The first checkout starts `Mob.State` (linked to the owner, which traps exits)
  against a throwaway `MOB_DATA_DIR`, saving the variable's previous value.
- Later checkouts share it. A `Mob.State` something else started is shared too,
  but never stopped by the owner.
- Check-in runs from `on_exit`, which ExUnit runs before it moves on. The last
  check-in stops the store, restores `MOB_DATA_DIR` and deletes the directory.
- A store that dies while checked out is replaced on the next checkout.
- Calls wait with `:infinity`. A timed-out caller would otherwise exit while its
  queued request still started or stopped the store afterwards.

Alternatives rejected:

- **One store for the whole run.** It is simpler, but `async: false` tests run
  after the async ones, and any that start `Mob.State` themselves would get
  `already_started`. `test/mob/plugins_tier4_test.exs` does, and downstream
  suites may. Stopping the store when the last screen test finishes keeps them
  working.
- **Treating `{:already_started, _}` as success.** It hides the error but keeps
  the hazard of stopping a store another test is using.

## Consequences

- Overlapping screen tests share one store, as they already did whenever their
  setups did not race. A test that runs alone still gets a fresh one.
- Screen tests are still not isolated from each other's `Mob.State` writes while
  they overlap. A screen test that needs isolation should be `async: false`.
- `test/mob/screen_case/state_owner_test.exs` pins the contract. Each of these
  mutants fails it: stopping on every check-in (the old per-test ownership),
  never stopping, returning an error for an already-running store, and not
  checking for one before starting (which moved `MOB_DATA_DIR` away from the
  external store's directory). Forty concurrent first checkouts all succeed
  and share one store.
- Stopping the store tolerates any exit. A store that died another way
  mid-stop (`:killed`, found in review) used to crash the owner before
  `MOB_DATA_DIR` was restored.
- Accepted residual risk, found in review: holders are refs, not monitored
  callers. A caller killed after its checkout is queued but before it registers
  `on_exit` leaves a holder behind, and the store is never stopped. That needs
  the owner to block the caller for an entire test timeout. Releasing when a
  caller's process dies would close it, but the test process exits before its
  `on_exit` callbacks run. So the store would stop before callbacks registered
  after ScreenCase's (they run in reverse order) could still use it, which
  breaks the guarantee this design exists for.
- On the host: 30 of 30 full-suite runs passed with the fix, against 4 of 10
  failing on `master`.
