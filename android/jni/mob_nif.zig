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
//!   * iter 3d (this iter): the finale. Remaining feature NIFs (color
//!     scheme, exit_app, safe_area, haptic, clipboard, open_url,
//!     share_text, launch notification, request_permission,
//!     biometric, location ×3, camera ×4, photos_pick, files_pick,
//!     audio ×5, motion ×2, scanner, notifications ×3, storage ×4,
//!     alert/action_sheet/toast, webview ×4, background ×2,
//!     Mob.Device ×7), the bridge bootstrap helpers
//!     (_mob_ui_cache_class_impl, _mob_bridge_init_activity,
//!     mob_set_startup_phase, mob_set_startup_error), all the
//!     deliver_* event dispatchers, and the NIF table itself with
//!     nif_load + the ERL_NIF_INIT entry point. mob_nif.c deleted.
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
    camera_start_frame_stream: jni.JMethodID = null,
    camera_stop_frame_stream: jni.JMethodID = null,
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
    // ── Mob.Peripheral.VendorUsb ─────────────────────────────────────────
    // Each takes a pid as jlong (so Kotlin can echo it back when calling
    // mob_deliver_vendor_usb_*) plus the operation's typed payload.
    vendor_usb_list_devices: jni.JMethodID = null,
    vendor_usb_request_permission: jni.JMethodID = null,
    vendor_usb_open: jni.JMethodID = null,
    vendor_usb_bulk_write: jni.JMethodID = null,
    vendor_usb_start_reading: jni.JMethodID = null,
    vendor_usb_stop_reading: jni.JMethodID = null,
    vendor_usb_close: jni.JMethodID = null,
    // ── Mob.Bt (Bluetooth Classic) ───────────────────────────────────────
    bt_list_paired: jni.JMethodID = null,
    bt_start_discovery: jni.JMethodID = null,
    bt_cancel_discovery: jni.JMethodID = null,
    bt_pair: jni.JMethodID = null,
    bt_unpair: jni.JMethodID = null,
    bt_disconnect: jni.JMethodID = null,
    bt_hfp_connect: jni.JMethodID = null,
    bt_hfp_subscribe_vendor_at: jni.JMethodID = null,
    bt_hfp_send_vendor_at: jni.JMethodID = null,
    bt_hfp_start_sco: jni.JMethodID = null,
    bt_hfp_stop_sco: jni.JMethodID = null,
    bt_hfp_send_audio: jni.JMethodID = null,
    bt_spp_connect: jni.JMethodID = null,
    bt_spp_write: jni.JMethodID = null,
    bt_hid_connect: jni.JMethodID = null,
    bt_hid_subscribe_raw: jni.JMethodID = null,
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

// ══════════════════════════════════════════════════════════════════════════
// Phase 6b iter 3d — finale: bridge bootstrap, feature NIFs, deliver_* event
// dispatchers, NIF table, and the ERL_NIF_INIT entry point. After this iter
// mob_nif.c is gone — everything below was the last residency of native
// state and entry points in C.
// ══════════════════════════════════════════════════════════════════════════

const NIF_LOG_TAG: [*:0]const u8 = "MobNIF";

inline fn logi_nif(comptime fmt: []const u8, args: anytype) void {
    jni.logWrite(jni.ANDROID_LOG_INFO, NIF_LOG_TAG, fmt, args);
}

inline fn loge_nif(comptime fmt: []const u8, args: anytype) void {
    jni.logWrite(jni.ANDROID_LOG_ERROR, NIF_LOG_TAG, fmt, args);
}

// ── Bridge bootstrap helpers ─────────────────────────────────────────────
// Called from mob_beam.zig during BEAM startup, BEFORE nif_load runs. The
// startup_phase / startup_error paths must be safe to call when only
// `Bridge.cls` + `Bridge.set_startup_phase` / `Bridge.set_startup_error`
// are populated (which is what _mob_ui_cache_class_impl does first).

/// `_mob_ui_cache_class_impl(jenv, bridge_class)` — invoked by
/// `mob_ui_cache_class` (in mob_beam.zig) from JNI_OnLoad. Caches the
/// MobBridge `jclass` as a global ref and pre-caches set_startup_phase /
/// set_startup_error so the BEAM launcher can drive the splash screen
/// before NIF load.
pub export fn _mob_ui_cache_class_impl(jenv_p: *jni.JNIEnv, bridge_class: [*:0]const u8) callconv(.c) void {
    logi_nif("mob_ui_cache_class: looking up {s}", .{bridge_class});
    const cls = jni.findClass(jenv_p, bridge_class);
    if (cls == null) {
        loge_nif("mob_ui_cache_class: {s} not found", .{bridge_class});
        return;
    }
    Bridge.cls = jni.newGlobalRef(jenv_p, cls);
    jni.deleteLocalRef(jenv_p, cls);
    // Pre-cache startup status methods — needed before nif_load runs.
    // These are optional (older MobBridge versions may not have them);
    // clear any pending exception rather than aborting.
    Bridge.set_startup_phase = jni.getStaticMethodID(jenv_p, Bridge.cls, "setStartupPhase", "(Ljava/lang/String;)V");
    if (Bridge.set_startup_phase == null) jni.exceptionClear(jenv_p);
    Bridge.set_startup_error = jni.getStaticMethodID(jenv_p, Bridge.cls, "setStartupError", "(Ljava/lang/String;)V");
    if (Bridge.set_startup_error == null) jni.exceptionClear(jenv_p);
    logi_nif("mob_ui_cache_class: {s} cached OK", .{bridge_class});
}

pub export fn mob_set_startup_phase(phase: [*:0]const u8) callconv(.c) void {
    if (g_jvm == null or Bridge.cls == null or Bridge.set_startup_phase == null) return;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return;
    const js = jni.newStringUTF(jenv, phase);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.set_startup_phase, js);
    jni.deleteLocalRef(jenv, js);
    detachIfAttached(attached);
    logi_nif("startup: {s}", .{phase});
}

pub export fn mob_set_startup_error(err: [*:0]const u8) callconv(.c) void {
    if (g_jvm == null or Bridge.cls == null or Bridge.set_startup_error == null) return;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return;
    const js = jni.newStringUTF(jenv, err);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.set_startup_error, js);
    jni.deleteLocalRef(jenv, js);
    detachIfAttached(attached);
    loge_nif("startup ERROR: {s}", .{err});
}

/// `_mob_bridge_init_activity` — invoked by `mob_init_bridge` (mob_beam.zig)
/// after the Activity global ref is set. Calls MobBridge.init(Activity)
/// which wires the Kotlin side to the running activity.
pub export fn _mob_bridge_init_activity(env: *jni.JNIEnv, activity: jni.JObject) callconv(.c) void {
    if (Bridge.cls == null) {
        loge_nif("_mob_bridge_init_activity: Bridge.cls not cached", .{});
        return;
    }
    const init = jni.getStaticMethodID(env, Bridge.cls, "init", "(Landroid/app/Activity;)V");
    env.*.CallStaticVoidMethod.?(env, Bridge.cls, init, activity);
    logi_nif("_mob_bridge_init_activity: MobBridge.init called", .{});
}

// ── Helpers for the feature NIFs below ───────────────────────────────────

/// Accept either a plain binary or an iolist (deep-flatten to binary).
/// Returns null on failure — the caller turns that into `badarg`.
fn getBinOrIolist(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM) ?erts.ErlNifBinary {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) != 0) return bin;
    if (erts.enif_inspect_iolist_as_binary(env, term, &bin) != 0) return bin;
    return null;
}

/// Heap-allocate a NUL-terminated copy of an `ErlNifBinary` for JNI's
/// NewStringUTF. Returns null on OOM. Caller frees via `freeCString`.
fn binToCString(bin: erts.ErlNifBinary) ?[*:0]u8 {
    const buf_ptr = jni.malloc(bin.size + 1) orelse return null;
    const dst: [*]u8 = @ptrCast(buf_ptr);
    @memcpy(dst[0..bin.size], bin.data[0..bin.size]);
    dst[bin.size] = 0;
    return @ptrCast(buf_ptr);
}

inline fn freeCString(p: ?[*:0]u8) void {
    if (p) |ptr| jni.free(@as(?*anyopaque, @ptrCast(ptr)));
}

/// Pack an ErlNifPid into a jlong for the JNI-side delivery handle. Kotlin
/// hands it back unchanged when it calls one of the mob_deliver_* hooks;
/// we round-trip via `pidFromLong`.
///
/// Size mismatch handling: on aarch64 ERL_NIF_TERM is c_ulong = u64,
/// same width as jlong (i64), so a @bitCast is a true reinterpret. On
/// armeabi-v7a (32-bit ARM) ERL_NIF_TERM is u32 but jlong is still i64,
/// so we zero-extend on the way out and truncate on the way back. This
/// mirrors the C original's `memcpy(min(sizeof(ErlNifPid), sizeof(jlong)))`
/// dance — the high 32 bits of the jlong carry no information on 32-bit
/// ARM, they just round-trip whatever Kotlin saw.
inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    // 32-bit ARM: zero-extend the u32 pid into the low 32 bits of i64.
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    // 32-bit ARM: take the low 32 bits of the jlong. The high bits are
    // whatever Kotlin's been passing around — discard them.
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// Call `MobBridge.<method>(pid_long, arg)` — the standard shape for
/// async device-capability NIFs (location, camera, audio_play, etc.).
/// Returns the `:ok` atom unconditionally; results land later via one of
/// the mob_deliver_* JNI hooks. `arg` may be null for void-of-pid methods.
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

fn callBridgePidStr2(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, a1: ?[*:0]const u8, a2: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const j1: jni.JString = if (a1) |a| jni.newStringUTF(jenv, a) else null;
    const j2: jni.JString = if (a2) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, method, pidToJlong(pid), j1, j2);
    if (j1 != null) jni.deleteLocalRef(jenv, j1);
    if (j2 != null) jni.deleteLocalRef(jenv, j2);
    detachIfAttached(attached);
    return erts.ok(env);
}

/// Read a jstring into an `ErlNifBinary` via UTF-8. Returns the binary
/// term + 1 (success) or 0 (null jstring / GetStringUTFChars failed).
/// Deletes the local ref on success.
fn jstringToBinaryTerm(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, js: jni.JString) ?erts.ERL_NIF_TERM {
    if (js == null) return null;
    const utf = jni.getStringUTFChars(jenv, js) orelse return null;
    const len = jni.strlen(utf);
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    @memcpy(bin.data[0..len], utf[0..len]);
    jni.releaseStringUTFChars(jenv, js, utf);
    jni.deleteLocalRef(jenv, js);
    return erts.enif_make_binary(env, &bin);
}

// ── Core feature NIFs ────────────────────────────────────────────────────

// nif_color_scheme/0 — :light | :dark. Returns :light if the optional
// MobBridge.getColorScheme() isn't compiled into the app.
export fn nif_color_scheme(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.get_color_scheme == null) return erts.atom(env, "light");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "light");
    const result = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.get_color_scheme);
    var out = erts.atom(env, "light");
    if (result != null) {
        if (jni.getStringUTFChars(jenv, result)) |str| {
            if (jni.strncmp(str, "dark", 4) == 0 and str[4] == 0) {
                out = erts.atom(env, "dark");
            }
            jni.releaseStringUTFChars(jenv, result, str);
        }
        jni.deleteLocalRef(jenv, result);
    }
    detachIfAttached(attached);
    return out;
}

// nif_exit_app/0 — Activity.moveTaskToBack(true). Called by Mob.Screen
// when the back gesture fires at the root of the nav stack.
export fn nif_exit_app(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.move_to_back);
    detachIfAttached(attached);
    return erts.ok(env);
}

// nif_safe_area/0 — {Top, Right, Bottom, Left} in dp via
// MobBridge.getSafeArea(). The Kotlin side returns float[4] in
// {top, right, bottom, left} order.
export fn nif_safe_area(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    var vals: [4]f32 = @splat(0);
    const arr = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.get_safe_area);
    if (arr != null) {
        jni.getFloatArrayRegion(jenv, arr, 0, 4, &vals);
        jni.deleteLocalRef(jenv, arr);
    }
    detachIfAttached(attached);
    return erts.makeTuple(env, .{
        erts.enif_make_double(env, @floatCast(vals[0])),
        erts.enif_make_double(env, @floatCast(vals[1])),
        erts.enif_make_double(env, @floatCast(vals[2])),
        erts.enif_make_double(env, @floatCast(vals[3])),
    });
}

// nif_haptic/1 — pass an atom (heavy/medium/light/...) to
// MobBridge.haptic(String).
export fn nif_haptic(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var type_buf: [32]u8 = @splat(0);
    _ = erts.enif_get_atom(env, argv[0], &type_buf, type_buf.len, erts.ERL_NIF_LATIN1);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jtype = jni.newStringUTF(jenv, jni.asCStr(&type_buf));
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.haptic, jtype);
    jni.deleteLocalRef(jenv, jtype);
    detachIfAttached(attached);
    return erts.ok(env);
}

// nif_clipboard_put/1 — ClipboardManager.setPrimaryClip via Kotlin.
export fn nif_clipboard_put(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const text = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(text);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jtext = jni.newStringUTF(jenv, text);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.clipboard_put, jtext);
    jni.deleteLocalRef(jenv, jtext);
    detachIfAttached(attached);
    return erts.ok(env);
}

// nif_clipboard_get/0 — returns {:ok, Binary} or :empty.
export fn nif_clipboard_get(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const result = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.clipboard_get);
    var out: erts.ERL_NIF_TERM = undefined;
    if (jstringToBinaryTerm(env, jenv, result)) |bin_term| {
        out = erts.makeTuple(env, .{ erts.atom(env, "ok"), bin_term });
    } else {
        out = erts.atom(env, "empty");
    }
    detachIfAttached(attached);
    return out;
}

// nif_open_url/1 — Intent ACTION_VIEW with the URI.
export fn nif_open_url(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const url = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(url);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jurl = jni.newStringUTF(jenv, url);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.open_url, jurl);
    jni.deleteLocalRef(jenv, jurl);
    detachIfAttached(attached);
    return erts.ok(env);
}

// nif_share_text/1 — system share sheet (Intent ACTION_SEND text/plain).
export fn nif_share_text(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const text = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(text);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jtext = jni.newStringUTF(jenv, text);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.share_text, jtext);
    jni.deleteLocalRef(jenv, jtext);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Launch notification (written from Kotlin on cold start) ──────────────
// MobBridge.setLaunchNotification(json) → mob_set_launch_notification(json).
// Apps call Mob.Device.take_launch_notification/0 → nif_take_launch_notification
// to consume it. Guarded by g_launch_notif_mutex (lazily created in nif_load).

var g_launch_notif_json: ?[*:0]u8 = null;
var g_launch_notif_mutex: ?*erts.ErlNifMutex = null;

pub export fn mob_set_launch_notification(json: ?[*:0]const u8) callconv(.c) void {
    const mutex = g_launch_notif_mutex orelse return;
    erts.enif_mutex_lock(mutex);
    defer erts.enif_mutex_unlock(mutex);
    if (g_launch_notif_json) |old| jni.free(@as(?*anyopaque, @ptrCast(old)));
    g_launch_notif_json = if (json) |j| jni.strdup(j) else null;
}

export fn nif_take_launch_notification(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    const mutex = g_launch_notif_mutex orelse return erts.atom(env, "none");
    erts.enif_mutex_lock(mutex);
    const taken = g_launch_notif_json;
    g_launch_notif_json = null;
    erts.enif_mutex_unlock(mutex);
    const json = taken orelse return erts.atom(env, "none");
    const len = jni.strlen(json);
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    @memcpy(bin.data[0..len], json[0..len]);
    jni.free(@as(?*anyopaque, @ptrCast(json)));
    return erts.enif_make_binary(env, &bin);
}

// ── Async result delivery (called from Kotlin via JNI) ───────────────────
// Each `mob_deliver_*` is invoked by the Kotlin side (after an async
// operation like locationGetOnce or cameraCapturePhoto completes) with
// the pid encoded as a jlong + the typed result. We rebuild an ErlNifPid
// and ship the appropriate {:tag, payload} message.

/// `mob_nif_deliver_json` exists for legacy callers in beam_jni.c — it's a
/// no-op. Typed dispatchers below cover the real surface.
pub export fn mob_nif_deliver_json(pid_long: jni.JLong, json_str: [*:0]const u8) callconv(.c) void {
    _ = pid_long;
    _ = json_str;
}

pub export fn mob_deliver_atom2(jpid: jni.JLong, a1: [*:0]const u8, a2: [*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, a1),
        erts.enif_make_atom(env, a2),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_atom3(jpid: jni.JLong, a1: [*:0]const u8, a2: [*:0]const u8, a3: [*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.enif_make_atom(env, a1),
        erts.enif_make_atom(env, a2),
        erts.enif_make_atom(env, a3),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_location(jpid: jni.JLong, lat: f64, lon: f64, acc: f64, alt: f64) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "lat"),
        erts.atom(env, "lon"),
        erts.atom(env, "accuracy"),
        erts.atom(env, "altitude"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_double(env, lat),
        erts.enif_make_double(env, lon),
        erts.enif_make_double(env, acc),
        erts.enif_make_double(env, alt),
    };
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "location"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_motion(
    jpid: jni.JLong,
    ax: f64,
    ay: f64,
    az: f64,
    gx: f64,
    gy: f64,
    gz: f64,
    ts: i64,
) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const accel = erts.makeTuple(env, .{
        erts.enif_make_double(env, ax),
        erts.enif_make_double(env, ay),
        erts.enif_make_double(env, az),
    });
    const gyro = erts.makeTuple(env, .{
        erts.enif_make_double(env, gx),
        erts.enif_make_double(env, gy),
        erts.enif_make_double(env, gz),
    });
    const keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "accel"),
        erts.atom(env, "gyro"),
        erts.atom(env, "timestamp"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        accel,
        gyro,
        erts.enif_make_int64(env, ts),
    };
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "motion"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

/// `{:webview, tag, binary}`. When `jpid == 0` the message routes to the
/// :mob_screen registered process; otherwise to the explicit pid.
fn deliverWebviewBinary(jpid: jni.JLong, comptime tag: [:0]const u8, utf8: [*:0]const u8) void {
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var pid: erts.ErlNifPid = undefined;
    if (jpid != 0) {
        pid = pidFromLong(jpid);
    } else if (erts.enif_whereis_pid(env, erts.atom(env, "mob_screen"), &pid) == 0) {
        return;
    }
    const len = jni.strlen(utf8);
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    @memcpy(bin.data[0..len], utf8[0..len]);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "webview"),
        erts.atom(env, tag),
        erts.enif_make_binary(env, &bin),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_webview_message(jpid: jni.JLong, json: [*:0]const u8) callconv(.c) void {
    deliverWebviewBinary(jpid, "message", json);
}

pub export fn mob_deliver_webview_blocked(jpid: jni.JLong, url: [*:0]const u8) callconv(.c) void {
    deliverWebviewBinary(jpid, "blocked", url);
}

/// `mob_deliver_file_result` — used by camera/photos/files/audio/scanner
/// capture results. Two shapes:
///   * `{event_atom, :cancelled}` when json_items is null OR "cancelled"
///   * `{:mob_file_result, event_bin, sub_bin, json_bin}` otherwise
pub export fn mob_deliver_file_result(
    jpid: jni.JLong,
    event: [*:0]const u8,
    sub: [*:0]const u8,
    json_items: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const cancelled = blk: {
        const j = json_items orelse break :blk true;
        const span = std.mem.span(j);
        break :blk std.mem.eql(u8, span, "cancelled");
    };

    const msg = if (cancelled) erts.makeTuple(env, .{
        erts.enif_make_atom(env, event),
        erts.atom(env, "cancelled"),
    }) else build: {
        const j = json_items.?;
        const jl = jni.strlen(j);
        const el = jni.strlen(event);
        const sl = jni.strlen(sub);
        var jb: erts.ErlNifBinary = undefined;
        var eb: erts.ErlNifBinary = undefined;
        var sb: erts.ErlNifBinary = undefined;
        _ = erts.enif_alloc_binary(jl, &jb);
        _ = erts.enif_alloc_binary(el, &eb);
        _ = erts.enif_alloc_binary(sl, &sb);
        @memcpy(jb.data[0..jl], j[0..jl]);
        @memcpy(eb.data[0..el], event[0..el]);
        @memcpy(sb.data[0..sl], sub[0..sl]);
        break :build erts.makeTuple(env, .{
            erts.atom(env, "mob_file_result"),
            erts.enif_make_binary(env, &eb),
            erts.enif_make_binary(env, &sb),
            erts.enif_make_binary(env, &jb),
        });
    };
    _ = erts.enif_send(null, &pid, env, msg);
}

/// `mob_deliver_camera_frame` — called from beam_jni.c after a
/// CameraX ImageAnalysis frame has been converted to the requested
/// pixel format. Posts the iOS-equivalent
/// `{:camera, :frame, %{bytes, width, height, format, timestamp_ms, dropped}}`
/// message to the BEAM caller pid. The `bytes` payload is copied into
/// a fresh BEAM binary so the caller can release the underlying Kotlin
/// ByteArray as soon as this function returns.
pub export fn mob_deliver_camera_frame(
    jpid: jni.JLong,
    bytes: [*]const u8,
    nbytes: usize,
    width: c_int,
    height: c_int,
    format: [*:0]const u8,
    timestamp_ms: jni.JLong,
    dropped: jni.JLong,
) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    var pix: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(nbytes, &pix) == 0) return;
    @memcpy(pix.data[0..nbytes], bytes[0..nbytes]);

    const keys = [_]erts.ERL_NIF_TERM{
        erts.enif_make_atom(env, "bytes"),
        erts.enif_make_atom(env, "width"),
        erts.enif_make_atom(env, "height"),
        erts.enif_make_atom(env, "format"),
        erts.enif_make_atom(env, "timestamp_ms"),
        erts.enif_make_atom(env, "dropped"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_binary(env, &pix),
        erts.enif_make_int(env, width),
        erts.enif_make_int(env, height),
        erts.enif_make_atom(env, format),
        erts.enif_make_int64(env, timestamp_ms),
        erts.enif_make_int64(env, dropped),
    };
    const payload = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "camera"),
        erts.atom(env, "frame"),
        payload,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_push_token(jpid: jni.JLong, token: [*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const len = jni.strlen(token);
    var tb: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &tb);
    @memcpy(tb.data[0..len], token[0..len]);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "push_token"),
        erts.atom(env, "android"),
        erts.enif_make_binary(env, &tb),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_notification(jpid: jni.JLong, json: [*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const len = jni.strlen(json);
    var jb: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &jb);
    @memcpy(jb.data[0..len], json[0..len]);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "mob_launch_notification"),
        erts.enif_make_binary(env, &jb),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

/// `mob_deliver_alert_action` — called from beam_jni.c when a dialog
/// button is tapped. Routes to :mob_screen as {:alert, action_atom}.
pub export fn mob_deliver_alert_action(action: [*:0]const u8) callconv(.c) void {
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var pid: erts.ErlNifPid = undefined;
    if (erts.enif_whereis_pid(env, erts.atom(env, "mob_screen"), &pid) == 0) return;
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "alert"),
        erts.enif_make_atom(env, action),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Mob.Peripheral.VendorUsb delivery functions ──────────────────────────
//
// Six typed delivery functions, called from beam_jni.c's
// Java_..._MobBridge_nativeDeliverVendorUsb* thunks when Kotlin-side USB
// events fire (enumeration result, permission grant/deny, device opened,
// inbound chunk, write completion, lifecycle events). They build a
// 5-tuple `{:peripheral, :vendor_usb, tag, session, payload}` and post
// it to `pid`. session==-1 → atom :nil; session>=0 → integer.
//
// devices_json / permission_*_json / opened_json carry a JSON binary
// payload that the Elixir side decodes via
// `Mob.VendorUsb.normalize_message/1` (mirrors the :mob_file_result
// JSON-binary precedent for camera/photos/files/audio/scan).

/// Session integer or :nil atom, depending on whether the Kotlin side
/// knows a session yet.
inline fn vendorUsbSessionTerm(env: ?*erts.ErlNifEnv, session: c_int) erts.ERL_NIF_TERM {
    return if (session < 0) erts.atom(env, "nil") else erts.enif_make_int(env, session);
}

pub export fn mob_deliver_vendor_usb_devices(jpid: jni.JLong, json_array: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const len: usize = if (json_array) |p| jni.strlen(p) else 0;
    var jb: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &jb);
    if (len > 0) {
        if (json_array) |p| @memcpy(jb.data[0..len], p[0..len]);
    }

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "peripheral"),
        erts.atom(env, "vendor_usb"),
        erts.atom(env, "devices_json"),
        erts.atom(env, "nil"),
        erts.enif_make_binary(env, &jb),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_vendor_usb_permission(jpid: jni.JLong, granted: c_int, device_json: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const len: usize = if (device_json) |p| jni.strlen(p) else 0;
    var jb: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &jb);
    if (len > 0) {
        if (device_json) |p| @memcpy(jb.data[0..len], p[0..len]);
    }

    const tag = if (granted != 0)
        erts.atom(env, "permission_granted_json")
    else
        erts.atom(env, "permission_denied_json");

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "peripheral"),
        erts.atom(env, "vendor_usb"),
        tag,
        erts.atom(env, "nil"),
        erts.enif_make_binary(env, &jb),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_vendor_usb_opened(jpid: jni.JLong, session: c_int, device_json: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const len: usize = if (device_json) |p| jni.strlen(p) else 0;
    var jb: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &jb);
    if (len > 0) {
        if (device_json) |p| @memcpy(jb.data[0..len], p[0..len]);
    }

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "peripheral"),
        erts.atom(env, "vendor_usb"),
        erts.atom(env, "opened_json"),
        vendorUsbSessionTerm(env, session),
        erts.enif_make_binary(env, &jb),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_vendor_usb_data(jpid: jni.JLong, session: c_int, bytes: ?[*]const u8, nbytes: usize) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    var db: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(nbytes, &db);
    if (nbytes > 0) {
        if (bytes) |p| @memcpy(db.data[0..nbytes], p[0..nbytes]);
    }

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "peripheral"),
        erts.atom(env, "vendor_usb"),
        erts.atom(env, "data"),
        vendorUsbSessionTerm(env, session),
        erts.enif_make_binary(env, &db),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_vendor_usb_write_complete(jpid: jni.JLong, session: c_int, bytes_written: c_int) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const keys = [_]erts.ERL_NIF_TERM{erts.atom(env, "bytes")};
    const vals = [_]erts.ERL_NIF_TERM{erts.enif_make_int(env, bytes_written)};
    const map = erts.makeMap(env, &keys, &vals) orelse return;

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "peripheral"),
        erts.atom(env, "vendor_usb"),
        erts.atom(env, "write_complete"),
        vendorUsbSessionTerm(env, session),
        map,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_vendor_usb_event(jpid: jni.JLong, session: c_int, tag: ?[*:0]const u8, reason: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(jpid);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const payload = if (reason) |r|
        erts.enif_make_atom(env, r)
    else
        erts.atom(env, "ok");
    const tag_term = if (tag) |t|
        erts.enif_make_atom(env, t)
    else
        erts.atom(env, "error");

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "peripheral"),
        erts.atom(env, "vendor_usb"),
        tag_term,
        vendorUsbSessionTerm(env, session),
        payload,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Capability NIFs (thin shims to Kotlin) ───────────────────────────────

export fn nif_request_permission(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var cap_buf: [32]u8 = @splat(0);
    _ = erts.enif_get_atom(env, argv[0], &cap_buf, cap_buf.len, erts.ERL_NIF_LATIN1);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.request_permission, pid, jni.asCStr(&cap_buf));
}

export fn nif_biometric_authenticate(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    var reason: [256]u8 = @splat(0);
    if (bin.size + 1 <= reason.len) {
        @memcpy(reason[0..bin.size], bin.data[0..bin.size]);
        reason[bin.size] = 0;
    } else {
        // Truncate. Matches the C original's defensive truncate-or-default.
        @memcpy(reason[0 .. reason.len - 1], bin.data[0 .. reason.len - 1]);
        reason[reason.len - 1] = 0;
    }
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.biometric_authenticate, pid, jni.asCStr(&reason));
}

export fn nif_location_get_once(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.location_get_once, pid, "balanced");
}

export fn nif_location_start(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var acc_buf: [16]u8 = @splat(0);
    jni.copyZ(&acc_buf, "balanced");
    _ = erts.enif_get_atom(env, argv[0], &acc_buf, acc_buf.len, erts.ERL_NIF_LATIN1);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.location_start, pid, jni.asCStr(&acc_buf));
}

export fn nif_location_stop(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.location_stop);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_camera_capture_photo(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var qual: [16]u8 = @splat(0);
    jni.copyZ(&qual, "high");
    _ = erts.enif_get_atom(env, argv[0], &qual, qual.len, erts.ERL_NIF_LATIN1);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.camera_capture_photo, pid, jni.asCStr(&qual));
}

export fn nif_camera_capture_video(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var max_dur: c_int = 60;
    _ = erts.enif_get_int(env, argv[0], &max_dur);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var dur_buf: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&dur_buf, "{d}", .{max_dur}) catch {};
    return callBridgePidStr(env, Bridge.camera_capture_video, pid, jni.asCStr(&dur_buf));
}

export fn nif_camera_start_preview(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.camera_start_preview, pid, json);
}

export fn nif_camera_stop_preview(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.camera_stop_preview);
    detachIfAttached(attached);
    return erts.ok(env);
}

// Live camera frame stream. CameraX ImageAnalysis on the Kotlin side
// converts YUV → RGB f32, then calls back via
// `nativeDeliverCameraFrame` → `mob_deliver_camera_frame` to post a
// `{:camera, :frame, %{...}}` message to the caller pid.
export fn nif_camera_start_frame_stream(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.camera_start_frame_stream, pid, json);
}

export fn nif_camera_stop_frame_stream(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.camera_stop_frame_stream);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_photos_pick(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var max: c_int = 1;
    _ = erts.enif_get_int(env, argv[0], &max);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var max_buf: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&max_buf, "{d}", .{max}) catch {};
    return callBridgePidStr(env, Bridge.photos_pick, pid, jni.asCStr(&max_buf));
}

export fn nif_files_pick(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.files_pick, pid, json);
}

export fn nif_audio_start_recording(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.audio_start_recording, pid, json);
}

export fn nif_audio_stop_recording(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.audio_stop_recording);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_audio_play(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const path_bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const opts_bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    const path = binToCString(path_bin) orelse return erts.atom(env, "error");
    defer freeCString(path);
    const opts = binToCString(opts_bin) orelse return erts.atom(env, "error");
    defer freeCString(opts);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr2(env, Bridge.audio_play, pid, path, opts);
}

export fn nif_audio_stop_playback(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.audio_stop_playback);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_audio_set_volume(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var vol: f64 = 1.0;
    _ = erts.enif_get_double(env, argv[0], &vol);
    var vol_buf: [32]u8 = @splat(0);
    _ = std.fmt.bufPrint(&vol_buf, "{d:.6}", .{vol}) catch {};
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jvol = jni.newStringUTF(jenv, jni.asCStr(&vol_buf));
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.audio_set_volume, jvol);
    jni.deleteLocalRef(jenv, jvol);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_foundation_models_generate_text(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.atom(env, "unsupported");
}

export fn nif_vision_recognize_text(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.atom(env, "unsupported");
}

export fn nif_speech_transcribe_audio(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.atom(env, "unsupported");
}

export fn nif_motion_start(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var interval_ms: c_int = 100;
    _ = erts.enif_get_int(env, argv[1], &interval_ms);
    var ival_buf: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&ival_buf, "{d}", .{interval_ms}) catch {};
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.motion_start, pid, jni.asCStr(&ival_buf));
}

export fn nif_motion_stop(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.motion_stop);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_scanner_scan(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.scanner_scan, pid, json);
}

export fn nif_notify_schedule(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.notify_schedule, pid, json);
}

export fn nif_notify_cancel(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    var nid: [256]u8 = @splat(0);
    const copy = @min(bin.size, nid.len - 1);
    @memcpy(nid[0..copy], bin.data[0..copy]);
    nid[copy] = 0;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const js = jni.newStringUTF(jenv, jni.asCStr(&nid));
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.notify_cancel, js);
    jni.deleteLocalRef(jenv, js);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_notify_register_push(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.notify_register_push, pid, null);
}

// ── Storage ──────────────────────────────────────────────────────────────

export fn nif_storage_dir(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var loc: [32]u8 = @splat(0);
    _ = erts.enif_get_atom(env, argv[0], &loc, loc.len, erts.ERL_NIF_LATIN1);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jloc = jni.newStringUTF(jenv, jni.asCStr(&loc));
    const result = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.storage_dir, jloc);
    jni.deleteLocalRef(jenv, jloc);
    const out = jstringToBinaryTerm(env, jenv, result) orelse erts.atom(env, "nil");
    detachIfAttached(attached);
    return out;
}

export fn nif_storage_save_to_media_store(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const path = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(path);
    var type_buf: [16]u8 = @splat(0);
    jni.copyZ(&type_buf, "auto");
    _ = erts.enif_get_atom(env, argv[1], &type_buf, type_buf.len, erts.ERL_NIF_LATIN1);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr2(env, Bridge.storage_save_to_media_store, pid, path, jni.asCStr(&type_buf));
}

export fn nif_storage_external_files_dir(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var type_buf: [32]u8 = @splat(0);
    _ = erts.enif_get_atom(env, argv[0], &type_buf, type_buf.len, erts.ERL_NIF_LATIN1);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jtype = jni.newStringUTF(jenv, jni.asCStr(&type_buf));
    const result = jenv.*.CallStaticObjectMethod.?(jenv, Bridge.cls, Bridge.storage_external_files_dir, jtype);
    jni.deleteLocalRef(jenv, jtype);
    const out = jstringToBinaryTerm(env, jenv, result) orelse erts.atom(env, "nil");
    detachIfAttached(attached);
    return out;
}

/// iOS-only — Android has no equivalent. Returns `{:error, :not_supported}`.
export fn nif_storage_save_to_photo_library(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.errorTuple(env, erts.atom(env, "not_supported"));
}

// ── Alert / action sheet / toast ─────────────────────────────────────────

export fn nif_alert_show(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const title_bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const msg_bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    const btns_bin = getBinOrIolist(env, argv[2]) orelse return erts.badarg(env);

    const title = binToCString(title_bin) orelse return erts.atom(env, "error");
    defer freeCString(title);
    const message = binToCString(msg_bin) orelse return erts.atom(env, "error");
    defer freeCString(message);
    const btns = binToCString(btns_bin) orelse return erts.atom(env, "error");
    defer freeCString(btns);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jtitle = jni.newStringUTF(jenv, title);
    const jmessage = jni.newStringUTF(jenv, message);
    const jbtns = jni.newStringUTF(jenv, btns);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.alert_show, jtitle, jmessage, jbtns);
    jni.deleteLocalRef(jenv, jtitle);
    jni.deleteLocalRef(jenv, jmessage);
    jni.deleteLocalRef(jenv, jbtns);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_action_sheet_show(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const title_bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const btns_bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    const title = binToCString(title_bin) orelse return erts.atom(env, "error");
    defer freeCString(title);
    const btns = binToCString(btns_bin) orelse return erts.atom(env, "error");
    defer freeCString(btns);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jtitle = jni.newStringUTF(jenv, title);
    const jbtns = jni.newStringUTF(jenv, btns);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.action_sheet_show, jtitle, jbtns);
    jni.deleteLocalRef(jenv, jtitle);
    jni.deleteLocalRef(jenv, jbtns);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_toast_show(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const msg_bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    var dur: [8]u8 = @splat(0);
    jni.copyZ(&dur, "short");
    _ = erts.enif_get_atom(env, argv[1], &dur, dur.len, erts.ERL_NIF_LATIN1);
    const msg = binToCString(msg_bin) orelse return erts.atom(env, "error");
    defer freeCString(msg);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jmsg = jni.newStringUTF(jenv, msg);
    const jdur = jni.newStringUTF(jenv, jni.asCStr(&dur));
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.toast_show, jmsg, jdur);
    jni.deleteLocalRef(jenv, jmsg);
    jni.deleteLocalRef(jenv, jdur);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── WebView ──────────────────────────────────────────────────────────────

export fn nif_webview_eval_js(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const code = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(code);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jcode = jni.newStringUTF(jenv, code);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.webview_eval_js, jcode);
    jni.deleteLocalRef(jenv, jcode);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_webview_post_message(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jjson = jni.newStringUTF(jenv, json);
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.webview_post_message, jjson);
    jni.deleteLocalRef(jenv, jjson);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_webview_can_go_back(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "false");
    const result = jenv.*.CallStaticBooleanMethod.?(jenv, Bridge.cls, Bridge.webview_can_go_back);
    detachIfAttached(attached);
    return if (result != 0) erts.atom(env, "true") else erts.atom(env, "false");
}

export fn nif_webview_go_back(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.webview_go_back);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Background (foreground service) ──────────────────────────────────────

export fn nif_background_keep_alive(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.background_keep_alive);
    detachIfAttached(attached);
    return erts.ok(env);
}

export fn nif_background_stop(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.background_stop);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Mob.Device — lifecycle events + queries ──────────────────────────────
// Android implementation is partial — only `:appearance` (color scheme
// changes from MainActivity.onConfigurationChanged) is wired today. The
// rest (battery, thermal, lifecycle) is queued behind ProcessLifecycleOwner
// + ComponentCallbacks2 plumbing. Until then the dispatcher pid is stored
// so what IS wired (color scheme) can deliver, and the query NIFs return
// reasonable defaults.

var g_device_dispatcher_pid: erts.ErlNifPid = .{ .pid = 0 };
var g_device_dispatcher_set: bool = false;

fn deviceSendAtomPayload(comptime tag: [:0]const u8, atom_name: [*:0]const u8, payload_atom_str: [*:0]const u8) void {
    if (!g_device_dispatcher_set) return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, tag),
        erts.enif_make_atom(env, atom_name),
        erts.enif_make_atom(env, payload_atom_str),
    });
    var pid = g_device_dispatcher_pid;
    _ = erts.enif_send(null, &pid, env, msg);
}

/// Called from beam_jni.c's `Java_..._MobBridge_nativeNotifyColorScheme`
/// when MainActivity.onConfigurationChanged sees a uiMode flip. `scheme`
/// must be "light" or "dark".
pub export fn mob_send_color_scheme_changed(scheme: ?[*:0]const u8) callconv(.c) void {
    const s = scheme orelse return;
    deviceSendAtomPayload("mob_device", "color_scheme_changed", s);
}

export fn nif_device_set_dispatcher(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var pid: erts.ErlNifPid = undefined;
    if (erts.enif_get_local_pid(env, argv[0], &pid) == 0) return erts.badarg(env);
    g_device_dispatcher_pid = pid;
    g_device_dispatcher_set = true;
    return erts.ok(env);
}

export fn nif_device_battery_state(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    // TODO(android): query BatteryManager. For now, unknown / -1.
    return erts.makeTuple(env, .{
        erts.atom(env, "unknown"),
        erts.enif_make_int(env, -1),
    });
}

export fn nif_device_thermal_state(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    // TODO(android): PowerManager.getCurrentThermalStatus() (API 29+).
    return erts.atom(env, "nominal");
}

export fn nif_device_low_power_mode(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    // TODO(android): PowerManager.isPowerSaveMode().
    return erts.atom(env, "false");
}

export fn nif_device_foreground(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    // TODO(android): track via ProcessLifecycleOwner.
    return erts.atom(env, "true");
}

export fn nif_device_os_version(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    // TODO(android): Build.VERSION.RELEASE via JNI.
    return erts.enif_make_string(env, "", erts.ERL_NIF_LATIN1);
}

export fn nif_device_model(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    // TODO(android): Build.MODEL via JNI.
    return erts.enif_make_string(env, "Android", erts.ERL_NIF_LATIN1);
}

// ── Mob.Peripheral.VendorUsb NIFs ────────────────────────────────────────
//
// Thin wrappers over MobBridge's @JvmStatic vendor_usb_* methods. Each
// runs on the caller's BEAM scheduler, dispatches to Kotlin via the
// cached jmethodID, and returns :ok. Results (devices listed, permission
// granted, read chunks, etc.) flow back asynchronously via the
// mob_deliver_vendor_usb_* exports above, which Kotlin invokes from its
// USB receiver / reader thread through the beam_jni.c thunks.
//
// bulk_write is marked DIRTY_IO in the NIF table because it does a
// blocking copy of up to 16 KiB into a Java byte[] + a synchronous
// Kotlin static call that ends up in UsbDeviceConnection.bulkTransfer.

/// Sentinel-style guard: if `method` is null (MobBridge.kt doesn't have
/// the matching vendor_usb_* @JvmStatic), send a single
/// `{:peripheral, :vendor_usb, :error, nil, :unsupported}` to the caller
/// and short-circuit the NIF with :ok. Mirrors the iOS stub behaviour so
/// downstream code paths look the same whether the user is on iOS or an
/// Android app generated from an older mob_new template.
fn vendorUsbUnsupported(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    const msg_env = erts.enif_alloc_env() orelse return erts.ok(env);
    defer erts.enif_free_env(msg_env);
    const msg = erts.makeTuple(msg_env, .{
        erts.atom(msg_env, "peripheral"),
        erts.atom(msg_env, "vendor_usb"),
        erts.atom(msg_env, "error"),
        erts.atom(msg_env, "nil"),
        erts.atom(msg_env, "unsupported"),
    });
    _ = erts.enif_send(null, &pid, msg_env, msg);
    return erts.ok(env);
}

export fn nif_vendor_usb_list_devices(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.vendor_usb_list_devices == null) return vendorUsbUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.vendor_usb_list_devices, pid, json);
}

export fn nif_vendor_usb_request_permission(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.vendor_usb_request_permission == null) return vendorUsbUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const ref = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(ref);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.vendor_usb_request_permission, pid, ref);
}

export fn nif_vendor_usb_open(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.vendor_usb_open == null) return vendorUsbUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.vendor_usb_open, pid, json);
}

export fn nif_vendor_usb_bulk_write(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.vendor_usb_bulk_write == null) return vendorUsbUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    const bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    var timeout_ms: c_int = 1000;
    if (erts.enif_get_int(env, argv[2], &timeout_ms) == 0) return erts.badarg(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    // Copy the bytes into a fresh Java `byte[]` so Kotlin can hand it to
    // UsbDeviceConnection.bulkTransfer without re-resolving the BEAM
    // binary. SetByteArrayRegion is a straight memcpy; the byte[]
    // outlives this NIF call but Kotlin will let it GC once the bulk
    // transfer returns.
    const size: jni.JSize = @intCast(bin.size);
    const jbytes = jni.newByteArray(jenv, size);
    if (jbytes != null) {
        // BEAM stores binary contents as unsigned bytes; JNI's byte[] is
        // signed (jbyte = int8_t). A bit-for-bit copy is fine — the
        // signed/unsigned distinction is irrelevant for bulk I/O bytes.
        jni.setByteArrayRegion(jenv, jbytes, 0, size, @ptrCast(bin.data));
        jenv.*.CallStaticVoidMethod.?(
            jenv,
            Bridge.cls,
            Bridge.vendor_usb_bulk_write,
            pidToJlong(pid),
            @as(jni.JInt, session),
            jbytes,
            @as(jni.JInt, timeout_ms),
        );
        jni.deleteLocalRef(jenv, jbytes);
    }
    return erts.ok(env);
}

export fn nif_vendor_usb_start_reading(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.vendor_usb_start_reading == null) return vendorUsbUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var chunk_bytes: c_int = 4096;
    if (erts.enif_get_int(env, argv[1], &chunk_bytes) == 0) return erts.badarg(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.vendor_usb_start_reading,
        pidToJlong(pid),
        @as(jni.JInt, session),
        @as(jni.JInt, chunk_bytes),
    );
    return erts.ok(env);
}

export fn nif_vendor_usb_stop_reading(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.vendor_usb_stop_reading == null) return vendorUsbUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.vendor_usb_stop_reading,
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

export fn nif_vendor_usb_close(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.vendor_usb_close == null) return vendorUsbUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.vendor_usb_close,
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

// ═════════════════════════════════════════════════════════════════════════
// Mob.Bt (Bluetooth Classic) — atom cache + delivery functions + NIFs
// ═════════════════════════════════════════════════════════════════════════

const MobBtAtoms = struct {
    // Channel atoms
    bt: erts.ERL_NIF_TERM = 0,
    bt_hfp: erts.ERL_NIF_TERM = 0,
    bt_spp: erts.ERL_NIF_TERM = 0,
    bt_hid: erts.ERL_NIF_TERM = 0,

    // Discovery / pairing tags
    discovery_started: erts.ERL_NIF_TERM = 0,
    discovery_finished: erts.ERL_NIF_TERM = 0,
    discovery_cancelled: erts.ERL_NIF_TERM = 0,
    discovered: erts.ERL_NIF_TERM = 0,
    paired_list: erts.ERL_NIF_TERM = 0,
    paired: erts.ERL_NIF_TERM = 0,
    pair_failed: erts.ERL_NIF_TERM = 0,
    unpaired: erts.ERL_NIF_TERM = 0,
    err: erts.ERL_NIF_TERM = 0,

    // Profile lifecycle tags
    connecting: erts.ERL_NIF_TERM = 0,
    connected: erts.ERL_NIF_TERM = 0,
    connect_failed: erts.ERL_NIF_TERM = 0,
    disconnected: erts.ERL_NIF_TERM = 0,

    // HFP-specific
    vendor_subscribed: erts.ERL_NIF_TERM = 0,
    vendor_at: erts.ERL_NIF_TERM = 0,
    sco_started: erts.ERL_NIF_TERM = 0,
    sco_stopped: erts.ERL_NIF_TERM = 0,
    sco_audio: erts.ERL_NIF_TERM = 0,

    // SPP-specific
    data: erts.ERL_NIF_TERM = 0,
    written: erts.ERL_NIF_TERM = 0,

    // HID-specific
    input: erts.ERL_NIF_TERM = 0,
    raw_report: erts.ERL_NIF_TERM = 0,

    // Map keys
    k_address: erts.ERL_NIF_TERM = 0,
    k_name: erts.ERL_NIF_TERM = 0,
    k_bonded: erts.ERL_NIF_TERM = 0,
    k_reason: erts.ERL_NIF_TERM = 0,
    k_cmd: erts.ERL_NIF_TERM = 0,
    k_cmd_type: erts.ERL_NIF_TERM = 0,
    k_args: erts.ERL_NIF_TERM = 0,
    k_size: erts.ERL_NIF_TERM = 0,
    k_type: erts.ERL_NIF_TERM = 0,
    k_code: erts.ERL_NIF_TERM = 0,
    k_value: erts.ERL_NIF_TERM = 0,

    // Constants
    nil_atom: erts.ERL_NIF_TERM = 0,
    true_atom: erts.ERL_NIF_TERM = 0,
    false_atom: erts.ERL_NIF_TERM = 0,
};

var mob_bt_atoms: MobBtAtoms = .{};

/// Initialise the BT atom cache. Call from `nifLoad` once before any
/// BT NIF or deliver function fires.
pub fn mobBtAtomsInit(env: ?*erts.ErlNifEnv) void {
    mob_bt_atoms.bt = erts.atom(env, "bt");
    mob_bt_atoms.bt_hfp = erts.atom(env, "bt_hfp");
    mob_bt_atoms.bt_spp = erts.atom(env, "bt_spp");
    mob_bt_atoms.bt_hid = erts.atom(env, "bt_hid");

    mob_bt_atoms.discovery_started = erts.atom(env, "discovery_started");
    mob_bt_atoms.discovery_finished = erts.atom(env, "discovery_finished");
    mob_bt_atoms.discovery_cancelled = erts.atom(env, "discovery_cancelled");
    mob_bt_atoms.discovered = erts.atom(env, "discovered");
    mob_bt_atoms.paired_list = erts.atom(env, "paired_list");
    mob_bt_atoms.paired = erts.atom(env, "paired");
    mob_bt_atoms.pair_failed = erts.atom(env, "pair_failed");
    mob_bt_atoms.unpaired = erts.atom(env, "unpaired");
    mob_bt_atoms.err = erts.atom(env, "error");

    mob_bt_atoms.connecting = erts.atom(env, "connecting");
    mob_bt_atoms.connected = erts.atom(env, "connected");
    mob_bt_atoms.connect_failed = erts.atom(env, "connect_failed");
    mob_bt_atoms.disconnected = erts.atom(env, "disconnected");

    mob_bt_atoms.vendor_subscribed = erts.atom(env, "vendor_subscribed");
    mob_bt_atoms.vendor_at = erts.atom(env, "vendor_at");
    mob_bt_atoms.sco_started = erts.atom(env, "sco_started");
    mob_bt_atoms.sco_stopped = erts.atom(env, "sco_stopped");
    mob_bt_atoms.sco_audio = erts.atom(env, "sco_audio");

    mob_bt_atoms.data = erts.atom(env, "data");
    mob_bt_atoms.written = erts.atom(env, "written");

    mob_bt_atoms.input = erts.atom(env, "input");
    mob_bt_atoms.raw_report = erts.atom(env, "raw_report");

    mob_bt_atoms.k_address = erts.atom(env, "address");
    mob_bt_atoms.k_name = erts.atom(env, "name");
    mob_bt_atoms.k_bonded = erts.atom(env, "bonded");
    mob_bt_atoms.k_reason = erts.atom(env, "reason");
    mob_bt_atoms.k_cmd = erts.atom(env, "cmd");
    mob_bt_atoms.k_cmd_type = erts.atom(env, "cmd_type");
    mob_bt_atoms.k_args = erts.atom(env, "args");
    mob_bt_atoms.k_size = erts.atom(env, "size");
    mob_bt_atoms.k_type = erts.atom(env, "type");
    mob_bt_atoms.k_code = erts.atom(env, "code");
    mob_bt_atoms.k_value = erts.atom(env, "value");

    mob_bt_atoms.nil_atom = erts.atom(env, "nil");
    mob_bt_atoms.true_atom = erts.atom(env, "true");
    mob_bt_atoms.false_atom = erts.atom(env, "false");
}

// ═════════════════════════════════════════════════════════════════════════
// (3) Term constructors — mirror the C mob_bt_make_* helpers
// ═════════════════════════════════════════════════════════════════════════

/// Convert a C string into an Erlang binary term. Empty input → empty
/// binary (NOT a `<<>>` atom dance). Atoms cache must be initialised.
fn mobBtMakeBinaryStr(env: ?*erts.ErlNifEnv, s: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const len: usize = if (s) |p| jni.strlen(p) else 0;
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    if (len > 0) {
        if (s) |p| @memcpy(bin.data[0..len], p[0..len]);
    }
    return erts.enif_make_binary(env, &bin);
}

/// Build a binary term from arbitrary bytes (PCM audio, raw HID reports,
/// SPP byte streams, etc).
fn mobBtMakeBinaryBytes(env: ?*erts.ErlNifEnv, bytes: ?[*]const u8, len: usize) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    if (len > 0) {
        if (bytes) |p| @memcpy(bin.data[0..len], p[0..len]);
    }
    return erts.enif_make_binary(env, &bin);
}

/// Build `%{address: <<...>>, name: <<...>>, bonded: bool}`.
fn mobBtMakeDeviceMap(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8, name: ?[*:0]const u8, bonded: c_int) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{
        mob_bt_atoms.k_address,
        mob_bt_atoms.k_name,
        mob_bt_atoms.k_bonded,
    };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, address),
        mobBtMakeBinaryStr(env, name),
        if (bonded != 0) mob_bt_atoms.true_atom else mob_bt_atoms.false_atom,
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{address: <<...>>}`.
fn mobBtMakeAddressOnly(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{mob_bt_atoms.k_address};
    const vals = [_]erts.ERL_NIF_TERM{mobBtMakeBinaryStr(env, address)};
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{address: <<...>>, name: <<...>>}`.
fn mobBtMakeAddressName(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8, name: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{ mob_bt_atoms.k_address, mob_bt_atoms.k_name };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, address),
        mobBtMakeBinaryStr(env, name),
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{address: <<...>>, reason: :reason_atom}`. Reason defaults to
/// `:unknown` for null Kotlin strings — never explodes on missing data.
fn mobBtMakeAddressReason(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8, reason: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const reason_atom = if (reason) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const keys = [_]erts.ERL_NIF_TERM{ mob_bt_atoms.k_address, mob_bt_atoms.k_reason };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, address),
        reason_atom,
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{reason: :reason_atom}`.
fn mobBtMakeReasonOnly(env: ?*erts.ErlNifEnv, reason: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const reason_atom = if (reason) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const keys = [_]erts.ERL_NIF_TERM{mob_bt_atoms.k_reason};
    const vals = [_]erts.ERL_NIF_TERM{reason_atom};
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{cmd: <<...>>, cmd_type: int, args: <<...>>, address: <<...>>}`
/// for vendor AT events. cmd_type is the HFP AT command type code.
fn mobBtMakeVendorAtMap(env: ?*erts.ErlNifEnv, cmd: ?[*:0]const u8, cmd_type: c_int, args: ?[*:0]const u8, address: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{
        mob_bt_atoms.k_cmd,
        mob_bt_atoms.k_cmd_type,
        mob_bt_atoms.k_args,
        mob_bt_atoms.k_address,
    };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, cmd),
        erts.enif_make_int(env, cmd_type),
        mobBtMakeBinaryStr(env, args),
        mobBtMakeBinaryStr(env, address),
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{size: int}` for write-completion events.
fn mobBtMakeSizeMap(env: ?*erts.ErlNifEnv, size: c_int) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{mob_bt_atoms.k_size};
    const vals = [_]erts.ERL_NIF_TERM{erts.enif_make_int(env, size)};
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{type: int, code: int, value: int}` for HID input events.
/// Matches the Linux evdev struct input_event triple.
fn mobBtMakeInputMap(env: ?*erts.ErlNifEnv, ev_type: c_int, code: c_int, value: c_int) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{
        mob_bt_atoms.k_type,
        mob_bt_atoms.k_code,
        mob_bt_atoms.k_value,
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_int(env, ev_type),
        erts.enif_make_int(env, code),
        erts.enif_make_int(env, value),
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

// ═════════════════════════════════════════════════════════════════════════
// (4) Paired-list streaming accumulator
// ═════════════════════════════════════════════════════════════════════════
//
// The Kotlin side streams paired devices one at a time (begin → 0..N
// entries → finish). We need a stable per-pid buffer to accumulate entries
// in, since Kotlin can interleave streams from concurrent callers.
//
// 16 buckets × 128 max entries each. Slot lookup/insert/remove holds the
// table mutex; enif_send happens AFTER the mutex is released so a slow
// consumer doesn't block other accumulators.

const MOB_BT_PAIRED_BUCKETS: usize = 16;
const MOB_BT_PAIRED_MAX_ENTRIES: usize = 128;
const MOB_BT_ADDR_MAX: usize = 24; // "00:11:22:33:44:55" + null + slop
const MOB_BT_NAME_MAX: usize = 248; // BT spec max friendly name + null

const MobBtPairedEntry = extern struct {
    address: [MOB_BT_ADDR_MAX]u8,
    name: [MOB_BT_NAME_MAX]u8,
    bonded: c_int,
};

const MobBtPairedSlot = extern struct {
    pid_long: jni.JLong,
    in_use: c_int,
    count: usize,
    entries: [MOB_BT_PAIRED_MAX_ENTRIES]MobBtPairedEntry,
};

var mob_bt_paired_slots: [MOB_BT_PAIRED_BUCKETS]MobBtPairedSlot = blk: {
    var buf: [MOB_BT_PAIRED_BUCKETS]MobBtPairedSlot = undefined;
    for (&buf) |*s| s.* = std.mem.zeroes(MobBtPairedSlot);
    break :blk buf;
};
var mob_bt_paired_mutex: ?*erts.ErlNifMutex = null;

/// Initialise the paired-list accumulator. Returns 0 on success, -1 on
/// mutex-create failure. Call from `nifLoad`.
pub fn mobBtPairedInit() c_int {
    mob_bt_paired_mutex = erts.enif_mutex_create("mob_bt_paired_mutex") orelse return -1;
    return 0;
}

/// Find an in-use slot matching `pid_long`. Must hold the mutex.
fn mobBtPairedFindLocked(pid_long: jni.JLong) ?*MobBtPairedSlot {
    for (&mob_bt_paired_slots) |*s| {
        if (s.in_use != 0 and s.pid_long == pid_long) return s;
    }
    return null;
}

/// Claim the first free slot for `pid_long`, OR — if `pid_long` already
/// has a slot — reset it for a new accumulation cycle. Must hold mutex.
fn mobBtPairedClaimLocked(pid_long: jni.JLong) ?*MobBtPairedSlot {
    if (mobBtPairedFindLocked(pid_long)) |existing| {
        existing.count = 0;
        return existing;
    }
    for (&mob_bt_paired_slots) |*s| {
        if (s.in_use == 0) {
            s.in_use = 1;
            s.pid_long = pid_long;
            s.count = 0;
            return s;
        }
    }
    return null; // all slots in use — drop this accumulation
}

/// Mark a slot free. Must hold mutex.
fn mobBtPairedReleaseLocked(slot: *MobBtPairedSlot) void {
    slot.in_use = 0;
    slot.pid_long = 0;
    slot.count = 0;
}

// ═════════════════════════════════════════════════════════════════════════
// (5) BT envelope helper — 4-tuple {:bt, tag, session_or_nil, payload}
// ═════════════════════════════════════════════════════════════════════════
//
// All BT deliveries share this shape. Session is either an integer
// (profile event) or `:nil` (discovery / pairing event). Channel atom is
// `:bt` for discovery/pairing/error, `:bt_hfp` / `:bt_spp` / `:bt_hid`
// for profile-scoped events.

/// Return :nil or an integer for the session slot.
inline fn btSessionTerm(env: ?*erts.ErlNifEnv, session: c_int) erts.ERL_NIF_TERM {
    return if (session < 0) mob_bt_atoms.nil_atom else erts.enif_make_int(env, session);
}

// ═════════════════════════════════════════════════════════════════════════
// (6) Delivery functions — `mob_deliver_bt_*` exports
// ═════════════════════════════════════════════════════════════════════════
//
// Called from beam_jni.c's Java_..._MobBridge_nativeDeliverBt* thunks when
// Kotlin emits BT events. Each builds the typed envelope tuple and posts
// it to `pid_long` (an ErlNifPid round-tripped through Kotlin as a
// jlong).
//
// 33 functions total. Same structural shape as the VendorUsb deliveries:
// alloc env, build msg, send, free env. No mutex contention except the
// paired-list trio (begin / entry / finish), which holds the accumulator
// mutex briefly.

// ── Discovery (2-tuples — no payload) ──────────────────────────────────

pub export fn mob_deliver_bt_discovery_started(pid_long: jni.JLong) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovery_started,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_discovery_finished(pid_long: jni.JLong) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovery_finished,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_discovery_cancelled(pid_long: jni.JLong) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovery_cancelled,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Discovery / pairing (3-tuples — no session) ────────────────────────

pub export fn mob_deliver_bt_discovered(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
    bonded: c_int,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovered,
        mobBtMakeDeviceMap(env, address, name, bonded),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_paired(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
    bonded: c_int,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.paired,
        mobBtMakeDeviceMap(env, address, name, bonded),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_pair_failed(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.pair_failed,
        mobBtMakeAddressReason(env, address, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_unpaired(pid_long: jni.JLong, address: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.unpaired,
        mobBtMakeAddressOnly(env, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_error(pid_long: jni.JLong, reason: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.err,
        mobBtMakeReasonOnly(env, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Legacy JSON paired-devices (unused by current Elixir API but kept
//    for compat with Kotlin templates that pre-date the streamed paired
//    list accumulator). Just shoves the JSON binary in as the payload.

pub export fn mob_deliver_bt_paired_devices(pid_long: jni.JLong, json: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        erts.atom(env, "paired_devices_json"),
        mob_bt_atoms.nil_atom,
        mobBtMakeBinaryStr(env, json),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Paired-list streaming (begin / entry / finish) ─────────────────────

pub export fn mob_deliver_bt_paired_list_begin(pid_long: jni.JLong) callconv(.c) void {
    erts.enif_mutex_lock(mob_bt_paired_mutex);
    _ = mobBtPairedClaimLocked(pid_long);
    erts.enif_mutex_unlock(mob_bt_paired_mutex);
}

pub export fn mob_deliver_bt_paired_list_entry(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
    bonded: c_int,
) callconv(.c) void {
    erts.enif_mutex_lock(mob_bt_paired_mutex);
    defer erts.enif_mutex_unlock(mob_bt_paired_mutex);

    const slot = mobBtPairedFindLocked(pid_long) orelse return;
    if (slot.count >= MOB_BT_PAIRED_MAX_ENTRIES) return;

    const entry = &slot.entries[slot.count];
    if (address) |a| {
        const a_len = jni.strlen(a);
        const a_copy = @min(a_len, entry.address.len - 1);
        @memcpy(entry.address[0..a_copy], a[0..a_copy]);
        entry.address[a_copy] = 0;
    } else {
        entry.address[0] = 0;
    }
    if (name) |n| {
        const n_len = jni.strlen(n);
        const n_copy = @min(n_len, entry.name.len - 1);
        @memcpy(entry.name[0..n_copy], n[0..n_copy]);
        entry.name[n_copy] = 0;
    } else {
        entry.name[0] = 0;
    }
    entry.bonded = if (bonded != 0) 1 else 0;
    slot.count += 1;
}

pub export fn mob_deliver_bt_paired_list_finish(pid_long: jni.JLong) callconv(.c) void {
    // Snapshot under lock, then release before any term allocation.
    var snapshot: MobBtPairedSlot = undefined;

    erts.enif_mutex_lock(mob_bt_paired_mutex);
    const slot = mobBtPairedFindLocked(pid_long);
    if (slot == null) {
        erts.enif_mutex_unlock(mob_bt_paired_mutex);
        return;
    }
    snapshot = slot.?.*;
    mobBtPairedReleaseLocked(slot.?);
    erts.enif_mutex_unlock(mob_bt_paired_mutex);

    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    // Empty list as the cons-cdr seed. `enif_make_list` is variadic in
    // C and intentionally not exposed in mob_erts.zig (see the comment
    // on the make_list bindings); `enif_make_list_from_array` with
    // count=0 returns the same empty-list term via the non-variadic ABI.
    const empty: [0]erts.ERL_NIF_TERM = .{};
    var list = erts.enif_make_list_from_array(env, &empty, 0);
    var i: usize = snapshot.count;
    while (i > 0) {
        i -= 1;
        const entry = &snapshot.entries[i];
        const addr_ptr: [*:0]const u8 = @ptrCast(&entry.address);
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const dev = mobBtMakeDeviceMap(env, addr_ptr, name_ptr, entry.bonded);
        list = erts.enif_make_list_cell(env, dev, list);
    }

    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.paired_list,
        list,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── HFP profile deliveries ─────────────────────────────────────────────

pub export fn mob_deliver_bt_hfp_connecting(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.connecting,
        erts.enif_make_int(env, session),
        mobBtMakeAddressOnly(env, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_connected(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.connected,
        erts.enif_make_int(env, session),
        mobBtMakeAddressName(env, address, name),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_connect_failed(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.connect_failed,
        mobBtMakeAddressReason(env, address, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_disconnected(
    pid_long: jni.JLong,
    session: c_int,
    reason_atom: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const reason_term = if (reason_atom) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.disconnected,
        erts.enif_make_int(env, session),
        reason_term,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_vendor_subscribed(pid_long: jni.JLong, session: c_int) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.vendor_subscribed,
        erts.enif_make_int(env, session),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_vendor_at(
    pid_long: jni.JLong,
    session: c_int,
    cmd: ?[*:0]const u8,
    cmd_type: c_int,
    args: ?[*:0]const u8,
    address: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.vendor_at,
        erts.enif_make_int(env, session),
        mobBtMakeVendorAtMap(env, cmd, cmd_type, args, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_sco_started(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.sco_started,
        erts.enif_make_int(env, session),
        mobBtMakeAddressOnly(env, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_sco_stopped(pid_long: jni.JLong, session: c_int) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.sco_stopped,
        erts.enif_make_int(env, session),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_sco_audio(
    pid_long: jni.JLong,
    session: c_int,
    pcm: ?[*]const u8,
    len: usize,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.sco_audio,
        erts.enif_make_int(env, session),
        mobBtMakeBinaryBytes(env, pcm, len),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_error(
    pid_long: jni.JLong,
    session: c_int,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.err,
        erts.enif_make_int(env, session),
        mobBtMakeReasonOnly(env, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── SPP profile deliveries ─────────────────────────────────────────────

pub export fn mob_deliver_bt_spp_connected(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.connected,
        erts.enif_make_int(env, session),
        mobBtMakeAddressName(env, address, name),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_connect_failed(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.connect_failed,
        mobBtMakeAddressReason(env, address, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_disconnected(
    pid_long: jni.JLong,
    session: c_int,
    reason_atom: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const reason_term = if (reason_atom) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.disconnected,
        erts.enif_make_int(env, session),
        reason_term,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_data(
    pid_long: jni.JLong,
    session: c_int,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.data,
        erts.enif_make_int(env, session),
        mobBtMakeBinaryBytes(env, bytes, len),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_written(pid_long: jni.JLong, session: c_int, size: c_int) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.written,
        erts.enif_make_int(env, session),
        mobBtMakeSizeMap(env, size),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_error(
    pid_long: jni.JLong,
    session: c_int,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.err,
        erts.enif_make_int(env, session),
        mobBtMakeReasonOnly(env, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── HID profile deliveries ─────────────────────────────────────────────

pub export fn mob_deliver_bt_hid_connected(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hid,
        mob_bt_atoms.connected,
        erts.enif_make_int(env, session),
        mobBtMakeAddressOnly(env, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hid_connect_failed(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hid,
        mob_bt_atoms.connect_failed,
        mobBtMakeAddressReason(env, address, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hid_disconnected(
    pid_long: jni.JLong,
    session: c_int,
    reason_atom: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const reason_term = if (reason_atom) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hid,
        mob_bt_atoms.disconnected,
        erts.enif_make_int(env, session),
        reason_term,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hid_input(
    pid_long: jni.JLong,
    session: c_int,
    ev_type: c_int,
    code: c_int,
    value: c_int,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hid,
        mob_bt_atoms.input,
        erts.enif_make_int(env, session),
        mobBtMakeInputMap(env, ev_type, code, value),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hid_raw_report(
    pid_long: jni.JLong,
    session: c_int,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hid,
        mob_bt_atoms.raw_report,
        erts.enif_make_int(env, session),
        mobBtMakeBinaryBytes(env, bytes, len),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ═════════════════════════════════════════════════════════════════════════
// (7) NIF wrappers — `nif_bt_*`
// ═════════════════════════════════════════════════════════════════════════
//
// Mirror VendorUsb structurally: pull caller pid via enif_self, attach
// JNIEnv, dispatch via the cached jmethodID, return :ok. All responses
// come back asynchronously through the mob_deliver_bt_* hooks.
//
// `vendor_at_send` and `_send_audio` / `_spp_write` are the only ones
// with non-trivial argument marshalling (byte arrays for the audio /
// SPP writes, two strings for vendor AT).
//
// `unsupported` short-circuit mirrors VendorUsb's pattern: if MobBridge
// doesn't have the matching @JvmStatic (old mob_new template), emit a
// single `{:bt, :error, nil, %{reason: :unsupported}}` and return :ok.

fn btUnsupported(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    const msg_env = erts.enif_alloc_env() orelse return erts.ok(env);
    defer erts.enif_free_env(msg_env);
    const unsupported = erts.atom(msg_env, "unsupported");
    const keys = [_]erts.ERL_NIF_TERM{erts.atom(msg_env, "reason")};
    const vals = [_]erts.ERL_NIF_TERM{unsupported};
    const map = erts.makeMap(msg_env, &keys, &vals) orelse unsupported;
    const msg = erts.makeTuple(msg_env, .{
        erts.atom(msg_env, "bt"),
        erts.atom(msg_env, "error"),
        erts.atom(msg_env, "nil"),
        map,
    });
    _ = erts.enif_send(null, &pid, msg_env, msg);
    return erts.ok(env);
}

// ── No-arg discovery / paired-list NIFs ──

export fn nif_bt_list_paired(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.bt_list_paired == null) return btUnsupported(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.bt_list_paired, pidToJlong(pid));
    return erts.ok(env);
}

export fn nif_bt_start_discovery(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.bt_start_discovery == null) return btUnsupported(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.bt_start_discovery, pidToJlong(pid));
    return erts.ok(env);
}

export fn nif_bt_cancel_discovery(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (Bridge.bt_cancel_discovery == null) return btUnsupported(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(jenv, Bridge.cls, Bridge.bt_cancel_discovery, pidToJlong(pid));
    return erts.ok(env);
}

// ── JSON-arg NIFs (pair / unpair / hfp_connect / spp_connect / hid_connect) ──

export fn nif_bt_pair(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_pair == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.bt_pair, pid, json);
}

export fn nif_bt_unpair(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_unpair == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.bt_unpair, pid, json);
}

export fn nif_bt_hfp_connect(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hfp_connect == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.bt_hfp_connect, pid, json);
}

export fn nif_bt_spp_connect(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_spp_connect == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.bt_spp_connect, pid, json);
}

export fn nif_bt_hid_connect(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hid_connect == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, Bridge.bt_hid_connect, pid, json);
}

// ── Session-only NIFs ──

export fn nif_bt_disconnect(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_disconnect == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.bt_disconnect,
        pidToJlong(pid),
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

export fn nif_bt_hfp_subscribe_vendor_at(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hfp_subscribe_vendor_at == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    const bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const jjson = jni.newStringUTF(jenv, json);
    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.bt_hfp_subscribe_vendor_at,
        pidToJlong(pid),
        @as(jni.JInt, session),
        jjson,
    );
    if (jjson != null) jni.deleteLocalRef(jenv, jjson);
    return erts.ok(env);
}

export fn nif_bt_hfp_start_sco(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hfp_start_sco == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.bt_hfp_start_sco,
        pidToJlong(pid),
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

export fn nif_bt_hfp_stop_sco(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hfp_stop_sco == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.bt_hfp_stop_sco,
        pidToJlong(pid),
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

export fn nif_bt_hid_subscribe_raw(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hid_subscribe_raw == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.bt_hid_subscribe_raw,
        pidToJlong(pid),
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

// ── Two-string + session NIF (hfp_send_vendor_at/3) ──

export fn nif_bt_hfp_send_vendor_at(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hfp_send_vendor_at == null) return btUnsupported(env);

    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);

    const cmd_bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    const cmd = binToCString(cmd_bin) orelse return erts.atom(env, "error");
    defer freeCString(cmd);

    const args_bin = getBinOrIolist(env, argv[2]) orelse return erts.badarg(env);
    const args = binToCString(args_bin) orelse return erts.atom(env, "error");
    defer freeCString(args);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const jcmd = jni.newStringUTF(jenv, cmd);
    const jargs = jni.newStringUTF(jenv, args);
    jenv.*.CallStaticVoidMethod.?(
        jenv,
        Bridge.cls,
        Bridge.bt_hfp_send_vendor_at,
        pidToJlong(pid),
        @as(jni.JInt, session),
        jcmd,
        jargs,
    );
    if (jcmd != null) jni.deleteLocalRef(jenv, jcmd);
    if (jargs != null) jni.deleteLocalRef(jenv, jargs);
    return erts.ok(env);
}

// ── Byte-array NIFs (hfp_send_audio/2, spp_write/2) — dirty IO ──

export fn nif_bt_hfp_send_audio(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_hfp_send_audio == null) return btUnsupported(env);

    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    const bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const size: jni.JSize = @intCast(bin.size);
    const jbytes = jni.newByteArray(jenv, size);
    if (jbytes != null) {
        jni.setByteArrayRegion(jenv, jbytes, 0, size, @ptrCast(bin.data));
        jenv.*.CallStaticVoidMethod.?(
            jenv,
            Bridge.cls,
            Bridge.bt_hfp_send_audio,
            pidToJlong(pid),
            @as(jni.JInt, session),
            jbytes,
        );
        jni.deleteLocalRef(jenv, jbytes);
    }
    return erts.ok(env);
}

export fn nif_bt_spp_write(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (Bridge.bt_spp_write == null) return btUnsupported(env);

    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    const bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const size: jni.JSize = @intCast(bin.size);
    const jbytes = jni.newByteArray(jenv, size);
    if (jbytes != null) {
        jni.setByteArrayRegion(jenv, jbytes, 0, size, @ptrCast(bin.data));
        jenv.*.CallStaticVoidMethod.?(
            jenv,
            Bridge.cls,
            Bridge.bt_spp_write,
            pidToJlong(pid),
            @as(jni.JInt, session),
            jbytes,
        );
        jni.deleteLocalRef(jenv, jbytes);
    }
    return erts.ok(env);
}

// ── nif_load: cache all method IDs at BEAM startup ───────────────────────

/// Required-method helper. Returns false if the method isn't on the
/// Kotlin side — caller turns that into a `return -1` from nif_load.
inline fn cacheRequired(jenv: *jni.JNIEnv, name: [*:0]const u8, sig: [*:0]const u8, field: *jni.JMethodID) bool {
    field.* = jni.getStaticMethodID(jenv, Bridge.cls, name, sig);
    if (field.* == null) {
        loge_nif("nif_load: {s} not found", .{name});
        return false;
    }
    return true;
}

/// Optional-method helper. Clears any JNI exception and logs at INFO.
inline fn cacheOptional(jenv: *jni.JNIEnv, name: [*:0]const u8, sig: [*:0]const u8, field: *jni.JMethodID) void {
    field.* = jni.getStaticMethodID(jenv, Bridge.cls, name, sig);
    if (field.* == null) {
        jni.exceptionClear(jenv);
        logi_nif("nif_load: {s} not found (optional)", .{name});
    }
}

fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = priv;
    _ = info;
    logi_nif("nif_load: entered, Bridge.cls={any}", .{Bridge.cls});
    if (Bridge.cls == null) {
        loge_nif("Bridge.cls not cached — was mob_ui_cache_class called?", .{});
        return -1;
    }

    // tap_mutex + component_mutex are created here (mob_nif_init_state is
    // a Zig-side export, but for the all-Zig finale we just call the
    // initialiser directly — no C boundary to cross).
    if (mob_nif_init_state() != 0) {
        loge_nif("nif_load: mob_nif_init_state failed (mutex create)", .{});
        return -1;
    }

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse {
        loge_nif("nif_load: get_jenv returned null", .{});
        return -1;
    };
    defer detachIfAttached(attached);

    if (!cacheRequired(jenv, "setRootJson", "(Ljava/lang/String;Ljava/lang/String;)V", &Bridge.set_root)) return -1;
    if (!cacheRequired(jenv, "moveToBack", "()V", &Bridge.move_to_back)) return -1;
    if (!cacheRequired(jenv, "getSafeArea", "()[F", &Bridge.get_safe_area)) return -1;

    // getColorScheme() is optional — apps that haven't been regenerated
    // since it was added still load fine; nif_color_scheme falls back to
    // :light.
    cacheOptional(jenv, "getColorScheme", "()Ljava/lang/String;", &Bridge.get_color_scheme);

    if (!cacheRequired(jenv, "haptic", "(Ljava/lang/String;)V", &Bridge.haptic)) return -1;
    if (!cacheRequired(jenv, "clipboardPut", "(Ljava/lang/String;)V", &Bridge.clipboard_put)) return -1;
    if (!cacheRequired(jenv, "clipboardGet", "()Ljava/lang/String;", &Bridge.clipboard_get)) return -1;
    if (!cacheRequired(jenv, "shareText", "(Ljava/lang/String;)V", &Bridge.share_text)) return -1;
    if (!cacheRequired(jenv, "openUrl", "(Ljava/lang/String;)V", &Bridge.open_url)) return -1;

    // Async device-capability methods. Most take (J, String) where J is
    // the pid as a long.
    if (!cacheRequired(jenv, "request_permission", "(JLjava/lang/String;)V", &Bridge.request_permission)) return -1;
    if (!cacheRequired(jenv, "biometric_authenticate", "(JLjava/lang/String;)V", &Bridge.biometric_authenticate)) return -1;
    if (!cacheRequired(jenv, "location_get_once", "(JLjava/lang/String;)V", &Bridge.location_get_once)) return -1;
    if (!cacheRequired(jenv, "location_start", "(JLjava/lang/String;)V", &Bridge.location_start)) return -1;
    if (!cacheRequired(jenv, "location_stop", "()V", &Bridge.location_stop)) return -1;
    if (!cacheRequired(jenv, "camera_capture_photo", "(JLjava/lang/String;)V", &Bridge.camera_capture_photo)) return -1;
    if (!cacheRequired(jenv, "camera_capture_video", "(JLjava/lang/String;)V", &Bridge.camera_capture_video)) return -1;
    if (!cacheRequired(jenv, "camera_start_preview", "(JLjava/lang/String;)V", &Bridge.camera_start_preview)) return -1;
    if (!cacheRequired(jenv, "camera_stop_preview", "()V", &Bridge.camera_stop_preview)) return -1;
    if (!cacheRequired(jenv, "camera_start_frame_stream", "(JLjava/lang/String;)V", &Bridge.camera_start_frame_stream)) return -1;
    if (!cacheRequired(jenv, "camera_stop_frame_stream", "()V", &Bridge.camera_stop_frame_stream)) return -1;
    if (!cacheRequired(jenv, "photos_pick", "(JLjava/lang/String;)V", &Bridge.photos_pick)) return -1;
    if (!cacheRequired(jenv, "files_pick", "(JLjava/lang/String;)V", &Bridge.files_pick)) return -1;
    if (!cacheRequired(jenv, "audio_start_recording", "(JLjava/lang/String;)V", &Bridge.audio_start_recording)) return -1;
    if (!cacheRequired(jenv, "audio_stop_recording", "()V", &Bridge.audio_stop_recording)) return -1;
    if (!cacheRequired(jenv, "audio_play", "(JLjava/lang/String;Ljava/lang/String;)V", &Bridge.audio_play)) return -1;
    if (!cacheRequired(jenv, "audio_stop_playback", "()V", &Bridge.audio_stop_playback)) return -1;
    if (!cacheRequired(jenv, "audio_set_volume", "(Ljava/lang/String;)V", &Bridge.audio_set_volume)) return -1;
    if (!cacheRequired(jenv, "storage_dir", "(Ljava/lang/String;)Ljava/lang/String;", &Bridge.storage_dir)) return -1;
    if (!cacheRequired(jenv, "storage_save_to_media_store", "(JLjava/lang/String;Ljava/lang/String;)V", &Bridge.storage_save_to_media_store)) return -1;
    if (!cacheRequired(jenv, "storage_external_files_dir", "(Ljava/lang/String;)Ljava/lang/String;", &Bridge.storage_external_files_dir)) return -1;
    if (!cacheRequired(jenv, "alert_show", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V", &Bridge.alert_show)) return -1;
    if (!cacheRequired(jenv, "action_sheet_show", "(Ljava/lang/String;Ljava/lang/String;)V", &Bridge.action_sheet_show)) return -1;
    if (!cacheRequired(jenv, "toast_show", "(Ljava/lang/String;Ljava/lang/String;)V", &Bridge.toast_show)) return -1;
    if (!cacheRequired(jenv, "webview_eval_js", "(Ljava/lang/String;)V", &Bridge.webview_eval_js)) return -1;
    if (!cacheRequired(jenv, "webview_post_message", "(Ljava/lang/String;)V", &Bridge.webview_post_message)) return -1;
    if (!cacheRequired(jenv, "webview_can_go_back", "()Z", &Bridge.webview_can_go_back)) return -1;
    if (!cacheRequired(jenv, "webview_go_back", "()V", &Bridge.webview_go_back)) return -1;
    if (!cacheRequired(jenv, "motion_start", "(JLjava/lang/String;)V", &Bridge.motion_start)) return -1;
    if (!cacheRequired(jenv, "motion_stop", "()V", &Bridge.motion_stop)) return -1;
    if (!cacheRequired(jenv, "scanner_scan", "(JLjava/lang/String;)V", &Bridge.scanner_scan)) return -1;
    if (!cacheRequired(jenv, "notify_schedule", "(JLjava/lang/String;)V", &Bridge.notify_schedule)) return -1;
    if (!cacheRequired(jenv, "notify_cancel", "(Ljava/lang/String;)V", &Bridge.notify_cancel)) return -1;
    if (!cacheRequired(jenv, "notify_register_push", "(JLjava/lang/String;)V", &Bridge.notify_register_push)) return -1;
    if (!cacheRequired(jenv, "background_keep_alive", "()V", &Bridge.background_keep_alive)) return -1;
    if (!cacheRequired(jenv, "background_stop", "()V", &Bridge.background_stop)) return -1;

    // Mob.Peripheral.VendorUsb. Optional rather than required so apps
    // generated from an older `mob_new` template (without the matching
    // MobBridge.kt vendor_usb block from mob_new#2) still load — every
    // vendor_usb NIF below short-circuits with `:unsupported` when the
    // matching methodID is null. The user-visible effect on a stale
    // app is "call returns :ok but you get a single :error event with
    // reason :unsupported", which mirrors the iOS stubs' behaviour.
    cacheOptional(jenv, "vendor_usb_list_devices", "(JLjava/lang/String;)V", &Bridge.vendor_usb_list_devices);
    cacheOptional(jenv, "vendor_usb_request_permission", "(JLjava/lang/String;)V", &Bridge.vendor_usb_request_permission);
    cacheOptional(jenv, "vendor_usb_open", "(JLjava/lang/String;)V", &Bridge.vendor_usb_open);
    cacheOptional(jenv, "vendor_usb_bulk_write", "(JI[BI)V", &Bridge.vendor_usb_bulk_write);
    cacheOptional(jenv, "vendor_usb_start_reading", "(JII)V", &Bridge.vendor_usb_start_reading);
    cacheOptional(jenv, "vendor_usb_stop_reading", "(I)V", &Bridge.vendor_usb_stop_reading);
    cacheOptional(jenv, "vendor_usb_close", "(I)V", &Bridge.vendor_usb_close);

    // ── Mob.Bt (Bluetooth Classic) ───────────────────────────────────────
    // Optional like VendorUsb — older mob_new templates without the matching
    // Kotlin bt_* block will boot, with each bt_* NIF short-circuiting to
    // {:bt, :error, nil, %{reason: :unsupported}}.
    cacheOptional(jenv, "bt_list_paired", "(J)V", &Bridge.bt_list_paired);
    cacheOptional(jenv, "bt_start_discovery", "(J)V", &Bridge.bt_start_discovery);
    cacheOptional(jenv, "bt_cancel_discovery", "(J)V", &Bridge.bt_cancel_discovery);
    cacheOptional(jenv, "bt_pair", "(JLjava/lang/String;)V", &Bridge.bt_pair);
    cacheOptional(jenv, "bt_unpair", "(JLjava/lang/String;)V", &Bridge.bt_unpair);
    cacheOptional(jenv, "bt_disconnect", "(JI)V", &Bridge.bt_disconnect);
    cacheOptional(jenv, "bt_hfp_connect", "(JLjava/lang/String;)V", &Bridge.bt_hfp_connect);
    cacheOptional(jenv, "bt_hfp_subscribe_vendor_at", "(JILjava/lang/String;)V", &Bridge.bt_hfp_subscribe_vendor_at);
    cacheOptional(jenv, "bt_hfp_send_vendor_at", "(JILjava/lang/String;Ljava/lang/String;)V", &Bridge.bt_hfp_send_vendor_at);
    cacheOptional(jenv, "bt_hfp_start_sco", "(JI)V", &Bridge.bt_hfp_start_sco);
    cacheOptional(jenv, "bt_hfp_stop_sco", "(JI)V", &Bridge.bt_hfp_stop_sco);
    cacheOptional(jenv, "bt_hfp_send_audio", "(JI[B)V", &Bridge.bt_hfp_send_audio);
    cacheOptional(jenv, "bt_spp_connect", "(JLjava/lang/String;)V", &Bridge.bt_spp_connect);
    cacheOptional(jenv, "bt_spp_write", "(JI[B)V", &Bridge.bt_spp_write);
    cacheOptional(jenv, "bt_hid_connect", "(JLjava/lang/String;)V", &Bridge.bt_hid_connect);
    cacheOptional(jenv, "bt_hid_subscribe_raw", "(JI)V", &Bridge.bt_hid_subscribe_raw);

    // BT atom cache + paired-list accumulator state.
    mobBtAtomsInit(env);
    if (mobBtPairedInit() != 0) {
        loge_nif("nif_load: failed to create BT paired mutex", .{});
        return -1;
    }

    g_launch_notif_mutex = erts.enif_mutex_create("mob_launch_notif_mutex");
    if (g_launch_notif_mutex == null) {
        loge_nif("nif_load: failed to create launch notif mutex", .{});
        return -1;
    }

    // Test harness method IDs — optional. Apps without the harness build
    // (release variants, downstream consumers that don't link it) won't
    // have these and that's fine; the test NIFs return :not_loaded.
    cacheOptional(jenv, "uiTree", "()Ljava/lang/String;", &Bridge.ui_tree);
    cacheOptional(jenv, "uiViewTree", "()Ljava/lang/String;", &Bridge.ui_view_tree);
    cacheOptional(jenv, "screenInfo", "()[F", &Bridge.screen_info);
    cacheOptional(jenv, "tapXy", "(FF)Z", &Bridge.tap_xy);
    cacheOptional(jenv, "tapByLabel", "(Ljava/lang/String;)Z", &Bridge.tap_by_label);
    cacheOptional(jenv, "typeText", "(Ljava/lang/String;)Z", &Bridge.type_text);
    cacheOptional(jenv, "deleteBackward", "()Z", &Bridge.delete_backward);
    cacheOptional(jenv, "clearText", "()Z", &Bridge.clear_text);
    cacheOptional(jenv, "longPressXy", "(FFJ)Z", &Bridge.long_press_xy);
    cacheOptional(jenv, "swipeXy", "(FFFF)Z", &Bridge.swipe_xy);

    logi_nif("Mob NIF loaded (Compose backend)", .{});
    return 0;
}

// ── NIF table + ERL_NIF_INIT entry point ─────────────────────────────────
// Replaces the static `ErlNifFunc nif_funcs[]` + `ERL_NIF_INIT` macro
// that used to live at the bottom of mob_nif.c. The entry point is the
// `<MODNAME>_nif_init` symbol the BEAM looks up from the driver_tab —
// driver_tab_android.zig already extern-declares `mob_nif_nif_init` for
// the static-NIF link path.

const nif_funcs = [_]erts.ErlNifFunc{
    // Test harness first — matches the iOS nif_funcs[] ordering convention.
    .{ .name = "ui_tree", .arity = 0, .fptr = nif_ui_tree, .flags = erts.ERL_NIF_DIRTY_JOB_CPU_BOUND },
    .{ .name = "ui_view_tree", .arity = 0, .fptr = nif_ui_view_tree, .flags = erts.ERL_NIF_DIRTY_JOB_CPU_BOUND },
    .{ .name = "ax_action", .arity = 2, .fptr = nif_ax_action, .flags = 0 },
    .{ .name = "ax_action_at_xy", .arity = 3, .fptr = nif_ax_action_at_xy, .flags = 0 },
    .{ .name = "ui_debug", .arity = 0, .fptr = nif_ui_debug, .flags = erts.ERL_NIF_DIRTY_JOB_CPU_BOUND },
    .{ .name = "screen_info", .arity = 0, .fptr = nif_screen_info, .flags = 0 },
    .{ .name = "tap", .arity = 1, .fptr = nif_tap, .flags = 0 },
    .{ .name = "tap_xy", .arity = 2, .fptr = nif_tap_xy, .flags = 0 },
    .{ .name = "type_text", .arity = 1, .fptr = nif_type_text, .flags = 0 },
    .{ .name = "delete_backward", .arity = 0, .fptr = nif_delete_backward, .flags = 0 },
    .{ .name = "key_press", .arity = 1, .fptr = nif_key_press, .flags = 0 },
    .{ .name = "clear_text", .arity = 0, .fptr = nif_clear_text, .flags = 0 },
    .{ .name = "long_press_xy", .arity = 3, .fptr = nif_long_press_xy, .flags = 0 },
    .{ .name = "swipe_xy", .arity = 4, .fptr = nif_swipe_xy, .flags = 0 },
    // Core mob functions.
    .{ .name = "platform", .arity = 0, .fptr = nif_platform, .flags = 0 },
    .{ .name = "color_scheme", .arity = 0, .fptr = nif_color_scheme, .flags = 0 },
    .{ .name = "log", .arity = 1, .fptr = nif_log, .flags = 0 },
    .{ .name = "log", .arity = 2, .fptr = nif_log2, .flags = 0 },
    .{ .name = "set_transition", .arity = 1, .fptr = nif_set_transition, .flags = erts.ERL_NIF_DIRTY_JOB_CPU_BOUND },
    .{ .name = "set_root", .arity = 1, .fptr = nif_set_root, .flags = erts.ERL_NIF_DIRTY_JOB_CPU_BOUND },
    .{ .name = "register_tap", .arity = 1, .fptr = nif_register_tap, .flags = 0 },
    .{ .name = "clear_taps", .arity = 0, .fptr = nif_clear_taps, .flags = 0 },
    .{ .name = "exit_app", .arity = 0, .fptr = nif_exit_app, .flags = 0 },
    .{ .name = "safe_area", .arity = 0, .fptr = nif_safe_area, .flags = 0 },
    .{ .name = "haptic", .arity = 1, .fptr = nif_haptic, .flags = 0 },
    .{ .name = "clipboard_put", .arity = 1, .fptr = nif_clipboard_put, .flags = 0 },
    .{ .name = "clipboard_get", .arity = 0, .fptr = nif_clipboard_get, .flags = 0 },
    .{ .name = "share_text", .arity = 1, .fptr = nif_share_text, .flags = 0 },
    .{ .name = "open_url", .arity = 1, .fptr = nif_open_url, .flags = 0 },
    .{ .name = "request_permission", .arity = 1, .fptr = nif_request_permission, .flags = 0 },
    .{ .name = "biometric_authenticate", .arity = 1, .fptr = nif_biometric_authenticate, .flags = 0 },
    .{ .name = "location_get_once", .arity = 0, .fptr = nif_location_get_once, .flags = 0 },
    .{ .name = "location_start", .arity = 1, .fptr = nif_location_start, .flags = 0 },
    .{ .name = "location_stop", .arity = 0, .fptr = nif_location_stop, .flags = 0 },
    .{ .name = "camera_capture_photo", .arity = 1, .fptr = nif_camera_capture_photo, .flags = 0 },
    .{ .name = "camera_capture_video", .arity = 1, .fptr = nif_camera_capture_video, .flags = 0 },
    .{ .name = "camera_start_preview", .arity = 1, .fptr = nif_camera_start_preview, .flags = 0 },
    .{ .name = "camera_stop_preview", .arity = 0, .fptr = nif_camera_stop_preview, .flags = 0 },
    .{ .name = "camera_start_frame_stream", .arity = 1, .fptr = nif_camera_start_frame_stream, .flags = 0 },
    .{ .name = "camera_stop_frame_stream", .arity = 0, .fptr = nif_camera_stop_frame_stream, .flags = 0 },
    .{ .name = "photos_pick", .arity = 2, .fptr = nif_photos_pick, .flags = 0 },
    .{ .name = "files_pick", .arity = 1, .fptr = nif_files_pick, .flags = 0 },
    .{ .name = "audio_start_recording", .arity = 1, .fptr = nif_audio_start_recording, .flags = 0 },
    .{ .name = "audio_stop_recording", .arity = 0, .fptr = nif_audio_stop_recording, .flags = 0 },
    .{ .name = "audio_play", .arity = 2, .fptr = nif_audio_play, .flags = 0 },
    .{ .name = "audio_stop_playback", .arity = 0, .fptr = nif_audio_stop_playback, .flags = 0 },
    .{ .name = "audio_set_volume", .arity = 1, .fptr = nif_audio_set_volume, .flags = 0 },
    .{ .name = "foundation_models_generate_text", .arity = 2, .fptr = nif_foundation_models_generate_text, .flags = 0 },
    .{ .name = "vision_recognize_text", .arity = 2, .fptr = nif_vision_recognize_text, .flags = 0 },
    .{ .name = "speech_transcribe_audio", .arity = 2, .fptr = nif_speech_transcribe_audio, .flags = 0 },
    .{ .name = "motion_start", .arity = 2, .fptr = nif_motion_start, .flags = 0 },
    .{ .name = "motion_stop", .arity = 0, .fptr = nif_motion_stop, .flags = 0 },
    .{ .name = "scanner_scan", .arity = 1, .fptr = nif_scanner_scan, .flags = 0 },
    .{ .name = "notify_schedule", .arity = 1, .fptr = nif_notify_schedule, .flags = 0 },
    .{ .name = "notify_cancel", .arity = 1, .fptr = nif_notify_cancel, .flags = 0 },
    .{ .name = "notify_register_push", .arity = 0, .fptr = nif_notify_register_push, .flags = 0 },
    .{ .name = "take_launch_notification", .arity = 0, .fptr = nif_take_launch_notification, .flags = 0 },
    .{ .name = "storage_dir", .arity = 1, .fptr = nif_storage_dir, .flags = 0 },
    .{ .name = "storage_save_to_media_store", .arity = 2, .fptr = nif_storage_save_to_media_store, .flags = 0 },
    .{ .name = "storage_external_files_dir", .arity = 1, .fptr = nif_storage_external_files_dir, .flags = 0 },
    .{ .name = "storage_save_to_photo_library", .arity = 1, .fptr = nif_storage_save_to_photo_library, .flags = 0 },
    .{ .name = "alert_show", .arity = 3, .fptr = nif_alert_show, .flags = 0 },
    .{ .name = "action_sheet_show", .arity = 2, .fptr = nif_action_sheet_show, .flags = 0 },
    .{ .name = "toast_show", .arity = 2, .fptr = nif_toast_show, .flags = 0 },
    .{ .name = "webview_eval_js", .arity = 1, .fptr = nif_webview_eval_js, .flags = 0 },
    .{ .name = "webview_post_message", .arity = 1, .fptr = nif_webview_post_message, .flags = 0 },
    .{ .name = "webview_can_go_back", .arity = 0, .fptr = nif_webview_can_go_back, .flags = 0 },
    .{ .name = "webview_go_back", .arity = 0, .fptr = nif_webview_go_back, .flags = 0 },
    .{ .name = "register_component", .arity = 1, .fptr = nif_register_component, .flags = 0 },
    .{ .name = "deregister_component", .arity = 1, .fptr = nif_deregister_component, .flags = 0 },
    .{ .name = "background_keep_alive", .arity = 0, .fptr = nif_background_keep_alive, .flags = 0 },
    .{ .name = "background_stop", .arity = 0, .fptr = nif_background_stop, .flags = 0 },
    // Mob.Device — lifecycle events + queries (Android stubs except dispatcher set).
    .{ .name = "device_set_dispatcher", .arity = 1, .fptr = nif_device_set_dispatcher, .flags = 0 },
    .{ .name = "device_battery_state", .arity = 0, .fptr = nif_device_battery_state, .flags = 0 },
    .{ .name = "device_thermal_state", .arity = 0, .fptr = nif_device_thermal_state, .flags = 0 },
    .{ .name = "device_low_power_mode", .arity = 0, .fptr = nif_device_low_power_mode, .flags = 0 },
    .{ .name = "device_foreground", .arity = 0, .fptr = nif_device_foreground, .flags = 0 },
    .{ .name = "device_os_version", .arity = 0, .fptr = nif_device_os_version, .flags = 0 },
    .{ .name = "device_model", .arity = 0, .fptr = nif_device_model, .flags = 0 },
    // ── Mob.Peripheral.VendorUsb (Android USB host) ──────────────────────────
    .{ .name = "vendor_usb_list_devices", .arity = 1, .fptr = nif_vendor_usb_list_devices, .flags = 0 },
    .{ .name = "vendor_usb_request_permission", .arity = 1, .fptr = nif_vendor_usb_request_permission, .flags = 0 },
    .{ .name = "vendor_usb_open", .arity = 1, .fptr = nif_vendor_usb_open, .flags = 0 },
    .{ .name = "vendor_usb_bulk_write", .arity = 3, .fptr = nif_vendor_usb_bulk_write, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
    .{ .name = "vendor_usb_start_reading", .arity = 2, .fptr = nif_vendor_usb_start_reading, .flags = 0 },
    .{ .name = "vendor_usb_stop_reading", .arity = 1, .fptr = nif_vendor_usb_stop_reading, .flags = 0 },
    .{ .name = "vendor_usb_close", .arity = 1, .fptr = nif_vendor_usb_close, .flags = 0 },
    // ── Mob.Bt (Bluetooth Classic) ───────────────────────────────────────
    .{ .name = "bt_list_paired", .arity = 0, .fptr = nif_bt_list_paired, .flags = 0 },
    .{ .name = "bt_start_discovery", .arity = 0, .fptr = nif_bt_start_discovery, .flags = 0 },
    .{ .name = "bt_cancel_discovery", .arity = 0, .fptr = nif_bt_cancel_discovery, .flags = 0 },
    .{ .name = "bt_pair", .arity = 1, .fptr = nif_bt_pair, .flags = 0 },
    .{ .name = "bt_unpair", .arity = 1, .fptr = nif_bt_unpair, .flags = 0 },
    .{ .name = "bt_disconnect", .arity = 1, .fptr = nif_bt_disconnect, .flags = 0 },
    .{ .name = "bt_hfp_connect", .arity = 1, .fptr = nif_bt_hfp_connect, .flags = 0 },
    .{ .name = "bt_hfp_subscribe_vendor_at", .arity = 2, .fptr = nif_bt_hfp_subscribe_vendor_at, .flags = 0 },
    .{ .name = "bt_hfp_send_vendor_at", .arity = 3, .fptr = nif_bt_hfp_send_vendor_at, .flags = 0 },
    .{ .name = "bt_hfp_start_sco", .arity = 1, .fptr = nif_bt_hfp_start_sco, .flags = 0 },
    .{ .name = "bt_hfp_stop_sco", .arity = 1, .fptr = nif_bt_hfp_stop_sco, .flags = 0 },
    .{ .name = "bt_hfp_send_audio", .arity = 2, .fptr = nif_bt_hfp_send_audio, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
    .{ .name = "bt_spp_connect", .arity = 1, .fptr = nif_bt_spp_connect, .flags = 0 },
    .{ .name = "bt_spp_write", .arity = 2, .fptr = nif_bt_spp_write, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
    .{ .name = "bt_hid_connect", .arity = 1, .fptr = nif_bt_hid_connect, .flags = 0 },
    .{ .name = "bt_hid_subscribe_raw", .arity = 1, .fptr = nif_bt_hid_subscribe_raw, .flags = 0 },
};

var mob_nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1, // enable dirty-NIF support — matches what ERL_NIF_INIT emits.
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

/// `mob_nif_nif_init` — the symbol the BEAM looks up via the static NIF
/// table to find this NIF's `ErlNifEntry`. driver_tab_android.zig already
/// extern-declares it. STATIC_ERLANG_NIF + ERL_NIF_INIT_NAME(mob_nif) in
/// the C header would have expanded to the same symbol.
pub export fn mob_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &mob_nif_entry;
}
