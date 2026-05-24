# mob_dev / mob_new Patch Spec — IAP Plugin Integration

Generated from end-to-end testing of `mob_iap` on iOS simulator and Android emulator.
Date: 2026-05-23

---

## 1. Android `audio_play_at` crash — `mob_new` template

**Root cause:** The generated `MobBridge.kt` has `audio_play(pid, path, optsJson)` but the NIF table declares `audio_play_at/3`, and `mob_nif.zig` `nifLoad` calls `cacheRequired(jenv, "audio_play_at", "(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)V", ...)`. When this lookup fails, `nifLoad` returns `-1`, the BEAM NIF load fails, and the app crashes with `NoSuchMethodError`.

**File to edit:** `mob_new/priv/templates/mob.new/android/app/src/main/java/<%= @app_module_underscore %>/MobBridge.kt.eex`

**Add after the existing `audio_play` method (around line 810 in generated output):**

```kotlin
    @JvmStatic
    fun audio_play_at(pid: Long, path: String, optsJson: String, atStr: String) {
        playbackPid  = pid
        playbackPath = path
        val activity = activityRef?.get() ?: return
        activity.runOnUiThread {
            try {
                audioPlayer?.release()
                audioPlayer = null
                val opts = org.json.JSONObject(optsJson)
                val loop   = opts.optBoolean("loop", false)
                val volume = opts.optDouble("volume", 1.0).toFloat()
                val player = MediaPlayer()
                player.setDataSource(path)
                player.isLooping = loop
                player.setVolume(volume, volume)
                player.setOnCompletionListener {
                    val p = playbackPid
                    val pp = playbackPath ?: ""
                    audioPlayer = null
                    playbackPath = null
                    val json = """[{"path":"$pp"}]"""
                    nativeDeliverFileResult(p, "audio", "playback_finished", json)
                }
                player.setOnErrorListener { _, _, _ ->
                    val p = playbackPid
                    audioPlayer = null
                    playbackPath = null
                    nativeDeliverAtom3(p, "audio", "playback_error", "player_error")
                    true
                }
                player.prepare()
                val atMs = atStr.toLongOrNull() ?: 0L
                if (atMs > 0) {
                    player.seekTo(atMs.toInt())
                }
                player.start()
                audioPlayer = player
            } catch (e: Exception) {
                nativeDeliverAtom3(pid, "audio", "playback_error", "setup_failed")
            }
        }
    }
```

**Rationale:** `atStr` is a wall-clock-ms-since-1970 timestamp passed as a string (because `enif_get_int64` isn't dynamically exported on Android). The method is identical to `audio_play` plus a `seekTo` call before `start()`.

---

## 2. iOS auto-discovery of plugin Swift sources — `mob_dev`

**Current state:** The iOS `build.zig` template already accepts `-Dproject_swift_sources=<comma-separated-paths>` and iterates them into the `swiftc` invocation. However, `mob_dev` (in `NativeBuild` or the Mix task that invokes `zig build`) passes an empty string for this flag.

**File to edit:** `mob_dev/lib/mob_dev/native_build.ex` (or wherever `project_swift_sources` is assembled for the zig invocation)

**Logic to add:** Before invoking `zig build`, scan all dependencies (direct + transitive) for files matching:
- `<dep_path>/priv/native/ios/*.swift`

Collect absolute paths, join with `,`, and pass as `-Dproject_swift_sources=<joined_paths>`.

**Example in the generated `build.zig` (already present in template):**
```zig
const project_swift_sources = b.option([]const u8, "project_swift_sources", "Comma-separated paths to plugin .swift files") orelse "";
```

**And the consumption (already present in template):**
```zig
if (project_swift_sources.len > 0) {
    var it = std.mem.splitScalar(u8, project_swift_sources, ',');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        swift_run.addFileArg(.{ .cwd_relative = path });
    }
}
```

**What `mob_dev` needs to do:** Populate that flag by scanning deps. The scan should look at each dependency's directory and check if `priv/native/ios/` contains `.swift` files.

---

## 3. Android auto-discovery of plugin C/Kotlin sources — `mob_dev` + `mob_new` template

**Current state:** The Android `build.zig` template has a hardcoded `sources` array:
```zig
const sources = [_]CObjectSpec{
    .{ .name = "driver_tab_android", .source = driver_tab },
    .{ .name = "mob_nif", .source = b.fmt("{s}/android/jni/mob_nif.zig", .{mob_dir}) },
    .{ .name = "mob_beam", .source = b.fmt("{s}/android/jni/mob_beam.zig", .{mob_dir}) },
    .{ .name = "beam_jni", .source = b.fmt("{s}/beam_jni.c", .{project_jni_dir}) },
};
```

Plugin C sources (like `mob_iap`'s `iap.c`) are not included.

**File to edit:** `mob_new/priv/templates/mob.new/android/app/src/main/jni/build.zig.eex`

**Template change — add a `project_plugin_sources` option and iterate it:**

After the existing `sources` array and before the `obj_paths` loop, add:

```zig
    // Plugin native sources (auto-discovered by mob_dev from deps).
    // Each entry: "name:path" where name is the .o basename and path is
    // the absolute source path. mob_dev scans priv/native/android/jni/
    // and priv/native/android/ for .c and .kt files.
    const project_plugin_sources = b.option([]const u8, "project_plugin_sources", "Comma-separated name:path pairs for plugin native sources") orelse "";
```

Then in the `for (sources)` loop or after it, add:

```zig
    if (project_plugin_sources.len > 0) {
        var plug_it = std.mem.splitScalar(u8, project_plugin_sources, ',');
        while (plug_it.next()) |pair| {
            if (pair.len == 0) continue;
            var colon_it = std.mem.splitScalar(u8, pair, ':');
            const name = colon_it.next() orelse continue;
            const path = colon_it.next() orelse continue;
            // Skip if already in sources (defensive)
            const obj = addCObject(b, .{
                .name = name,
                .source = path,
                .target = target,
                .optimize = optimize,
                .c_flags = c_flags,
                .otp_dir = otp_dir,
                .erts_vsn = erts_vsn,
                .mob_dir = mob_dir,
            });
            const install = b.addInstallFile(obj, b.fmt("{s}/{s}.o", .{ abi, name }));
            c_objects_step.dependOn(&install.step);
            obj_paths.append(b.allocator, obj) catch @panic("OOM");
        }
    }
```

**`mob_dev` logic to add:** Scan deps for:
- `<dep_path>/priv/native/android/jni/*.c` — compile as C objects
- `<dep_path>/priv/native/android/*.kt` — compile as Kotlin (Gradle handles these; no zig involvement needed for Kotlin)

For `.c` files, produce `"name:path"` pairs where `name` is the filename without extension and `path` is the absolute path. Join with `,` and pass as `-Dproject_plugin_sources=...`.

**Note on Kotlin:** Plugin Kotlin files (like `MobIapBridge.kt`) are picked up by Gradle's default source set if they're in `src/main/java/...` or `src/main/kotlin/...`. The `mob_iap` plugin puts its Kotlin in `priv/native/android/MobIapBridge.kt`. For this to work, `mob_dev` or the generator needs to either:
- Copy/symlink plugin Kotlin files into the project's `android/app/src/main/java/com/<package>/` tree, OR
- Add the plugin's `priv/native/android/` directory as an additional source root in `build.gradle`

The simpler approach for `mob_new`/`mob_dev` is to copy plugin `.kt` files into the generated project at build time (similar to how C sources are discovered).

---

## 4. Inject `com.android.vending.BILLING` permission — `mob_new` template

**Current state:** The generated `AndroidManifest.xml` does not include the Play Billing permission when `:mob_iap` is a dependency.

**File to edit:** `mob_new/priv/templates/mob.new/android/app/src/main/AndroidManifest.xml.eex`

**Change:** Add a conditional EEx block around the existing permissions. After the `INTERNET` permission (or wherever appropriate), add:

```xml
    <%= if @uses_billing do %>
    <uses-permission android:name="com.android.vending.BILLING" />
    <% end %>
```

**`mob_new` generator logic:** In the Mix task that generates `mob.new`, check if the generated `mix.exs` dependencies include `:mob_iap`. If yes, set `uses_billing: true` in the template binding.

Alternatively, a simpler approach: always include the BILLING permission. It has no runtime effect if Play Billing isn't used (it's just a declaration). However, Google Play may flag it during review if the app doesn't actually implement IAP. Safer to make it conditional.

---

## Summary of files to change

| Repo | File | Change |
|---|---|---|
| **mob_new** | `priv/templates/mob.new/android/app/src/main/java/<%= @app_module_underscore %>/MobBridge.kt.eex` | Add `audio_play_at` method |
| **mob_new** | `priv/templates/mob.new/android/app/src/main/jni/build.zig.eex` | Add `project_plugin_sources` option + iteration |
| **mob_new** | `priv/templates/mob.new/android/app/src/main/AndroidManifest.xml.eex` | Add conditional BILLING permission |
| **mob_dev** | `lib/mob_dev/native_build.ex` (iOS zig invocation) | Scan deps for `priv/native/ios/*.swift`, populate `-Dproject_swift_sources` |
| **mob_dev** | `lib/mob_dev/native_build.ex` (Android zig invocation) | Scan deps for `priv/native/android/jni/*.c`, populate `-Dproject_plugin_sources` |
| **mob_dev** | Generator / build orchestration | Copy plugin `.kt` files from `priv/native/android/` into project tree before Gradle build |

---

## Verification commands (once patches applied)

```bash
# 1. Generate a fresh test app
mix mob.new iap_test2 --module IapTest2
cd iap_test2
# Add {:mob_iap, path: "~/Projects/mob/plugins/mob_iap"} to mix.exs
mix deps.get

# 2. iOS sim — should build without manual build.zig edits
mix mob.deploy --native --ios

# 3. Android — should build without manual build.zig edits
mix mob.deploy --native --android

# 4. Verify BILLING permission is in manifest
grep BILLING android/app/src/main/AndroidManifest.xml

# 5. Verify audio_play_at exists in generated MobBridge.kt
grep audio_play_at android/app/src/main/java/com/example/iap_test2/MobBridge.kt
```
