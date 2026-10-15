# A physical iPhone loads deployed BEAMs from numbered, committed directories

- Date: 2026-10-15
- Status: accepted
- Linear: MOB-408

## Context

`mix mob.deploy` can't rewrite a physical iPhone's signed bundle, so it copies
the app's BEAMs into the app's data container with `xcrun devicectl device
copy to`, and `mob_beam.m` loads them instead of the bundle's. Until now that
was one directory, `Documents/otp/<app>`, preferred whenever it existed, and
mob_dev replaced it with `--remove-existing-content true` so removed modules
didn't linger.

That flag doesn't do what its help says ("remove files from the destination
directory"). On an iPhone (devicectl 642.16, iOS 26) it empties the app's
whole data container except the destination: the SQLite database, every other
file in Documents, `Documents/otp`'s other entries, Library and tmp. Every
BEAM deploy wiped the app's data. And a copy interrupted part-way left
`Documents/otp/<app>` incomplete, which `mob_beam.m` still preferred, so the
app could not boot until another deploy succeeded.

devicectl has no delete or rename verb. A plain copy (no flag) only adds and
overwrites, so the host can't swap a directory atomically or clean one up.

## Decision

Each deploy is a new directory, and the phone decides what to load and what
to delete (`ios/mob_code_versions.h`, run by `test/native/code_versions_test.c`):

- mob_dev uploads to `Documents/otp/<app>.versions/<N>/` with a plain copy,
  `N` above every entry already there (zero-padded to 10 digits), reads back
  `<app>.beam` to check it, then copies `<N>/.mob_complete` on its own. The
  marker is the commit.
- At boot `mob_beam.m` loads the highest `N` that has the marker; without one,
  the legacy `Documents/otp/<app>`; without that, the bundle. A copy that
  dies before its marker is never loaded, so the previous version keeps
  booting.
- Having chosen version `N`, it deletes every lower-numbered directory, marked
  or not (marker first, so a half-deleted one can't be chosen), and the legacy
  `Documents/otp/<app>`. Higher numbers without a marker are kept: one may be
  a deploy in progress. They go once a later deploy commits and boots.
- Development builds create `Documents/otp/<app>.versions/` at every boot.
  That is how mob_dev tells a runtime reads the layout: it uses it only when
  that directory exists on the phone *and* the project's mob has
  `ios/mob_code_versions.h` (so keep that file name). Otherwise it merges into
  `Documents/otp/<app>` without removing anything. See mob_dev's
  `decisions/2026-10-15-ios-deploy-never-empties-the-container.md`.

Rejected:

- **A pointer file naming the current version.** Rewriting it is the one write
  that has to be atomic, and devicectl doesn't say whether a copy replaces a
  file atomically; an emptied pointer would need a fallback scan anyway. The
  marker per directory is written once and only its existence matters.
- **Numbering from the Mac's clock.** Two Macs, or a clock set back, would
  deploy below the version already running. mob_dev numbers from the phone's
  own listing instead.
- **Collecting garbage from the Mac.** devicectl can't delete.

## Consequences

- A BEAM deploy no longer touches anything outside `Documents/otp/<app>*`
  (with mob_dev ≥ 0.7.28, whatever the runtime), and with mob ≥ 0.9.20 an
  interrupted one leaves the previous code running.
- A deploy uploads every BEAM again, as before (the old flag emptied the
  directory first). A module removed from the project is gone on the next
  versioned deploy instead of lingering.
- The first deploy after `mix mob.deploy --native` to mob ≥ 0.9.20 still goes
  to the legacy directory, because the new runtime hasn't booted to create
  `<app>.versions/`; the ones after are versioned, and the first versioned
  boot deletes the legacy directory.
- Release builds (`MOB_RELEASE`) don't create `<app>.versions/`, but still
  load what is there, as they loaded the legacy override before.
- An app downgraded below mob 0.9.20 keeps `<app>.versions/` on the phone;
  mob_dev ignores it because the project's mob lacks the header.
