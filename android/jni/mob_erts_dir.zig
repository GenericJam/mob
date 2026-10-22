//! mob_erts_dir.zig — which `erts-<vsn>` directory under the OTP root the BEAM
//! boots from (BINDIR = <otp_root>/<erts>/bin).
//!
//! The ERTS version follows the OTP runtime mob_dev ships (erts-17.0 for
//! OTP 29.0, erts-17.1.1 for OTP 29.1.2), so it can't be a constant here: a
//! constant ties every mob release to one runtime. And mob_dev's OTP push
//! merges into files/otp/, so after an upgrade the old erts-* sits next to the
//! new one. The highest version wins. BINDIR only has to exist and hold the
//! helper binaries, which mob_beam.zig symlinks in from the APK's native lib
//! dir, so picking the newer of two is safe either way.
//!
//! Kept free of JNI/libc so `zig test` runs it on the host. ios/mob_erts_dir.h
//! is the same rule in C; keep the two in step.

const std = @import("std");

pub const prefix = "erts-";

/// True when `name` is an `erts-<vsn>` directory name.
pub fn isErts(name: []const u8) bool {
    return name.len > prefix.len and std.mem.startsWith(u8, name, prefix);
}

/// True when erts dir `a` has a higher version than `b`. Versions compare as
/// dot-separated integers, so erts-17.10 > erts-17.9 and erts-17.1.1 >
/// erts-17.1; a component that isn't a number counts as 0.
pub fn newer(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a[prefix.len..], '.');
    var ib = std.mem.splitScalar(u8, b[prefix.len..], '.');
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null and pb == null) return false;
        const na = component(pa);
        const nb = component(pb);
        if (na != nb) return na > nb;
    }
}

fn component(part: ?[]const u8) u32 {
    const s = part orelse return 0;
    return std.fmt.parseInt(u32, s, 10) catch 0;
}

/// Tracks the best `erts-*` name seen so far while a caller walks a
/// directory. `name()` is NUL-terminated, ready for a path format.
pub const Picker = struct {
    buf: [64]u8 = @splat(0),
    len: usize = 0,

    pub fn offer(self: *Picker, entry: []const u8) void {
        if (!isErts(entry) or entry.len >= self.buf.len) return;
        if (self.len != 0 and !newer(entry, self.buf[0..self.len])) return;
        @memcpy(self.buf[0..entry.len], entry);
        self.buf[entry.len] = 0;
        self.len = entry.len;
    }

    pub fn name(self: *const Picker) ?[*:0]const u8 {
        if (self.len == 0) return null;
        return @ptrCast(&self.buf);
    }
};

test "newer compares dot-separated integers" {
    try std.testing.expect(newer("erts-17.1.1", "erts-17.0"));
    try std.testing.expect(!newer("erts-17.0", "erts-17.1.1"));
    try std.testing.expect(newer("erts-17.10", "erts-17.9"));
    try std.testing.expect(newer("erts-17.1.1", "erts-17.1"));
    try std.testing.expect(!newer("erts-17.1", "erts-17.1"));
    try std.testing.expect(newer("erts-18.0", "erts-17.99.99"));
}

test "picker keeps the highest erts dir and ignores everything else" {
    var p: Picker = .{};
    try std.testing.expect(p.name() == null);
    for ([_][]const u8{ ".", "..", "lib", "erts", "erts-17.0", "releases", "erts-17.1.1", "erts-17.1", "my_app" }) |e| p.offer(e);
    try std.testing.expectEqualStrings("erts-17.1.1", std.mem.sliceTo(p.name().?, 0));
}

test "picker with a single erts dir" {
    var p: Picker = .{};
    p.offer("lib");
    p.offer("erts-17.0");
    try std.testing.expectEqualStrings("erts-17.0", std.mem.sliceTo(p.name().?, 0));
}
