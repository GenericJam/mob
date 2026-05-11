//! mob_nif.zig — Mob Android NIF implementations (Zig).
//!
//! Phase 6b iter 3 of the build-system migration: incremental port of
//! mob_nif.c (~2570 lines, 79 NIFs) to Zig. The C file stays in the build
//! alongside this one — both contribute symbols to the final lib<app>.so.
//! mob_nif.c's static `ErlNifFunc nif_funcs[]` table references the Zig
//! exports here via `extern` declarations at the top of mob_nif.c.
//!
//! Sub-iter sequence:
//!   * iter 3a (this file as it lands): 3 standalone NIFs — platform/0,
//!     log/1, log/2. No JNI, no shared state. Proves the cross-language
//!     linkage pattern.
//!   * iter 3b: test harness NIFs (ui_tree, tap_xy, type_text, swipe, etc.).
//!   * iter 3c: event senders + cached MobBridge method-ID struct + handle
//!     registries + per-handle throttle state.
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
