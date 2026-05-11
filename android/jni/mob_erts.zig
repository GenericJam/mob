//! mob_erts.zig — Hand-declared FFI bindings for the BEAM's ERL_NIF surface.
//!
//! Companion to mob_zig.zig (which covers JNI / libc / Android log). This
//! module narrows in on the symbols that NIF authors call when writing
//! against `erl_nif.h`. We hand-declare what we use rather than @cImport'ing
//! erl_nif.h for the same reasons documented at the top of mob_zig.zig:
//! Zig 0.17-dev's @cImport is gone, translate-c is unreliable on deeply
//! nested headers, and the surface is small + stable so an auditable
//! hand declaration is easy to maintain.
//!
//! Phase 6b iter 3a introduces this file. It declares only what iter 3a's
//! NIFs (nif_platform, nif_log, nif_log2) need; later iters extend it as
//! their ported NIFs require more of the ERL_NIF surface.
//!
//! Authoritative reference: OTP 27+ `erl_nif.h` and `erl_nif_api_funcs.h`.

const std = @import("std");

// ── Core types ─────────────────────────────────────────────────────────────

/// ERL_NIF_TERM is `ErlNifUInt`, which is `unsigned long` on every platform
/// where BEAM is supported. c_ulong matches that and stays 64-bit on
/// aarch64-android (LP64), which is what we ship.
pub const ERL_NIF_TERM = c_ulong;

/// Opaque from the user's perspective — the BEAM owns the layout.
pub const ErlNifEnv = opaque {};

/// ErlNifPid is a struct with a single ERL_NIF_TERM. Marked `extern` so
/// alignment matches the C definition.
pub const ErlNifPid = extern struct {
    pid: ERL_NIF_TERM,
};

/// Opaque mutex handle. enif_mutex_create returns one; the others take a
/// pointer to it.
pub const ErlNifMutex = opaque {};

/// Char encoding for enif_get_atom / enif_get_string / enif_make_string.
pub const ErlNifCharEncoding = c_int;
pub const ERL_NIF_LATIN1: ErlNifCharEncoding = 1;
pub const ERL_NIF_UTF8: ErlNifCharEncoding = 2;

/// Binary view. `data` points at heap-owned bytes; `size` is the length;
/// the trailing internal pointers (ref_bin, __spare__) are opaque to NIF
/// authors. Layout matches C exactly so `enif_inspect_binary(env, term, &bin)`
/// fills the same struct shape.
pub const ErlNifBinary = extern struct {
    size: usize,
    data: [*]u8,
    ref_bin: ?*anyopaque = null,
    __spare__: [2]?*anyopaque = .{ null, null },
};

/// NIF table entry. `fptr` follows the standard NIF signature
/// `ERL_NIF_TERM (*)(ErlNifEnv*, int argc, const ERL_NIF_TERM argv[])`.
pub const ErlNifFunc = extern struct {
    name: [*:0]const u8,
    arity: c_uint,
    fptr: ?*const fn (env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM,
    flags: c_uint,
};

// ── Term constructors ─────────────────────────────────────────────────────

pub extern fn enif_make_atom(env: ?*ErlNifEnv, name: [*:0]const u8) ERL_NIF_TERM;
pub extern fn enif_make_int(env: ?*ErlNifEnv, i: c_int) ERL_NIF_TERM;
pub extern fn enif_make_double(env: ?*ErlNifEnv, d: f64) ERL_NIF_TERM;
pub extern fn enif_make_badarg(env: ?*ErlNifEnv) ERL_NIF_TERM;
pub extern fn enif_make_binary(env: ?*ErlNifEnv, bin: *ErlNifBinary) ERL_NIF_TERM;
pub extern fn enif_make_string(env: ?*ErlNifEnv, str: [*:0]const u8, enc: ErlNifCharEncoding) ERL_NIF_TERM;

// ── Term inspectors ───────────────────────────────────────────────────────

/// Returns 1 on success, 0 on failure. Fills `bin` with the binary's
/// {size, data} view (no copy).
pub extern fn enif_inspect_binary(env: ?*ErlNifEnv, term: ERL_NIF_TERM, bin: *ErlNifBinary) c_int;

/// Returns 1 on success, 0 on failure. Reads an Erlang charlist into a
/// fixed-size C string buffer (NUL-terminated on success).
pub extern fn enif_get_string(
    env: ?*ErlNifEnv,
    list: ERL_NIF_TERM,
    buf: [*]u8,
    len: c_uint,
    enc: ErlNifCharEncoding,
) c_int;

/// Returns 1 on success, 0 on failure. Reads an atom name into a buffer
/// (NUL-terminated on success).
pub extern fn enif_get_atom(
    env: ?*ErlNifEnv,
    atom: ERL_NIF_TERM,
    buf: [*]u8,
    len: c_uint,
    enc: ErlNifCharEncoding,
) c_int;

// ── Convenience wrappers ──────────────────────────────────────────────────
// Idiomatic Zig surface over the bare extern fns. Keeps NIF bodies tight.

/// Make an atom from a comptime-known string literal.
pub inline fn atom(env: ?*ErlNifEnv, comptime name: [:0]const u8) ERL_NIF_TERM {
    return enif_make_atom(env, name.ptr);
}

/// The canonical `:ok` return.
pub inline fn ok(env: ?*ErlNifEnv) ERL_NIF_TERM {
    return enif_make_atom(env, "ok");
}

/// The canonical `badarg` return — typed identically to `ok` so the call
/// sites read symmetrically.
pub inline fn badarg(env: ?*ErlNifEnv) ERL_NIF_TERM {
    return enif_make_badarg(env);
}
