//! What native code keeps for the :mob_screen router while the router can't
//! take it: notification envelopes and opened links that arrive before the
//! BEAM is up (the tap or link that cold-launched the app) or while it starts.
//! The router drains a queue when it starts, one entry per take NIF call
//! (decisions/2026-10-01-notification-delivery-envelope.md,
//! decisions/2026-10-03-deep-link-delivery.md). mob_nif.zig keeps one queue per
//! kind; ios/mob_stored_queue.h is the iOS twin.
//!
//! A FIFO, not one slot: a foreground arrival during boot must not displace
//! the tap that launched the app. When it is full (a router that never starts)
//! the newest entry is refused, so whatever launched the app is kept.
//!
//! The queue holds C strings it does not allocate: push takes ownership of a
//! stored entry, and every entry that leaves (pop, takeAll) belongs to the
//! caller again. That keeps allocation, and the logging of a refused entry,
//! outside the lock.
//!
//! Tests: `zig test android/jni/mob_stored_queue.zig`.

const std = @import("std");

pub const capacity = 16;

pub const Push = enum {
    /// The queue owns the entry now.
    stored,
    /// `unless_queued` and an equal entry is waiting; the caller still owns it.
    already_queued,
    /// The queue is full; the caller still owns it.
    full,
};

pub const StoredQueue = struct {
    items: [capacity]?[*:0]u8 = @splat(null),
    head: usize = 0,
    count: usize = 0,
    // A spinlock, not an ErlNifMutex: Kotlin stores before the BEAM exists
    // (onCreate), and NotificationReceiver can store while nif_load is still
    // running, so the lock has to work before erts does. It is held for a few
    // loads and stores.
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn acquire(q: *StoredQueue) void {
        while (q.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(q: *StoredQueue) void {
        q.lock.store(false, .release);
    }

    /// Appends `s`, taking ownership when the result is `.stored`. With
    /// `unless_queued`, an entry equal to one already waiting is not added.
    pub fn push(q: *StoredQueue, s: [*:0]u8, unless_queued: bool) Push {
        q.acquire();
        defer q.release();
        if (unless_queued and q.containsLocked(s)) return .already_queued;
        if (q.count == capacity) return .full;
        q.items[(q.head + q.count) % capacity] = s;
        q.count += 1;
        return .stored;
    }

    fn containsLocked(q: *StoredQueue, s: [*:0]const u8) bool {
        var i: usize = 0;
        while (i < q.count) : (i += 1) {
            const waiting = q.items[(q.head + i) % capacity] orelse continue;
            if (std.mem.orderZ(u8, waiting, s) == .eq) return true;
        }
        return false;
    }

    /// The oldest entry, now the caller's, or null.
    pub fn pop(q: *StoredQueue) ?[*:0]u8 {
        q.acquire();
        defer q.release();
        if (q.count == 0) return null;
        const s = q.items[q.head];
        q.items[q.head] = null;
        q.head = (q.head + 1) % capacity;
        q.count -= 1;
        return s;
    }

    /// Empties the queue under one hold of the lock, so an entry pushed
    /// concurrently lands after the clear and survives it. Returns the
    /// entries, oldest first, as the caller's.
    pub fn takeAll(q: *StoredQueue, out: *[capacity][*:0]u8) []const [*:0]u8 {
        q.acquire();
        defer q.release();
        const n = q.count;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const slot = (q.head + i) % capacity;
            out[i] = q.items[slot].?;
            q.items[slot] = null;
        }
        q.head = 0;
        q.count = 0;
        return out[0..n];
    }
};

const testing = std.testing;

fn dup(s: []const u8) ![*:0]u8 {
    return (try testing.allocator.dupeZ(u8, s)).ptr;
}

fn release(s: [*:0]u8) void {
    testing.allocator.free(std.mem.span(s));
}

fn expectPop(q: *StoredQueue, expected: []const u8) !void {
    const s = q.pop() orelse return error.TestExpectedEntry;
    defer release(s);
    try testing.expectEqualStrings(expected, std.mem.span(s));
}

test "pops oldest first, across the wrap of the ring" {
    var q: StoredQueue = .{};
    // Move head past the start so the next pushes wrap.
    for (0..capacity - 2) |_| try testing.expectEqual(Push.stored, q.push(try dup("old"), false));
    for (0..capacity - 2) |_| try expectPop(&q, "old");

    try testing.expectEqual(Push.stored, q.push(try dup("a"), false));
    try testing.expectEqual(Push.stored, q.push(try dup("b"), false));
    try testing.expectEqual(Push.stored, q.push(try dup("c"), false));

    try expectPop(&q, "a");
    try expectPop(&q, "b");
    try expectPop(&q, "c");
    try testing.expectEqual(@as(?[*:0]u8, null), q.pop());
}

test "a full queue refuses the newest entry and keeps the oldest" {
    var q: StoredQueue = .{};
    try testing.expectEqual(Push.stored, q.push(try dup("launch"), false));
    for (1..capacity) |_| try testing.expectEqual(Push.stored, q.push(try dup("later"), false));

    const refused = try dup("overflow");
    try testing.expectEqual(Push.full, q.push(refused, false));
    release(refused);

    try expectPop(&q, "launch");
    for (1..capacity) |_| try expectPop(&q, "later");
    try testing.expectEqual(@as(?[*:0]u8, null), q.pop());
}

test "unless_queued refuses an entry equal to one waiting, and only then" {
    var q: StoredQueue = .{};
    try testing.expectEqual(Push.stored, q.push(try dup("tap"), true));

    const again = try dup("tap");
    try testing.expectEqual(Push.already_queued, q.push(again, true));
    release(again);

    try testing.expectEqual(Push.stored, q.push(try dup("tap"), false));
    try testing.expectEqual(Push.stored, q.push(try dup("other"), true));

    try expectPop(&q, "tap");
    try expectPop(&q, "tap");
    try expectPop(&q, "other");
}

test "takeAll empties the queue, oldest first, and the queue keeps working" {
    var q: StoredQueue = .{};
    try testing.expectEqual(Push.stored, q.push(try dup("w"), false));
    try expectPop(&q, "w");
    try testing.expectEqual(Push.stored, q.push(try dup("x"), false));
    try testing.expectEqual(Push.stored, q.push(try dup("y"), false));

    var out: [capacity][*:0]u8 = undefined;
    const taken = q.takeAll(&out);
    try testing.expectEqual(@as(usize, 2), taken.len);
    try testing.expectEqualStrings("x", std.mem.span(taken[0]));
    try testing.expectEqualStrings("y", std.mem.span(taken[1]));
    for (taken) |s| release(s);

    try testing.expectEqual(@as(?[*:0]u8, null), q.pop());
    try testing.expectEqual(Push.stored, q.push(try dup("z"), false));
    try expectPop(&q, "z");
}

test "two queues are independent" {
    var notifications: StoredQueue = .{};
    var links: StoredQueue = .{};
    try testing.expectEqual(Push.stored, notifications.push(try dup("{\"id\":\"n1\"}"), false));
    try testing.expectEqual(Push.stored, links.push(try dup("myapp://x"), false));

    try expectPop(&links, "myapp://x");
    try testing.expectEqual(@as(?[*:0]u8, null), links.pop());
    try expectPop(&notifications, "{\"id\":\"n1\"}");
}
