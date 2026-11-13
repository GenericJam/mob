// on_touch move gating on iOS (MOB-518).
//
//     make -C test/native run
//
// Compiles ios/mob_touch_throttle.h itself, the rule mob_nif.m applies to each
// pointer's moves. The same cases run against android/jni/touch_throttle.zig
// under `zig test`, so the two platforms can't drift apart unnoticed. It does
// not cover how mob_nif.m feeds it (the pointer object, the send); that needs a
// device. See decisions/2026-11-12-per-node-multi-pointer-on-touch.md.
#include "../../ios/mob_touch_throttle.h"

#include <stdio.h>

static int failures = 0;

#define CHECK(cond, ...)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                   \
            fprintf(stderr, __VA_ARGS__);                                                          \
            fprintf(stderr, "\n");                                                                 \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

int main(void) {
    MobTouchGate g;

    g = mob_touch_gate_init(-1, 0, 0, 0, 0);
    CHECK(!mob_touch_move_due(&g, 1000, 500, 500), "moves off: nothing is ever due");

    g = mob_touch_gate_init(16, 1, 100, 10, 10);
    CHECK(!mob_touch_move_due(&g, 115, 30, 10), "move inside the throttle window is dropped");
    CHECK(mob_touch_move_due(&g, 116, 30, 10), "same move after the window is sent");

    g = mob_touch_gate_init(16, 4, 0, 10, 10);
    CHECK(!mob_touch_move_due(&g, 10000, 12, 11), "move under delta is dropped however late");

    g = mob_touch_gate_init(0, 4, 0, 10, 10);
    CHECK(mob_touch_move_due(&g, 1, 12, 12), "delta is |dx| + |dy|, not either axis alone");

    g = mob_touch_gate_init(0, 5, 0, 0, 0);
    CHECK(!mob_touch_move_due(&g, 1, 2, 0), "2 of 5 dp: dropped");
    CHECK(!mob_touch_move_due(&g, 2, 4, 0), "4 of 5 dp from the reference: dropped");
    CHECK(mob_touch_move_due(&g, 3, 6, 0), "dropped moves keep the reference, so 6 dp is sent");
    CHECK(!mob_touch_move_due(&g, 4, 8, 0), "the sent move is the new reference");

    g = mob_touch_gate_init(0, 0, 0, 1, 1);
    CHECK(mob_touch_move_due(&g, 0, 1, 1), "throttle 0 / delta 0 send every move");
    CHECK(mob_touch_move_due(&g, 0, 1, 1), "including a repeat of the position");

    g = mob_touch_gate_init(50, 0, 1000, 0, 0);
    CHECK(!mob_touch_move_due(&g, 1049, 9, 9), "throttle counts from the down");
    CHECK(mob_touch_move_due(&g, 1050, 9, 9), "first move at exactly throttle_ms is sent");
    CHECK(!mob_touch_move_due(&g, 1099, 20, 20), "then from the last sent move");
    CHECK(mob_touch_move_due(&g, 1100, 20, 20), "and again at throttle_ms after it");

    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("touch_throttle_test: all passed\n");
    return 0;
}
