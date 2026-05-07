# Common Fixes & Pitfalls

## Android NIFs must be statically linked, never `dlopen`'d

**Symptom**: BEAM's `erlang:load_nif/2` fails on Android with
`dlopen failed: cannot locate symbol "enif_get_tuple" referenced by ".../foo.so"`.
Happens for any NIF library shipped as a `.so` rather than a static
`.a` linked into the app's main native lib (e.g. `libpigeon.so`).

**Root cause**: Android's dynamic linker loads native libs with
`RTLD_LOCAL` by default — Java's `System.loadLibrary` doesn't take a
flags arg. The BEAM's `enif_*` API functions are statically linked
into `libpigeon.so` (via `libbeam.a`). When the BEAM later
`dlopen`s a NIF, that NIF can't see `libpigeon.so`'s symbols —
`RTLD_LOCAL` hides them from siblings/children.

**Things that don't fix it (we tried)**:

- `-Wl,--export-dynamic` on the parent's link. Adds symbols to the
  dynamic symbol table, but Android's loader honours the flags the
  parent was originally loaded with, not what's marked exported.
- Re-`dlopen`ing the parent from inside its own JNI code with
  `RTLD_NOW | RTLD_GLOBAL`. The call returns a non-NULL handle, but
  subsequent `dlopen`s still can't see the parent's symbols. Per
  bionic source, `RTLD_GLOBAL` only affects the children of a lib
  loaded that way; it doesn't retroactively promote a lib already
  loaded `RTLD_LOCAL`.

**Fix**: build the NIF as a static `.a`, ship it in the OTP tarball at
`erts-VSN/lib/<name>.a`, and link it into the app's main native lib via
`target_link_libraries(... -Wl,--whole-archive ${OTP_DIR}/${ERTS_VSN}/lib/<name>.a -Wl,--no-whole-archive ...)`.

For OTP-internal NIFs (`crypto`, `asn1rt_nif`), pass `--enable-static-nifs`
to OTP `configure` so they're compiled with `-DSTATIC_ERLANG_NIF` and
registered in the generated `erts_static_nif_tab[]`. The BEAM then
resolves the NIF via `dlsym(RTLD_DEFAULT, "<modname>_nif_init")`
without ever calling `dlopen`.

**Implication for app developers**: any custom NIFs added to a mob
app must follow the same pattern — static `.a` (with
`-DSTATIC_ERLANG_NIF_LIBNAME=<name>`), linked into the app's
`CMakeLists.txt`. Dynamic NIF `.so` files won't work on Android.

---

## Cross-compiling OTP for Android on macOS produces empty `.a` archives

**Symptom**: `./otp_build boot --xcomp-conf=./xcomp/erl-xcomp-arm64-android.conf`
fails at the `erl_call` link step with hundreds of `undefined symbol: ei_*` errors.
`lib/erl_interface/obj/aarch64-unknown-linux-android/libei.a` exists but is exactly
**96 bytes** — an empty ar archive containing only the symbol table header.
Every `.o` file under `obj.mt/<arch>/` and `obj.st/<arch>/` exists fine.

**Root cause**: macOS's BSD `ar` (`/usr/bin/ar`) silently rejects ELF object files
with `ranlib: warning: archive member 'foo.o' not a mach-o file` and emits an
empty `.a`. The OTP xcomp configs (`erl-xcomp-arm64-android.conf`, `erl-xcomp-arm-android.conf`,
etc.) override `CC` and `LD` for the NDK toolchain but leave `AR=ar` and
`RANLIB=ranlib` as defaults — so they fall through to `/usr/bin/ar`. The `rcv`
flag still exits 0, so `make` proceeds to the `erl_call` link step where the
empty libei.a manifests as undefined symbols.

Reproducer:
```bash
cd /tmp && touch a.o b.o && /usr/bin/ar rcv test.a a.o b.o
# warning: archive member 'a.o' not a mach-o file
ls -la test.a   # → 96 bytes (empty)
```

**Fix**: Add `AR="llvm-ar"` and `RANLIB="llvm-ranlib"` to the xcomp conf
(both ship in every NDK toolchain at
`$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/`). Re-running `./otp_build configure`
regenerates the per-arch Makefiles with the correct `AR`/`RANLIB`, and libei.a
fills with the ~70 expected `.o` files (~3.5 MB).

**Fixed in**: `~/code/otp/xcomp/erl-xcomp-arm64-android.conf` (and arm32 conf).
Should be upstreamed to `otp/xcomp/erl-xcomp-*android.conf` since this affects
any macOS-host Android cross-build.

---

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

## `mix mob.deploy` code pushed but screen didn't update (dist hot-load needs re-render trigger)

**Symptom**: `mix mob.deploy` reports `✓ (dist, no restart)` — code was pushed, no error —
but the running app looks unchanged. Tapping a button or navigating away and back causes
the new code to appear.

**Root cause**: Erlang hot code loading (`code:load_binary`) replaces the module in the
code server immediately, but does **not** cause any running process to re-execute. The
`Mob.Screen` GenServer is sitting in its receive loop waiting for the next message. Until
something sends it a message, `render/1` is never called again — so the display stays as-is
even though the new code is live in memory. This is standard Erlang behaviour, not a bug in
the BEAM, but it's non-obvious when you expect to see visual feedback immediately.

The condition for this to occur: the iOS app is running with Erlang distribution active
(which it always is after `mix mob.deploy --native`). iOS shares the Mac's network stack, so
`mob_dev` can connect to the device node without any tunnel setup. When it connects, it
prefers the dist hot-load path over the filesystem + restart path.

Android is not affected by this issue in the same way — the Android dist path requires adb
tunnels that the deployer doesn't set up, so Android always falls through to the filesystem
push + restart path.

**Fix**: After a successful dist push, `mob_dev` now sends `:__mob_hot_reload__` to the
`:mob_screen` registered process on the device via `:rpc.call`:

```elixir
:rpc.call(node, :erlang, :send, [:mob_screen, :__mob_hot_reload__])
```

`Mob.Screen`'s `handle_info` catch-all receives it, delegates to the user module (which
ignores unknown messages), then calls `do_render/2` with the current version of the screen
module. The screen repaints immediately with no restart and no loss of GenServer state.

**Fixed in**: `mob_dev/lib/mob_dev/deployer.ex` — `push_via_dist/2` now sends the
re-render message after `HotPush.push_all/1` (2026-04-21).

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

---

## Android WebView black screen in LiveView apps (`"webview"` vs `"web_view"` type mismatch)

**Symptom**: LiveView app on Android shows a completely black screen. iOS works fine.
No WebView-related log output (no `chromium` tag entries in logcat). Erlang distribution
confirms the `:mob_screen` GenServer is mounted (`platform: :android`, `safe_area` set,
`root_view: :json_tree`), but nothing renders.

**Root cause**: `Mob.UI.webview/1` returns `%{type: :web_view, ...}` (underscore). The
Elixir renderer serialises this to JSON as `"type": "web_view"`. The iOS NIF maps `"web_view"`
correctly. However, `MobBridge.kt`'s `RenderNode` `when` clause used `"webview"` (no
underscore), so the type never matched and `MobWebView` was never called. The
`AnimatedContent` root remained `null` — the Compose UI was blank.

**Fix**: In `MobBridge.kt`, change the `RenderNode` when clause:
```kotlin
// Before:
"webview"  -> MobWebView(node, m)
// After:
"web_view" -> MobWebView(node, m)
```

**Fixed in**: `mob_new/priv/templates/mob.new/android/app/src/main/java/MobBridge.kt.eex`
and all existing projects — `mob_demo`, `my_app2`, `pegleg_test`, `smoke_test`,
`sqlite_test`, `sqlite_alt`, `liveview_test` (2026-04-25).

---

## Android WebView `ERR_CLEARTEXT_NOT_PERMITTED` for localhost

**Symptom**: After fixing the type mismatch above, the WebView renders but shows
"Webpage not available — net::ERR_CLEARTEXT_NOT_PERMITTED" when trying to load
`http://127.0.0.1:4200/`.

**Root cause**: Android 9+ (API 28+) blocks plain HTTP (cleartext) traffic by default
via the Network Security Configuration policy. The LiveView endpoint runs on plain HTTP
at `127.0.0.1:4200`, which is blocked without an explicit exception.

**Fix**: Add a network security config that permits cleartext to `127.0.0.1` and
`localhost`, and reference it from `AndroidManifest.xml`:

1. Create `android/app/src/main/res/xml/network_security_config.xml`:
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <network-security-config>
       <domain-config cleartextTrafficPermitted="true">
           <domain includeSubdomains="false">127.0.0.1</domain>
           <domain includeSubdomains="false">localhost</domain>
       </domain-config>
   </network-security-config>
   ```

2. In `AndroidManifest.xml`, add to `<application>`:
   ```xml
   android:networkSecurityConfig="@xml/network_security_config"
   ```

**Fixed in**: `mob_new/priv/static/mob.new/android/app/src/main/res/xml/network_security_config.xml`
(created) and `mob_new/priv/templates/mob.new/android/app/src/main/AndroidManifest.xml.eex`.
All existing projects patched (2026-04-25).

Note: `mix mob.enable liveview` already had `android_add_liveview_network_config` which
does the same thing, but `mix mob.new --liveview` did not call it during generation.

---

## `Mob.Screen` crashes on `:__mob_hot_reload__` GenServer cast

**Symptom**: After running `mix mob.deploy`, logcat shows the `:mob_screen` GenServer
terminating with `"attempted to cast GenServer :mob_screen but no handle_cast/2 clause
was provided"`. The screen goes blank and requires an app restart.

**Root cause**: Something sends `:__mob_hot_reload__` to `:mob_screen` as a `GenServer.cast`
(wrapped in `{:"$gen_cast", :__mob_hot_reload__}`). `Mob.Screen` used `use GenServer` but
defined no `handle_cast/2`, so any cast terminates the process.

Note: `mob_dev`'s deployer sends the message via `:erlang.send` (plain message to
`handle_info`), not as a cast. If you see a cast arriving, check for older deployed
mob_dev code on the device.

**Fix**: Added `handle_cast/2` to `Mob.Screen` that re-renders on hot reload:
```elixir
def handle_cast(:__mob_hot_reload__, {module, socket, nav_history, render_mode}) do
  new_socket = if render_mode == :render, do: do_render(module, socket), else: socket
  {:noreply, {module, new_socket, nav_history, render_mode}}
end
```

**Fixed in**: `mob/lib/mob/screen.ex` (2026-04-25).

---

## iOS BEAM crashes when `Mob.Test.pop` / `pop_to_root` is called via distribution

**Symptom**: `Mob.Test.pop(node)`, `Mob.Test.pop_to(node, ...)`, or
`Mob.Test.pop_to_root(node)` causes the iOS node to crash immediately. The node
goes offline; `Node.list/0` no longer shows it.

**Root cause**: The pop NIFs (`nif_nav_pop`, `nif_nav_pop_to_root`) mutate the
SwiftUI `NavigationPath` from the Erlang distribution thread. SwiftUI requires all
state mutations to happen on the main thread. The push path runs on the main thread
(guarded by a `DispatchQueue.main.async` block); the pop path does not.

**Status**: Not yet fixed. Push navigation (`navigate/3`) is safe.

**Workaround**:
- Use `Mob.Test.navigate(node, SomeScreen)` to drive the app forward instead of back.
- Drive backward navigation via native UI tap using the MCP simulator tools
  (`mcp__ios_simulator__ui_tap` on the Back button) rather than `Mob.Test.pop`.
- In automated tests, structure flows so pop is unnecessary — navigate forward to
  reset state, or restart the app.

---

## arm32 Android OTP: `asn1rt_nif.a` not built by cross-compile

**Symptom**: CMake/ninja build fails with:

```
ninja: error: '.../erts-16.3/lib/asn1rt_nif.a', needed by 'libsmoketest.so', missing
```

Only happens for `armeabi-v7a` (arm32) targets. arm64 and iOS builds are unaffected.

**Root cause**: OTP's build system emits `asn1rt_nif.a` for arm64 and iOS cross-compile
targets but silently skips it for arm32 (`arm-unknown-linux-androideabi`). The static
NIF table in `driver_tab_android.c` references the symbol `asn1rt_nif_nif_init`, which
must come from this library.

**Critical detail**: The file must be compiled with `-DSTATIC_ERLANG_NIF_LIBNAME=asn1rt_nif`.
Without this flag the init symbol is `nif_init`, not `asn1rt_nif_nif_init`, and the linker
will fail with an undefined symbol at link time even though the `.a` file exists.

**Fix**: Compile manually and place at `erts-<vsn>/lib/asn1rt_nif.a` in the tarball:

```bash
NDK=~/Library/Android/sdk/ndk/27.2.12479018/toolchains/llvm/prebuilt/darwin-x86_64/bin
OTP_SRC=~/code/otp

$NDK/armv7a-linux-androideabi21-clang \
  -march=armv7-a -mfloat-abi=softfp -mthumb \
  -fvisibility=hidden -fno-common -fno-strict-aliasing \
  -fstack-protector-strong -O2 \
  -I "$OTP_SRC/erts/arm-unknown-linux-androideabi" \
  -I "$OTP_SRC/erts/include/arm-unknown-linux-androideabi" \
  -I "$OTP_SRC/erts/emulator/beam" \
  -I "$OTP_SRC/erts/include" \
  -DHAVE_CONFIG_H \
  -DSTATIC_ERLANG_NIF_LIBNAME=asn1rt_nif \
  -c "$OTP_SRC/lib/asn1/c_src/asn1_erl_nif.c" \
  -o /tmp/asn1rt_nif_arm32.o

$NDK/llvm-ar rc /tmp/asn1rt_nif_arm32.a /tmp/asn1rt_nif_arm32.o
$NDK/llvm-ranlib /tmp/asn1rt_nif_arm32.a
```

**Fixed in**: `mob_dev/build_release.md` — documents the arm32 compilation requirement
and the correct compile command (2026-04-25).

---

## macOS `tar` inserts `._` Apple Double sidecar files into archives

**Symptom**: When pushing OTP or BEAM files to an Android device, Toybox tar on the
device prints a stream of errors like:

```
tar: chown 501:20 '._.': Operation not permitted
tar: chown 501:20 '._liberl_child_setup.so': Operation not permitted
```

The `._<filename>` entries are macOS Apple Double metadata files that macOS `tar`
silently inserts into archives. On Android, Toybox tar tries to restore the macOS
owner (UID 501, GID 20) and fails because the device doesn't have those users.

**Root cause**: macOS `tar` writes AppleDouble sidecar files by default when archiving
on HFS+/APFS. The environment variable `COPYFILE_DISABLE=1` disables this behaviour.

**Fix**: Set `COPYFILE_DISABLE=1` in the environment of every macOS `tar` create call:

```elixir
System.cmd("tar", ["czf", out, ...], env: [{"COPYFILE_DISABLE", "1"}])
```

**Fixed in**: `mob_dev/lib/mob_dev/deployer.ex` and `mob_dev/lib/mob_dev/native_build.ex`
— all `tar` archive creation calls now pass `env: [{"COPYFILE_DISABLE", "1"}]` (2026-04-25).

---

## Toybox tar on Android 10 exits 1 on chown failure even when extraction succeeds

**Symptom**: `run-as <pkg> tar xf ...` exits with code 1, causing `mob_dev` to report
an error. But the files are actually present and intact on the device.

**Root cause**: Android 10 ships Toybox tar (not GNU tar). Toybox tar exits 1 when it
cannot restore file ownership from the archive, even if all files were extracted
correctly. Archives created on macOS embed owner UID 501 / GID 20; the `run-as`
sandbox cannot `chown` to those values, so every file triggers a non-fatal error that
still sets the exit code to 1.

**Fix**: Append `2>/dev/null; true` to all device-side extraction commands so the
non-zero exit code and stderr noise are suppressed:

```elixir
adb.(["shell", "run-as #{bundle_id} sh -c 'tar xf ... 2>/dev/null; true'"])
```

**Fixed in**: `mob_dev/lib/mob_dev/deployer.ex` and `mob_dev/lib/mob_dev/native_build.ex`
— all device-side `tar xf` invocations now append `2>/dev/null; true` (2026-04-25).

---

## Toybox tar on Android 10 does not support `--strip-components`

**Symptom**: OTP or BEAM push fails with:

```
run-as tar failed: tar: Unknown option strip-components=1
```

**Root cause**: GNU tar's `--strip-components=N` flag strips leading path components
during extraction. Toybox tar (shipped on Android 10 and some Android 11 devices) does
not implement this flag.

**Fix**: Change the archive structure so no stripping is needed. Instead of archiving a
named wrapper directory and stripping it on extraction, archive the contents directly:

```bash
# Instead of:
tar czf archive.tar.gz -C /parent wrapper_dir/    # extracts as wrapper_dir/file
# Use:
tar czf archive.tar.gz -C /parent/wrapper_dir .   # extracts as ./file
```

On the device side, simply `tar xf archive.tar.gz` with no `--strip-components`.

**Fixed in**: `mob_dev/lib/mob_dev/deployer.ex` — `push_beams_android_runas/2` changed
archive creation to `tar cf -C tmp_dir .` (2026-04-25).

---

## `mob.exs` bundle_id mismatch silently skips OTP push

**Symptom**: `mix mob.deploy` completes without error but the app crashes on launch.
The deploy log shows:

```
⚠ ZY22CRLMWK: com.mob.mobqa not installed — skipping OTP push
```

The OTP runtime is never pushed to the device, so the BEAM starts but can't find the
app module. `erl_crash.dump` on the device contains:

```
Slogan: {undef,[{smoke_test,start,[],[]}]}
```

**Root cause**: `mob.exs` contains a `bundle_id` that doesn't match the package name
in `android/app/build.gradle`. The deployer checks for the installed package using
`pm list packages <bundle_id>` before pushing OTP. If the IDs don't match, it skips
the push with a warning rather than failing hard.

`mob.exs` is gitignored and machine-specific. It's easy for it to drift from the
project's actual bundle ID, especially when the same file was copied from another
project.

**Fix**: Ensure `bundle_id` in `mob.exs` exactly matches `applicationId` in
`android/app/build.gradle`.

**Diagnosis**:
```bash
# What mob.exs thinks the bundle ID is:
grep bundle_id mob.exs

# What the APK actually uses:
grep applicationId android/app/build.gradle
```

---

## Elixir stdlib version mismatch — `function_clause` in `Regex.safe_run` (Android)

**Symptom**: App crashes at startup with `function_clause` in `Elixir.Regex.safe_run/3`
inside `Phoenix.Endpoint.Supervisor.build_url/2`. The first argument is a `%Regex{}`
struct with `re_pattern: {re_pattern,0,0,0,#Ref<...>}`.

**Root cause**: The mob Android OTP packages a specific Elixir stdlib. `mix mob.deploy --native`
pushes the host Elixir BEAMs to the device. If the host Elixir is upgraded afterwards
(e.g. 1.18.4 → 1.19.5), subsequent `mix mob.deploy` runs only push app BEAMs — the
device keeps the old Elixir stdlib. Phoenix compiled with Elixir 1.19.5 stores regex
literals in OTP 28 NIF format; Elixir 1.18.4's `Regex.safe_run` has no clause for that
format.

**Fix**: `mob.deploy` now auto-detects and syncs Elixir stdlib when versions differ
(`sync_elixir_stdlib_android/1` in `mob_dev/lib/mob_dev/deployer.ex`). Simply run
`mix mob.deploy` and the warning + sync happen automatically.

**Quick manual fix**:
```bash
ELIXIR_EBIN=$(elixir -e "IO.puts(:code.lib_dir(:elixir))")/ebin
PKG=com.mob.YOUR_APP
adb -s SERIAL push "$ELIXIR_EBIN/." /data/data/$PKG/files/otp/lib/elixir/ebin/
adb -s SERIAL shell "am force-stop $PKG && am start -n $PKG/.MainActivity"
```

---

## `:badbool` from `nil and bool` silently kills the screen GenServer

**Symptom**: A specific tap on a Mob app stops working. The button label still updates
the AX tree on tap (chevron flips on the underlying state), but visible UI doesn't
re-render. Subsequent taps on the same button do nothing. Killing and restarting the
app reproduces the same broken state because the trigger is in persisted state
(`Mob.State` → dets), so the offending render path keeps crashing immediately on
re-render.

**Root cause**: Elixir has two boolean operator families with different semantics:

- `&&` and `||` are *lazy* — they short-circuit on truthy/falsy and pass through any value.
- `and`, `or`, and `not` are *strict* — they require booleans on both sides and raise
  `:badbool` when given `nil` or any non-boolean.

When a render branch like

    selected? = (some_optional_thing && check) and other_flag

evaluates `some_optional_thing` to `nil`, the `&&` short-circuits to `nil`. Then
`nil and other_flag` raises `{:badbool, :and, nil}`. The render crashes; `Mob.Screen`
terminates; the screen freezes on its last good frame; the next interaction reproduces
the crash.

**Fix**: Use `&&` consistently — never mix `&&` and `and` in the same expression
unless you've explicitly converted the left side to a real boolean (e.g. `!!nil` →
`false`).

```elixir
# bad — nil and _ raises :badbool:
selected? = (ta.fill && fill.product.id == ta.fill.product.id) and ta.locked

# good — fully lazy chain, short-circuits cleanly on nil:
selected? = ta.locked && ta.fill && fill.product.id == ta.fill.product.id
```

**Diagnosis**: Look in `adb logcat -s Elixir` (Android) or the iOS console for a
`gen_server` terminate message naming the screen module and a `:badbool` reason.
The persisted state survives kill+restart, so the symptom looks like a UI lockup
rather than a crash.

**Fixed in**: `air_cart_max/lib/air_cart_max/home_screen.ex:936` (`override_menu_section`,
2026-05-02). Caught after iOS-side red herring (border `.overlay()` was intercepting
taps, separate fix); the real bug only surfaced when adb logcat showed the gen_server
terminate on Steve's moto G.

---

## iOS sim app dies silently when launched without `MOB_SIM_RUNTIME_DIR` (Springboard tap, MCP `launch_app`, Xcode run)

**Symptom**: iOS simulator app exits ~135ms after `mob_start_beam` logs
`Starting BEAM…`. No Erlang crash dump, no further `[MobBeam]` lines, no error
in the iOS sim system log. Springboard reports
`Process exited: <RBSProcessExitContext| voluntary>`. Only `mix mob.deploy`
launches succeed; tapping the app icon, `xcrun simctl launch <udid> <bundle>`,
the iOS-Simulator MCP `launch_app` tool, and Xcode's Run button all reproduce
the silent crash.

**Root cause**: `mob/ios/mob_beam.m::resolve_sim_otp_root()` resolves the OTP
runtime root to `MOB_SIM_RUNTIME_DIR` env var if set, otherwise *always* to
`/tmp/otp-ios-sim` — it never checks the new canonical path
`~/.mob/runtime/ios-sim`. `mix mob.deploy` writes the runtime to
`~/.mob/runtime/ios-sim/<app>/` (per `MobDev.Paths.sim_runtime_dir/1`) and
launches via `MobDev.Discovery.IOS.launch_app/3`, which passes
`SIMCTL_CHILD_MOB_SIM_RUNTIME_DIR=~/.mob/runtime/ios-sim` so the env var is
set and resolution lands in the right place.

Any other launch path (Springboard, plain `xcrun simctl launch`, MCP, Xcode)
inherits no env vars from `mix mob.deploy`, so `MOB_SIM_RUNTIME_DIR` is unset
and `resolve_sim_otp_root()` falls back to `/tmp/otp-ios-sim`. If the legacy
path is empty or contains a different project's release, BEAM tries to start
`<app>:start().` from a release that has no `<app>.app` and aborts. ERTS
boot-time errors go to stderr, which iOS sim doesn't route to `os_log`, so
nothing is visible.

In our case `/tmp/otp-ios-sim` was a leftover from an older `smoke_test`
deploy. `square_triangle`'s `[MobBeam] otp_root=/tmp/otp-ios-sim` log line was
the smoking gun — the new default would have been `~/.mob/runtime/ios-sim`.

**Diagnosis**:
1. Look for the `[MobBeam] otp_root=…` log line — if it points anywhere other
   than where `mix mob.deploy` actually wrote (check
   `~/.mob/runtime/ios-sim/<app>/` for the project's BEAMs), the resolver is
   wrong.
2. Confirm `<app>:start().` would fail by listing the release used:
   `ls $OTP_ROOT/<app_module>/<App>.app` should exist.
3. The exit is "voluntary" in launchd terms (BEAM calls `abort()` after
   reporting the boot error to stderr), so no crash report is generated under
   `~/Library/Logs/DiagnosticReports/`.

**Fix**: `resolve_sim_otp_root()` now takes `app_module` and prefers
`<host-home>/.mob/runtime/ios-sim` when that path contains an `<app_module>/`
subdirectory, before falling back to `/tmp/otp-ios-sim`.

**Critical detail — `HOME` is wrong on iOS sim apps**: a launched simulator
app inherits `HOME` pointing to its per-app sandbox container
(`…/CoreSimulator/Devices/<udid>/data/Containers/Data/Application/<uuid>`),
NOT the Mac user's home. The Mac user's home is exposed via
`SIMULATOR_HOST_HOME`. The resolver checks `SIMULATOR_HOST_HOME` first and
falls back to `HOME` (which is right only when the binary is invoked outside
simctl, e.g. from a raw test harness on the Mac). Using `HOME` alone always
misses, since `<container>/.mob/runtime/ios-sim` never exists.

**Fixed in**: `mob/ios/mob_beam.m::resolve_sim_otp_root` (2026-05-04). Verified
on `square_triangle` iOS sim — plain `xcrun simctl launch` (no env var) now
boots BEAM successfully, picks up the right runtime, and joins distribution.

## Play Store install: BEAM fails to start — ERTS helpers not found (`erl_child_setup: : no such file or directory`)

**Symptom**: App works with `adb install` but crashes immediately when installed from
the Play Store (internal testing or production). Logcat shows:

```
erl_child_setup: : no such file or directory
```

or similar ENOENT for `inet_gethost` or `epmd`. The BEAM never starts.

**Root cause**: Play Store delivers apps as split APKs. On Android 6+, the system does
**not** extract `.so` files from split APKs to `nativeLibraryDir` — they stay inside the
split APK zip. `mob_beam.c` creates symlinks `erts-VER/bin/<name>` →
`<nativeLibraryDir>/lib<name>.so`. When `nativeLibraryDir` is empty (Play Store path),
every symlink is dangling and BEAM's exec calls fail with ENOENT.

**Fix**: `MobBridge.extractBeamHelpersFromSplitApk()` (called from `MobBridge.init()`)
detects an empty `nativeLibraryDir`, opens the ABI split APK from
`ApplicationInfo.splitSourceDirs` as a zip, and extracts:
- `liberl_child_setup.so` → `<filesDir>/otp/erts-VER/bin/erl_child_setup`
- `libinet_gethost.so` → `<filesDir>/otp/erts-VER/bin/inet_gethost`
- `libepmd.so` → `<filesDir>/otp/erts-VER/bin/epmd`
- `libsqlite3_nif.so` → `<filesDir>/otp/lib/exqlite-VER/priv/sqlite3_nif.so`

`mob_beam.c` was patched to `stat` the target before symlinking — if the file already
exists from extraction, it skips the symlink.

**Does not affect `adb install`**: Full APK install extracts `.so` to `nativeLibraryDir`
normally. The issue is Play Store split APK delivery only.

**Fixed in**: `MobBridge.kt` (2026-05-04, air_cart_max versionCode 12) and
`mob/android/jni/mob_beam.c` (2026-05-04). See `extractBeamHelpersFromSplitApk` in
the generated `MobBridge.kt` for the canonical implementation.

## Play Store install: BEAM starts, black screen — `crypto.app not found` (historical)

**Status**: superseded as of 2026-05-06 by tarballs that ship a real
`:crypto` NIF (OpenSSL 3.x, statically linked). The black-screen-on-Play
symptom no longer reproduces with current tarballs; the workarounds
described below (`patch_crypto_deps!/1` and `add_crypto_stub!/2`) can be
removed from `release_android.ex` once we're confident no apps still
depend on the older shim path.

**Original symptom**: App installs from Play Store, does not crash with
a native signal, but shows only a black screen. Logcat (`adb logcat -s
Elixir`) shows:

```
step 5 => {'EXIT',{{badmatch,{error,{crypto,{"no such file or directory","crypto.app"}}}},...}}
```

**Original root cause**: pre-2026-05 Mob Android OTP releases were
cross-compiled `--without-ssl`, so the `:crypto` OTP application was
absent. `ecto`, `phoenix_pubsub`, `plug_crypto`, and others list
`:crypto` in their `{applications, [...]}` so `ensure_all_started`
crashed when the application controller called `application:load(crypto)`.

**Original workaround** (now obsolete — leaving for code archeology):

1. `patch_crypto_deps!/1` — walked staging tree's `*.app` files and
   removed `:crypto` from each `{applications, [...]}`.
2. `add_crypto_stub!/2` — compiled a minimal `crypto.erl` stub from
   `mob_dev/priv/android/crypto.erl` (only `strong_rand_bytes/1` via
   `:rand`) and shipped a `crypto.app` with no `{mod,...}` entry so
   starting it was a no-op.

Stub used `:rand`, not a cryptographically secure RNG — fine for the
HTTP-only-loopback dev model, dangerous on the open internet.

**Why it's gone**: the current tarballs static-link real OpenSSL into
the app's main native lib. Ecto's `strong_rand_bytes/1`, plug_crypto's
HMAC-SHA256, peer_net's x25519 etc. all just work with the standard
OTP `:crypto` API. No app-level patching needed.

---

## NDK 27 / clang 18 split libc++ — `undefined symbol: __cxa_allocate_exception`

**Symptom**: linking the app's `libpigeon.so` against Mob's bundled
`libbeam.a` fails with one or more of:

```
undefined symbol: __cxa_allocate_exception
undefined symbol: __cxa_throw
undefined symbol: __cxa_begin_catch
undefined reference to `std::__ne140000::...`
```

The user's Android Studio shipped NDK 25 (or 26), gradle picked it
up by default, and `libpigeon.so` got compiled against a different
libc++ inline namespace than the one baked into Mob's `libbeam.a`.

**Root cause**: NDK 27 ships clang 18, which defaults libc++ to the
versioned inline namespace `std::__ne180000::`. NDK 25 / clang 14
uses `std::__ne140000::`. Symbols in those namespaces don't link
across versions — the C++ exception ABI runtime calls
(`__cxa_allocate_exception`, `__cxa_throw`, etc.) are emitted by
the compiler, expected to resolve at link time, and the wrong
namespace makes them appear undefined.

The bundled OTP tarballs in `~/.mob/cache/otp-android-*` are
cross-compiled against NDK 27 (see
`mob_dev/scripts/release/openssl/_lib.sh` `NDK_VERSION=27.2.12479018`).
Whatever NDK ships in the user's Android Studio determines the
namespace `libpigeon.so` is built against.

**Diagnostic** — confirm an ABI mismatch on a fresh checkout:

```bash
# What namespace is libbeam.a built against?
nm ~/.mob/cache/otp-android-*/erts-*/lib/libbeam.a | grep __ne180000 | head
# expect hits — those are NDK 27 symbols

# What's gradle picking up locally?
ls ~/Library/Android/sdk/ndk/
# expect 27.2.12479018; if you see 25.x or 26.x as the only entry, that's it
```

**Fix**:

```bash
sdkmanager --install "ndk;27.2.12479018"
```

Or via Android Studio → SDK Manager → SDK Tools → NDK (Side by side)
→ check `27.2.12479018`.

The generated `android/app/build.gradle` already pins
`ndkVersion '27.2.12479018'`, so once the NDK is installed gradle
will use it automatically. `mix mob.doctor` reports installed NDKs
and flags this exact mismatch (since 2026-05-07); `mix mob.install`
warns at onboarding time.

**Escape hatch** — if you genuinely need a different NDK (legacy
library, hardware-specific toolchain, etc.):

```elixir
# mob.exs (travels with the project)
config :mob_dev, android_ndk_version: "25.1.8937393"
```

```bash
# or env var (machine-static)
export MOB_ANDROID_NDK_VERSION=25.1.8937393
```

The override means you've opted out of the bundled-OTP libc++ ABI
guarantee. `libpigeon.so` and `libbeam.a` will not agree on the
namespace; you'll get the link errors above and you own the debug.
`mob.doctor` warns; it doesn't fail. See
`mob_dev/lib/mob_dev/ndk_version.ex` for precedence and rationale.

**When we rebuild OTP tarballs against a newer NDK**: bump in three
places, lock-step:

1. `mob_dev/lib/mob_dev/ndk_version.ex` — `@recommended`.
2. `mob_new/lib/mob_new/ndk_version.ex` — `@recommended` (drift
   test enforces equality).
3. `mob_dev/scripts/release/openssl/_lib.sh` — `NDK_VERSION` default.

