//! mob_beam.zig — Mob BEAM launcher and JNI bridge initialisation (Android).
//!
//! Phase 6b iter 2 of the build-system migration: Zig port of the original
//! mob_beam.c. Behaviour is intentionally byte-for-byte equivalent — every
//! load-bearing comment in the C version (cold-start race fix, SELinux exec
//! rules, Play Store split-APK fallback, exqlite/pythonx priv-dir symlinks)
//! is preserved verbatim because future maintainers will hit the same
//! constraints and need the same explanations in front of them.
//!
//! The FFI surface (JNI vtable, libc, Android log, dlfcn, pthreads) lives in
//! mob_zig.zig — see that file's header for why we hand-declare it (Zig
//! 0.17-dev's @cImport is gone and `zig translate-c` hangs on the NDK's
//! jni.h).
//!
//! Symbols defined elsewhere in the link:
//!   * mob_nif.c provides   `_mob_ui_cache_class_impl`,
//!                          `_mob_bridge_init_activity`,
//!                          `mob_set_startup_phase`,
//!                          `mob_set_startup_error`,
//!                          `g_jvm`, `g_activity`.
//!   * libbeam.a provides   `erl_start`.

const std = @import("std");
const jni = @import("mob_zig.zig");
const build_options = @import("build_options");

// ── Comptime build flags ──────────────────────────────────────────────────
// Compile-time knobs threaded in by build.zig via `b.addOptions()`.
//
//   * `no_beam` — Config A: baseline measurement. BEAM never launched, the
//     activity stays a stock Android shell. Used for battery benchmarks.
//   * `beam_flags_mode` — picks the default scheduler-tuning argv shape:
//       - "untuned":     no flags (stock Erlang defaults)
//       - "sbwt_only":   only -sbwt none / -sbwtdcpu / -sbwtdio (cuts the
//                        scheduler-busy-wait idle drain; lightest tuning)
//       - "nerves_full": full Nerves-style tuning (-S 1:1 -SDcpu 1:1 ...)
//                        (default)
//
// The runtime override (beams_dir/mob_beam_flags) supersedes either default.
const NO_BEAM: bool = build_options.no_beam;
const BEAM_FLAGS_MODE: []const u8 = build_options.beam_flags_mode;

// ── Logging ───────────────────────────────────────────────────────────────

const LOG_TAG: [*:0]const u8 = "MobBeam";

inline fn logi(comptime fmt: []const u8, args: anytype) void {
    jni.logWrite(jni.ANDROID_LOG_INFO, LOG_TAG, fmt, args);
}

inline fn loge(comptime fmt: []const u8, args: anytype) void {
    jni.logWrite(jni.ANDROID_LOG_ERROR, LOG_TAG, fmt, args);
}

inline fn lastErrno() [*:0]const u8 {
    return jni.strerror(jni.__errno().*);
}

// ── Externs from mob_nif.c ────────────────────────────────────────────────
// Forward declarations for symbols that live next to us in the final .so.
// These are defined by mob_nif.c (kept C in iter 2 — port in a later iter).

extern fn _mob_ui_cache_class_impl(env: *jni.JNIEnv, bridge_class: [*:0]const u8) callconv(.c) void;
extern fn _mob_bridge_init_activity(env: *jni.JNIEnv, activity: jni.JObject) callconv(.c) void;
extern fn mob_set_startup_phase(phase: [*:0]const u8) callconv(.c) void;
extern fn mob_set_startup_error(err: [*:0]const u8) callconv(.c) void;

// Global JVM pointer + Activity global ref. Defined in mob_nif.c, populated
// from JNI_OnLoad / mob_init_bridge. Both may be null until those run.
extern var g_jvm: ?*jni.JavaVM;
extern var g_activity: jni.JObject;

// ── Extern from libbeam.a ─────────────────────────────────────────────────
// BEAM entry point. erl_start blocks forever in the normal case; returning
// is an unexpected-exit condition we report and let the OS reap the process.
extern fn erl_start(argc: c_int, argv: [*]const ?[*:0]const u8) callconv(.c) void;

// ── Constants ─────────────────────────────────────────────────────────────

const ERTS_VSN: []const u8 = "erts-17.0";

// ── Module-level state ────────────────────────────────────────────────────
// Populated in mob_init_bridge, read by mob_start_beam. Sized generously
// so paths under /data/data/<package>/files/... never truncate.

var s_native_lib_dir: [512]u8 = @splat(0);
var s_files_dir: [512]u8 = @splat(0);

// Runtime BEAM flag override loaded from beams_dir/mob_beam_flags.
// In-place tokenised (NULs replace whitespace), pointers indexed into the
// buffer. Same shape as the C version.
var s_flags_buf: [512]u8 = @splat(0);
var s_runtime_flags: [64]?[*:0]const u8 = @splat(null);
var s_runtime_flag_count: usize = 0;

// ── Small helpers ─────────────────────────────────────────────────────────

/// Format `fmt`/`args` into `buf`, NUL-terminating the result. Returns a
/// `[*:0]const u8` view of the buffer. Mirrors `snprintf(buf, sizeof(buf), ...)`.
fn formatZ(buf: []u8, comptime fmt: []const u8, args: anytype) [*:0]const u8 {
    std.debug.assert(buf.len > 0);
    const slice = std.fmt.bufPrint(buf, fmt, args) catch buf[0 .. buf.len - 1];
    const end = @min(slice.len, buf.len - 1);
    buf[end] = 0;
    return @ptrCast(buf.ptr);
}

inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// ── BEAM stdout/stderr → logcat ──────────────────────────────────────────
// Without this, anything the BEAM writes to stderr (including ** crash
// reports from Logger and the boot script's :application.start/2 errors)
// is silently dropped on Android. Wire stdout + stderr to a pipe and read
// them on a detached thread, emitting each line under the "BEAMout" tag.
// One-shot: called once from mob_init_bridge before any BEAM code runs.
//
// See beam_crash.md (Incident #1) for the case that motivated this.

fn mobBeamLogReader(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const fd: c_int = @intCast(@intFromPtr(arg));
    var buf: [4096]u8 = undefined;
    var line: [4096]u8 = undefined;
    var line_pos: usize = 0;
    while (true) {
        const n = jni.read(fd, &buf, buf.len);
        if (n <= 0) break;
        const got: usize = @intCast(n);
        var i: usize = 0;
        while (i < got) : (i += 1) {
            const c = buf[i];
            if (c == '\n' or line_pos >= line.len - 1) {
                line[line_pos] = 0;
                if (line_pos > 0) {
                    const cstr: [*:0]const u8 = @ptrCast(&line);
                    _ = jni.__android_log_write(jni.ANDROID_LOG_INFO, "BEAMout", cstr);
                }
                line_pos = 0;
            } else if (c != '\r') {
                line[line_pos] = c;
                line_pos += 1;
            }
        }
    }
    return null;
}

fn mobCaptureBeamStdio() void {
    var pipe_fds: [2]c_int = undefined;
    if (jni.pipe(&pipe_fds) != 0) {
        loge("mob_capture_beam_stdio: pipe() failed: {s}", .{lastErrno()});
        return;
    }
    if (jni.dup2(pipe_fds[1], jni.STDOUT_FILENO) < 0) {
        loge("mob_capture_beam_stdio: dup2 stdout failed: {s}", .{lastErrno()});
    }
    if (jni.dup2(pipe_fds[1], jni.STDERR_FILENO) < 0) {
        loge("mob_capture_beam_stdio: dup2 stderr failed: {s}", .{lastErrno()});
    }
    _ = jni.close(pipe_fds[1]);

    var tid: jni.PthreadT = 0;
    const arg: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(pipe_fds[0])));
    if (jni.pthread_create(&tid, null, mobBeamLogReader, arg) != 0) {
        loge("mob_capture_beam_stdio: pthread_create failed: {s}", .{lastErrno()});
        _ = jni.close(pipe_fds[0]);
        return;
    }
    _ = jni.pthread_detach(tid);

    // Disable buffering so output reaches the pipe immediately, not on
    // exit (which we never reach for a long-running BEAM).
    _ = jni.setvbuf(jni.stdout, null, jni._IONBF, 0);
    _ = jni.setvbuf(jni.stderr, null, jni._IONBF, 0);
    logi("mob_capture_beam_stdio: piping stdout/stderr to logcat (tag: BEAMout)", .{});
}

// ── Public entry points ───────────────────────────────────────────────────

export fn mob_ui_cache_class(env: *jni.JNIEnv, bridge_class: [*:0]const u8) callconv(.c) void {
    _mob_ui_cache_class_impl(env, bridge_class);
}

export fn mob_init_bridge(env: *jni.JNIEnv, activity: jni.JObject) callconv(.c) void {
    // Capture BEAM stdio first so any startup errors (NIF load failures,
    // application:start/2 crashes) land in logcat instead of /dev/null.
    mobCaptureBeamStdio();

    const activity_global = jni.newGlobalRef(env, activity);
    g_activity = activity_global;
    _mob_bridge_init_activity(env, activity_global);

    // Get nativeLibraryDir so mob_start_beam can symlink ERTS executables there.
    // Files in the native lib dir carry the apk_data_file SELinux label which
    // allows execve() from untrusted_app, unlike files in app_data_file.
    const ctx_cls = jni.findClass(env, "android/content/Context");
    const get_app_info = jni.getMethodID(env, ctx_cls, "getApplicationInfo", "()Landroid/content/pm/ApplicationInfo;");
    const app_info = jni.callObjectMethod(env, activity, get_app_info);
    const app_info_cls = jni.findClass(env, "android/content/pm/ApplicationInfo");
    const fid = jni.getFieldID(env, app_info_cls, "nativeLibraryDir", "Ljava/lang/String;");
    const jdir = jni.getObjectField(env, app_info, fid);
    if (jni.getStringUTFChars(env, jdir)) |dir| {
        jni.copyZ(&s_native_lib_dir, dir);
        jni.releaseStringUTFChars(env, jdir, dir);
    }
    logi("mob_init_bridge: native lib dir = {s}", .{jni.asCStr(&s_native_lib_dir)});

    // Get filesDir for OTP root path (app-specific, avoids hardcoding package name).
    const get_files_dir = jni.getMethodID(env, ctx_cls, "getFilesDir", "()Ljava/io/File;");
    const files_dir_obj = jni.callObjectMethod(env, activity, get_files_dir);
    const file_cls = jni.findClass(env, "java/io/File");
    const get_path = jni.getMethodID(env, file_cls, "getPath", "()Ljava/lang/String;");
    const jfiles_path = jni.callObjectMethod(env, files_dir_obj, get_path);
    if (jni.getStringUTFChars(env, jfiles_path)) |fp| {
        jni.copyZ(&s_files_dir, fp);
        jni.releaseStringUTFChars(env, jfiles_path, fp);
    }
    logi("mob_init_bridge: files dir = {s}", .{jni.asCStr(&s_files_dir)});
}

export fn mob_start_beam(app_module: [*:0]const u8) callconv(.c) void {
    if (NO_BEAM) {
        // Config A: baseline measurement — stock Android activity, BEAM never launched.
        logi("mob_start_beam: NO_BEAM defined, skipping BEAM launch (battery baseline)", .{});
        return;
    }

    // Re-dlopen ourselves with RTLD_GLOBAL so the BEAM's enif_* symbols
    // (statically linked into this library) are visible when the BEAM
    // later dlopens a NIF library (e.g. crypto.so). Without this, Android
    // loads libpigeon.so with RTLD_LOCAL by default, hiding enif_* from
    // dlopen'd children — crypto.so on_load fails with
    // `cannot locate symbol enif_get_tuple`.
    {
        var self_path_buf: [600]u8 = undefined;
        const self_path = formatZ(&self_path_buf, "{s}/lib{s}.so", .{
            jni.asCStr(&s_native_lib_dir),
            app_module,
        });
        if (jni.dlopen(self_path, jni.RTLD_NOW | jni.RTLD_GLOBAL) == null) {
            const err: [*:0]const u8 = jni.dlerror() orelse "unknown";
            loge("mob_start_beam: dlopen self with RTLD_GLOBAL failed: {s}", .{err});
        } else {
            logi("mob_start_beam: re-dlopened self RTLD_GLOBAL: {s}", .{self_path});
        }
    }

    mob_set_startup_phase("Setting up BEAM environment…");

    // Build all paths dynamically from s_files_dir (set in mob_init_bridge).
    var otp_root_buf: [560]u8 = undefined;
    const otp_root = formatZ(&otp_root_buf, "{s}/otp", .{jni.asCStr(&s_files_dir)});

    var bindir_buf: [600]u8 = undefined;
    const bindir = formatZ(&bindir_buf, "{s}/{s}/bin", .{ otp_root, ERTS_VSN });

    var beams_dir_buf: [600]u8 = undefined;
    const beams_dir = formatZ(&beams_dir_buf, "{s}/{s}", .{ otp_root, app_module });

    var elixir_dir_buf: [600]u8 = undefined;
    const elixir_dir = formatZ(&elixir_dir_buf, "{s}/lib/elixir/ebin", .{otp_root});

    var logger_dir_buf: [600]u8 = undefined;
    const logger_dir = formatZ(&logger_dir_buf, "{s}/lib/logger/ebin", .{otp_root});

    var eex_dir_buf: [600]u8 = undefined;
    const eex_dir = formatZ(&eex_dir_buf, "{s}/lib/eex/ebin", .{otp_root});

    var crash_dump_buf: [560]u8 = undefined;
    const crash_dump = formatZ(&crash_dump_buf, "{s}/erl_crash.dump", .{jni.asCStr(&s_files_dir)});

    _ = jni.setenv("BINDIR", bindir, 1);
    _ = jni.setenv("ROOTDIR", otp_root, 1);
    _ = jni.setenv("PROGNAME", "erl", 1);
    _ = jni.setenv("EMU", "beam", 1);
    _ = jni.setenv("HOME", jni.asCStr(&s_files_dir), 1);
    _ = jni.setenv("MOB_DATA_DIR", jni.asCStr(&s_files_dir), 1);

    // MOB_BEAMS_DIR — the directory where app BEAMs (and priv/) are deployed.
    //
    // Problem: Ecto.Migrator uses :code.priv_dir(app) to locate migration .exs
    // files. :code.priv_dir/1 works by looking up the app's OTP lib structure
    // ($OTP_ROOT/lib/APP-VERSION/ebin/). Mob apps are deployed to a flat -pa
    // directory (e.g. files/otp/my_app/*.beam), not an OTP lib structure, so
    // :code.priv_dir/1 returns {error, bad_name} and Ecto silently reports
    // "Migrations already up" without running anything.
    //
    // Fix: deployer.ex pushes priv/ alongside the BEAMs into beams_dir/priv/.
    // App code reads MOB_BEAMS_DIR at startup and passes the explicit path to
    // Ecto.Migrator.run/4 instead of relying on :code.priv_dir/1. This env var
    // is the only reliable way to communicate beams_dir to Elixir code since it
    // is computed here from getFilesDir() at runtime (the path includes the
    // Android user ID which is not predictable at compile time).
    _ = jni.setenv("MOB_BEAMS_DIR", beams_dir, 1);
    _ = jni.setenv("ERL_CRASH_DUMP", crash_dump, 1);
    _ = jni.setenv("ERL_CRASH_DUMP_SECONDS", "30", 1);

    // MOB_NATIVE_LIB_DIR — the app's nativeLibraryDir (apk_data_file context,
    // exec allowed). Apps that bundle extra binaries (escript, rebar3, etc.)
    // as `lib<name>.so` in jniLibs/<abi>/ can find them here at runtime —
    // their paths include the APK install hash and aren't predictable at
    // compile time. Empty when launched from a split APK that didn't extract
    // .so files; callers should fall back to BINDIR in that case.
    if (s_native_lib_dir[0] != 0) {
        _ = jni.setenv("MOB_NATIVE_LIB_DIR", jni.asCStr(&s_native_lib_dir), 1);
    }

    // RUSTLER_BEAM_LIBRARY_PATH — tells rustler where the .so containing it
    // (libpigeon.so in Mob's static-link model) lives, so its
    // DlsymNifFiller can dlopen(path, RTLD_NOW | RTLD_NOLOAD) directly
    // instead of dlopen(NULL). On Bionic, dlopen(NULL) returns the app
    // process namespace which misses sibling .so's exported symbols even
    // when System.loadLibrary'd with RTLD_GLOBAL — see filmor's comment on
    // rusterlium/rustler#726. dladdr on a function we know is in this .so
    // (mob_start_beam itself) gives us dli_fname = the absolute load path.
    {
        var info = std.mem.zeroes(jni.DlInfo);
        const probe: *const anyopaque = @ptrCast(&mob_start_beam);
        if (jni.dladdr(probe, &info) != 0) {
            if (info.dli_fname) |fname| {
                _ = jni.setenv("RUSTLER_BEAM_LIBRARY_PATH", fname, 1);
                _ = jni.__android_log_print(
                    jni.ANDROID_LOG_INFO,
                    "MobBeam",
                    "RUSTLER_BEAM_LIBRARY_PATH=%s",
                    fname,
                );
            }
        }
    }

    var eval_expr_buf: [280]u8 = undefined;
    const eval_expr = formatZ(&eval_expr_buf, "{s}:start().", .{app_module});

    // Compile-time default BEAM tuning flags. Selected by build_options.beam_flags_mode
    // (untuned / sbwt_only / nerves_full). Runtime override below wins if present.
    const default_flags: []const [*:0]const u8 = comptime selectDefaultFlags();

    // Runtime override: read whitespace-separated flags from beams_dir/mob_beam_flags.
    // Written by `mix mob.deploy --schedulers N` or `--beam-flags "..."`.
    {
        var flags_path_buf: [640]u8 = undefined;
        const flags_path = formatZ(&flags_path_buf, "{s}/mob_beam_flags", .{beams_dir});
        if (jni.fopen(flags_path, "r")) |fp| {
            const n_read = jni.fread(&s_flags_buf, 1, s_flags_buf.len - 1, fp);
            _ = jni.fclose(fp);
            s_flags_buf[n_read] = 0;
            s_runtime_flag_count = 0;
            var p: usize = 0;
            while (p < n_read and s_runtime_flag_count < 63) {
                while (p < n_read and isWhitespace(s_flags_buf[p])) : (p += 1) {}
                if (p >= n_read or s_flags_buf[p] == 0) break;
                s_runtime_flags[s_runtime_flag_count] = @ptrCast(&s_flags_buf[p]);
                s_runtime_flag_count += 1;
                while (p < n_read and !isWhitespace(s_flags_buf[p]) and s_flags_buf[p] != 0) : (p += 1) {}
                if (p < n_read) {
                    s_flags_buf[p] = 0;
                    p += 1;
                }
            }
            s_runtime_flags[s_runtime_flag_count] = null;
            logi("mob_start_beam: loaded {d} runtime flags from {s}", .{ s_runtime_flag_count, flags_path });
        }
    }

    var boot_path_buf: [580]u8 = undefined;
    const boot_path = formatZ(&boot_path_buf, "{s}/releases/29/start_clean", .{otp_root});

    var args: [128]?[*:0]const u8 = @splat(null);
    var ac: usize = 0;
    args[ac] = "beam";
    ac += 1;
    if (s_runtime_flag_count > 0) {
        var i: usize = 0;
        while (i < s_runtime_flag_count) : (i += 1) {
            args[ac] = s_runtime_flags[i];
            ac += 1;
        }
    } else {
        for (default_flags) |f| {
            args[ac] = f;
            ac += 1;
        }
    }
    args[ac] = "--";
    ac += 1;
    args[ac] = "-root";
    ac += 1;
    args[ac] = otp_root;
    ac += 1;
    args[ac] = "-bindir";
    ac += 1;
    args[ac] = bindir;
    ac += 1;
    args[ac] = "-progname";
    ac += 1;
    args[ac] = "erl";
    ac += 1;
    args[ac] = "--";
    ac += 1;
    args[ac] = "-noshell";
    ac += 1;
    args[ac] = "-noinput";
    ac += 1;
    args[ac] = "-boot";
    ac += 1;
    args[ac] = boot_path;
    ac += 1;
    args[ac] = "-pa";
    ac += 1;
    args[ac] = elixir_dir;
    ac += 1;
    args[ac] = "-pa";
    ac += 1;
    args[ac] = logger_dir;
    ac += 1;
    args[ac] = "-pa";
    ac += 1;
    args[ac] = eex_dir;
    ac += 1;
    args[ac] = "-pa";
    ac += 1;
    args[ac] = beams_dir;
    ac += 1;
    args[ac] = "-eval";
    ac += 1;
    args[ac] = eval_expr;
    ac += 1;
    args[ac] = null;

    // ── Cold-start race condition fix ────────────────────────────────────────
    //
    // DO NOT REMOVE THIS BLOCK.
    //
    // Problem: on a cold start (first launch after install or after the process
    // was killed), calling erl_start() too early causes a SIGABRT deep inside
    // ERTS pthread initialisation.  The crash looks like:
    //
    //   FORTIFY: pthread_mutex_lock called on a destroyed mutex
    //   backtrace:
    //     #00  abort
    //     #01  pthread_mutex_lock (FORTIFY wrapper)
    //     #02  ... (ERTS internal thread pool setup)
    //     #03  erl_start
    //
    // Root cause: Android's hwui (hardware-accelerated UI renderer) creates its
    // own native thread pool during the very first layout/draw pass.  That
    // initialisation uses pthread mutexes that it allocates and later destroys.
    // ERTS also calls into pthreads during erl_start().  If erl_start() runs
    // concurrently with hwui's first-draw setup, the two pthread paths race on
    // the same internal libc state and the FORTIFY mutex check fires → SIGABRT.
    //
    // The race only reproduces on cold start because:
    //   • On warm start hwui's thread pool already exists → no race.
    //   • The window-focus event is the earliest point at which Android
    //     guarantees the first layout/draw pass has completed, so hwui's
    //     pthread state is stable.
    //
    // Fix: poll Activity.hasWindowFocus() every 50 ms before calling erl_start().
    // hasWindowFocus() returns true only after the window has been drawn and
    // given input focus, which is *after* hwui finishes its thread-pool setup.
    // We wait up to 3 seconds (covers slow emulators and heavily loaded devices)
    // and fall through anyway so a stuck window never blocks BEAM forever.
    //
    // Why this lives here instead of in MainActivity.kt:
    //   Putting the delay in Kotlin would mean every app built on Mob needs to
    //   replicate and maintain the fix.  Centralising it in mob_beam.zig means
    //   app code can stay a simple `Thread({ nativeStartBeam() }).start()`.
    //
    // JNI threading notes:
    //   • beam-main is created via `new Thread()` in Kotlin, so it is already
    //     attached to the JVM when this function runs.  Calling
    //     AttachCurrentThread on an already-attached thread is a no-op, but
    //     calling DetachCurrentThread on a Java-created thread makes ART abort.
    //   • We therefore call GetEnv first.  If the thread is already attached
    //     (needs_detach == 0) we skip both Attach and Detach.  Only a purely
    //     native thread that was never attached would set needs_detach == 1.
    if (g_jvm) |jvm| {
        if (g_activity != null) {
            mob_set_startup_phase("Waiting for window focus…");

            const existing = jni.getEnv(jvm, jni.JNI_VERSION_1_6);
            const needs_detach = existing == null;
            const env2_maybe: ?*jni.JNIEnv = existing orelse jni.attachCurrentThread(jvm);

            if (env2_maybe) |env2| {
                const act_cls = jni.getObjectClass(env2, g_activity);
                const has_focus = jni.getMethodID(env2, act_cls, "hasWindowFocus", "()Z");
                var waited: i32 = 0;
                const max_wait: i32 = 3000; // ms — fall through if focus never arrives
                while (jni.callBooleanMethod(env2, g_activity, has_focus) == 0 and waited < max_wait) {
                    const ts = jni.Timespec{ .tv_sec = 0, .tv_nsec = 50_000_000 }; // 50 ms
                    _ = jni.nanosleep(&ts, null);
                    waited += 50;
                }
                // Only detach if we attached above — detaching a Java thread aborts ART.
                if (needs_detach) jni.detachCurrentThread(jvm);
                if (waited >= max_wait) {
                    logi("mob_start_beam: focus timeout ({d} ms) — starting BEAM anyway", .{waited});
                } else if (waited > 0) {
                    logi("mob_start_beam: waited {d} ms for window focus", .{waited});
                }
            } else {
                loge("mob_start_beam: AttachCurrentThread failed — skipping focus wait", .{});
            }
        }
    }
    // ── end cold-start race condition fix ────────────────────────────────────

    mob_set_startup_phase("Starting BEAM…");
    logi("mob_start_beam: starting BEAM with module={s}, argc={d}", .{ app_module, ac });

    // Symlink ERTS executables from BINDIR to the native lib dir.
    //
    // When installed via `adb install`, nativeLibraryDir contains the .so files
    // and the symlink approach works (apk_data_file SELinux label allows execve).
    //
    // When installed via Play Store (split APKs), Android does NOT extract .so
    // files to nativeLibraryDir on modern devices — they stay inside the split APK
    // zip. In that case MobBridge.extractBeamHelpersFromSplitApk() copies the
    // binaries directly into erts/bin/ before this point. We detect that scenario
    // by checking whether the nativeLibDir target exists: if it doesn't, skip the
    // unlink+symlink so we don't clobber the already-extracted real file.
    if (s_native_lib_dir[0] != 0) {
        const exes = [_][*:0]const u8{ "erl_child_setup", "inet_gethost", "epmd" };
        const libs = [_][*:0]const u8{ "liberl_child_setup.so", "libinet_gethost.so", "libepmd.so" };
        var i: usize = 0;
        while (i < exes.len) : (i += 1) {
            var bin_path_buf: [512]u8 = undefined;
            var lib_path_buf: [512]u8 = undefined;
            const bin_path = formatZ(&bin_path_buf, "{s}/{s}/bin/{s}", .{ otp_root, ERTS_VSN, exes[i] });
            const lib_path = formatZ(&lib_path_buf, "{s}/{s}", .{ jni.asCStr(&s_native_lib_dir), libs[i] });
            var st: jni.Stat = undefined;
            if (jni.stat(lib_path, &st) == 0) {
                // nativeLibDir has the file (adb install) — use symlink
                _ = jni.unlink(bin_path);
                if (jni.symlink(lib_path, bin_path) == 0) {
                    logi("mob_start_beam: symlink {s} -> {s}", .{ exes[i], lib_path });
                } else {
                    loge("mob_start_beam: symlink {s} failed: {s}", .{ exes[i], lastErrno() });
                }
            } else {
                // nativeLibDir empty (Play Store split APK) — MobBridge should have
                // extracted the binary directly to bin_path; leave it in place.
                var st_bin: jni.Stat = undefined;
                if (jni.stat(bin_path, &st_bin) == 0) {
                    logi("mob_start_beam: symlink {s} (extracted from split APK)", .{exes[i]});
                } else {
                    loge("mob_start_beam: symlink {s} missing from both nativeLibDir and bin/", .{exes[i]});
                }
            }
        }
    }

    // Optional ERTS extras: symlink iff the app shipped them in jniLibs.
    // Silently skip otherwise — these aren't required for BEAM boot, but apps
    // that want them (e.g. Mix.install of a rebar3-built dep needs `escript`
    // *and* a spawnable `erl` / `erlexec` for the escript runner to bootstrap
    // a fresh VM) can drop `lib<name>.so` into android/app/src/main/jniLibs/<abi>/
    // to get a working BINDIR/<name>. `erl` and `erlexec` both target the
    // same library because they're the same binary — erlexec doesn't switch
    // on argv[0].
    if (s_native_lib_dir[0] != 0) {
        const opt_exes = [_][*:0]const u8{ "escript", "erlexec", "erl", "beam.smp" };
        const opt_libs = [_][*:0]const u8{ "libescript.so", "liberlexec.so", "liberlexec.so", "libbeam_smp.so" };
        var j: usize = 0;
        while (j < opt_exes.len) : (j += 1) {
            var bin_path_buf: [512]u8 = undefined;
            var lib_path_buf: [512]u8 = undefined;
            const bin_path = formatZ(&bin_path_buf, "{s}/{s}/bin/{s}", .{ otp_root, ERTS_VSN, opt_exes[j] });
            const lib_path = formatZ(&lib_path_buf, "{s}/{s}", .{ jni.asCStr(&s_native_lib_dir), opt_libs[j] });
            var st: jni.Stat = undefined;
            if (jni.stat(lib_path, &st) == 0) {
                _ = jni.unlink(bin_path);
                if (jni.symlink(lib_path, bin_path) == 0) {
                    logi("mob_start_beam: symlink {s} -> {s} (optional)", .{ opt_exes[j], lib_path });
                } else {
                    loge("mob_start_beam: symlink {s} failed: {s}", .{ opt_exes[j], lastErrno() });
                }
            }
            // No lib in nativeLibDir => app didn't ask for this extra. Skip
            // silently — don't log; not an error.
        }
    }

    // Symlink sqlite3_nif.so into the exqlite OTP lib structure so that
    // code:priv_dir(:exqlite) resolves correctly.
    //
    // The OTP code server registers lib_dirs by scanning $OTP_ROOT/lib/*/ebin
    // at boot. For code:lib_dir(:exqlite) to work, exqlite must live at
    // $OTP_ROOT/lib/exqlite-VERSION/ — a flat -pa dir is NOT sufficient.
    // The deployer creates $OTP_ROOT/lib/exqlite-VERSION/{ebin,priv}; we
    // create the sqlite3_nif.so symlink inside priv/ at runtime so the path
    // (which contains the APK install hash) is always up-to-date.
    if (s_native_lib_dir[0] != 0) {
        var nif_target_buf: [560]u8 = undefined;
        const nif_target = formatZ(&nif_target_buf, "{s}/libsqlite3_nif.so", .{jni.asCStr(&s_native_lib_dir)});

        // Scan $OTP_ROOT/lib/ for exqlite-* and symlink the NIF in its priv/.
        var lib_path_buf: [600]u8 = undefined;
        const lib_path = formatZ(&lib_path_buf, "{s}/lib", .{otp_root});
        var found = false;
        if (jni.opendir(lib_path)) |d| {
            while (jni.readdir(d)) |entry| {
                if (jni.strncmp(@ptrCast(&entry.d_name), "exqlite-", 8) == 0) {
                    var exqlite_priv_buf: [700]u8 = undefined;
                    const d_name_c: [*:0]const u8 = @ptrCast(&entry.d_name);
                    const exqlite_priv = formatZ(&exqlite_priv_buf, "{s}/{s}/priv", .{ lib_path, d_name_c });
                    _ = jni.mkdir(exqlite_priv, 0o755);
                    var nif_link_buf: [760]u8 = undefined;
                    const nif_link = formatZ(&nif_link_buf, "{s}/sqlite3_nif.so", .{exqlite_priv});
                    var st_nif: jni.Stat = undefined;
                    if (jni.stat(nif_target, &st_nif) == 0) {
                        // nativeLibDir has the NIF (adb install) — use symlink
                        _ = jni.unlink(nif_link);
                        if (jni.symlink(nif_target, nif_link) == 0) {
                            logi("mob_start_beam: symlink exqlite NIF -> {s}", .{nif_target});
                            found = true;
                        } else {
                            loge("mob_start_beam: symlink exqlite NIF failed: {s}", .{lastErrno()});
                        }
                    } else {
                        // nativeLibDir empty — MobBridge extracted NIF directly to nif_link
                        var st_nif_file: jni.Stat = undefined;
                        if (jni.stat(nif_link, &st_nif_file) == 0) {
                            logi("mob_start_beam: exqlite NIF extracted from split APK", .{});
                            found = true;
                        } else {
                            loge("mob_start_beam: exqlite NIF missing from both nativeLibDir and priv/", .{});
                        }
                    }
                    break;
                }
            }
            _ = jni.closedir(d);
        }

        if (!found) {
            // Fallback: symlink into flat beams_dir/priv/ for backward compatibility
            // while the deployer hasn't yet created the versioned lib structure.
            var priv_dir_buf: [660]u8 = undefined;
            const priv_dir = formatZ(&priv_dir_buf, "{s}/priv", .{beams_dir});
            _ = jni.mkdir(priv_dir, 0o755);
            var nif_link_buf: [720]u8 = undefined;
            const nif_link = formatZ(&nif_link_buf, "{s}/sqlite3_nif.so", .{priv_dir});
            var st_nif_fb: jni.Stat = undefined;
            if (jni.stat(nif_target, &st_nif_fb) == 0) {
                _ = jni.unlink(nif_link);
                if (jni.symlink(nif_target, nif_link) == 0) {
                    logi("mob_start_beam: symlink sqlite3_nif.so (fallback) -> {s}", .{nif_target});
                } else {
                    loge("mob_start_beam: symlink sqlite3_nif (fallback) failed: {s}", .{lastErrno()});
                }
            } else {
                var st_fb_file: jni.Stat = undefined;
                if (jni.stat(nif_link, &st_fb_file) == 0) {
                    logi("mob_start_beam: sqlite3_nif.so (fallback) extracted from split APK", .{});
                } else {
                    loge("mob_start_beam: sqlite3_nif.so (fallback) missing — NIF load will fail", .{});
                }
            }
        }
    }

    // Symlink libpythonx.so into the pythonx OTP lib structure for the
    // same reason as exqlite above. Pythonx's NIF on_load does
    //   path = :filename.join(:code.priv_dir(:pythonx), 'libpythonx')
    //   :erlang.load_nif(path, 0)
    // For dlopen to resolve enif_* (defined in the main app native lib)
    // the .so has to live in the app's namespace — i.e. nativeLibraryDir.
    // mob_dev's NativeBuild already places libpythonx.so in jniLibs, so
    // the APK installer extracts it to nativeLibraryDir at install time.
    // We just symlink into the OTP lib priv/ to make :code.priv_dir
    // return a path that dlopen can follow.
    if (s_native_lib_dir[0] != 0) {
        var pyx_target_buf: [560]u8 = undefined;
        const pyx_target = formatZ(&pyx_target_buf, "{s}/libpythonx.so", .{jni.asCStr(&s_native_lib_dir)});

        var st_pyx: jni.Stat = undefined;
        if (jni.stat(pyx_target, &st_pyx) == 0) {
            var lib_path_buf: [600]u8 = undefined;
            const lib_path = formatZ(&lib_path_buf, "{s}/lib", .{otp_root});
            if (jni.opendir(lib_path)) |d2| {
                while (jni.readdir(d2)) |entry| {
                    if (jni.strncmp(@ptrCast(&entry.d_name), "pythonx-", 8) == 0) {
                        var pyx_priv_buf: [700]u8 = undefined;
                        const d_name_c: [*:0]const u8 = @ptrCast(&entry.d_name);
                        const pyx_priv = formatZ(&pyx_priv_buf, "{s}/{s}/priv", .{ lib_path, d_name_c });
                        _ = jni.mkdir(pyx_priv, 0o755);
                        var pyx_link_buf: [760]u8 = undefined;
                        const pyx_link = formatZ(&pyx_link_buf, "{s}/libpythonx.so", .{pyx_priv});
                        _ = jni.unlink(pyx_link);
                        if (jni.symlink(pyx_target, pyx_link) == 0) {
                            logi("mob_start_beam: symlink pythonx NIF -> {s}", .{pyx_target});
                        } else {
                            loge("mob_start_beam: symlink pythonx NIF failed: {s}", .{lastErrno()});
                        }
                        break;
                    }
                }
                _ = jni.closedir(d2);
            }
        }
    }

    // erl_start blocks forever in the normal case. If it returns at all the
    // BEAM has exited unexpectedly — report it to the UI and let logcat carry
    // the details. The caller's caller (Java thread) will reap the process.
    erl_start(@intCast(ac), @ptrCast(&args));
    mob_set_startup_error("BEAM exited unexpectedly — see logcat (tag: MobBeam) for details");
    loge("mob_start_beam: erl_start returned (unexpected)", .{});
}

// ── Comptime helpers ──────────────────────────────────────────────────────

fn selectDefaultFlags() []const [*:0]const u8 {
    // String comparison at comptime — build_options.beam_flags_mode is a
    // []const u8 baked into the binary at build time.
    if (std.mem.eql(u8, BEAM_FLAGS_MODE, "untuned")) {
        return &.{};
    }
    if (std.mem.eql(u8, BEAM_FLAGS_MODE, "sbwt_only")) {
        return &.{
            "-sbwt",     "none",
            "-sbwtdcpu", "none",
            "-sbwtdio",  "none",
        };
    }
    // Default: full Nerves-style tuning.
    return &.{
        "-S",        "1:1",
        "-SDcpu",    "1:1",
        "-SDio",     "1",
        "-A",        "1",
        "-sbwt",     "none",
        "-sbwtdcpu", "none",
        "-sbwtdio",  "none",
    };
}
