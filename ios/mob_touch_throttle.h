// mob_touch_throttle.h — when an on_touch pointer's move is sent (MOB-518).
//
// Header-only and free of Foundation/UIKit so the native harness
// (test/native/touch_throttle_test.c) compiles and runs this exact code on the
// host. Included by mob_nif.m only. android/jni/touch_throttle.zig is the same
// rule for Android, and the two must agree; see
// decisions/2026-11-12-per-node-multi-pointer-on-touch.md.
#ifndef MOB_TOUCH_THROTTLE_H
#define MOB_TOUCH_THROTTLE_H

#include <math.h>
#include <stdint.h>

// One pointer's move rule and the last event it sent. throttle_ms < 0 turns
// moves off.
typedef struct {
    int throttle_ms;
    double delta;
    int64_t last_ts;
    double last_x;
    double last_y;
} MobTouchGate;

static inline MobTouchGate mob_touch_gate_init(int throttle_ms, double delta, int64_t ts, double x,
                                               double y) {
    MobTouchGate gate = {throttle_ms, delta, ts, x, y};
    return gate;
}

// 1 when a move to (x, y) at ts is sent: moves are on, at least throttle_ms
// have passed since this pointer's last sent event, and it has travelled at
// least delta (|dx| + |dy|) since then. A sent move becomes the new reference
// point; a dropped one doesn't, so slow steady motion still adds up to a move.
static inline int mob_touch_move_due(MobTouchGate *gate, int64_t ts, double x, double y) {
    if (gate->throttle_ms < 0)
        return 0;
    if (ts - gate->last_ts < gate->throttle_ms)
        return 0;
    if (fabs(x - gate->last_x) + fabs(y - gate->last_y) < gate->delta)
        return 0;
    gate->last_ts = ts;
    gate->last_x = x;
    gate->last_y = y;
    return 1;
}

#endif
