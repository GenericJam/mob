# Common Fixes & Pitfalls

## `+C` flags crash BEAM silently on Android (exit(1), no logcat output)

**Symptom**: App exits cleanly with code 1 within ~60ms of `erl_start`. No Erlang code
runs (no diagnostic files written). BEAM stderr goes to `/dev/null` on Android, so no
error message is visible in logcat. The last logcat line is the symlink logs from
`mob_start_beam`.

**Root cause**: `erl_start` is called directly (bypassing `erlexec`). The BEAM arg
parser in `erl_start` requires all emulator flags to start with `-`. Any `+`-prefixed
arg (e.g. `+C multi_time_warp`) hits:

```c
if (argv[i][0] != '-') erts_usage();   // → exit(1) with no output
```

`erlexec` normally translates `+` flags to `-` before passing them to the BEAM, but
mob_beam.c calls `erl_start` directly.

**Fix**: Use `-C multi_time_warp` instead of `+C multi_time_warp`. Or omit it entirely
— `multi_time_warp` is already the default in OTP 28 (erts-16.3).

**Fixed in**: `mob/android/jni/mob_beam.c` — removed `"+C", "multi_time_warp"` from
`BEAM_EXTRA_FLAGS` (2026-04-14).

---

## Android BEAM stderr is silent

All ERTS error output (arg parse errors, boot failures, `erts_usage()`) goes to fd 2
(stderr). On Android, stderr from JNI threads goes to `/dev/null`, not logcat.

To capture BEAM stderr for diagnosis, redirect fd 2 to a file before calling
`erl_start`:

```c
char stderr_log[580];
snprintf(stderr_log, sizeof(stderr_log), "%s/beam_stderr.log", s_files_dir);
int fd = open(stderr_log, O_CREAT | O_WRONLY | O_TRUNC, 0644);
if (fd >= 0) { dup2(fd, STDERR_FILENO); close(fd); }
```

Then after crash: `adb shell "run-as com.mob.demo cat /data/user/0/com.mob.demo/files/beam_stderr.log"`

---

## iOS BEAM crashes with `eaddrinuse` when Android is also connected

**Symptom**: iOS simulator app exits immediately. `xcrun simctl launch --console` shows:
`Protocol 'inet_tcp': register/listen error: eaddrinuse`

**Root cause**: `mob_beam.m` defaults to dist port 9100 when `MOB_DIST_PORT` is not set.
When an Android device is connected, `adb forward tcp:9100 tcp:9100` is active and holds
port 9100 on localhost. The iOS BEAM tries to bind the same port for Erlang distribution
and fails.

**Fix**: Default iOS dist port changed from 9100 → 9101 in `mob/ios/mob_beam.m`.
Per the port assignment scheme: Android = 9100, iOS sim = 9101.
Requires a native rebuild (`mix mob.deploy --native --ios`).

**Fixed in**: `mob/ios/mob_beam.m` (2026-04-14).

---

## Dashboard LiveView crash: `process_keyed/5 ArgumentError`

**Symptom**: `mob_dev` Phoenix LiveView server crashes with `ArgumentError` in
`Phoenix.LiveView.Diff.process_keyed/5` during rapid log ingestion.

**Root causes (three separate issues)**:
1. `phx-update="stream"` and `phx-hook="ScrollBottom"` on the **same** element — explicitly
   prohibited by LiveView. Hook must be on an outer wrapper; stream on an inner element.
2. Variable name collision: loop variable `line` used in both deploy output `:for` and
   the stream `:for` iterator.
3. Double `:if` directives inside stream items — use `<%= if %>...<% else %>...<% end %>`
   instead.

**Fixed in**: `mob_dev/lib/mob_dev/server/live/dashboard_live.ex` — converted log list
to a Phoenix stream, separated hook/stream elements, renamed loop variable.

---

## `mix mob.deploy` silently skips updating BEAM files

**Symptom**: `mix mob.deploy --ios` reports "Pushing N BEAM file(s) ✓" but the deployed
beams in `/tmp/otp-ios-sim/<app>/` retain old timestamps and old content (e.g. `mob_nif.beam`
missing `log/2` export even after force-recompiling the dep).

**Root cause**: `Deployer.deploy_ios/3` runs `System.cmd("cp", ["-r", "#{dir}/.", dest])`
where `dir` is a relative path like `_build/dev/lib/mob_demo/ebin`. `System.cmd` spawns an
OS subprocess that uses the **OS process CWD**, not the Erlang process CWD. Mix sets the
Erlang CWD to the project root via `:file.set_cwd`, but this doesn't affect the OS CWD of
spawned subprocesses. If the two differ (e.g. because Mix compiled a dep in a sub-directory),
the relative path resolves to the wrong location and `cp` silently exits 0 with no matching
source files.

**Fix**: Use `Path.expand(dir)` before passing to `System.cmd`, which resolves the relative
path against `File.cwd!()` (the Erlang process CWD, correctly set to the project root).

**Fixed in**: `mob_dev/lib/mob_dev/deployer.ex` — both `deploy_ios/3` and
`push_beams_android/2` now use `Path.expand(dir)` (2026-04-14).

---

## Android crash: OTP spawns local `epmd` that conflicts with ADB reverse tunnel

**Symptom**: Distribution fails or crashes when `mix mob.connect` is active. OTP's
`Node.start/2` tries to spawn a local `epmd` that also binds port 4369, conflicting
with the ADB reverse tunnel listener (`adb reverse tcp:4369 tcp:4369`).

**Root cause**: `mix mob.connect` runs `adb reverse tcp:4369 tcp:4369`, which creates a
listener on device port 4369 forwarded to Mac EPMD. When `Node.start/2` is called, OTP
attempts to spawn a local `epmd` daemon that also tries to bind port 4369 — conflicting
with the ADB listener.

**Fix**: Set `:kernel` env `start_epmd: false` before calling `Node.start/2`, which
prevents OTP from spawning a local EPMD. Additionally, poll port 4369 before starting
distribution — if the ADB tunnel isn't up (standalone launch, no `mix mob.connect`),
skip distribution entirely rather than crashing. Timeout is 10 seconds.

The polling also acts as a synchronization barrier: distribution only starts once the Mac
EPMD is actually reachable, eliminating the timing race.

If no EPMD appears within 10s, `Mob.Dist` logs:
`"Mob.Dist: no EPMD on port 4369 after 10s — skipping dist (run mix mob.connect to enable)"`

**Fixed in**: `mob/lib/mob/dist.ex` — `start_after/4` now calls `wait_for_epmd/1` and
sets `start_epmd: false` before `Node.start/2` (2026-04-15).

---

## Android BEAM crashes every time after first deploy — `mix mob.connect` missing chcon

**Symptom**: App works on first `mix mob.deploy` but crashes every subsequent time
`mix mob.connect` relaunches it. Logcat shows:

```
E MobBeam: mob_start_beam: symlink erl_child_setup failed: Permission denied
E MobBeam: mob_start_beam: symlink inet_gethost failed: Permission denied
E MobBeam: mob_start_beam: symlink epmd failed: Permission denied
W beam-main: avc: denied { search } scontext=u:r:untrusted_app:s0:c19,...
                                    tcontext=u:object_r:app_data_file:s0:c2,...
```

And `files/erl_crash.dump` contains:
```
Slogan: Runtime terminating during boot ({undef,[{mob_demo,start,[],[]}, ...]})
```

Or a SIGABRT tombstone from inside `mob_start_beam`/`erl_start`.

**Root cause (two-part)**:

1. **SELinux MCS mismatch**: When the APK is installed/reinstalled, Android assigns the
   package a pair of MCS categories (e.g. `c19,c257,c512,c768`). Files in `files/otp/`
   pushed via `adb push` retain whatever category they had at push time (e.g. `c2`). The
   app process runs with `c19` but the OTP directory has `c2` → SELinux denies access →
   symlink creation fails → `erl_start` calls `abort()` → SIGABRT.
   `mix mob.deploy` runs `chcon` to fix this, but `mix mob.connect` (which calls
   `Android.restart_app`) did NOT run `chcon` before `am start`.

2. **Missing `mob_demo/` BEAMs**: If only `mix mob.connect` (not `mix mob.deploy`) was
   run, the app BEAM files in `files/otp/mob_demo/` may not exist. The BEAM starts but
   `mob_demo:start()` is `undef` → clean OTP exit (not a crash signal, no auto-restart).

**Fix**: Added `chcon -R $(stat -c %C .../files) .../files/otp` to `Android.restart_app`
in `mob_dev/lib/mob_dev/discovery/android.ex`. Now both `mob.deploy` and `mob.connect`
heal the SELinux labels before starting the app.

**Fixed in**: `mob_dev/lib/mob_dev/discovery/android.ex` — `restart_app/4` now runs
`chcon` before `am start` (2026-04-15).

---

## Android symlink permission denied after APK reinstall

**Symptom**: App crashes on every launch after reinstalling the APK. Logcat shows:

```
E MobBeam: mob_start_beam: symlink erl_child_setup failed: Permission denied
E MobBeam: mob_start_beam: symlink inet_gethost failed: Permission denied
E MobBeam: mob_start_beam: symlink epmd failed: Permission denied
```

The BEAM never starts. The app appears to open but immediately goes blank.

**Root cause**: Android assigns each app a pair of SELinux MCS categories (e.g.
`c9,c257,c512,c768`). These are embedded in the labels on the app's data directory
by `installd` at install time. When an APK is reinstalled, Android may assign a *new*
category pair. Files already present in the data directory (pushed by `adb push`) retain
their old categories. The process then can't access files labeled with a different category —
SELinux MCS isolation blocks it even though both use the `app_data_file` type.

Diagnosis — compare the process category with the file category:
```
# App's current category (from parent dir, always correct):
adb shell ls -laZ /data/user/0/com.mob.demo/

# OTP files' category (may be stale):
adb shell ls -laZ /data/user/0/com.mob.demo/files/otp/erts-16.3/bin/erl_child_setup
```
A mismatch in the first MCS number (e.g. `c9` vs `c2`) is the tell.

**Why `restorecon` doesn't fix it**: `restorecon` only restores the *type label*
(`app_data_file`). MCS categories are not part of the file_contexts policy — they are
set per-package by `installd` and `restorecon` leaves them unchanged.

**Fix**: Use `chcon` to copy the correct context from the app's own `files/` directory
(which `installd` always keeps correctly labeled) to the OTP tree:

```bash
# One-liner on device:
chcon -R $(stat -c %C /data/user/0/com.mob.demo/files) /data/user/0/com.mob.demo/files/otp
```

In the deployer, this runs automatically via `restart_android` (before `am start`) and
`push_beams_android` (after `adb push`).

**Fixed in**: `mob_dev/lib/mob_dev/deployer.ex` — replaced both `restorecon` calls with
`chcon -R $(stat -c %C <files_dir>) <otp_dir>` (2026-04-15).

---

## Android "screen wipe" when backgrounding / resuming the app

**Symptom**: When the app is backgrounded and then resumed, the screen briefly goes
black or white (a "wipe") for 1–2 frames before the UI reappears. The app content
visually disappears and snaps back.

**Root causes (two separate issues)**:

1. **`Theme.NoTitleBar` white `windowBackground`**: The default system theme has a white
   `windowBackground`. Android briefly shows the window background during the 1–2 frame
   gap between recreating the window surface and Compose drawing the first frame on resume.
   With a white background the flash is highly visible. Changing it to black makes it
   imperceptible (matches the app's dark default background).

2. **Missing `android:configChanges`**: Without this, any system configuration change
   (rotation, font scale, display density, keyboard availability, etc.) destroys and
   recreates the Activity. This calls `nativeStartBeam()` a second time on an already-
   running BEAM — undefined behavior (likely crash or silent second BEAM instance).
   Declaring all expected config changes prevents Activity recreation entirely; Compose
   handles them in-process.

**Fix**:

1. Create `app/src/main/res/values/styles.xml`:
   ```xml
   <style name="AppTheme" parent="android:style/Theme.NoTitleBar">
       <item name="android:windowBackground">@android:color/black</item>
       <item name="android:windowAnimationStyle">@null</item>
       <item name="android:windowNoTitle">true</item>
   </style>
   ```
   (`windowAnimationStyle` is cleared so system window open/close slide animations
   don't fight Compose's own nav transitions.)

2. In `AndroidManifest.xml`:
   - Change `android:theme` on `<application>` from `@android:style/Theme.NoTitleBar`
     to `@style/AppTheme`
   - Add to `<activity>`:
     ```
     android:configChanges="orientation|screenSize|screenLayout|keyboard|keyboardHidden|navigation|uiMode|fontScale|density"
     ```

**Fixed in**: `mob_demo/android/app/src/main/res/values/styles.xml` (created) and
`mob_demo/android/app/src/main/AndroidManifest.xml` — theme + configChanges (2026-04-15).
