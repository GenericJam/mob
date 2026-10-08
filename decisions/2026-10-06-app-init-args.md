# Apps write their own Erlang init arguments to `$MOB_DATA_DIR/mob_init_args`

- Date: 2026-10-06
- Status: accepted

## Context

Operator needs Erlang distribution over TLS: `-proto_dist inet_tls` and
`-ssl_dist_optfile <file>`. Those are *init* arguments, read by `init` and
`net_kernel`, and belong after the second `--` in the BEAM's argv. The only
runtime knob mob had, `beams_dir/mob_beam_flags`, is spliced into the
*emulator* section before the first `--`, and the emulator rejects init flags
there (`beam.smp -S 1:1 -proto_dist foo -- …` exits 1 with
`unknown flag -proto_dist`). It is also written only by `mix mob.deploy`, next
to the deployed BEAMs, so a release build never has one; on iOS that directory
is inside the signed, read-only bundle unless mob_dev pushed BEAMs to
Documents.

## Decision

- A second file, `mob_init_args`, in `MOB_DATA_DIR` (Android `getFilesDir()`,
  iOS `NSDocumentDirectory`): app-private and writable by the app in every
  build, unlike the beams directory. Absent file = the old argv exactly.
- Both launchers append its tokens **after** mob's own init arguments
  (`-noshell` … `-eval`), in development and release builds. Appending, not
  prepending, means an app can't displace the arguments mob needs to boot
  (`-boot`, `-pa`, `-eval`). Repeating a flag mob already passes is not a
  supported override: `init:get_argument/1` returns every occurrence and
  readers differ in which they use. The only overlap that matters, iOS's
  development `-name`, is handled below.
- Same tokenizer shape as `mob_beam_flags` (split on space, tab, CR, LF; no
  quoting), plus NUL as a separator. The tokenizer lives in its own pure file
  per platform (`android/jni/mob_init_args.zig`, `ios/mob_init_args.h`) so it
  is tested on the host (`zig test`, `make -C test/native run`).
- Limits: a 1024-byte buffer (so 1023 bytes of file) and 63 arguments. Past
  either, the launcher keeps whole arguments only (a token cut by the buffer
  edge is dropped, never passed half), logs, and boots with the rest. The argv
  arrays are sized from these constants for the worst case on each platform
  rather than a fixed 128. `Mob.InitArgs.write/1` refuses anything over the
  limits, any empty argument and any containing whitespace or NUL, so the
  truncation path only sees hand-written files.
- `Mob.InitArgs.write/1` writes a temporary file and renames it over the old
  one, so a launch racing the write reads the old or the new file, never half
  of either.
- iOS only: if the app's arguments include `-name` or `-sname`, `mob_beam.m`
  leaves out its own development dist flags (`-name`, `-setcookie`,
  `inet_dist_listen_min/max`, `inet_dist_use_interface`) and doesn't stop the
  boot over a busy mob dist port. Two `-name` flags would leave the node name
  to argv order; the app asking for its own name owns distribution. Without
  such a token nothing changes. Android needs no equivalent: it never starts
  distribution at boot (the hwui race, see `Mob.Dist`), so apps there set
  transport flags as init arguments and still start distribution at runtime.
- Release behaviour is otherwise unchanged: release builds still add no mob
  dist flags and (iOS) run no in-process EPMD.

## Consequences

- A bad init argument can stop the BEAM booting, and no Elixir code then runs
  to undo it; recovery is clearing app data or reinstalling. `Mob.InitArgs`
  documents this; mob deliberately doesn't validate flag semantics, only the
  shape the launcher can carry.
- The `-name` check is a plain token match: an app passing `-name` as the
  *value* of another flag would also suppress mob's dist flags. No real flag
  takes `-name` as a value.
- On iOS release builds an app that names its node needs an EPMD-less setup
  (`-start_epmd false` with `-erl_epmd_port`), since mob runs no EPMD there.
- CI installs the pinned Zig toolchain and runs the Android tokenizer tests;
  the macOS native harness compiles and runs the iOS tokenizer plus the shared
  argv placement and development/release distribution policy. The two
  tokenizers remain separate implementations of one format, so both suites pin
  the same boundary cases.
