//! mob_nif.zig — Mob Android NIF implementations (Zig).
//!
//! Phase 6b iter 3 of the build-system migration: incremental port of
//! mob_nif.c (~2570 lines, 79 NIFs) to Zig. The C file stays in the build
//! alongside this one — both contribute symbols to the final lib<app>.so.
//! mob_nif.c's static `ErlNifFunc nif_funcs[]` table references the Zig
//! exports here via `extern` declarations at the top of mob_nif.c.
//!
//! Sub-iter sequence:
//!   * iter 3a: 3 standalone NIFs — platform/0, log/1, log/2. No JNI, no
//!     shared state. Proved the cross-language linkage pattern.
//!   * iter 3b: test harness NIFs (ui_tree, ui_view_tree, screen_info,
//!     tap, tap_xy, type_text, delete_backward, key_press, clear_text,
//!     long_press_xy, swipe_xy, ax_action stubs, ui_debug) + the cached
//!     `Bridge` MobBridge method-ID struct + `get_jenv` (the thread-
//!     attach helper).
//!   * iter 3c (this iter): event senders (mob_send_* family — tap,
//!     change, focus/blur/submit/select/compose, gestures, throttled
//!     scroll/drag/pinch/rotate/pointer_move, scroll-began/ended/settled,
//!     back), tap + component handle registries with their mutexes,
//!     per-handle throttle state, and the 6 NIFs that touch these
//!     statics (nif_set_root, nif_register_tap, nif_clear_taps,
//!     nif_set_transition, nif_register_component, nif_deregister_component).
//!     The C-side `nif_load` calls `mob_nif_init_state` (exported here)
//!     to create the mutexes during BEAM init.
//!   * iter 3d: remaining feature NIFs (storage, WebView, alert,
//!     action_sheet, toast, native view components, lifecycle,
//!     Mob.Device). Moves the NIF table itself here. mob_nif.c deleted.
//!
//! All exports use the C ABI so the C-side NIF table can reference them.

const std = @import("std");
const jni = @import("mob_zig.zig");
const erts = @import("mob_erts.zig");

// ── Logging tag for NIFs that log to Android logcat ──────────────────────

const ELIXIR_TAG: [*:0]const u8 = "Elixir";

// ── NIF: platform/0 ──────────────────────────────────────────────────────
// Returns the atom :android. iOS has a parallel `nif_platform` in
// `ios/mob_nif.m` that returns :ios.

export fn nif_platform(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.atom(env, "android");
}

// ── NIF: log/1 ───────────────────────────────────────────────────────────
// Accept either a binary or an Erlang charlist; emit under tag "Elixir"
// at ANDROID_LOG_INFO. Truncates at 4 KB (matches the C version's local
// buffer size).

export fn nif_log(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var buf: [4096]u8 = @splat(0);
    if (!fillBufferFromTerm(env, argv[0], &buf)) {
        return erts.badarg(env);
    }
    const cstr: [*:0]const u8 = @ptrCast(&buf);
    _ = jni.__android_log_print(jni.ANDROID_LOG_INFO, ELIXIR_TAG, "%s", cstr);
    return erts.ok(env);
}

// ── NIF: log/2 ───────────────────────────────────────────────────────────
// argv[0] is a level atom (:debug | :info | :warning | :error); argv[1] is
// the message (binary or charlist). Unknown atom → INFO.

export fn nif_log2(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var buf: [4096]u8 = @splat(0);
    const priority = atomToAndroidPriority(env, argv[0]);
    if (!fillBufferFromTerm(env, argv[1], &buf)) {
        return erts.badarg(env);
    }
    const cstr: [*:0]const u8 = @ptrCast(&buf);
    _ = jni.__android_log_print(priority, ELIXIR_TAG, "%s", cstr);
    return erts.ok(env);
}

// ── Helpers ──────────────────────────────────────────────────────────────

/// Pull a binary or charlist into a NUL-terminated buffer. Returns false if
/// neither inspect_binary nor get_string succeeded.
fn fillBufferFromTerm(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: *[4096]u8) bool {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) != 0) {
        const len = @min(bin.size, buf.len - 1);
        @memcpy(buf[0..len], bin.data[0..len]);
        buf[len] = 0;
        return true;
    }
    return erts.enif_get_string(env, term, buf.ptr, @intCast(buf.len), erts.ERL_NIF_LATIN1) != 0;
}

/// Map :debug / :info / :warning / :error to the Android log priority.
/// Unknown atom → INFO (matches the C default).
fn atomToAndroidPriority(env: ?*erts.ErlNifEnv, level_atom: erts.ERL_NIF_TERM) c_int {
    var level: [16]u8 = @splat(0);
    if (erts.enif_get_atom(env, level_atom, &level, level.len, erts.ERL_NIF_LATIN1) == 0) {
        return jni.ANDROID_LOG_INFO;
    }
    const len = jni.zLen(&level);
    const view = level[0..len];
    if (std.mem.eql(u8, view, "debug")) return jni.ANDROID_LOG_DEBUG;
    if (std.mem.eql(u8, view, "warning")) return jni.ANDROID_LOG_WARN;
    if (std.mem.eql(u8, view, "error")) return jni.ANDROID_LOG_ERROR;
    return jni.ANDROID_LOG_INFO;
}

// ── Cached MobBridge method IDs (Phase 6b iter 3b) ───────────────────────
// Moved from mob_nif.c's `static struct { ... } Bridge;`. The C side now
// extern-declares a matching `struct BridgeMethods Bridge` so the senders
// and feature NIFs that haven't been ported yet can still read these
// fields. Field order matches the C struct exactly — drift here will
// silently mis-resolve method IDs at runtime.
//
// The set_startup_phase / set_startup_error pair is populated by mob_beam
// (during BEAM startup, before NIFs load); the rest are filled by
// nif_load on the BEAM-side load callback.

pub const BridgeMethods = extern struct {
    cls: jni.JClass = null,
    set_root: jni.JMethodID = null,
    move_to_back: jni.JMethodID = null,
    get_safe_area: jni.JMethodID = null,
    get_color_scheme: jni.JMethodID = null,
    haptic: jni.JMethodID = null,
    clipboard_put: jni.JMethodID = null,
    clipboard_get: jni.JMethodID = null,
    share_text: jni.JMethodID = null,
    open_url: jni.JMethodID = null,
    request_permission: jni.JMethodID = null,
    biometric_authenticate: jni.JMethodID = null,
    location_get_once: jni.JMethodID = null,
    location_start: jni.JMethodID = null,
    location_stop: jni.JMethodID = null,
    camera_capture_photo: jni.JMethodID = null,
    camera_capture_video: jni.JMethodID = null,
    camera_start_preview: jni.JMethodID = null,
    camera_stop_preview: jni.JMethodID = null,
    alert_show: jni.JMethodID = null,
    action_sheet_show: jni.JMethodID = null,
    toast_show: jni.JMethodID = null,
    webview_eval_js: jni.JMethodID = null,
    webview_post_message: jni.JMethodID = null,
    webview_can_go_back: jni.JMethodID = null,
    webview_go_back: jni.JMethodID = null,
    photos_pick: jni.JMethodID = null,
    files_pick: jni.JMethodID = null,
    audio_start_recording: jni.JMethodID = null,
    audio_stop_recording: jni.JMethodID = null,
    audio_play: jni.JMethodID = null,
    audio_stop_playback: jni.JMethodID = null,
    audio_set_volume: jni.JMethodID = null,
    motion_start: jni.JMethodID = null,
    motion_stop: jni.JMethodID = null,
    scanner_scan: jni.JMethodID = null,
    notify_schedule: jni.JMethodID = null,
    notify_cancel: jni.JMethodID = null,
    notify_register_push: jni.JMethodID = null,
    take_launch_notification: jni.JMethodID = null,
    storage_dir: jni.JMethodID = null,
    storage_save_to_media_store: jni.JMethodID = null,
    storage_external_files_dir: jni.JMethodID = null,
    background_keep_alive: jni.JMethodID = null,
    background_stop: jni.JMethodID = null,
    // Cached before nif_load (used during BEAM startup before NIFs are loaded)
    set_startup_phase: jni.JMethodID = null,
    set_startup_error: jni.JMethodID = null,
    // ── Test harness ──────────────────────────────────────────────────────
    ui_tree: jni.JMethodID = null,
    ui_view_tree: jni.JMethodID = null,
    screen_info: jni.JMethodID = null,
    tap_xy: jni.JMethodID = null,
    tap_by_label: jni.JMethodID = null,
    type_text: jni.JMethodID = null,
    delete_backward: jni.JMethodID = null,
    clear_text: jni.JMethodID = null,
    long_press_xy: jni.JMethodID = null,
    swipe_xy: jni.JMethodID = null,
};

/// Exported with C ABI so mob_nif.c (and beam_jni.c for the senders in
/// iter 3c) can extern-declare it and read/write the same memory.
pub export var Bridge: BridgeMethods = .{};

// ── Externs from mob_beam.zig (Phase 6b iter 2) ──────────────────────────
extern var g_jvm: ?*jni.JavaVM;
extern var g_activity: jni.JObject;

// ── get_jenv: attach the current thread if needed ────────────────────────
// Returns the env pointer; *attached is set to 1 iff this call had to
// attach (caller must DetachCurrentThread when done). Match the C
// signature byte-for-byte — `int *attached` in C → `*c_int` in Zig.
// Exported so the C-side senders + feature NIFs can call it.
//
// JNI_EDETACHED = -2 (from jni.h). When GetEnv returns it the calling
// thread is not yet attached; AttachCurrentThread takes care of that.
// Any other GetEnv return (JNI_OK = 0, JNI_EVERSION = -3) means "leave
// it alone" — attached stays 0 so we won't detach a thread we didn't
// attach (and detaching a Java-spawned thread aborts ART).
const JNI_EDETACHED: jni.JInt = -2;

pub export fn get_jenv(attached: *c_int) ?*jni.JNIEnv {
    attached.* = 0;
    const jvm = g_jvm orelse return null;
    var ptr: ?*anyopaque = null;
    const rc = jvm.*.GetEnv.?(jvm, &ptr, jni.JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        var env: ?*jni.JNIEnv = null;
        if (jvm.*.AttachCurrentThread.?(jvm, &env, null) == jni.JNI_OK) {
            attached.* = 1;
            return env;
        }
        return null;
    }
    return @ptrCast(@alignCast(ptr));
}

/// Detach when get_jenv set *attached = 1. Convenience wrapper used by
/// every test harness NIF below — keeps the call-site idiom compact and
/// the comment-block "if attached → detach" rule local to one place.
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

// ── Binary / string helpers ──────────────────────────────────────────────

/// Make an `ErlNifBinary` from a C-style {ptr, len} pair and wrap it as a
/// term. BEAM owns the allocated bytes after make_binary returns.
fn cstrToBin(env: ?*erts.ErlNifEnv, src: [*]const u8, len: usize) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    @memcpy(bin.data[0..len], src[0..len]);
    return erts.enif_make_binary(env, &bin);
}

/// jstring → binary term. Returns `:nil` if the jstring is null or the
/// UTF-8 view can't be obtained. Always releases the local ref + UTF
/// chars; caller doesn't need to clean up.
fn jstringToBin(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, js: jni.JString) erts.ERL_NIF_TERM {
    if (js == null) return erts.atom(env, "nil");
    const utf = jni.getStringUTFChars(jenv, js) orelse return erts.atom(env, "nil");
    const len = std.mem.span(utf).len;
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    @memcpy(bin.data[0..len], utf[0..len]);
    jni.releaseStringUTFChars(jenv, js, utf);
    jni.deleteLocalRef(jenv, js);
    return erts.enif_make_binary(env, &bin);
}

/// Return `{:error, atom}` after detaching if needed. Centralised so the
/// test harness NIFs don't repeat the boilerplate.
inline fn errorAtom(env: ?*erts.ErlNifEnv, comptime reason: [:0]const u8) erts.ERL_NIF_TERM {
    return erts.errorTuple(env, erts.atom(env, reason));
}

/// `{:error, :not_loaded}` — the early-bail path for NIFs that need a
/// Bridge method that wasn't compiled into the app (e.g. older mob_dev
/// versions that pre-date a Kotlin-side helper).
inline fn notLoaded(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return errorAtom(env, "not_loaded");
}

// ── Test harness NIFs (Phase 6b iter 3b) ─────────────────────────────────
// Drive the running app from a Mac-side IEx via Erlang distribution. They
// look up cached method IDs on `Bridge`, hop into the JVM via get_jenv,
// dispatch via Compose's gesture/test bridge on the Kotlin side, then
// either return an `:ok` atom or a structured error tuple. dp coordinates,
// matching iOS convention.

// nif_ui_tree/0 — returns [{type_atom, label_binary, value_binary, {x,y,w,h}}, ...]
//
// Calls MobBridge.uiTree() which returns a newline-separated string:
//   type|label|value|x|y|w|h\n...
// Parses that into a list of 4-tuples matching the iOS ui_tree format.
export fn nif_ui_tree(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.ui_tree == null) return notLoaded(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jresult = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.ui_tree);
    if (jresult == null) {
        detachIfAttached(attached);
        return erts.makeList(env, &.{});
    }

    const raw = jni.getStringUTFChars(jenv, jresult);
    var items_buf: [512]erts.ERL_NIF_TERM = undefined;
    var count: usize = 0;

    if (raw) |r| {
        const raw_slice = std.mem.span(r);
        var line_it = std.mem.splitScalar(u8, raw_slice, '\n');
        while (line_it.next()) |line| {
            if (count >= items_buf.len) break;
            if (line.len == 0 or line.len >= 512) continue;

            // Split on '|': type | label | value | x | y | w | h
            var fields: [7][]const u8 = undefined;
            var field_count: usize = 0;
            var field_it = std.mem.splitScalar(u8, line, '|');
            while (field_it.next()) |f| {
                if (field_count >= 7) {
                    field_count += 1; // overflow marker
                    break;
                }
                fields[field_count] = f;
                field_count += 1;
            }
            if (field_count != 7) continue;

            const x = std.fmt.parseFloat(f64, fields[3]) catch 0.0;
            const y = std.fmt.parseFloat(f64, fields[4]) catch 0.0;
            const w = std.fmt.parseFloat(f64, fields[5]) catch 0.0;
            const h = std.fmt.parseFloat(f64, fields[6]) catch 0.0;

            const frame = erts.makeTuple(env, .{
                erts.enif_make_double(env, x),
                erts.enif_make_double(env, y),
                erts.enif_make_double(env, w),
                erts.enif_make_double(env, h),
            });

            // Empty label/value → atom :nil, non-empty → binary.
            const label = if (fields[1].len == 0)
                erts.atom(env, "nil")
            else
                cstrToBin(env, fields[1].ptr, fields[1].len);
            const value = if (fields[2].len == 0)
                erts.atom(env, "nil")
            else
                cstrToBin(env, fields[2].ptr, fields[2].len);

            // The type field is small and unbounded in length theoretically;
            // copy it into a NUL-terminated buffer so enif_make_atom is safe.
            var type_buf: [64]u8 = @splat(0);
            const tlen = @min(fields[0].len, type_buf.len - 1);
            @memcpy(type_buf[0..tlen], fields[0][0..tlen]);
            const type_cstr: [*:0]const u8 = @ptrCast(&type_buf);

            items_buf[count] = erts.makeTuple(env, .{
                erts.enif_make_atom(env, type_cstr),
                label,
                value,
                frame,
            });
            count += 1;
        }
        jni.releaseStringUTFChars(jenv, jresult, r);
    }
    jni.deleteLocalRef(jenv, jresult);
    detachIfAttached(attached);

    return erts.makeList(env, items_buf[0..count]);
}

// nif_ui_view_tree/0 — returns nested-map UI tree from MobBridge.uiViewTree().
//
// Bridge contract: Kotlin returns a JSON string of the form
//   {"type":"root","label":null,"value":null,"frame":[0,0,W,H],"children":[...]}
// parsed by Mob.Test.tree/1 (jason decode is fast; no need for a C-side
// JSON tokenizer). Returns {:error, :not_loaded} when MobBridge.uiViewTree()
// isn't present (early-adopter apps without registry).
export fn nif_ui_view_tree(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.ui_view_tree == null) return notLoaded(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jresult = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.ui_view_tree);
    const result = jstringToBin(env, jenv, jresult);
    detachIfAttached(attached);
    return result;
}

// nif_screen_info/0 — returns %{width, height, scale, safe_area: %{...}}
//
// Width/height are in dp (already px-divided by density on the Kotlin
// side). scale is the density factor (1.0/1.5/2.0/2.625/3.0/...) — same
// role as UIScreen.scale on iOS.
//
// Bridge contract: MobBridge.screenInfo() returns float[6+] = [w, h,
// scale, safe_top, safe_bottom, safe_left, safe_right]. Falls back to
// safe_area-only info if screenInfo() isn't bound (older bridges).
export fn nif_screen_info(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    var vals: [7]f32 = @splat(0);
    if (Bridge.screen_info != null) {
        const arr = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.screen_info);
        if (arr != null) {
            const got = jni.getArrayLength(jenv, arr);
            const take: jni.JInt = if (got > 7) 7 else got;
            jni.getFloatArrayRegion(jenv, arr, 0, take, &vals);
            jni.deleteLocalRef(jenv, arr);
        }
    }
    detachIfAttached(attached);

    const sa_keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "top"),
        erts.atom(env, "bottom"),
        erts.atom(env, "left"),
        erts.atom(env, "right"),
    };
    const sa_vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, @floatCast(vals[3])),
        erts.enif_make_double(env, @floatCast(vals[4])),
        erts.enif_make_double(env, @floatCast(vals[5])),
        erts.enif_make_double(env, @floatCast(vals[6])),
    };
    const safe_area = erts.makeMap(env, &sa_keys, &sa_vals) orelse erts.atom(env, "error");

    const keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "width"),
        erts.atom(env, "height"),
        erts.atom(env, "scale"),
        erts.atom(env, "safe_area"),
    };
    const vvals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, @floatCast(vals[0])),
        erts.enif_make_double(env, @floatCast(vals[1])),
        erts.enif_make_double(env, @floatCast(vals[2])),
        safe_area,
    };
    return erts.makeMap(env, &keys, &vvals) orelse erts.atom(env, "error");
}

// nif_ax_action/2 + nif_ax_action_at_xy/3 — Android stubs.
//
// Both are iOS-only today. Compose semantics walker (the proper Android
// implementation) is queued under WireTap (see future_developments.md).
// Return a clear error so callers get `{:error, :not_supported_on_android}`
// instead of an `:undef` crash.

export fn nif_ax_action(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return errorAtom(env, "not_supported_on_android");
}

export fn nif_ax_action_at_xy(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return errorAtom(env, "not_supported_on_android");
}

// nif_ui_debug/0 — returns raw uiTree string as a binary (for debugging).
export fn nif_ui_debug(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.ui_tree == null) return notLoaded(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jresult = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.ui_tree);
    const result = jstringToBin(env, jenv, jresult);
    detachIfAttached(attached);
    return result;
}

// nif_tap/1 — tap by accessibility label binary.
export fn nif_tap(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.tap_by_label == null) return notLoaded(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[0], &bin) == 0) return erts.badarg(env);

    // NewStringUTF takes a NUL-terminated C string; binary's data isn't
    // NUL-terminated. Copy to a stack buffer for typical short labels;
    // fall back to malloc on long ones.
    var stack_buf: [512]u8 = undefined;
    const use_heap = bin.size + 1 > stack_buf.len;
    const heap_buf: ?*anyopaque = if (use_heap) jni.malloc(bin.size + 1) else null;
    if (use_heap and heap_buf == null) return erts.atom(env, "error");
    const buf_ptr: [*]u8 = if (use_heap) @ptrCast(heap_buf) else &stack_buf;
    defer if (use_heap) jni.free(heap_buf);

    @memcpy(buf_ptr[0..bin.size], bin.data[0..bin.size]);
    buf_ptr[bin.size] = 0;
    const label_cstr: [*:0]const u8 = @ptrCast(buf_ptr);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jlabel = jni.newStringUTF(jenv, label_cstr);
    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, Bridge.cls, Bridge.tap_by_label, jlabel);
    jni.deleteLocalRef(jenv, jlabel);
    detachIfAttached(attached);
    return if (ok != 0) erts.ok(env) else errorAtom(env, "no_element_with_label");
}

// nif_tap_xy/2 — tap at (x, y) dp coordinates.
export fn nif_tap_xy(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.tap_xy == null) return notLoaded(env);
    const x = erts.getNumber(env, argv[0]) orelse return erts.badarg(env);
    const y = erts.getNumber(env, argv[1]) orelse return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, Bridge.cls, Bridge.tap_xy, @as(f32, @floatCast(x)), @as(f32, @floatCast(y)));
    detachIfAttached(attached);
    return if (ok != 0) erts.ok(env) else errorAtom(env, "dispatch_failed");
}

// nif_type_text/1 — type text into the focused view.
export fn nif_type_text(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.type_text == null) return notLoaded(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[0], &bin) == 0) return erts.badarg(env);

    var stack_buf: [4096]u8 = undefined;
    const use_heap = bin.size + 1 > stack_buf.len;
    const heap_buf: ?*anyopaque = if (use_heap) jni.malloc(bin.size + 1) else null;
    if (use_heap and heap_buf == null) return erts.atom(env, "error");
    const buf_ptr: [*]u8 = if (use_heap) @ptrCast(heap_buf) else &stack_buf;
    defer if (use_heap) jni.free(heap_buf);

    @memcpy(buf_ptr[0..bin.size], bin.data[0..bin.size]);
    buf_ptr[bin.size] = 0;
    const text_cstr: [*:0]const u8 = @ptrCast(buf_ptr);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jtext = jni.newStringUTF(jenv, text_cstr);
    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, Bridge.cls, Bridge.type_text, jtext);
    jni.deleteLocalRef(jenv, jtext);
    detachIfAttached(attached);
    return if (ok != 0) erts.ok(env) else errorAtom(env, "no_first_responder");
}

// nif_delete_backward/0 — delete one character backward.
export fn nif_delete_backward(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.delete_backward == null) return notLoaded(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, Bridge.cls, Bridge.delete_backward);
    detachIfAttached(attached);
    return if (ok != 0) erts.ok(env) else errorAtom(env, "no_first_responder");
}

// nif_key_press/1 — not yet implemented on Android (no KeyCharacterMap lookup).
export fn nif_key_press(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return errorAtom(env, "not_implemented");
}

// nif_clear_text/0 — select-all + delete in the focused view.
export fn nif_clear_text(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.clear_text == null) return notLoaded(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, Bridge.cls, Bridge.clear_text);
    detachIfAttached(attached);
    return if (ok != 0) erts.ok(env) else errorAtom(env, "no_first_responder");
}

// nif_long_press_xy/3 — long press at (x, y) for duration_ms milliseconds.
export fn nif_long_press_xy(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.long_press_xy == null) return notLoaded(env);
    const x = erts.getNumber(env, argv[0]) orelse return erts.badarg(env);
    const y = erts.getNumber(env, argv[1]) orelse return erts.badarg(env);
    var dur: c_int = 0;
    if (erts.enif_get_int(env, argv[2], &dur) == 0) return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const ok = jenv.*.CallStaticBooleanMethod.?(
        jenv,
        Bridge.cls,
        Bridge.long_press_xy,
        @as(f32, @floatCast(x)),
        @as(f32, @floatCast(y)),
        @as(i64, @intCast(dur)),
    );
    detachIfAttached(attached);
    return if (ok != 0) erts.ok(env) else errorAtom(env, "dispatch_failed");
}

// nif_swipe_xy/4 — swipe from (x1, y1) to (x2, y2) in dp.
export fn nif_swipe_xy(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.swipe_xy == null) return notLoaded(env);
    const x1 = erts.getNumber(env, argv[0]) orelse return erts.badarg(env);
    const y1 = erts.getNumber(env, argv[1]) orelse return erts.badarg(env);
    const x2 = erts.getNumber(env, argv[2]) orelse return erts.badarg(env);
    const y2 = erts.getNumber(env, argv[3]) orelse return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const ok = jenv.*.CallStaticBooleanMethod.?(
        jenv,
        Bridge.cls,
        Bridge.swipe_xy,
        @as(f32, @floatCast(x1)),
        @as(f32, @floatCast(y1)),
        @as(f32, @floatCast(x2)),
        @as(f32, @floatCast(y2)),
    );
    detachIfAttached(attached);
    return if (ok != 0) erts.ok(env) else errorAtom(env, "dispatch_failed");
}

// ── Handle registries (Phase 6b iter 3c) ─────────────────────────────────
//
// Two pools of per-widget routing slots. The tap registry is cleared every
// render frame (clear_taps); the component registry is persistent — slots
// stay live across renders and are explicitly freed by deregister_component.
//
// Both pools sit behind mutexes. The mutexes are created lazily by
// mob_nif_init_state (called from mob_nif.c's nif_load BEAM callback).

const MAX_TAP_HANDLES: usize = 256;
const MAX_COMPONENT_HANDLES: usize = 64;

/// Per-tap slot: the registered pid, an optional caller-supplied tag, and
/// the throttle state for high-frequency events. tag_env is non-null while
/// the slot is in use; clear_taps frees it and nulls it back out.
const TapHandle = extern struct {
    pid: erts.ErlNifPid,
    tag_env: ?*erts.ErlNifEnv,
    tag: erts.ERL_NIF_TERM,

    // ── Batch 5 throttle state — populated by mob_set_throttle_config ──
    throttle_ms: c_int,
    debounce_ms: c_int,
    delta_threshold: f64,
    leading: c_int,
    trailing: c_int,
    last_emit_ns: i64,
    last_x: f64,
    last_y: f64,
    seq: u64,
};

const ComponentHandle = extern struct {
    pid: erts.ErlNifPid,
    active: c_int,
};

var tap_handles: [MAX_TAP_HANDLES]TapHandle = @splat(std.mem.zeroes(TapHandle));
var tap_handle_next: c_int = 0;
var tap_mutex: ?*erts.ErlNifMutex = null;
/// Snapshotted by nif_set_root; written by nif_set_transition. Guarded by
/// tap_mutex (the C original reused that mutex rather than allocating a
/// second one — keep the lock geometry the same).
var g_transition: [16]u8 = blk: {
    var buf: [16]u8 = @splat(0);
    buf[0] = 'n';
    buf[1] = 'o';
    buf[2] = 'n';
    buf[3] = 'e';
    break :blk buf;
};

var component_handles: [MAX_COMPONENT_HANDLES]ComponentHandle = @splat(std.mem.zeroes(ComponentHandle));
var component_mutex: ?*erts.ErlNifMutex = null;

/// Initialise both mutexes. Called from mob_nif.c's nif_load BEAM callback
/// — must run once before any sender or NIF that locks them. Returns 0
/// on success, -1 on failure (matches the C nif_load return convention).
pub export fn mob_nif_init_state() callconv(.c) c_int {
    tap_mutex = erts.enif_mutex_create("mob_tap_mutex") orelse return -1;
    component_mutex = erts.enif_mutex_create("mob_component_mutex") orelse return -1;
    return 0;
}

// ── Sender helpers ───────────────────────────────────────────────────────
// All senders share the same shape: lock tap_mutex, validate the handle
// is in use (slot index in range AND tag_env non-null), copy the pid + tag
// out under the lock, then build and deliver the message to that pid in a
// freshly allocated env. The lock is dropped before enif_send so we don't
// hold it across a potentially-blocking send.

/// Snapshot a TapHandle's routing under the tap_mutex. Returns null if
/// the handle is unused/out of range. The boolean flag pulls seq too —
/// only the throttled-event senders care about that.
const TapSnap = struct {
    pid: erts.ErlNifPid,
    tag: erts.ERL_NIF_TERM,
    seq: u64,
};

fn snapTap(handle: c_int) ?TapSnap {
    erts.enif_mutex_lock(tap_mutex);
    defer erts.enif_mutex_unlock(tap_mutex);
    if (handle < 0 or handle >= tap_handle_next) return null;
    const h = &tap_handles[@intCast(handle)];
    if (h.tag_env == null) return null;
    return TapSnap{ .pid = h.pid, .tag = h.tag, .seq = h.seq };
}

/// `{:event, tag}` — used by focus/blur/submit/select and the gesture
/// senders that don't carry a payload.
fn sendEvent(handle: c_int, comptime atom_name: [:0]const u8) void {
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, atom_name.ptr),
        erts.enif_make_copy(env, snap.tag),
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

/// `{:change, tag, value}` — used by the three change senders below. The
/// value term must originate in the same env we're delivering through.
fn sendChange(handle: c_int, value_term: erts.ERL_NIF_TERM) void {
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "change"),
        erts.enif_make_copy(env, snap.tag),
        erts.enif_make_copy(env, value_term),
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Tap + change senders ────────────────────────────────────────────────

/// Called from beam_jni.c's `nativeSendTap` JNI stub. Sends `{:tap, tag}`
/// to the pid registered for `handle`.
pub export fn mob_send_tap(handle: c_int) callconv(.c) void {
    sendEvent(handle, "tap");
}

pub export fn mob_send_change_str(handle: c_int, utf8: [*:0]const u8) callconv(.c) void {
    const tmp = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(tmp);
    var bin: erts.ErlNifBinary = undefined;
    const len = std.mem.span(utf8).len;
    _ = erts.enif_alloc_binary(len, &bin);
    @memcpy(bin.data[0..len], utf8[0..len]);
    const term = erts.enif_make_binary(tmp, &bin);
    sendChange(handle, term);
}

pub export fn mob_send_change_bool(handle: c_int, bool_val: c_int) callconv(.c) void {
    const tmp = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(tmp);
    const term = erts.enif_make_atom(tmp, if (bool_val != 0) "true" else "false");
    sendChange(handle, term);
}

pub export fn mob_send_change_float(handle: c_int, value: f64) callconv(.c) void {
    const tmp = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(tmp);
    const term = erts.enif_make_double(tmp, value);
    sendChange(handle, term);
}

// ── Focus / blur / submit / select / compose ────────────────────────────

pub export fn mob_send_focus(handle: c_int) callconv(.c) void {
    sendEvent(handle, "focus");
}
pub export fn mob_send_blur(handle: c_int) callconv(.c) void {
    sendEvent(handle, "blur");
}
pub export fn mob_send_submit(handle: c_int) callconv(.c) void {
    sendEvent(handle, "submit");
}
pub export fn mob_send_select(handle: c_int) callconv(.c) void {
    sendEvent(handle, "select");
}

/// `{:compose, tag, %{text, phase}}` — IME composition events. phase is
/// began | updating | committed | cancelled (the latter two are terminal).
pub export fn mob_send_compose(handle: c_int, text: ?[*:0]const u8, phase: [*:0]const u8) callconv(.c) void {
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const text_cstr: [*:0]const u8 = text orelse "";
    const keys = [_]erts.ERL_NIF_TERM{
        erts.enif_make_atom(env, "text"),
        erts.enif_make_atom(env, "phase"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_string(env, text_cstr, erts.ERL_NIF_LATIN1),
        erts.enif_make_atom(env, phase),
    };
    const payload = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "compose"),
        erts.enif_make_copy(env, snap.tag),
        payload,
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Gesture senders (Batch 4) ───────────────────────────────────────────
// Per-widget opt-in — only handles with a registered tag emit. Direction-
// aware swipes go through mob_send_swipe_with_direction; the legacy fixed
// directions stay around for any beam_jni.c stubs that haven't migrated.

pub export fn mob_send_long_press(handle: c_int) callconv(.c) void {
    sendEvent(handle, "long_press");
}
pub export fn mob_send_double_tap(handle: c_int) callconv(.c) void {
    sendEvent(handle, "double_tap");
}
pub export fn mob_send_swipe_left(handle: c_int) callconv(.c) void {
    sendEvent(handle, "swipe_left");
}
pub export fn mob_send_swipe_right(handle: c_int) callconv(.c) void {
    sendEvent(handle, "swipe_right");
}
pub export fn mob_send_swipe_up(handle: c_int) callconv(.c) void {
    sendEvent(handle, "swipe_up");
}
pub export fn mob_send_swipe_down(handle: c_int) callconv(.c) void {
    sendEvent(handle, "swipe_down");
}

pub export fn mob_send_swipe_with_direction(handle: c_int, direction: [*:0]const u8) callconv(.c) void {
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "swipe"),
        erts.enif_make_copy(env, snap.tag),
        erts.enif_make_atom(env, direction),
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Throttle infrastructure (Batch 5 Tier 1) ────────────────────────────
// Per-handle throttle + delta-threshold gating, mirroring iOS. Phase
// boundaries (began/ended) bypass the throttle so the BEAM always sees
// the start + stop of a gesture even when intermediate samples are
// dropped.

pub export fn mob_set_throttle_config(
    handle: c_int,
    throttle_ms: c_int,
    debounce_ms: c_int,
    delta_threshold: f64,
    leading: c_int,
    trailing: c_int,
) callconv(.c) void {
    erts.enif_mutex_lock(tap_mutex);
    defer erts.enif_mutex_unlock(tap_mutex);
    if (handle < 0 or handle >= tap_handle_next) return;
    const h = &tap_handles[@intCast(handle)];
    if (h.tag_env == null) return;
    h.throttle_ms = throttle_ms;
    h.debounce_ms = debounce_ms;
    h.delta_threshold = delta_threshold;
    h.leading = leading;
    h.trailing = trailing;
}

/// Returns true if this sample should emit (and updates last_emit_ns +
/// last_x/y + seq under the mutex). `default_throttle_ms` and
/// `default_delta` are the gesture-specific defaults applied when the
/// per-handle config left those fields at 0.
fn throttleCheck(handle: c_int, x: f64, y: f64, default_throttle_ms: i32, default_delta: f64) bool {
    erts.enif_mutex_lock(tap_mutex);
    defer erts.enif_mutex_unlock(tap_mutex);
    if (handle < 0 or handle >= tap_handle_next) return false;
    const h = &tap_handles[@intCast(handle)];
    if (h.tag_env == null) return false;

    const throttle_ms: i32 = if (h.throttle_ms != 0) h.throttle_ms else default_throttle_ms;
    const delta_threshold: f64 = if (h.delta_threshold > 0) h.delta_threshold else default_delta;

    const now_ns = jni.nowNs();
    const dx = x - h.last_x;
    const dy = y - h.last_y;
    const dist = @abs(dx) + @abs(dy);

    if (h.last_emit_ns > 0 and throttle_ms > 0) {
        const elapsed_ms = @divTrunc(now_ns - h.last_emit_ns, 1_000_000);
        if (elapsed_ms < throttle_ms) return false;
    }
    if (h.last_emit_ns > 0 and dist < delta_threshold) return false;

    h.last_emit_ns = now_ns;
    h.last_x = x;
    h.last_y = y;
    h.seq +%= 1; // wrap on overflow; matches C's `++` on unsigned long long
    return true;
}

inline fn isPhaseBoundary(phase: [*:0]const u8) bool {
    const span = std.mem.span(phase);
    return std.mem.eql(u8, span, "began") or std.mem.eql(u8, span, "ended");
}

/// Build the scroll/drag payload map. Caller owns `env`.
fn buildScrollMap(
    env: ?*erts.ErlNifEnv,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    vx: f64,
    vy: f64,
    phase: [*:0]const u8,
    ts_ms: i64,
    seq: u64,
) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{
        erts.enif_make_atom(env, "x"),
        erts.enif_make_atom(env, "y"),
        erts.enif_make_atom(env, "dx"),
        erts.enif_make_atom(env, "dy"),
        erts.enif_make_atom(env, "velocity_x"),
        erts.enif_make_atom(env, "velocity_y"),
        erts.enif_make_atom(env, "phase"),
        erts.enif_make_atom(env, "ts"),
        erts.enif_make_atom(env, "seq"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, x),
        erts.enif_make_double(env, y),
        erts.enif_make_double(env, dx),
        erts.enif_make_double(env, dy),
        erts.enif_make_double(env, vx),
        erts.enif_make_double(env, vy),
        erts.enif_make_atom(env, phase),
        erts.enif_make_int64(env, ts_ms),
        erts.enif_make_uint64(env, seq),
    };
    return erts.makeMap(env, &keys, &vals) orelse erts.atom(env, "error");
}

pub export fn mob_send_scroll(
    handle: c_int,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    vx: f64,
    vy: f64,
    phase: [*:0]const u8,
) callconv(.c) void {
    if (!isPhaseBoundary(phase) and !throttleCheck(handle, x, y, 33, 1.0)) return;
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const ts_ms = @divTrunc(jni.nowNs(), 1_000_000);
    const payload = buildScrollMap(env, x, y, dx, dy, vx, vy, phase, ts_ms, snap.seq);
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "scroll"),
        erts.enif_make_copy(env, snap.tag),
        payload,
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_send_drag(
    handle: c_int,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    phase: [*:0]const u8,
) callconv(.c) void {
    if (!isPhaseBoundary(phase) and !throttleCheck(handle, x, y, 16, 1.0)) return;
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const ts_ms = @divTrunc(jni.nowNs(), 1_000_000);
    const keys = [_]erts.ERL_NIF_TERM{
        erts.enif_make_atom(env, "x"),
        erts.enif_make_atom(env, "y"),
        erts.enif_make_atom(env, "dx"),
        erts.enif_make_atom(env, "dy"),
        erts.enif_make_atom(env, "phase"),
        erts.enif_make_atom(env, "ts"),
        erts.enif_make_atom(env, "seq"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, x),
        erts.enif_make_double(env, y),
        erts.enif_make_double(env, dx),
        erts.enif_make_double(env, dy),
        erts.enif_make_atom(env, phase),
        erts.enif_make_int64(env, ts_ms),
        erts.enif_make_uint64(env, snap.seq),
    };
    const payload = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "drag"),
        erts.enif_make_copy(env, snap.tag),
        payload,
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_send_pinch(handle: c_int, scale: f64, velocity: f64, phase: [*:0]const u8) callconv(.c) void {
    if (!isPhaseBoundary(phase) and !throttleCheck(handle, scale, 0, 16, 0.01)) return;
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const ts_ms = @divTrunc(jni.nowNs(), 1_000_000);
    const keys = [_]erts.ERL_NIF_TERM{
        erts.enif_make_atom(env, "scale"),
        erts.enif_make_atom(env, "velocity"),
        erts.enif_make_atom(env, "phase"),
        erts.enif_make_atom(env, "ts"),
        erts.enif_make_atom(env, "seq"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, scale),
        erts.enif_make_double(env, velocity),
        erts.enif_make_atom(env, phase),
        erts.enif_make_int64(env, ts_ms),
        erts.enif_make_uint64(env, snap.seq),
    };
    const payload = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "pinch"),
        erts.enif_make_copy(env, snap.tag),
        payload,
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_send_rotate(handle: c_int, degrees: f64, velocity: f64, phase: [*:0]const u8) callconv(.c) void {
    if (!isPhaseBoundary(phase) and !throttleCheck(handle, degrees, 0, 16, 1.0)) return;
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const ts_ms = @divTrunc(jni.nowNs(), 1_000_000);
    const keys = [_]erts.ERL_NIF_TERM{
        erts.enif_make_atom(env, "degrees"),
        erts.enif_make_atom(env, "velocity"),
        erts.enif_make_atom(env, "phase"),
        erts.enif_make_atom(env, "ts"),
        erts.enif_make_atom(env, "seq"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, degrees),
        erts.enif_make_double(env, velocity),
        erts.enif_make_atom(env, phase),
        erts.enif_make_int64(env, ts_ms),
        erts.enif_make_uint64(env, snap.seq),
    };
    const payload = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "rotate"),
        erts.enif_make_copy(env, snap.tag),
        payload,
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_send_pointer_move(handle: c_int, x: f64, y: f64) callconv(.c) void {
    if (!throttleCheck(handle, x, y, 33, 4.0)) return;
    const snap = snapTap(handle) orelse return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const ts_ms = @divTrunc(jni.nowNs(), 1_000_000);
    const keys = [_]erts.ERL_NIF_TERM{
        erts.enif_make_atom(env, "x"),
        erts.enif_make_atom(env, "y"),
        erts.enif_make_atom(env, "ts"),
        erts.enif_make_atom(env, "seq"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, x),
        erts.enif_make_double(env, y),
        erts.enif_make_int64(env, ts_ms),
        erts.enif_make_uint64(env, snap.seq),
    };
    const payload = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "pointer_move"),
        erts.enif_make_copy(env, snap.tag),
        payload,
    });
    var pid = snap.pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Tier 2: semantic single-fire scroll events ──────────────────────────

pub export fn mob_send_scroll_began(handle: c_int) callconv(.c) void {
    sendEvent(handle, "scroll_began");
}
pub export fn mob_send_scroll_ended(handle: c_int) callconv(.c) void {
    sendEvent(handle, "scroll_ended");
}
pub export fn mob_send_scroll_settled(handle: c_int) callconv(.c) void {
    sendEvent(handle, "scroll_settled");
}
pub export fn mob_send_top_reached(handle: c_int) callconv(.c) void {
    sendEvent(handle, "top_reached");
}
pub export fn mob_send_scrolled_past(handle: c_int) callconv(.c) void {
    sendEvent(handle, "scrolled_past");
}

// ── Component event sender ──────────────────────────────────────────────

pub export fn mob_send_component_event(
    handle: c_int,
    event: [*:0]const u8,
    payload_json: [*:0]const u8,
) callconv(.c) void {
    if (handle < 0 or handle >= @as(c_int, @intCast(MAX_COMPONENT_HANDLES))) return;
    erts.enif_mutex_lock(component_mutex);
    const slot = &component_handles[@intCast(handle)];
    if (slot.active == 0) {
        erts.enif_mutex_unlock(component_mutex);
        return;
    }
    const pid_copy = slot.pid;
    erts.enif_mutex_unlock(component_mutex);

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, "component_event"),
        erts.enif_make_string(env, event, erts.ERL_NIF_LATIN1),
        erts.enif_make_string(env, payload_json, erts.ERL_NIF_LATIN1),
    });
    var pid = pid_copy;
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Back gesture ────────────────────────────────────────────────────────

/// Called from beam_jni.c's nativeHandleBack JNI stub when the Android
/// back gesture fires. Looks up the :mob_screen registered process and
/// sends {:mob, :back}. Mob.Screen handles popping the nav stack or
/// exiting the app at root.
pub export fn mob_handle_back() callconv(.c) void {
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var pid: erts.ErlNifPid = undefined;
    if (erts.enif_whereis_pid(env, erts.enif_make_atom(env, "mob_screen"), &pid) != 0) {
        const msg = erts.makeTuple(env, .{
            erts.enif_make_atom(env, "mob"),
            erts.enif_make_atom(env, "back"),
        });
        _ = erts.enif_send(null, &pid, env, msg);
    }
}

// ── NIFs that touch the tap registry / g_transition / Bridge.set_root ───
// (Ported alongside the senders so all consumers of these statics are
// co-located in Zig.)

// nif_set_root/1 — pass JSON node tree to Compose. Snapshots the current
// `g_transition` (set by nif_set_transition before this call) and resets
// it to "none" so the next render starts from a clean default.
export fn nif_set_root(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[0], &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, argv[0], &bin) == 0)
    {
        return erts.badarg(env);
    }

    // Null-terminate for NewStringUTF.
    const json_ptr: ?*anyopaque = jni.malloc(bin.size + 1) orelse
        return erts.atom(env, "error");
    defer jni.free(json_ptr);
    const json_buf: [*]u8 = @ptrCast(json_ptr);
    @memcpy(json_buf[0..bin.size], bin.data[0..bin.size]);
    json_buf[bin.size] = 0;
    const json_cstr: [*:0]const u8 = @ptrCast(json_buf);

    // Snapshot transition under the mutex; reset to "none" for next call.
    var transition: [16]u8 = @splat(0);
    erts.enif_mutex_lock(tap_mutex);
    @memcpy(&transition, &g_transition);
    @memset(&g_transition, 0);
    g_transition[0] = 'n';
    g_transition[1] = 'o';
    g_transition[2] = 'n';
    g_transition[3] = 'e';
    erts.enif_mutex_unlock(tap_mutex);
    const transition_cstr: [*:0]const u8 = @ptrCast(&transition);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jjson = jni.newStringUTF(jenv, json_cstr);
    const jtransition = jni.newStringUTF(jenv, transition_cstr);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.set_root, jjson, jtransition);
    jni.deleteLocalRef(jenv, jjson);
    jni.deleteLocalRef(jenv, jtransition);
    detachIfAttached(attached);
    return erts.ok(env);
}

// nif_register_tap/1 — accepts a pid (tag = :ok) or {pid, tag} (any term
// as the tag). Returns the integer handle.
export fn nif_register_tap(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var pid: erts.ErlNifPid = undefined;
    var tag_term: erts.ERL_NIF_TERM = undefined;

    if (erts.enif_get_local_pid(env, argv[0], &pid) != 0) {
        tag_term = erts.enif_make_atom(env, "ok");
    } else {
        var arity: c_int = 0;
        var elems: [*]const erts.ERL_NIF_TERM = undefined;
        if (erts.enif_get_tuple(env, argv[0], &arity, &elems) == 0 or arity != 2) {
            return erts.badarg(env);
        }
        if (erts.enif_get_local_pid(env, elems[0], &pid) == 0) return erts.badarg(env);
        tag_term = elems[1];
    }

    erts.enif_mutex_lock(tap_mutex);
    defer erts.enif_mutex_unlock(tap_mutex);
    if (tap_handle_next >= @as(c_int, @intCast(MAX_TAP_HANDLES))) return erts.badarg(env);

    const handle: c_int = tap_handle_next;
    tap_handle_next += 1;
    const slot = &tap_handles[@intCast(handle)];
    slot.pid = pid;
    slot.tag_env = erts.enif_alloc_env() orelse return erts.atom(env, "error");
    slot.tag = erts.enif_make_copy(slot.tag_env, tag_term);
    return erts.enif_make_int(env, handle);
}

// nif_clear_taps/0 — cleared at the start of every render. Frees each
// slot's tag_env (which owns the persistent tag term) and zeroes the
// throttle state so reuse across renders doesn't leak stale config.
export fn nif_clear_taps(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    erts.enif_mutex_lock(tap_mutex);
    defer erts.enif_mutex_unlock(tap_mutex);
    var i: usize = 0;
    while (i < @as(usize, @intCast(tap_handle_next))) : (i += 1) {
        const h = &tap_handles[i];
        if (h.tag_env != null) {
            erts.enif_free_env(h.tag_env);
            h.tag_env = null;
        }
        // Reset throttle state — slots get reused across renders.
        h.throttle_ms = 0;
        h.debounce_ms = 0;
        h.delta_threshold = 0;
        h.leading = 1;
        h.trailing = 1;
        h.last_emit_ns = 0;
        h.last_x = 0;
        h.last_y = 0;
        h.seq = 0;
    }
    tap_handle_next = 0;
    return erts.ok(env);
}

// nif_set_transition/1 — store the transition type atom (push/pop/reset/
// none) to be picked up by the next set_root call. Must be called before
// set_root for the transition to take effect on that render.
export fn nif_set_transition(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    erts.enif_mutex_lock(tap_mutex);
    defer erts.enif_mutex_unlock(tap_mutex);
    if (erts.enif_get_atom(env, argv[0], &g_transition, g_transition.len, erts.ERL_NIF_LATIN1) == 0) {
        return erts.badarg(env);
    }
    return erts.ok(env);
}

// nif_register_component/1 — allocate a persistent component handle for
// a Native View pid. Linear scan through MAX_COMPONENT_HANDLES slots;
// fails when all are in use.
export fn nif_register_component(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var pid: erts.ErlNifPid = undefined;
    if (erts.enif_get_local_pid(env, argv[0], &pid) == 0) return erts.badarg(env);

    erts.enif_mutex_lock(component_mutex);
    defer erts.enif_mutex_unlock(component_mutex);
    var i: usize = 0;
    while (i < MAX_COMPONENT_HANDLES) : (i += 1) {
        if (component_handles[i].active == 0) {
            component_handles[i].pid = pid;
            component_handles[i].active = 1;
            return erts.enif_make_int(env, @intCast(i));
        }
    }
    return erts.badarg(env);
}

// nif_deregister_component/1 — release a component handle. Slot becomes
// available for the next register call.
export fn nif_deregister_component(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var handle: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &handle) == 0 or
        handle < 0 or
        handle >= @as(c_int, @intCast(MAX_COMPONENT_HANDLES)))
    {
        return erts.badarg(env);
    }
    erts.enif_mutex_lock(component_mutex);
    component_handles[@intCast(handle)].active = 0;
    erts.enif_mutex_unlock(component_mutex);
    return erts.ok(env);
}
