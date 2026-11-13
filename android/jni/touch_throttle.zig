//! on_touch move gating (MOB-518), kept free of erts/JNI so `zig test` can run
//! it on the host. ios/mob_touch_throttle.h is the same rule for iOS; the two
//! must agree (decisions/2026-11-12-per-node-multi-pointer-on-touch.md).

/// Per-pointer state: the move rule and the last event this pointer sent.
pub const State = struct {
    /// Negative: moves are off for this pointer.
    throttle_ms: i32,
    delta: f64,
    last_ts: i64,
    last_x: f64,
    last_y: f64,

    pub fn init(throttle_ms: i32, delta: f64, ts: i64, x: f64, y: f64) State {
        return .{ .throttle_ms = throttle_ms, .delta = delta, .last_ts = ts, .last_x = x, .last_y = y };
    }

    /// Whether a move to (x, y) at `ts` is sent. It is when moves are on, at
    /// least `throttle_ms` have passed since this pointer's last sent event,
    /// and it has travelled at least `delta` (|dx| + |dy|) since then. A sent
    /// move becomes the new reference point; a dropped one doesn't, so slow
    /// steady motion still adds up to a move.
    pub fn moveDue(self: *State, ts: i64, x: f64, y: f64) bool {
        if (self.throttle_ms < 0) return false;
        if (ts - self.last_ts < self.throttle_ms) return false;
        if (@abs(x - self.last_x) + @abs(y - self.last_y) < self.delta) return false;
        self.last_ts = ts;
        self.last_x = x;
        self.last_y = y;
        return true;
    }
};

const testing = @import("std").testing;

test "moves off: nothing is ever due" {
    var s = State.init(-1, 0, 0, 0, 0);
    try testing.expect(!s.moveDue(1000, 500, 500));
}

test "a move inside the throttle window is dropped, the same move after it is sent" {
    var s = State.init(16, 1, 100, 10, 10);
    try testing.expect(!s.moveDue(115, 30, 10));
    try testing.expect(s.moveDue(116, 30, 10));
}

test "a move under delta is dropped however late it comes" {
    var s = State.init(16, 4, 0, 10, 10);
    try testing.expect(!s.moveDue(10_000, 12, 11));
}

test "delta is the summed x and y distance, not either axis alone" {
    var s = State.init(0, 4, 0, 10, 10);
    try testing.expect(s.moveDue(1, 12, 12));
}

test "dropped moves don't reset the reference, so slow motion accumulates" {
    var s = State.init(0, 5, 0, 0, 0);
    try testing.expect(!s.moveDue(1, 2, 0));
    try testing.expect(!s.moveDue(2, 4, 0));
    try testing.expect(s.moveDue(3, 6, 0));
    // The sent move is the new reference: 6 → 8 is only 2.
    try testing.expect(!s.moveDue(4, 8, 0));
}

test "throttle 0 and delta 0 send every move, including a repeat of the position" {
    var s = State.init(0, 0, 0, 1, 1);
    try testing.expect(s.moveDue(0, 1, 1));
    try testing.expect(s.moveDue(0, 1, 1));
}

test "the throttle counts from the last sent event, which starts as the down" {
    var s = State.init(50, 0, 1000, 0, 0);
    try testing.expect(!s.moveDue(1049, 9, 9));
    try testing.expect(s.moveDue(1050, 9, 9));
    try testing.expect(!s.moveDue(1099, 20, 20));
    try testing.expect(s.moveDue(1100, 20, 20));
}
