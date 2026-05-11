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
//!   * iter 3b (this iter): test harness NIFs (ui_tree, ui_view_tree,
//!     screen_info, tap, tap_xy, type_text, delete_backward, key_press,
//!     clear_text, long_press_xy, swipe_xy, ax_action stubs, ui_debug)
//!     + the cached `Bridge` MobBridge method-ID struct + `get_jenv` (the
//!     thread-attach helper). Moving Bridge/get_jenv here unblocks the
//!     remaining sub-iters — both senders (iter 3c) and the feature NIFs
//!     (iter 3d) reach into the same struct.
//!   * iter 3c: event senders + tap/component handle registries +
//!     per-handle throttle state.
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
