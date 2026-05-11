//! driver_tab_ios.zig — Reference snapshot of the static NIF table (Zig rewrite).
//!
//! Phase 6a of the build-system migration: the per-app source-of-truth
//! for static NIFs still lives in `mob.exs`'s `:static_nifs` (regenerated
//! by `mix mob.regen_driver_tab`), but the *output* shape moves from C
//! to Zig. The hand-written file below matches the C version byte-for-
//! byte semantically, validates the C-ABI exports libbeam.a expects, and
//! gives later iters a comptime-friendly structure to build on.
//!
//! Link BEFORE libbeam.a so this overrides BEAM's built-in empty
//! `erts_static_nif_tab[]` and `driver_tab[]`.

// ── ABI types ──────────────────────────────────────────────────────────────
// Layouts mirror the C structs in libbeam.a. They use Zig's `extern struct`
// so the field order + alignment matches the C ABI exactly.

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

// NON-VALUE sentinel matches the C `#define THE_NON_VALUE` — used as
// `nif_mod` for entries the BEAM populates at load time.
const THE_NON_VALUE: c_ulong = 0;

// ── External driver entry refs (from libbeam.a / OTP) ──────────────────────

extern var inet_driver_entry: ErlDrvEntryStub;
extern var ram_file_driver_entry: ErlDrvEntryStub;

// ── External NIF init refs ─────────────────────────────────────────────────
// Each ERL_NIF_INIT(name, ...) macro in NIF source files generates a
// `<name>_nif_init` C function. We declare them here as extern so the
// table below can reference them.

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
// Built into the app binary via crypto.a + libcrypto.a (OpenSSL).
// Same pattern as Android — see driver_tab_android.{c,zig} for rationale
// (Android RTLD_LOCAL hides parent's enif_* symbols from dlopen'd
// children; iOS App Store likewise rejects dynamic NIFs in the bundle).
extern fn crypto_nif_init() callconv(.c) ?*anyopaque;

// mob_nif.m's ERL_NIF_INIT(mob_nif, ...) with -DSTATIC_ERLANG_NIF
// generates: mob_nif_nif_init.
extern fn mob_nif_nif_init() callconv(.c) ?*anyopaque;

// exqlite's sqlite3_nif is linked statically on device only. The build
// system passes a comptime flag to opt in (wired through build.zig in
// iter 2). For now `sqlite_static` is a plain comptime constant — its
// default is false (the simulator path), and device builds will
// override at compile time via the build module options system.
const sqlite_static: bool = false;
extern fn sqlite3_nif_nif_init() callconv(.c) ?*anyopaque;

// ── Static driver table ────────────────────────────────────────────────────
// inet + ram_file are the only drivers in the iOS bundle. NULL-terminator
// at the end matches the C version exactly.

export var driver_tab: [3]ErtsStaticDriver = .{
    .{ .de = &inet_driver_entry, .flags = 0 },
    .{ .de = &ram_file_driver_entry, .flags = 0 },
    .{ .de = null, .flags = 0 },
};

// erts_init_static_drivers is a hook BEAM calls during init. We have
// no drivers to register dynamically — the table above is the whole
// story — so the function is empty. Matches the C version.
export fn erts_init_static_drivers() callconv(.c) void {}

// ── Static NIF table ───────────────────────────────────────────────────────
// Comptime-built so adding the conditional sqlite3_nif entry is a clean
// `if` rather than `#ifdef`. The output array length adjusts automatically.

const base_nifs = [_]ErtsStaticNif{
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
};

const sqlite_nif = ErtsStaticNif{
    .nif_init = sqlite3_nif_nif_init,
    .is_builtin = 0,
    .nif_mod = THE_NON_VALUE,
    .entry = null,
};

const sentinel = ErtsStaticNif{
    .nif_init = null,
    .is_builtin = 0,
    .nif_mod = THE_NON_VALUE,
    .entry = null,
};

export var erts_static_nif_tab = blk: {
    if (sqlite_static) {
        break :blk base_nifs ++ [_]ErtsStaticNif{ sqlite_nif, sentinel };
    } else {
        break :blk base_nifs ++ [_]ErtsStaticNif{sentinel};
    }
};
