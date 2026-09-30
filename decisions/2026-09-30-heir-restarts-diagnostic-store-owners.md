# The heir restarts a dead diagnostic store owner

- Date: 2026-09-30
- Status: accepted
- Linear: MOB-302

## Context

`2026-09-30-diagnostic-stores-share-one-hardened-owner.md` gave every
diagnostic table `Mob.Diag.Heir` as its ETS heir and said the next owner takes
the tables back. Nothing started a next owner. `Mob.Diag.Store.ensure/1` checks
only that the store's flag table exists. The heir held that table, so the write
path never called an owner again.

On a Moto G (Android 15), the `Mob.Agent.Receipts` owner was killed. Three
writes, an `ensure/1` and three seconds later, `Mob.Diag.health/0` still showed
`owner: nil`, with the table `held_by: :heir`. Killing the heir then deleted all
seven receipts, counted as `resets: 1`. The heir had not prevented the loss,
only delayed it.

## Decision

When the heir receives `{:"ETS-TRANSFER", table, old_owner, store}`, it starts a
replacement owner. The owner's existing setup takes the tables back with
`give_back/2`.

- **In a spawned process.** The new owner's `init/1` calls `give_back/2`, which
  is a call into the heir. If the heir started the owner itself, the two would
  deadlock. A store that fails to start must also not take down the heir, which
  holds every other store's orphaned tables.
- **After the old owner is down.** An exiting process passes its ETS tables on
  before its monitors fire. The restarter monitors the old owner and starts the
  replacement only after `:DOWN`, so one setup finds every table with the heir.
  If it started on the first transfer, setup could run while later tables still
  belonged to the dying owner. Setup leaves such tables alone as `:other`.
- **Once per death, never in a loop.** `Mob.Diag.Store.owner_generation/1` is the
  store's `owner_starts` count, paired with its `:atomics` ref so it never
  repeats. `init/1` bumps the count only after its setup succeeds. The heir
  restarts a store only when the generation has moved since its last restart of
  that store:
  - One death transfers several tables, but only one owner starts.
  - Suppose an owner takes its tables back during setup and then dies, from a
    crashing `after_setup/0`, say. It has not moved the generation, so its
    tables stay with the heir. They are not restarted forever.

  A failed start is logged.
- **Start or set up, not both.** `Mob.Diag.Store.restart/1` starts an owner,
  whose `init/1` sets up. Someone else's `ensure/1` or `reload/1` may have
  taken the name first. `GenServer.start/3` then returns
  `{:already_started, pid}` without running `init/1`. That owner is asked to set
  up again, because it may have set up before the heir had the tables. A fresh
  owner is not set up twice.
- **Only stores.** Heir data can name a module that is no longer loaded, or no
  longer implements `Mob.Diag.Store`, because a hot push removed it. The heir
  skips it, and its tables stay with the heir. A module with no state entry
  never had an owner finish setup, so the heir skips it without spawning
  anything. Tables that an older `mob`'s owner holds never name this heir, so
  they are unaffected.

Alternatives rejected:

- **Restart from `ensure/1`.** Checking the owner as well as the flag table
  puts a registry lookup on every write. It would also leave a store that
  nobody writes to orphaned, so its rows would die with the heir.
- **Restart inline in the heir.** It deadlocks on `give_back/2`. It also runs
  store code in the one process that holds every store's orphaned tables.
- **The heir monitors owners that announce themselves.** That is exact per
  death, but it needs a new protocol between owner and heir, and owners would
  have to announce themselves again after each heir restart. The generation
  count already exists.
- **Backoff or rate limits against a crash loop.** These are time constants.
  The fact that matters, whether the owner finished starting, is already known.

## Consequences

- In `Mob.Diag.health/0`, `owner: nil` is now transient. If an owner stays `nil`
  while the heir holds its tables, the restart failed and the reason was
  logged. The next setup, from `reload/1` or a state-version change, takes the
  tables back.
- Each owner death costs one spawned process and one owner start.
- If an owner dies while its own restart is failing, no further restart
  follows. That is the price of never looping.
- A test that stops an owner must delete its tables first. Otherwise the heir
  starts another owner under the test's teardown. A test that kills an owner
  waits for the replacement. See `test/mob/diag/store_test.exs` and
  `test/mob/agent/receipts_store_test.exs`.
- Verified on the host. `test/mob/diag/store_test.exs` fails:
  - when the heir ignores transfers (six tests);
  - when it restarts once per transfer, or sets a fresh owner up twice (the
    test that each death gets one restart);
  - when it dedupes per dying owner rather than per generation (the crash
    loop).

  Two guards have no failing test that fails every time:
  - The store check on heir data fails its test in about nine runs of ten.
    Without the check, the only effect is a logged failed start, and a test
    cannot wait for something that never happens.
  - The wait for `:DOWN` relies on ERTS passing a process's ETS tables on
    before firing its monitors. In 2,000 kills of an owner with five tables,
    every table was already with the heir at `:DOWN`. No test can make the
    transfers slower than a restart.
