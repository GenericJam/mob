# Mob.data_dir/0 is the one writable per-app dir; MOB_BEAMS_DIR is read-only

- Date: 2026-05-26
- Status: accepted

## Context
Apps need a writable place for runtime files (SQLite DBs, caches, downloaded
assets). There was no public helper, so code derived paths ad hoc — and a
Code-To-Cloud app derived its stem cache from `MOB_BEAMS_DIR`. That works on
Android (its beams dir is under the writable `filesDir`) but on iOS
`MOB_BEAMS_DIR` lives inside the signed, read-only `.app` bundle, so
`File.mkdir_p!` failed with `:eperm` and downloads silently never started. The
trap is invisible until an app ships to iOS. `Mob.State` already had the
correct `MOB_DATA_DIR || HOME || cwd` logic inline but didn't expose it.

## Decision
Add `Mob.data_dir/0` (and `data_dir/1` for a created subdir) as the public,
documented writable-dir helper, resolving `MOB_DATA_DIR` (iOS
NSDocumentDirectory, Android filesDir) with `$HOME` then cwd fallbacks, and
creating the dir. Refactor `Mob.State` to use it. The doc explicitly warns
against `MOB_BEAMS_DIR` for writes.

## Consequences
- One blessed, documented path for runtime writes; the iOS read-only-bundle
  trap is called out at the point of use.
- `Mob.State`'s host/dev fallback shifts from `cwd/priv/repo` to `cwd` only in
  the (rare) case where both `MOB_DATA_DIR` and `$HOME` are unset — on device
  and normal dev hosts the path is unchanged.
- Apps caching/downloading files should switch to `Mob.data_dir/1`.
