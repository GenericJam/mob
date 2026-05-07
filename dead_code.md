# Dead Code Triage — `mix_unused` baseline

`mix_unused` (Hauleth) integrated into `mob/` and `mob_dev/` as a
dev-only `:unused` compiler tracer. Captures baseline of "may be dead"
public functions for future cleanup. **Not actionable in one
session**; this doc tracks what was found so future passes can chip
away at it.

## How to run

```bash
cd ~/code/mob_dev   # or ~/code/mob
mix compile --force 2>&1 | grep hint:
```

The tracer fires on every `mix compile` in dev. Hints look like:

```
hint: MobDev.Foo.bar/1 should be private (is not used outside defining module)
hint: MobDev.Foo.baz/0 is unused
```

## Two hint flavors

- **"should be private"** — `def` that's only called from within its
  defining module. These should be `defp`. Pure cleanup, no behavior
  change. Genuinely actionable.
- **"is unused"** — `def` not called anywhere in the project. Often
  false positives in library code (the real callers live in
  downstream projects). Still worth eyeballing for genuinely-dead
  functions left from refactors.

## Baseline (2026-05-06)

| Repo | should-be-private | is-unused | Total |
|---|---:|---:|---:|
| `mob_dev` | 72 | 48 | 120 |
| `mob` | 23 | 164 | 195 |

`peer_net` not yet integrated.

### `mob_dev` top buckets (`is unused` only — possibly genuine)

| Bucket | Count | Notes |
|---|---:|---|
| `MobDev.OtpTrace.*` | 29 | Probably dispatch-via-`apply` — Pass 5 work |
| `MobDev.Bench.*` | 14 | Battery bench harness — exposed for diag |
| `MobDev.SecurityScan.*` | 10 | New module; some hints will resolve as the wiring lands |
| `MobDev.IconGenerator.*` | 7 | Documented public-seam in CLAUDE.md |
| `MobDev.NativeBuild.*` | 5 | Mostly should-be-private |

### `mob` top buckets (`is unused` only — almost all false positives)

| Bucket | Count | Notes |
|---|---:|---|
| `Mob.Device` | 21 | Public capability API; called by user apps |
| `Mob.Event` | 19 | Public event constructors |
| `Mob.Storage` | 13 | Public DETS API |
| `Mob.Screen` / `Mob.Socket` / `Mob.Canvas` / `Mob.Audio` / `Mob.UI` | 7-8 each | Public framework API |

`mob` is a library — the "unused" set is mostly *its public API not
called from itself*, which is correct behavior for a library.

## Triage strategy

Don't bulk-fix the lists. Instead:

1. **Should-be-private wins first.** Each is an isolated refactor:
   change `def` to `defp`, run tests, done. If a test breaks, the
   function was dispatched dynamically — add to ignore list. Estimate
   ~5 min per function for the careful ones, batchable ~50/hour.

2. **Tackle by-module, not by-list.** Fix all hints in
   `Mob.UI.Foo` in one go — local context loaded.

3. **For library "unused" hints**: only investigate when refactoring
   that module anyway. Don't burn cycles trying to prove every public
   function is reachable from somewhere.

4. **Update the ignore list** in `mix.exs` if a hint is a stable
   false positive (e.g., a documented test seam). Don't silence
   broadly; keep the ignore list precise.

5. **Re-run periodically.** After every refactor or feature land,
   `mix compile --force | grep hint:` and look for *new* hints,
   not the absolute count.

## Why not auto-fix

- mix_unused can't see `apply/2,3`, message dispatch, behaviour
  callbacks, or callers in downstream apps.
- A false-positive auto-fix that deletes a documented public function
  silently breaks user apps. Manual triage is the safe move.

## Pre-extraction note

`lean_release_extraction.md` (in `mob_dev/`) describes extracting
`OtpAudit` + the slim toolchain to a standalone Hex package
(`lean_release`). The `mix_unused` integration above is incidental —
not part of the extraction. The extraction concerns reachability
analysis on *shipped artifacts* (release trees), not source-level
dead code.
