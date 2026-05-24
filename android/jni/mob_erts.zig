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
//! their ported NIFs require more of the ERL_NIF surface. iter 3b adds the
//! list / tuple / map constructors, enif_get_int / enif_get_double,
//! enif_alloc_binary, and enif_inspect_iolist_as_binary for the test
//! harness NIFs.
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

/// NIF dirty-job flags. Match the `ErlNifDirtyTaskFlags` enum in erl_nif.h —
/// these are the `flags` field values for ErlNifFunc entries that should
/// dispatch on a dirty scheduler. Plain CPU-bound work on the BEAM thread
/// (JSON parse, tree walks) uses CPU_BOUND; long-blocking I/O uses IO_BOUND.
pub const ERL_NIF_DIRTY_JOB_CPU_BOUND: c_uint = 1;
pub const ERL_NIF_DIRTY_JOB_IO_BOUND: c_uint = 2;

/// `ErlNifEntry` — the top-level NIF library descriptor. Returned by the
/// `<module>_nif_init` symbol that the `ERL_NIF_INIT` macro generates in C.
/// Iter 3d builds this struct manually in Zig (instead of via the C macro)
/// so the entire NIF surface — table, load callback, and entry returned to
/// the BEAM — lives in mob_nif.zig.
///
/// Major/minor + min_erts must match the headers the BEAM was built with.
/// We hard-code 2/18 + "erts-14.0" to match the bundled OTP 29 headers; if
/// you bump the OTP runtime, also bump these. `options = 1` allows dirty
/// NIFs (matches what the ERL_NIF_INIT macro emits today).
pub const ERL_NIF_MAJOR_VERSION: c_int = 2;
pub const ERL_NIF_MINOR_VERSION: c_int = 18;
pub const ERL_NIF_MIN_ERTS_VERSION: [*:0]const u8 = "erts-14.0";
pub const ERL_NIF_VM_VARIANT: [*:0]const u8 = "beam.vanilla";

/// ErlNifResourceTypeInit — declared opaque (we never construct one; only
/// its size is read from the entry to gate ABI compatibility). Size on
/// aarch64-linux: 5 pointers = 40 bytes (dtor/stop/down/dyncall + int).
pub const SIZEOF_ErlNifResourceTypeInit: usize = 40;

pub const ErlNifLoadFn = ?*const fn (env: ?*ErlNifEnv, priv_data: *?*anyopaque, load_info: ERL_NIF_TERM) callconv(.c) c_int;
pub const ErlNifReloadFn = ?*const fn (env: ?*ErlNifEnv, priv_data: *?*anyopaque, load_info: ERL_NIF_TERM) callconv(.c) c_int;
pub const ErlNifUpgradeFn = ?*const fn (env: ?*ErlNifEnv, priv_data: *?*anyopaque, old_priv: *?*anyopaque, load_info: ERL_NIF_TERM) callconv(.c) c_int;
pub const ErlNifUnloadFn = ?*const fn (env: ?*ErlNifEnv, priv_data: ?*anyopaque) callconv(.c) void;

pub const ErlNifEntry = extern struct {
    major: c_int,
    minor: c_int,
    name: [*:0]const u8,
    num_of_funcs: c_int,
    funcs: [*]const ErlNifFunc,
    load: ErlNifLoadFn,
    reload: ErlNifReloadFn,
    upgrade: ErlNifUpgradeFn,
    unload: ErlNifUnloadFn,
    vm_variant: [*:0]const u8,
    options: c_uint,
    sizeof_ErlNifResourceTypeInit: usize,
    min_erts: [*:0]const u8,
};

// ── Term constructors ─────────────────────────────────────────────────────

pub extern fn enif_make_atom(env: ?*ErlNifEnv, name: [*:0]const u8) ERL_NIF_TERM;
pub extern fn enif_make_int(env: ?*ErlNifEnv, i: c_int) ERL_NIF_TERM;
pub extern fn enif_make_double(env: ?*ErlNifEnv, d: f64) ERL_NIF_TERM;
pub extern fn enif_make_badarg(env: ?*ErlNifEnv) ERL_NIF_TERM;
pub extern fn enif_make_binary(env: ?*ErlNifEnv, bin: *ErlNifBinary) ERL_NIF_TERM;
pub extern fn enif_make_string(env: ?*ErlNifEnv, str: [*:0]const u8, enc: ErlNifCharEncoding) ERL_NIF_TERM;

// List construction (iter 3b).
//
// `enif_make_list` in C is variadic with a count prefix; we expose the
// non-variadic `enif_make_list_from_array` and `enif_make_list_cell`
// (prepend) primitives. Fixed-arity helpers below are built on top.
pub extern fn enif_make_list_cell(env: ?*ErlNifEnv, car: ERL_NIF_TERM, cdr: ERL_NIF_TERM) ERL_NIF_TERM;
pub extern fn enif_make_list_from_array(env: ?*ErlNifEnv, arr: [*]const ERL_NIF_TERM, cnt: c_uint) ERL_NIF_TERM;

// Tuple construction (iter 3b). `enif_make_tuple` is variadic; the
// non-variadic `enif_make_tuple_from_array` is the underlying primitive.
pub extern fn enif_make_tuple_from_array(env: ?*ErlNifEnv, arr: [*]const ERL_NIF_TERM, cnt: c_uint) ERL_NIF_TERM;

// Map construction (iter 3b). Returns 1 on success, 0 on duplicate key.
// `keys` and `values` are parallel arrays of length `cnt`; `*map_out` is
// populated on success.
pub extern fn enif_make_map_from_arrays(
    env: ?*ErlNifEnv,
    keys: [*]const ERL_NIF_TERM,
    values: [*]const ERL_NIF_TERM,
    cnt: usize,
    map_out: *ERL_NIF_TERM,
) c_int;

// Binary allocation (iter 3b). Returns 1 on success, 0 on OOM. The caller
// owns `bin.data` until it's wrapped via `enif_make_binary`, after which
// BEAM owns it.
pub extern fn enif_alloc_binary(size: usize, bin: *ErlNifBinary) c_int;

// 64-bit integer constructors (iter 3c). Used by the throttled gesture/
// scroll/drag/pinch senders for monotonic timestamps and sequence numbers.
//
// Symbol-name twist: OTP's `erl_nif_api_funcs.h` does
//
//     #if SIZEOF_LONG == 8
//     #  define enif_make_int64  enif_make_long
//     #  define enif_make_uint64 enif_make_ulong
//     #endif
//
// On aarch64-android (LP64 — `long` is 8 bytes) the real symbols in
// libbeam.a are `enif_make_long` / `enif_make_ulong`; `enif_make_int64`
// is just a preprocessor alias. Zig doesn't run the C preprocessor, so
// `extern fn enif_make_int64` would look for a literal symbol that
// doesn't exist on 64-bit and dlopen would fail at app launch with
// `cannot locate symbol "enif_make_int64"`.
//
// On armeabi-v7a (ILP32 — `long` is 4 bytes) the alias doesn't fire and
// `enif_make_int64` is a real symbol. We pick the right linker name at
// comptime via `@extern`.
const enif_make_int64_fn = @extern(
    *const fn (?*ErlNifEnv, i64) callconv(.c) ERL_NIF_TERM,
    .{ .name = if (@sizeOf(c_long) == 8) "enif_make_long" else "enif_make_int64" },
);
const enif_make_uint64_fn = @extern(
    *const fn (?*ErlNifEnv, u64) callconv(.c) ERL_NIF_TERM,
    .{ .name = if (@sizeOf(c_long) == 8) "enif_make_ulong" else "enif_make_uint64" },
);

pub inline fn enif_make_int64(env: ?*ErlNifEnv, i: i64) ERL_NIF_TERM {
    return enif_make_int64_fn(env, i);
}

pub inline fn enif_make_uint64(env: ?*ErlNifEnv, i: u64) ERL_NIF_TERM {
    return enif_make_uint64_fn(env, i);
}

// Term-env hop (iter 3c). enif_send delivers a message to a pid; the
// `msg_env` must be a "process-independent" env allocated via
// enif_alloc_env / freed via enif_free_env after the send returns.
// Terms in `msg_env` must originate there or be copied in via
// enif_make_copy.
pub extern fn enif_alloc_env() ?*ErlNifEnv;
pub extern fn enif_free_env(env: ?*ErlNifEnv) void;
pub extern fn enif_alloc(size: usize) ?*anyopaque;
pub extern fn enif_free(ptr: ?*anyopaque) void;
pub extern fn enif_make_copy(dst: ?*ErlNifEnv, src_term: ERL_NIF_TERM) ERL_NIF_TERM;
pub extern fn enif_send(
    caller_env: ?*ErlNifEnv,
    to_pid: *const ErlNifPid,
    msg_env: ?*ErlNifEnv,
    msg: ERL_NIF_TERM,
) c_int;
pub extern fn enif_self(caller_env: ?*ErlNifEnv, pid: *ErlNifPid) ?*ErlNifPid;

// Pid resolution (iter 3c).
pub extern fn enif_get_local_pid(env: ?*ErlNifEnv, term: ERL_NIF_TERM, pid: *ErlNifPid) c_int;
pub extern fn enif_whereis_pid(env: ?*ErlNifEnv, name: ERL_NIF_TERM, pid: *ErlNifPid) c_int;

// Tuple inspectors (iter 3c).
pub extern fn enif_get_tuple(env: ?*ErlNifEnv, tpl: ERL_NIF_TERM, arity: *c_int, array: *[*]const ERL_NIF_TERM) c_int;

// List inspectors.
pub extern fn enif_get_list_length(env: ?*ErlNifEnv, term: ERL_NIF_TERM, len: *c_uint) c_int;
pub extern fn enif_get_list_cell(env: ?*ErlNifEnv, term: ERL_NIF_TERM, head: *ERL_NIF_TERM, tail: *ERL_NIF_TERM) c_int;

// Mutex (iter 3c). enif_mutex_create allocates; destroy + try-lock omitted
// — Mob only uses simple lock/unlock pairs and the mutexes live for the
// lifetime of the BEAM process (no destroy needed).
pub extern fn enif_mutex_create(name: [*:0]const u8) ?*ErlNifMutex;
pub extern fn enif_mutex_lock(mtx: ?*ErlNifMutex) void;
pub extern fn enif_mutex_unlock(mtx: ?*ErlNifMutex) void;

// ── Term inspectors ───────────────────────────────────────────────────────

/// Returns 1 on success, 0 on failure. Fills `bin` with the binary's
/// {size, data} view (no copy).
pub extern fn enif_inspect_binary(env: ?*ErlNifEnv, term: ERL_NIF_TERM, bin: *ErlNifBinary) c_int;

/// Returns 1 on success, 0 on failure. Like enif_inspect_binary, but
/// accepts an iolist (list of binaries/integers) and materialises a
/// contiguous binary view. Used when callers can pass either a plain
/// binary or an iolist (e.g. set_root/1).
pub extern fn enif_inspect_iolist_as_binary(env: ?*ErlNifEnv, term: ERL_NIF_TERM, bin: *ErlNifBinary) c_int;

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

/// Read an integer term. Returns 1 on success, 0 on failure.
pub extern fn enif_get_int(env: ?*ErlNifEnv, term: ERL_NIF_TERM, ip: *c_int) c_int;

/// Read a double term. Returns 1 on success, 0 on failure.
pub extern fn enif_get_double(env: ?*ErlNifEnv, term: ERL_NIF_TERM, dp: *f64) c_int;

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

/// Build an N-tuple from a comptime-known list of terms. Mirrors the C
/// `enif_make_tupleN` inlines but works for any arity via the underlying
/// `enif_make_tuple_from_array` primitive.
pub inline fn makeTuple(env: ?*ErlNifEnv, elems: anytype) ERL_NIF_TERM {
    const arr: [elems.len]ERL_NIF_TERM = elems;
    return enif_make_tuple_from_array(env, &arr, elems.len);
}

/// `{:error, Reason}` 2-tuple convenience.
pub inline fn errorTuple(env: ?*ErlNifEnv, reason: ERL_NIF_TERM) ERL_NIF_TERM {
    return makeTuple(env, .{ enif_make_atom(env, "error"), reason });
}

/// Build a proper Erlang list from a slice of terms.
pub inline fn makeList(env: ?*ErlNifEnv, items: []const ERL_NIF_TERM) ERL_NIF_TERM {
    return enif_make_list_from_array(env, items.ptr, @intCast(items.len));
}

/// Build a map from parallel key/value slices. Returns null on duplicate
/// key (matches the C convention of `enif_make_map_from_arrays` returning 0).
pub inline fn makeMap(env: ?*ErlNifEnv, keys: []const ERL_NIF_TERM, values: []const ERL_NIF_TERM) ?ERL_NIF_TERM {
    std.debug.assert(keys.len == values.len);
    var out: ERL_NIF_TERM = undefined;
    if (enif_make_map_from_arrays(env, keys.ptr, values.ptr, keys.len, &out) == 0) return null;
    return out;
}

/// Read a numeric term as a double, accepting either a double or an integer
/// term. Returns null if neither path succeeds. Mirrors a common pattern
/// in the test harness NIFs where Erlang callers may pass `100` or `100.0`
/// interchangeably for coordinates.
pub inline fn getNumber(env: ?*ErlNifEnv, term: ERL_NIF_TERM) ?f64 {
    var d: f64 = 0;
    if (enif_get_double(env, term, &d) != 0) return d;
    var i: c_int = 0;
    if (enif_get_int(env, term, &i) != 0) return @floatFromInt(i);
    return null;
}
