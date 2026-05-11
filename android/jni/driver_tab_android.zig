//! driver_tab_android.zig — Reference snapshot of the static NIF table (Zig rewrite).
//!
//! Phase 6a of the build-system migration: hand-coded Zig sibling to
//! driver_tab_android.c, matching it byte-for-byte semantically.
//! Validates that Zig's `export` keyword produces the C-ABI symbols
//! libbeam.a expects (`erts_static_nif_tab`, `driver_tab`,
//! `erts_init_static_drivers`).
//!
//! Link BEFORE libbeam.a so this overrides BEAM's built-in empty
//! `erts_static_nif_tab[]` and `driver_tab[]`.

// ── ABI types ──────────────────────────────────────────────────────────────

const ErtsStaticDriver = extern struct {
    de: ?*anyopaque,
    flags: c_int,
};

const ErtsStaticNif = extern struct {
    nif_init: ?*const fn () callconv(.c) ?*anyopaque,
    is_builtin: c_int,
    nif_mod: c_ulong,
    entry: ?*anyopaque,
};

const ErlDrvEntryStub = extern struct {
    de: ?*anyopaque,
    flags: c_int,
};

const THE_NON_VALUE: c_ulong = 0;

// ── External driver entry refs (from libbeam.a / OTP) ──────────────────────

extern var inet_driver_entry: ErlDrvEntryStub;
extern var ram_file_driver_entry: ErlDrvEntryStub;

// ── External NIF init refs ─────────────────────────────────────────────────

extern fn prim_tty_nif_init() callconv(.c) ?*anyopaque;
extern fn erl_tracer_nif_init() callconv(.c) ?*anyopaque;
extern fn prim_buffer_nif_init() callconv(.c) ?*anyopaque;
extern fn prim_file_nif_init() callconv(.c) ?*anyopaque;
extern fn zlib_nif_init() callconv(.c) ?*anyopaque;
extern fn zstd_nif_init() callconv(.c) ?*anyopaque;
extern fn prim_socket_nif_init() callconv(.c) ?*anyopaque;
extern fn prim_net_nif_init() callconv(.c) ?*anyopaque;
extern fn asn1rt_nif_nif_init() callconv(.c) ?*anyopaque;

// crypto.c's ERL_NIF_INIT(crypto, ...) generates crypto_nif_init.
// Built into libpigeon.so via crypto.a + libcrypto.a (OpenSSL).
// Without this entry, the BEAM falls through to dlopen("crypto.so") which
// fails because Android's RTLD_LOCAL hides libpigeon.so's enif_* symbols
// from the dlopen'd library. With it, the BEAM resolves crypto via
// dlsym(RTLD_DEFAULT) and load_nif uses the static path — no dlopen,
// real OpenSSL.
extern fn crypto_nif_init() callconv(.c) ?*anyopaque;

// mob_nif.c's ERL_NIF_INIT(mob_nif, ...) generates mob_nif_nif_init.
extern fn mob_nif_nif_init() callconv(.c) ?*anyopaque;

// ── Static driver table ────────────────────────────────────────────────────

export var driver_tab: [3]ErtsStaticDriver = .{
    .{ .de = &inet_driver_entry, .flags = 0 },
    .{ .de = &ram_file_driver_entry, .flags = 0 },
    .{ .de = null, .flags = 0 },
};

export fn erts_init_static_drivers() callconv(.c) void {}

// ── Static NIF table ───────────────────────────────────────────────────────

export var erts_static_nif_tab = [_]ErtsStaticNif{
    .{ .nif_init = prim_tty_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = erl_tracer_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = prim_buffer_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = prim_file_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = zlib_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = zstd_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = prim_socket_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = prim_net_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = asn1rt_nif_nif_init, .is_builtin = 1, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = crypto_nif_init, .is_builtin = 1, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = mob_nif_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
    .{ .nif_init = null, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },
};
