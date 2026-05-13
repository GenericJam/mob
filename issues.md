# Issues

Tracked items not yet addressed. Each section captures the symptom, why it
happens, and what a fix would look like — so the next session can pick one
up without re-deriving context.

## 1. Disable `phoenix_live_reload` on iOS device builds — **FIXED 2026-05-10**

> **Resolution.** `mob_new`'s `mob_live_app_content/4` (LiveViewPatcher)
> now sets `code_reloader: false`, `watchers: []`, `live_reload: false`
> in the on-device endpoint config. Newly-generated LV projects pick this
> up automatically; existing projects need a one-line edit in their
> `mob_app.ex`.

**Symptom** — `beam_stdout.log` on launch:
```
[error] `priv` dir for `:file_system` application is not available in current runtime,
        appoint executable file with `config.exs` or `FILESYSTEM_FSMAC_EXECUTABLE_FILE` env.
[error] Can't find executable `mac_listener`
[warning] Not able to start file_system worker, reason: {:error, :fs_mac_bootstrap_error}
[warning] Could not start Phoenix live-reload because we cannot listen to the file system.
```

**Why** — LiveReload spawns the macOS `mac_listener` binary to watch the project tree
for file changes. It can't possibly work on iOS device (no shell, no fork, no host
filesystem to watch), and the file isn't bundled. Phoenix falls back gracefully
("You don't need to worry!") but the noise pollutes the log.

**Fix** — in the on-device `Application.put_env` for the Endpoint (lives in
`live_view_patcher.ex` → `mob_live_app_content/4`), explicitly disable reload:

```elixir
Application.put_env(:#{app_name}, #{module_name}Web.Endpoint,
  # ... existing config ...
  code_reloader: false,
  watchers: [],
  live_reload: false  # ← add this
)
```

Or remove `:phoenix_live_reload` from the `extra_applications` list entirely
when running on-device (it's a dev-only dep anyway).

---

## 2. Silence `:esbuild` / `:tailwind` startup warnings on-device — **FIXED 2026-05-10**

> **Resolution.** Option (a) — `Application.put_env(:esbuild, :version, "0.25.0")`
> + `:tailwind, :version, "3.4.6"` set in `mob_app.ex` before
> `ensure_all_started`. Versions match Phoenix 1.7's defaults; bump
> alongside `mix phx.new` upgrades.

**Symptom** — same log:
```
[warning] esbuild version is not configured. Please set it in your config files:
    config :esbuild, :version, "0.25.0"
[warning] tailwind version is not configured. Please set it in your config files:
    config :tailwind, :version, "3.4.6"
```

**Why** — both `:esbuild` and `:tailwind` are dev-time asset-compilation tools.
They're listed as runtime applications in the host project, so they get started
on-device too via `Application.ensure_all_started`. They warn about missing
version configs because the dev-only `config/dev.exs` doesn't get bundled.

**Fix options** (cheapest first):

- **(a) Set the versions** in `mob_app.ex` before `ensure_all_started`:
  ```elixir
  Application.put_env(:esbuild, :version, "0.25.0")
  Application.put_env(:tailwind, :version, "3.4.6")
  ```
  Cosmetic — the tools never actually run on-device, but the warnings go away.

- **(b) Mark them runtime-only false** in the generated `mix.exs`:
  ```elixir
  {:esbuild, "~> 0.8", runtime: false},
  {:tailwind, "~> 0.2", runtime: false},
  ```
  Cleaner — they're build-time-only deps, no reason to start them at runtime.
  Existing `mix.exs` template emits `runtime: Mix.env() == :dev` which is correct
  for host builds; verify the generator is doing this for LV-mode projects.

---

## 3. WebSocket → longpoll fallback in WKWebView

**Symptom** — the LiveView client connects three times within ~70ms during
mount, with the second and third using longpoll:

```
13:20:00.097 [info] CONNECTED TO Phoenix.LiveView.Socket in 2ms
  Transport: :websocket
13:20:00.155 [info] CONNECTED TO Phoenix.LiveView.Socket in 29µs
  Transport: :longpoll
13:20:00.164 [info] CONNECTED TO Phoenix.LiveView.Socket in 18µs
  Transport: :longpoll
[debug] Duplicate channel join for topic "lv:phx-..."
        Closing existing channel for new join.
```

Phoenix handles the duplicate join gracefully, but the WebSocket-then-longpoll
churn is unexpected on a loopback connection that should just work.

**Hypotheses to check**

1. **WKWebView WebSocket on loopback** — does WKWebView allow plain `ws://` to
   `127.0.0.1` without ATS exception? `Info.plist` may need `NSAllowsLocalNetworking`
   or per-domain `NSExceptionAllowsInsecureHTTPLoads`. Test: open the page in
   mobile Safari instead of WKWebView and see whether the longpoll fallback
   still happens.

2. **`check_origin` rejecting the WKWebView origin** — Phoenix is at
   `127.0.0.1:4200` but the WKWebView load might present a different `Origin`
   header depending on how the URL was loaded. If `check_origin` rejects the
   first WS, the client retries on longpoll. The current on-device config has
   `check_origin: false`, but the LiveView socket may still apply per-socket
   origin checks. Worth grep'ing the generated endpoint config for any
   `check_origin` overrides.

3. **Bandit websocket upgrade behaviour** — Bandit 1.x may send the
   `Sec-WebSocket-Accept` response after a delay long enough that the client's
   open-timeout expires and falls back. Check the Bandit version in the
   on-device runtime vs the host dev server.

**Investigation tooling** — WKWebView supports remote inspection via Safari's
Develop menu when the device is plugged in. Settings → Safari → Advanced →
Web Inspector = on. Then Safari → Develop → [iPhone name] → ToyLvApp → choose
the page. The WebSocket frames + console errors there will say definitively
why the connection drops.

**Not urgent** — the longpoll fallback works correctly. Worth fixing because
(a) WS is faster, (b) the duplicate joins burn CPU on every nav, (c) it
suggests something in the loopback WS path is fragile and might bite worse
later (intermittent disconnects under load).

---

## 4. LiveView port 4200 collides across multiple installed Mob LV apps — **FIXED 2026-05-10**

> **Resolution.** Recommendation #1 from below: hash the app name into
> `4200..4999` for the on-device default. Implementation lives in
> `mob_new`'s `mob_live_app_content/4`:
>
> ```elixir
> defp default_liveview_port do
>   4200 + :erlang.phash2(:<app_name>, 800)
> end
> ```
>
> Generated `mob.exs` ships `# config :mob, liveview_port: 4200`
> commented out — uncomment to pin a specific value (e.g. for a test
> harness that hardcodes a port). `Mob.LiveView.local_url/1` reads
> the env automatically, so the WebView URL stays in sync with the
> resolved port without further changes.

**Symptom** — second LV app fails to start with:
```
Running TestLvDemoWeb.Endpoint with Bandit 1.10.4 at http failed,
  port 4200 already in use
... :eaddrinuse ...
step 5 => {'EXIT', {{badmatch, {error, ...}}, ...}}
```

App appears stuck on the "Starting BEAM…" splash forever. Logcat
(Android) or beam_stdout.log (iOS) shows the eaddrinuse trace.

**Why** — every Mob LiveView project generated by `mix mob.new --liveview`
hardcodes port 4200 in `lib/<app>/mob_app.ex`:

```elixir
liveview_port = Application.get_env(:mob, :liveview_port, 4200)
Application.put_env(:#{app}, #{module}Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: liveview_port],
  ...
)
```

When two Mob LV apps are installed on the same device and one is alive
(even just backgrounded — Android happily keeps recent apps in memory),
the second can't bind 4200. Bandit returns `{:error, :eaddrinuse}`, the
endpoint supervisor crashes, and so does the whole BEAM.

We saw this on a Moto E (32-bit Android) where `mob_test_liveview` was
sitting in the background and prevented `test_lv_demo` from launching.

**Workaround for now** — force-stop the squatter:
```bash
adb shell am force-stop com.mob.mob_test_liveview
```
Then relaunch the target app.

**Fix options** (in order of mechanical complexity):

1. **Hash the bundle id into the port.** Deterministic and unique-per-app
   without runtime negotiation. The port stays predictable across
   restarts, which keeps the WebView load URL static (it points at
   `http://127.0.0.1:<port>/`).

   ```elixir
   defp default_port do
     # Range 4200..4999 — small enough to not collide with system ports,
     # large enough that birthday-paradox collisions are vanishingly rare
     # for any reasonable number of installed Mob apps.
     4200 + rem(:erlang.phash2(unquote(app_name)), 800)
   end
   ```
   Plumb the same expression into the WebView's URL builder
   (`MobScreen.render` calls `Mob.LiveView.local_url`) so the WebView and
   the endpoint agree.

2. **Try 4200, fall back to ephemeral on `:eaddrinuse`.** Keeps 4200 as
   the friendly default for the single-app case but recovers gracefully
   when a sibling is squatting. Requires the WebView to learn the actual
   bound port at runtime — Bandit exposes it via `:ranch.info(listener)`
   or similar after `start_link`. Then `Mob.LiveView.local_url` reads the
   real port instead of `Application.get_env(:mob, :liveview_port)`.

3. **Always use port 0 (ephemeral), expose via NIF.** Most robust but
   requires the WebView load to wait for the endpoint's port to be
   resolved before navigating. Cleaner long-term answer.

Recommendation: **(1)** is the smallest fix that materially improves the
multi-app case without changing any other architecture. The hash space
of 800 ports gives p < 0.5% collision odds even with 5 installed apps,
and a collision would still produce the same eaddrinuse failure with
the same workaround.

**Generator change required** in
`mob_new/lib/mob_new/live_view_patcher.ex` (the `mob_live_app_content/4`
function) so newly-generated projects pick up the hash-based default.
Existing projects need a one-line edit in their `mob_app.ex` (or
regenerate).

---

## 5. `mix mob.deploy --native --ios` silently prefers iPhone over sim — **FIXED 2026-05-10**

> **Resolution.** Option #1 (the recommended one): when
> `auto_detect_physical_ios/0` picks an iPhone and a sim is also booted,
> it now prints the alternative `--device <short-id>` invocation so the
> user can target the sim explicitly. Default behavior unchanged.

**Symptom** — `mix mob.deploy --native --ios` builds and installs on the
physical iPhone, never the booted simulator. No log line indicates the
choice. Output suggests a single deploy was attempted:
```
=== Installing on device 00008110-001E1C3A34F8401E ===   ← iPhone, not sim
=== Build and install complete ===
  ✓ iOS (device) native build complete
  Pushing 830 BEAM file(s) to 1 device(s)...             ← only one
```

If you want the sim, you have to know that you'd need
`--device <sim-udid>`, but there's nothing in the deploy output
suggesting that. New users hit this and assume the sim path doesn't
work or that mob can't see the sim.

**Why** — `mob_dev/lib/mob_dev/native_build.ex` `build_all/1`:

```elixir
physical_udid = cond do
  is_binary(device_id) and ios_physical_udid?(device_id) -> device_id
  is_nil(device_id) -> auto_detect_physical_ios()    # ← picks iPhone if connected
  true -> nil
end

cond do
  physical_udid -> [build_ios_physical(...) | results]
  File.exists?("ios/build.sh") -> [build_ios(...) | results]   # sim path
  ...
end
```

`auto_detect_physical_ios/0` returns the iPhone's UDID if exactly one is
connected — and the device branch wins, full stop. The sim path is
unreachable when an iPhone is plugged in.

**Workaround** — pass `--device <sim-udid>` explicitly. Get UDIDs from
`mix mob.devices`. Requires mob_dev ≥ 0.3.18 (earlier versions had a
predicate bug that misclassified sim UDIDs as physical and routed them
through the device build path).

**Fix options**

1. **Print what was picked, with the alternative.** Cheapest, lowest
   surprise:
   ```
   Auto-detected physical iPhone: Kevin's iPhone (00008110-...).
     Pass --device 78354490... to target the iPhone 17 simulator instead.
   ```
   Mob already has `auto_detect_physical_ios` printing a note for the
   single-device case; extend it to mention the simulator alternative
   when both are available.

2. **Build for both targets when both are available.** `:ios in platforms`
   currently emits one iOS build; instead emit one per available target.
   Doubles build time but matches the Android behaviour where any
   connected device gets the APK, and removes the surprise. Cost: longer
   first deploy, ~80–100 MB more disk used per cycle (sim + device
   bundles in `_build`).

3. **Reverse the default — prefer sim when both exist.** Sim builds are
   faster, don't require provisioning profiles, and are usually what's
   wanted during iteration. Physical iPhone is the deployment target
   *near* shipping. Promote sim-first via the cond order. Anyone who
   wants the iPhone passes `--device <udid>` (consistent with the
   simulator's current second-class status — simulator users have to
   pass `--device` once a physical is plugged in, so it'd just be
   reversing who pays the friction cost).

Recommendation: **(1) immediately** — one-line message change, fixes the
discoverability problem without changing default behaviour. **(2) later**
once the iOS device build cycle is faster (the EPMD / forker patches +
tarball schema bump from 0.3.17 already cut a chunk; more wins possible
by avoiding unnecessary OTP rebundling on every native build).

**Not in scope here** — the matching predicate bug
(`ios_physical_udid?/1` matching sim UDIDs by format) is fixed in
mob_dev 0.3.18.

---

## 6. Native `.so` files aren't 16 KB-page aligned (Android 15+ warning)

**Symptom** — on Android 15+ devices/emulators (where 16 KB memory pages
are available), launching a Mob app pops a system dialog:

> Android App Compatibility
>
> This app isn't 16 KB compatible. ELF alignment check failed. This app
> will be run using page size compatible mode. For best compatibility,
> please recompile the application with 16 KB support.
>
> The following libraries are not 16 KB aligned:
> • lib/arm64-v8a/libinet_gethost.so : LOAD segment not aligned
> • lib/arm64-v8a/libsqlite3_nif.so : LOAD segment not aligned
> • lib/arm64-v8a/libimage_processing_util_jni.so : LOAD segment not aligned
> • lib/arm64-v8a/liberl_child_setup.so : LOAD segment not aligned
> • lib/arm64-v8a/libepmd.so : LOAD segment not aligned
> • lib/arm64-v8a/libmobtest.so : LOAD segment not aligned
> • lib/arm64-v8a/libbarhopper_v3.so : LOAD segment not aligned

**Why** — Android 15 added 16 KB page support as a memory/perf
improvement over the legacy 4 KB pages. Native libraries must have
their ELF LOAD segments aligned to 16 KB boundaries to take advantage.
Libraries built before this requirement (everything in the list
above) get loaded in per-app "page size compatible mode" — small
memory + perf cost, but functionally fine.

The fix is a single linker flag at build time:

```
-Wl,-z,max-page-size=16384
```

**Each library has a different owner:**

| Library | Source | Fix |
|---|---|---|
| `liberl_child_setup.so` | OTP runtime | rebuild OTP tarball with the flag |
| `libinet_gethost.so`    | OTP runtime | rebuild OTP tarball with the flag |
| `libepmd.so`            | OTP runtime | rebuild OTP tarball with the flag |
| `libmobtest.so`         | Mob's NDK build (`android/jni/`) | add to CMakeLists |
| `libsqlite3_nif.so`     | exqlite Hex dep | upstream fix or local re-link |
| `libimage_processing_util_jni.so` | androidx.camera | bump CameraX dep |
| `libbarhopper_v3.so`    | com.google.mlkit:barcode-scanning | bump ML Kit dep |

**Recommendation: bundle the fix into the next OTP tarball schema bump.**
We already plan to re-cut the iOS-device tarball when EPMD source got
added; that same release cycle is the natural place to add
`-Wl,-z,max-page-size=16384` to every `.so` build step. Concretely:

- **OTP cross-compile** (Android arm32 + arm64): add the flag to
  `LDFLAGS` in `xcomp/erl-xcomp-arm{,64}-android.conf` (or via
  `make CFLAGS=...` override at build time).
- **`libmobtest.so`**: add the flag to
  `android/jni/CMakeLists.txt` (or wherever the NDK `LOCAL_LDFLAGS`
  / `target_link_options` live).
- **exqlite**: file an upstream issue or use Android's
  `zipalign -p 16384` (page-aligns `.so` LOAD segments) as a
  post-processing step in the deployer's APK packaging. The
  `zipalign -p 16384` form is a real flag in NDK 27+.
- **CameraX / ML Kit**: bump to a version that ships 16 KB-aligned
  binaries. Most current Google libraries already do.

**Priority** — low. Warning, not an error. Apps run correctly today
in compatibility mode. Worth doing alongside the next OTP rebuild
(and definitely before the conference talk demo where audience
phones will be Android 15+).

**Reference** — <https://developer.android.com/guide/practices/page-sizes>

---

## 7. iOS Slider doesn't honor `accessibilityIncrement`/`Decrement` — **FIXED 2026-05-10**

> **Resolution.** `MobSlider` in `ios/MobRootView.swift` now has
> `.accessibilityAdjustableAction { direction in … }` with default step
> `(max - min) / 10` (matches VoiceOver's default for native UISlider).
> Increments/decrements call `node.onChangeFloat?` so `:change` events
> still flow. `Mob.Test.adjust_slider/4` works end-to-end after this.

**Symptom** — `Mob.Test.adjust_slider/4` (and direct `mob_nif:ax_action_at_xy(x, y, :increment)`) returns `:ok` but the slider's value never changes. Verified 2026-04-30 against `mob_test`'s ControlsScreen on a real iPhone with VoiceOver active.

```
3 single decrements with explicit pause:
  1: result=:ok  brightness=0.5
  2: result=:ok  brightness=0.5
  3: result=:ok  brightness=0.5
```

**Why** — SwiftUI's plain `Slider` view does not emit accessibility traits/actions for adjustment unless the developer attaches `.accessibilityAdjustableAction { direction in … }`. With our default rendering, iOS sends the AX action and SwiftUI silently drops it. The NIF correctly invokes `accessibilityIncrement` on the hit-tested element; the failure is below us in the SwiftUI view.

**Fix** — in Mob's iOS Slider rendering (the SwiftUI view that backs `<Slider>`), attach an adjustable-action modifier that increments/decrements by a sensible step. A reasonable default is `(max - min) / 10`, configurable via a new optional `step:` prop:

```swift
Slider(value: $value, in: min...max, step: stepValue)
    .accessibilityAdjustableAction { direction in
        let delta = stepValue > 0 ? stepValue : (max - min) / 10
        switch direction {
        case .increment: value = Swift.min(value + delta, max)
        case .decrement: value = Swift.max(value - delta, min)
        @unknown default: break
        }
    }
```

This unblocks `Mob.Test.adjust_slider/4` end-to-end. Same component on Android (`MobSlider` in MobBridgeKt) should accept a similar step prop and use Compose's `Modifier.semantics { setProgress(...) }`.

**Priority** — medium. The Mob.Test/AX action API exists and works; just needs Mob's components to be conformant.

---

## 8. iOS Toggle's `label:` prop doesn't reach the AX tree — **FIXED 2026-05-10**

> **Resolution.** `MobToggle` in `ios/MobRootView.swift` now appends
> `.accessibilityLabel(label)` after the `Toggle("Label", isOn:)` view.
> SwiftUI's Toggle initializer doesn't propagate the label string into
> the underlying control's accessibilityLabel, so this is the explicit
> bridge. After the fix, the toggle appears in `ui_tree` as
> `:button label="Notifications" value="1"` and
> `Mob.Test.toggle(node, "Notifications")` finds it via plain match.

**Symptom** — `Mob.Test.toggle/2` returns `{:error, :label_not_found}` because the visible label text doesn't appear in `mob_nif:ui_tree/0`. The toggle itself comes through as:

```
:button  y=133.5  w=327.0 h=28.0  label=""  value="1"
```

Empty AX label. Pre-existing position-based fallback (`ax_action_at_xy` with toggle index) works, but the natural-feeling `Mob.Test.toggle(node, "Notifications")` doesn't.

**Why** — Mob's iOS Toggle component uses SwiftUI's `Toggle("Label", isOn: $value)` form (or equivalent), but the underlying SwiftUI `Switch` only inherits the label visually — the AX tree exposes it as a separate text node, not as the switch's `accessibilityLabel`. Or more likely the current Mob iOS Toggle renders the label as a sibling Text and the Switch with no `.accessibilityLabel`.

**Fix** — in Mob's iOS Toggle rendering, propagate the `label` prop to `.accessibilityLabel(label)` on the underlying control. Then the toggle appears in AX as `:button label="Notifications" value="1"` and `Mob.Test.toggle(node, "Notifications")` finds it via plain label match. (Android: similar — Compose `Switch` inside `Modifier.semantics { contentDescription = label }`.)

**Priority** — medium. Same as #7 — testing API exists, just needs Mob component to be AX-conformant.

---

## 9. Alert OK-button `accessibilityActivate` is a no-op

**Symptom** — `Mob.Test.dismiss_alert(node, "OK")` (and direct `mob_nif:tap("OK")` while an alert is showing) returns `:ok` but the alert stays on screen.

**Why** — UIAlertController exposes the alert's button twice in the AX tree: once as the visual `UIView` and once as the action target. Both have label `"OK"`, identical frame `{43.5, 375.5, 288, 48}`. Our finder matches the first one (the visual view), and `accessibilityActivate` on the visual view doesn't fire the underlying `UIAlertAction`'s handler.

**Fix options**:

- **(a) AX-route the action** — find the UIAlertController in the responder chain, look up the matching action by title, invoke its handler directly. Reliable but ties Mob.Test to an internal UIKit detail.
- **(b) Have Mob.Alert tag its buttons** — give each rendered alert button an accessibility identifier we can match precisely, and have the NIF dispatch via the action target rather than the visual view.
- **(c) Punt to a synthesized tap on the button's frame** — works for visual buttons but iOS's UIAlertController might guard its actions behind specific touch conditions.

**Priority** — low. Workaround exists: define alert buttons with a Mob `action:` atom and dismiss them in user code via `Mob.Test.send_message(node, {:alert, :ok_action})`. Useful enough that we should do (b) eventually.

---

## 10. Android 17 SELinux blocks BEAM startup (cgroup probe denials)

**Symptom** — on the Android 17 dev-preview emulator (`sdk_gphone16k_arm64`,
API 37, 16 KB pages), the app launches but the BEAM never reaches Elixir
code. logcat shows the symlink phase complete, then silence, then process
death. Activity manager reports "Process com.example.<app> exited cleanly (1)"
within 2–3 seconds of `mob_start_beam: starting BEAM`.

The killing AVC denials (logcat, all `permissive=0`):

```
W beam-main:  avc: denied { search } for name="/" dev="cgroup" ... \
              tcontext=u:object_r:cgroup:s0 ... permissive=0   (×3)
W erts_dios_1: avc: denied { read } for name="/" dev="dm-0" ino=55 ... \
              tcontext=u:object_r:rootfs:s0 ... permissive=0
```

No tombstone (it's a clean `_exit(1)`, not a SIGSEGV).

**Why** — Android 17's `untrusted_app_34` SELinux domain refuses two probes
the BEAM does at scheduler init:

1. **`beam-main` → `/sys/fs/cgroup/`**. OTP added cgroup-aware CPU/memory
   carrier sizing in OTP 26 — see
   `erts/lib_src/common/erl_misc_utils.c` → `get_cgroup_path/2` and
   `read_cpu_quota/1`. The init code calls `fopen("/proc/self/cgroup", "r")`
   then walks `/proc/self/mountinfo` to find cgroup mounts under `/sys/fs/cgroup/`.
   Each cgroup-fs traversal requires `search` permission on the cgroup
   directory — Android 17 doesn't grant it to third-party apps.

2. **`erts_dios_1` → `/` (rootfs)**. Dirty I/O scheduler probing. Less clear
   what triggers the read; possibly an OTP-internal default-cwd check or
   `realpath`-ish code resolving symlinks at scheduler init.

OTP intends both probes to fall back gracefully on failure, but in practice
the cascading `EACCES` from these two paths surfaces as a fatal exit
during scheduler init on Android 17. Older Android releases granted
`untrusted_app_*` enough cgroup access for these probes to succeed (or
return an empty result OTP handled fine), so the issue is invisible on
shipping Android.

**Scope today** — limited to Android 17 dev preview. Public Android 15 is
the user-facing target; Android 16 (rollout in progress on Pixel 9+)
needs a verification pass to know if it's also affected (run a vanilla
Mob deploy against an Android 16 image — system_image
`system-images;android-36;google_apis;arm64-v8a`). If Android 16 is
clean, this is a future-shipping issue worth fixing before Android 17 GA.
If Android 16 already breaks, raise priority — Pixel users are about to
hit this in volume.

**Workarounds**

1. **Use Android 14/15 emulators or physical devices.** Older SELinux
   policy permits the cgroup probes. Most existing Mob users are here.
2. **Boot the Android 17 emulator with SELinux disabled**:
   ```bash
   emulator -avd <Android17-AVD> -selinux disabled
   ```
   Lets the BEAM start; **dev-only**, never on a real device. Useful for
   testing app code against Android 17 APIs while we work on the fix.

**Real fix — OTP source patch (the right answer)**

We already maintain two OTP-source patches in `mob_dev/scripts/release/patches/`
(`forker_start` skip on iOS device, EPMD `NO_DAEMON` guard). A third would
sit alongside, applied during OTP cross-compile via `xcompile_*.sh`.

Two patch options inside `erl_misc_utils.c`:

- **Wrap the cgroup probe in a feature flag.** Add `-DERTS_NO_CGROUP_DETECTION`
  to the Android xcomp configs (`xcomp/erl-xcomp-arm{,64}-android.conf`)
  and gate `get_cgroup_path/2` and friends behind it — return
  `ERTS_CGROUP_NONE` immediately when the flag is set. Cheap, surgical,
  and means OTP's CPU-quota detection falls back to the default for
  Android, which is fine since Android already enforces CPU limits via
  its own scheduler.

- **Catch `EACCES` at each fopen/opendir.** More invasive, more correct,
  but might miss edge cases — OTP's existing fallback isn't exercised
  on Linux+EACCES because that combination is rare in practice.

Recommendation: **(1) cgroup-detection-disabled flag** for Android, baked
into the next Android tarball alongside the 16 KB-page alignment fix
(issues.md #6). Both naturally batch into the same OTP rebuild cycle.

**Investigation tooling**

- `adb -s <device> logcat | grep avc:` while reproducing — shows every
  denial as it fires, not just the BEAM-induced ones.
- `adb shell ls -lZ /sys/fs/cgroup` — confirms the SELinux label OTP is
  hitting (`u:object_r:cgroup:s0`).
- The OTP source: `erts/lib_src/common/erl_misc_utils.c` lines 1072–1322
  (cgroup detection) is the entire surface area we'd need to patch.

**Reference** — Android SELinux policy for `untrusted_app_*` lives at
<https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/untrusted_app_all.te>.
The cgroup access rules tightened around the API 34/35 transition; API
37 is even stricter.

---

## 11. Android Compose semantics walker not implemented (`ui_tree`/`ax_action` Android-side)

**Symptom** — verified 2026-04-30 against `mob_test` on a Moto E:

```
ui_tree/1                    {:error, :not_loaded}            (MobBridge.uiTree() not in Kotlin)
ax_action/3                  {:error, :not_supported_on_android}  (NIF stub)
ax_action_at_xy/4            {:error, :not_supported_on_android}  (NIF stub)
toggle/2, dismiss_alert/2,   {:error, :ui_tree_unavailable}   (depend on the above)
adjust_slider/4
```

`screen_info/1`, `view_tree/1`, `tap/2` (by tag), `screen/1`, `assigns/1`,
`back/1`, `find_view/2` all work. The ax-action family is Android-blind today.

**Why** — `mob_nif:ui_tree/0` calls a `MobBridge.uiTree()` static method that
doesn't exist in `MobBridge.kt` (the C side gracefully returns
`{:error, :not_loaded}` if the symbol's missing). `mob_nif:ax_action/2` and
`ax_action_at_xy/3` were added to the iOS NIF as part of the WireTap test
harness work; their Android counterparts are NIF stubs that return
`{:error, :not_supported_on_android}` so callers get a clear error instead of
crashing.

**The right Android implementation is a Compose semantics walker.** Mob's
Android renderer is Compose, so the View tree walk stops at a single
`AndroidComposeView`. To populate `ui_tree` (or its replacement) and to drive
AX actions, `MobBridge.kt` needs to:

1. Find every `AndroidComposeView` in the View hierarchy (one per Compose
   root — activity content + dialogs + popups).
2. Pull the `SemanticsOwner` from each (`@RestrictTo` API; reflection or
   suppress, like UIAutomator and the Compose Inspector do).
3. Walk `SemanticsNode.children`, extracting `boundsInWindow`,
   `SemanticsProperties.{Text, ContentDescription, Role, EditableText,
   StateDescription, ProgressBarRangeInfo, …}`.
4. Emit each node in the same `{type, label, value, {x,y,w,h}}` shape (in dp,
   to match iOS).
5. Look up actions on each node via `SemanticsActions.{OnClick, ScrollBy,
   SetProgress, Dismiss, …}` and invoke them for `ax_action`/
   `ax_action_at_xy`.

**Cost estimate** — ~200 lines Kotlin in `MobBridge.kt` template (must also
land in `mob_new`'s template so future-generated apps get it), ~50 lines
extra in `nif_ax_action`/`nif_ax_action_at_xy` to actually call into the new
Kotlin methods. Roughly one focused day for v1; ongoing maintenance as
Compose's `@RestrictTo` reflection paths break across major releases (ref
UIAutomator's git history).

**Where this lands** — WireTap-side concern, but the Mob library hosts the
NIF stubs. Implementation belongs in WireTap (or in `mob_new`'s template if
we want it available to all Mob apps without WireTap).

**Priority** — medium-high if you want `Mob.Test.adjust_slider`/`toggle`/etc.
to work on Android. Low if Mob apps are happy driving via tag-based
`Mob.Test.tap/2` and `Mob.Test.send_message/2`, which work fine on Android
today.

**Related operational note (BeamForegroundService)** — when iterating on
Android NIF/Kotlin changes, `mix mob.deploy --native --device <serial>` does
NOT fully restart the BEAM. Mob's `BeamForegroundService` outlives the
Activity restart, so the BEAM keeps running with the OLD `.so` and `.beam`
loaded. To pick up new NIF symbols, force-stop **both** packages:

```bash
adb -s <serial> shell am force-stop com.example.<app>
adb -s <serial> shell am force-stop com.mob.<app>      # foreground service
adb -s <serial> shell am start -n com.example.<app>/.MainActivity
```

Otherwise calls to new NIF functions return `:undef` (BEAM module not
reloaded) or `:not_loaded` (NIF library cached) even though the new
artifacts are on disk.

---

## 12. iOS `TextField` ignores `value:` prop updates after first render — **FIXED 2026-05-01**

> **Resolution.** Two-part fix:
> 1. **`ios/mob_nif.m`** — the prop parser was reading `text:` for all node
>    types, but app code (and Mob's own demos) pass `value:` for text fields,
>    matching the React/SwiftUI controlled-input convention. Added a
>    `MobNodeTypeTextField`-gated read of `props[@"value"]` that maps into
>    `node.text`. If both `text:` and `value:` are passed, `value:` wins.
> 2. **`ios/MobRootView.swift`** — added `.onChange(of: initialText)` to
>    `MobTextField`. When the parent re-renders with a new value AND the
>    field is *not* currently focused, the SwiftUI `@State` is synced to the
>    new value. The `!isFocused` guard prevents the cursor from being yanked
>    while the user is mid-edit.
>
> Verified end-to-end on `air_cart_max`: programmatically setting
> `tank.rate_lb_per_ac = 120.0` from a `handle_info` clause now surfaces in
> the field on the next render.



**Symptom** — A `:text_field` rendered with `value: assigns.foo` shows the
initial value correctly, but subsequent re-renders that change `value:`
(e.g. via `Mob.Socket.assign(:foo, "100")` from a `handle_info` clause that
isn't `:change`-driven) do **not** update what the field displays. The
underlying socket assigns are updated and the rest of the screen
re-renders, but the field stays stuck at its first-rendered value (or
empty/placeholder if nothing was set on first render).

Hit while building Air Cart Maximiser (`~/code/air_cart_max`):

```elixir
# Tank product cycles to "wheat" → set rate to default 100.0 in same handler
def handle_info({:tap, {:cycle_product, idx}}, socket) do
  ...
  new_tanks = List.update_at(cart.tanks, idx, fn t ->
    %{t | product_id: next_id, rate_lb_per_ac: 100.0}   # set rate here
  end)
  {:noreply, Mob.Socket.assign(socket, :cart, %{cart | tanks: new_tanks})}
end

# Render passes value: from the updated cart
%{type: :text_field, props: %{value: format_rate(tank.rate_lb_per_ac), ...}}
```

After cycling, the text field stays empty (showing placeholder "lb/ac")
even though `cart.tanks[idx].rate_lb_per_ac == 100.0` and other widgets
reflecting that assigns value (the per-tank "ac/fill" calc, the bottom
total) update correctly. Only the text field's display is stale.

**Why (suspected)** — iOS `UITextField` is "uncontrolled" — once the field
is created, its `.text` is owned by the UIKit object and the SwiftUI
renderer only reads from it via `@State` / `@Binding`. The Mob renderer
likely creates the field on first render and then never reassigns
`.text` on subsequent diffs (or the diff matches by position and the
shouldDiff check skips re-binding the value). User-driven `on_change`
events still flow correctly because UIKit fires those from the field's
own state.

**Workaround in app code** — let the user be the source of truth for the
text. Don't programmatically set values that should appear in a field
unless they came from a `:change` event. Document defaults in the
placeholder, not by pre-filling the value.

**Fix options for Mob**

1. **Force the binding to update on diff.** If the diff sees a new
   `value:` prop that doesn't match the field's current text, explicitly
   set `.text` (UIKit) or update the `@State` (SwiftUI) before returning.
   Risk: if the user is mid-edit and the parent re-renders, the field
   could yank the cursor. Mitigation: only re-set if not first responder.

2. **Document the limitation.** Add a note to the `:text_field` docs that
   it's user-source-of-truth and `value:` is read only on first render.
   This matches how iOS-native developers think about UITextField, and
   keeps the workaround in app code (don't auto-fill).

3. **Add an explicit `controlled?: true` prop.** Opt-in two-way binding
   for screens that want React-style controlled inputs. Default off (no
   surprise). Wire path: `controlled?: true` on the props side becomes a
   `@Binding` on the SwiftUI side instead of a one-shot initial value.

**Where this matters** — any screen with text fields whose value can
change for reasons other than user typing: programmatic clearing,
loading from persistence, computed defaults, undo/redo, or cross-field
auto-population (zip → city kind of thing).

---

## 13. iOS keyboard "Done" toolbar shows one button per `:text_field` on screen — **FIXED 2026-05-01**

> **Resolution.** Wrapped the contents of `MobTextField`'s
> `ToolbarItemGroup(placement: .keyboard)` in an `if isFocused { ... }`
> guard. Previously every `MobTextField` in the view tree contributed its
> own Spacer + Done button to the merged keyboard accessory toolbar.
> Now only the focused field's button shows.
>
> Verified on `air_cart_max` HomeScreen with 4 rate fields visible: was 4
> stacked Dones, now 1.



**Symptom** — When a screen has multiple `:text_field` widgets, focusing
any one of them brings up the iOS keyboard with an accessory toolbar
showing **one "Done" button per text field on the screen**, all stacked
horizontally:

```
[ Done ] [ Done ] [ Done ] [ Done ]
```

Tapping any Done dismisses the keyboard correctly (eventually — sometimes
takes two taps). But the visual is confusing — looks like there are
multiple actions when really they're all the same "dismiss" action.

Reproduced on `~/code/air_cart_max` HomeScreen with 4 tank rows each
containing a `:text_field` for the rate input. iPhone 17 sim, iOS 26.4.

**Why (suspected)** — Mob's `:text_field` likely attaches a per-field
`UIToolbar` as the field's `inputAccessoryView`. When iOS shows the
keyboard for one focused field, it apparently surfaces all visible
toolbars, not just the focused field's.

More likely: each field's accessory view is the same shared toolbar
instance and iOS is rendering one `Done` per field in some flow-layout
parent.

**Workaround** — none. Doesn't break functionality, just looks bad. Users
learn to tap any of the Dones.

**Fix options**

1. **Single shared accessory view per screen, owned by the screen, not
   per field.** When any field becomes first responder, attach the one
   shared toolbar. Detach on blur. Cost: a screen-level coordinator.

2. **Drop the toolbar entirely; rely on `return_key:`** — the on-screen
   keyboard already has a Done/Return key. The `inputAccessoryView`
   toolbar is redundant in most cases. Could be opt-in via
   `accessory_toolbar?: true` for screens that genuinely need it.

3. **Conditional toolbar** — only attach the accessory if the keyboard
   doesn't natively offer a way to dismiss (e.g. `keyboard: :decimal`
   on iPhone where the number pad has no return key). For other
   keyboards, no toolbar.

Recommendation: **(2) drop by default + opt-in flag** is the cleanest.
The number-pad case from (3) is the only place a toolbar is genuinely
useful, and even then a single shared toolbar (1) avoids the stacking
problem.

---

## 14. iOS sim's distribution node name doesn't match `mix mob.connect`'s expectation — **WORKED AROUND 2026-05-10**

> **Resolution.** Option (1) from the fix list — defensive fallback in
> `mob_dev/lib/mob_dev/connector.ex`. `wait_for_nodes/2` now builds a
> per-device candidate list and tries each in parallel via
> `try_connect_each/2`. For iOS sims the list is
> `[<app>_ios_<short>@127.0.0.1, <app>_ios@127.0.0.1]`; first responder
> wins and the connected `Device.node` is updated to whichever name
> actually registered. The output surfaces the alternate name when the
> fallback is used so the user can copy it for direct RPC.
>
> **Root cause still TBD.** The fallback works around the symptom but
> doesn't explain why `mob_beam.m`'s `getenv("SIMULATOR_UDID")` sometimes
> returns NULL in launch contexts where it should be set. Worth
> investigating: confirm via `simctl spawn <udid> printenv | grep SIM`
> on a freshly-deployed sim, then trace through the launcher chain
> (`xcrun simctl install` then user-tap vs `simctl launch`). The fix
> there belongs in mob_beam.m (or the launch path that drops the var).

**Symptom** — After `mix mob.deploy --native --ios --device <sim-udid>`,
running `mix mob.connect --no-iex` shows the sim node as a timeout while
a physical iPhone (also running the same app, deployed earlier) connects
fine over LAN:

```
  air_cart_max_ios_78354490@127.0.0.1 ...  ✗     ← sim, expected node
  air_cart_max_ios@10.0.0.120 ...  ✓             ← physical iPhone
  ✗ iPhone 17: timed out waiting for air_cart_max_ios_78354490@127.0.0.1
Connected cluster (1 node(s)):
  ✓ air_cart_max_ios@10.0.0.120  [port 9101]
```

The sim's app launches, renders correctly, and is interactive (verified
via `mcp__ios-simulator__ui_*` tools). It's just not appearing in EPMD
under the expected name.

**Why (suspected)** — `mix mob.connect` constructs the expected sim node
name as `<app>_ios_<udid-prefix>@127.0.0.1` (per-sim suffix to avoid
collision when multiple sims are booted), but the iOS BEAM startup in
`mob_beam.m` derives its node name differently — possibly just
`<app>_ios@127.0.0.1` (no suffix) or it picks up a stale env var from
`SIMCTL_CHILD_*`.

**Impact** — agent can't use `Mob.Test.tap/find/assigns` against the sim,
which is the recommended primary inspection path per `guides/agentic_coding.md`.
Falls back to MCP tools (screenshots + AX tree), which work but are
slower and less precise (per the "Layer 1 first" guidance).

**Workaround for agents** — use the MCP tools (`mcp__ios-simulator__*`) for
sim verification. Use `Mob.Test` against any connected physical device
(which gets the simpler `<app>_ios@<lan-ip>` naming).

**Fix options**

1. **Reconcile the naming.** Either `mob_dev/lib/.../connect.ex` should
   probe both `<app>_ios@127.0.0.1` and `<app>_ios_<udid-prefix>@127.0.0.1`
   in parallel and use whichever responds, or `mob_beam.m` should always
   use the per-UDID-prefix form when running under a sim.

2. **Print the actual registered name from the sim's app log.** Even if
   mob_dev's expectation is wrong, surfacing what the sim is actually
   registered as would give the user a node name they can use directly.

3. **Make sim distribution opt-out, not opt-in.** Currently sim
   distribution is best-effort and silently degrades. Make it a hard
   requirement when `--device <sim-udid>` is passed and surface the
   mismatch loudly.

**Where this matters** — every dev iteration on a sim. This is the
agentic-coding loop's foundation; if `Mob.Test` doesn't work against
the sim, agents lose the fast path and burn cycles on screenshots.

---

## 15. `mix mob.add_nif --type zigler` — Zig toolchain mismatch (FIXED for the PATH-priority bug; **partial: macOS 26 upstream incompat remains**, 2026-05-12)

**Resolution (partial, 2026-05-12, mob_dev commit forthcoming):** The
scaffold now queues `mix zig.get` after adding the `:zigler ~> 0.15`
dep, so Zigler installs and uses its pinned Zig 0.15.2 from the
user-cache directory instead of falling through to
`System.find_executable("zig")` (which on this machine picks up the
mob-pinned 0.17-dev). A test pins the contract: every
`--type zigler` scaffold run must queue `zig.get`. The moduledoc on
the generated stub now spells out the toolchain pin so users
understand why `mix zig.get` ran.

**Still broken on macOS 26 (Sequoia/Tahoe):** even with the correct
Zig 0.15.2, building the example NIF on macOS 26 fails with a
cascade of undefined symbols starting with
`__availability_version_check`. This is a Zig-stdlib /
compiler_rt issue tracked upstream — Zig 0.15 was built before
macOS 26's tighter library linking and references SDK symbols that
the newer linker won't resolve. The fix is Zig 0.16+ (which Zigler
0.15.2 doesn't yet support). Linux and older macOS are unaffected.



**Symptom** — After scaffolding with `mix mob.add_nif foo --type zigler`,
`mix compile` fails inside the zigler dep's sema phase:

```
/_build/dev/lib/zigler/priv/beam/get.zig:718:12: error: invalid builtin function: '@Type'
    return @Type(.{ .@"struct" = constructed_struct });
/_build/dev/lib/zigler/priv/beam/payload.zig:36:12: error: invalid builtin function: '@Type'
    return @Type(result_type_info);
/_build/dev/lib/zigler/priv/beam/sema.zig:282:27: error: root source file struct 'fs' has no member named 'File'
    const stdout = std.fs.File.stdout();
```

**Why** — `:zigler ~> 0.15` resolves to `zigler 0.15.2`, which targets a
Zig stdlib snapshot from before the `@Type` builtin signature change
and before `std.fs.File.stdout()` was removed. The installed Zig
(currently `0.17.0-dev.269+ebff43698`, the version mob_dev builds with)
is past both changes.

The Elixir-side scaffolding itself is correct — it emits a clean
`use Zig, otp_app: :app` module with an example `pub fn` in a `~Z`
sigil. The bug is only the version pin.

**Fix options**

1. **Bump the zigler dep pin.** Check what version of zigler (if any)
   tracks Zig 0.17-dev. If a newer zigler release is compatible, bump
   the version in `MobDev.AddNif.maybe_add_zigler_dep/2`.

2. **Pin Zig instead.** Mob already pins a specific Zig version via
   `~/zig/zig-aarch64-macos-0.17.0-dev.269+ebff43698/`. If zigler 0.15
   needs an earlier Zig, document the supported range, or vendor a
   second Zig install for the zigler path.

3. **Skip zigler-via-Hex entirely.** Zigler's "compile a .so" model
   doesn't fit Mob's static-link constraint anyway (the moduledoc
   already warns about this). The static-link path requires manual
   wire-up regardless of zigler. Consider removing `--type zigler`
   from `mob.add_nif` and pointing users at writing the Zig directly
   through the existing `ios/build.zig` + `android/jni/*.zig`
   pipelines that the framework already uses.

**Where this matters** — anyone trying `mix mob.add_nif --type zigler`
hits this on first compile. The error is multi-line stdlib-internal
output that doesn't suggest "your version pin is wrong" — easy to
read as "Zigler is broken" and give up.

**Empirically verified 2026-05-12** in `~/code/test_migration` against
`zigler 0.15.2` + `zig 0.17.0-dev.269`. The Elixir scaffold ran cleanly
(stub + mob.exs entry + driver_tab regen all succeeded); the failure is
purely the dep's Zig source not matching the installed Zig.

---

## 16. `mix mob.add_nif --type rustler` Rust crate fails to link on macOS host (no `-undefined dynamic_lookup`) — **FIXED 2026-05-12**

**Resolution (2026-05-12, mob_dev commit forthcoming):** The
scaffold now emits `native/<name>/.cargo/config.toml` with the
required `rustflags` for both Apple targets:

```toml
[target.aarch64-apple-darwin]
rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]

[target.x86_64-apple-darwin]
rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]
```

Empirically verified: scaffolding `mix mob.add_nif foo_rustler
--type rustler` and running `mix compile` on macOS arm64 now
succeeds (links to `priv/native/foo_rustler.so`). A test pins
the contract — every `--type rustler` scaffold run creates a
`.cargo/config.toml` with both targets and the dynamic_lookup
flags.

Linux is unaffected — `rustflags` scope is Apple-only.



**Symptom** — After scaffolding with `mix mob.add_nif foo --type rustler`,
`mix compile` invokes Cargo which fails the link step:

```
Undefined symbols for architecture arm64:
  "_enif_raise_exception", referenced from:
    rustler::codegen_runtime::NifReturned::apply in librustler-*.rlib
  "_enif_schedule_nif", referenced from:
    rustler::codegen_runtime::NifReturned::apply in librustler-*.rlib
ld: symbol(s) not found for architecture arm64
error: could not compile `foo_rustler` (lib) due to 1 previous error
```

**Why** — Rustler's default `crate-type = ["cdylib"]` builds a `.dylib`
that gets `dlopen`'d at NIF load. The `enif_*` symbols come from the
*host* BEAM process at load time, not from a library the .dylib links
against. Apple's `ld` errors out on the undefined symbols unless told
explicitly to defer them.

On Linux this isn't an issue (`ld.bfd`/`ld.lld` defer by default). On
macOS, Rustler-on-host needs `.cargo/config.toml`:

```toml
[target.aarch64-apple-darwin]
rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]

[target.x86_64-apple-darwin]
rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]
```

Our scaffolding doesn't emit this file. The user hits the cryptic
link error and has to know to search "Rustler macOS undefined symbols"
to find the answer.

**Fix** — `MobDev.AddNif.add_rustler_files/3` (the writer that creates
`native/<name>/Cargo.toml` + `src/lib.rs` + `.gitignore`) should also
emit `native/<name>/.cargo/config.toml` with the dynamic_lookup
rustflags pinned for both Apple targets.

Note the static-link path that Mob actually ships with is different —
the moduledoc warns this scaffold's default `cdylib` won't work on
iOS/Android anyway; the user has to switch to `staticlib` and wire
the resulting `.a` into `ios/build.zig` + `android/jni/`. But the
host-dev flow (sim, `mix run`) should at least compile cleanly so
the user can iterate before doing the static-link work.

**Empirically verified 2026-05-12** in `~/code/test_migration` against
`rustler 0.37.3`. Scaffold succeeded; first `mix compile` failed at
the cdylib link step on macOS arm64.

---

## 17. NIF surface discoverability — `--python` vs `--type {c, zigler, rustler}`

**Symptom** — Three NIF-related Mix surfaces, three different shapes:

- `mix mob.add_nif <name> --type {c, zigler, rustler, elixir-only}`
  — scaffold a *new* NIF (you write the native side).
- `mix mob.enable pythonx` — wire a *pre-built* hex NIF dep (CPython)
  into an existing project, including OTP-bundle changes.
- `mix mob.new --python` — sugar for "generate project then enable
  pythonx".

A user thinking "I want to add a NIF" finds `mob.add_nif`, sees C/
Zigler/Rustler under `--type`, and reasonably wonders why pythonx
isn't there.

**Why the split exists** — they're conceptually different:

- `add_nif` produces *stubs to fill in* (your own C/Rust/Zig).
- `enable pythonx` *wires a third-party prebuilt NIF dep* — there's no
  user-written native code, but there IS OTP-runtime work (bundling
  Python.framework on iOS, packaging the Android Python lib dir).

Future third-party NIF deps that need similar bundling work (a
TensorFlow Lite wrapper, an OpenCV wrapper, a RocksDB NIF) would
naturally also live under `mob.enable`, not `mob.add_nif`. Conflating
the two surfaces will eventually break.

**Fix options**

1. **Add a discoverability alias.** `mob.add_nif --type pythonx`
   becomes a thin shim that prints `"pythonx is a third-party dep,
   delegating to mob.enable pythonx"` and chains to it. Cheap; keeps
   the conceptual split clean; surfaces the right command via the
   wrong one.

2. **Document the split in both task moduledocs.** `mob.add_nif`'s
   `@moduledoc` mentions "for third-party NIF deps, see `mob.enable`";
   `mob.enable`'s mentions the inverse. Cheapest; relies on users
   reading `--help`.

3. **Keep both routes.** `mob.add_nif --type pythonx` does the same
   thing as `mob.enable pythonx`. Most consistent surface, but
   conflates the two concepts conceptually (a user might then expect
   `mob.add_nif --type tflite` to also Just Work).

**Recommendation** — (1) for now. The split is conceptually right,
but discoverability is poor.

**Where this matters** — when a user types `mix mob.add_nif --help`
and tries to figure out how to add Python.

---

## 18. NIF source auto-wiring missing for `mob.add_nif --type {c, rustler}` builds

**Symptom** — After `mix mob.add_nif foo --type c`, the next native
build (`mix mob.deploy --native`) leaves `c_src/foo.c` unlinked.
On Elixir-side, `:erlang.load_nif/2` fails with:

```
The on_load function for module Elixir.<App>.Nifs.Foo returned:
  {:error, {:load_failed,
    "Failed to load NIF library: 'dlopen(foo.so, 0x0006): tried: ...'"}}
```

(BEAM fell through from the static-NIF table to dlopen because
nothing registered `<name>_nif_init` at link time.)

The C scaffold's moduledoc currently tells the user to do this
manually — but the right scaffolding action is to auto-wire it.

**Why this matters now** — `--demo` made this gap visible because
the demo flow expects the C NIF to actually work. Verified manually:
hand-adding an `addCObject` block + `-DSTATIC_ERLANG_NIF
-DSTATIC_ERLANG_NIF_LIBNAME=<name>` flags to `ios/build_device.zig`
gets the demo working end-to-end (Hello from C! on iPhone).

**Fix shape**

1. **iOS** — the `build_device.zig` template (in `mob_new`) and
   `build.zig` (sim) should iterate `:static_nifs` from `mob.exs`
   and emit an `addCObject` block for each entry that has a
   corresponding `c_src/<name>.c` file. The `c_flags` need
   `-DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=<name>` baked
   in.

2. **Android** — equivalent in `android/jni/CMakeLists.txt`: glob
   `${PROJECT_ROOT}/c_src/*.c` (or read `mob.exs :static_nifs`)
   and add to `target_sources` with the same -D flags.

3. **`mob.regen_driver_tab`** could grow a side-effect that lists
   which `c_src/*.c` files exist and warns if the project's
   `build.zig` / CMakeLists isn't picking them up. Belt-and-braces.

**Workaround until then** — hand-edit `ios/build_device.zig` to add:

```zig
installAndCollect(b, objects_step, &objs, addCObject(b, .{
    .name = "<your_nif>",
    .source = "<project>/c_src/<your_nif>.c",
    .target = target,
    .optimize = optimize,
    .c_flags = c_flags_base ++ &[_][]const u8{
        "-DSTATIC_ERLANG_NIF",
        "-DSTATIC_ERLANG_NIF_LIBNAME=<your_nif>",
    },
    .mob_dir = mob_dir,
    .otp_root = otp_root,
    .erts_vsn = erts_vsn,
    .sdkroot = sdkroot,
}), "<your_nif>.o");
```

The two -D flags are mandatory: without `STATIC_ERLANG_NIF_LIBNAME`,
`ERL_NIF_INIT(Elixir.App.Nifs.Foo, ...)` mangles to an invalid C
symbol name (dots in identifiers don't compile).

**Empirically verified 2026-05-12** via the demo screen flow in
`~/code/test_migration`. The full diagnosis lives in
`mob_dev/lib/mix/tasks/mob.add_nif.ex`'s `c_skeleton/3` docstring.

### Rustler is in the same boat (verified 2026-05-12)

Same gap, harder shape:

1. **Cargo `crate-type`** — scaffolded as `cdylib` (for host-dev
   ergonomics). iOS device needs `staticlib`. Add both:
   `crate-type = ["staticlib", "cdylib"]`. The Mob scaffold should
   emit this dual form by default — host-dev still gets the
   `.dylib`, iOS device gets the `.a`.
2. **Cross-compile target** — `rustup target add aarch64-apple-ios`
   is a one-time setup the scaffold doesn't run. `mix mob.doctor`
   could check for this and prompt.
3. **Invoke cross-compile** — Rustler's mix integration only knows
   about the host target. iOS device needs:
   ```bash
   cd native/<name> && cargo rustc --release \
       --target aarch64-apple-ios --crate-type staticlib
   ```
   This isn't wired into `mix mob.deploy --native`.
4. **Link the `.a` into iOS build** — hand-add `run.addArg(...)`
   for `native/<name>/target/aarch64-apple-ios/release/lib<name>.a`
   inside `addLink()` in `ios/build_device.zig`. Same pattern as
   the `sqlite_static_lib` hook already there.
5. **Rustler crate version pin** — scaffold currently pins
   `rustler = "0.32"` in the generated `Cargo.toml`. Rustler 0.32
   hardcodes `nif_init` (no per-crate symbol). Rustler 0.37+ derives
   `<crate>_nif_init` from `CARGO_CRATE_NAME` automatically, which
   is exactly what mob's static-NIF table expects. **Bump the
   Cargo.toml template to `rustler = "0.37"` (or latest).**
6. **rustler::init! deprecation** — the macro warns "deprecated:
   only one argument expected" with the 0.37 form. The scaffold's
   `rustler::init!("Elixir.<Mod>", [greet]);` should drop the
   functions list and use `#[rustler::nif]` exclusively (auto-
   discovery via inventory).

**Empirically verified 2026-05-12 on physical iPhone**:
- Scaffolded `mix mob.add_nif greet_rust --type rustler --demo --yes`
- Hand-bumped `Cargo.toml` to `rustler = "0.37"` and added
  `staticlib` to crate-type.
- `cargo rustc --release --target aarch64-apple-ios --crate-type staticlib`
- Hand-added the `.a` to addLink's lib list in `build_device.zig`.
- `mix mob.deploy --native --ios-device` → succeeds.
- `Mob.Test.tap(node, :run)` →
  `result: "Hello from Rust!"` and
  `[info] [greet_rust-nif] call 1 returned: "Hello from Rust!"`

So the path works; what's missing is automation. Steps 1-2 are
scaffold-side (mob_dev). Steps 3-4 are build-template-side
(mob_new templates). Step 5 is a one-line bump. Step 6 is a
template polish.

### Zigler — blocked upstream

`mob.add_nif --type zigler --demo` fails at host compile on macOS 26
before iOS even enters the picture (issue #15). Until Zigler supports
Zig 0.16+, no automated iOS-device path is possible on this Mac.
Linux and older macOS users can verify zigler --demo end-to-end
following the same pattern as C/Rust above.
