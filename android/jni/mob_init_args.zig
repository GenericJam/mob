//! mob_init_args.zig — the app's own Erlang init arguments (MOB-406).
//!
//! The app writes whitespace-separated tokens to `$MOB_DATA_DIR/mob_init_args`
//! (`Mob.InitArgs.write/1`); mob_beam.zig appends them after mob's own init
//! arguments (after the second `--`) at the next launch, in dev and release
//! builds. Unlike `beams_dir/mob_beam_flags`, which feeds the *emulator*
//! section, these are what `-proto_dist` / `-ssl_dist_optfile` need: the
//! emulator rejects init flags before the first `--`.
//!
//! The tokenizer is kept free of JNI/libc so `zig test` runs it on the host.
//! ios/mob_init_args.h is the same algorithm in C, with the same limits; keep
//! the two (and `Mob.InitArgs`'s validation) in step.

const std = @import("std");

pub const file_name = "mob_init_args";

/// The whole file must fit with room for the terminating NUL; `Mob.InitArgs`
/// refuses to write more than `buf_len - 1` bytes.
pub const buf_len: usize = 1024;

/// Tokens past this are dropped (and reported via `truncated`).
pub const max_args: usize = 63;

pub const InitArgs = struct {
    buf: [buf_len]u8 = @splat(0),
    argv: [max_args][*:0]const u8 = undefined,
    count: usize = 0,
    /// Set when the file was longer than `buf_len - 1` bytes or held more
    /// than `max_args` tokens. Whatever was kept ends on a token boundary.
    truncated: bool = false,

    /// Tokenises `buf[0..n]` in place. `n == buf_len` means the file filled
    /// the buffer, i.e. it may continue past it.
    pub fn parse(self: *InitArgs, n: usize) void {
        std.debug.assert(n <= buf_len);
        self.count = 0;
        self.truncated = false;
        var end = n;
        if (n == buf_len) {
            self.truncated = true;
            end = buf_len - 1;
            // A token running into the last byte may continue in the file:
            // drop it rather than pass half of it.
            if (!isSeparator(self.buf[end])) {
                while (end > 0 and !isSeparator(self.buf[end - 1])) end -= 1;
            }
        }
        self.buf[end] = 0;

        var p: usize = 0;
        while (p < end) {
            while (p < end and isSeparator(self.buf[p])) p += 1;
            if (p >= end) break;
            if (self.count == max_args) {
                self.truncated = true;
                break;
            }
            self.argv[self.count] = @ptrCast(&self.buf[p]);
            self.count += 1;
            while (p < end and !isSeparator(self.buf[p])) p += 1;
            self.buf[p] = 0;
            p += 1;
        }
    }

    pub fn args(self: *const InitArgs) []const [*:0]const u8 {
        return self.argv[0..self.count];
    }

    /// Appends the parsed init arguments at `start` and writes the trailing
    /// NULL `erl_start` expects. The launcher owns everything before `start`.
    pub fn appendTo(self: *const InitArgs, out: []?[*:0]const u8, start: usize) usize {
        std.debug.assert(start + self.count < out.len);
        var next = start;
        for (self.args()) |arg| {
            out[next] = arg;
            next += 1;
        }
        out[next] = null;
        return next;
    }
};

/// NUL separates too, so a stray one can't swallow the rest of the file.
pub inline fn isSeparator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0;
}

fn parseInto(a: *InitArgs, text: []const u8) void {
    const n = @min(text.len, buf_len);
    @memcpy(a.buf[0..n], text[0..n]);
    a.parse(n);
}

fn expectArgs(a: *const InitArgs, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, a.count);
    for (want, a.args()) |w, got| try std.testing.expectEqualStrings(w, std.mem.span(got));
}

test "splits on spaces, tabs and newlines and ignores leading/trailing ones" {
    var a: InitArgs = .{};
    parseInto(&a, "  -proto_dist inet_tls\t-ssl_dist_optfile /data/x.conf\r\n");
    try expectArgs(&a, &.{ "-proto_dist", "inet_tls", "-ssl_dist_optfile", "/data/x.conf" });
    try std.testing.expect(!a.truncated);
}

test "an empty or blank file gives no arguments" {
    var a: InitArgs = .{};
    parseInto(&a, "");
    try expectArgs(&a, &.{});
    parseInto(&a, " \n\t ");
    try expectArgs(&a, &.{});
}

test "an embedded NUL separates instead of ending the list" {
    var a: InitArgs = .{};
    parseInto(&a, "-a\x00-b c");
    try expectArgs(&a, &.{ "-a", "-b", "c" });
}

test "a file that fits exactly in buf_len - 1 bytes is kept whole" {
    var text: [buf_len - 1]u8 = undefined;
    @memset(&text, 'x');
    text[0] = '-';
    var a: InitArgs = .{};
    parseInto(&a, &text);
    try std.testing.expectEqual(@as(usize, 1), a.count);
    try std.testing.expectEqual(buf_len - 1, std.mem.span(a.argv[0]).len);
    try std.testing.expect(!a.truncated);
}

test "a file past the buffer drops the token cut at the edge" {
    // "-a b " then one token that straddles byte buf_len - 1.
    var text: [buf_len + 50]u8 = undefined;
    @memset(&text, 'y');
    @memcpy(text[0..5], "-a b ");
    var a: InitArgs = .{};
    parseInto(&a, &text);
    try std.testing.expect(a.truncated);
    try expectArgs(&a, &.{ "-a", "b" });
}

test "a cut that lands on a separator keeps the token before it" {
    var text: [buf_len + 10]u8 = undefined;
    @memset(&text, 'z');
    text[buf_len - 1] = ' ';
    var a: InitArgs = .{};
    parseInto(&a, &text);
    try std.testing.expect(a.truncated);
    try std.testing.expectEqual(@as(usize, 1), a.count);
}

test "one token larger than the buffer is dropped entirely" {
    var text: [buf_len + 1]u8 = undefined;
    @memset(&text, 'q');
    var a: InitArgs = .{};
    parseInto(&a, &text);
    try std.testing.expect(a.truncated);
    try std.testing.expectEqual(@as(usize, 0), a.count);
}

test "more than max_args tokens keeps the first max_args" {
    var text: [2 * (max_args + 5)]u8 = undefined;
    var i: usize = 0;
    while (i < text.len) : (i += 2) @memcpy(text[i .. i + 2], "a ");
    var a: InitArgs = .{};
    parseInto(&a, &text);
    try std.testing.expect(a.truncated);
    try std.testing.expectEqual(max_args, a.count);
}

test "exactly max_args tokens is not a truncation" {
    var text: [2 * max_args]u8 = undefined;
    var i: usize = 0;
    while (i < text.len) : (i += 2) @memcpy(text[i .. i + 2], "a ");
    var a: InitArgs = .{};
    parseInto(&a, &text);
    try std.testing.expect(!a.truncated);
    try std.testing.expectEqual(max_args, a.count);
}

test "launcher append keeps existing argv, appends after it, and terminates" {
    var a: InitArgs = .{};
    parseInto(&a, "-proto_dist operator");
    var out: [6]?[*:0]const u8 = @splat(null);
    out[0] = "beam";
    out[1] = "--";
    const end = a.appendTo(&out, 2);

    try std.testing.expectEqual(@as(usize, 4), end);
    try std.testing.expectEqualStrings("beam", std.mem.span(out[0].?));
    try std.testing.expectEqualStrings("--", std.mem.span(out[1].?));
    try std.testing.expectEqualStrings("-proto_dist", std.mem.span(out[2].?));
    try std.testing.expectEqualStrings("operator", std.mem.span(out[3].?));
    try std.testing.expect(out[4] == null);
}
