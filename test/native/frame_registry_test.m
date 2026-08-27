// Frame-registry semantics check (MOB-102 / MOB-103).
//
//     make -C test/native run
//
// There is no XCTest target in this repo and `ios/mob_nif.m` can't be compiled
// on the host (it needs UIKit and the swiftc-generated MobApp-Swift.h), so the
// registry functions are reproduced here verbatim from the "Element frame
// registry" section of ios/mob_nif.m. That makes this a check of the ALGORITHM
// — ownership, generation gating, purge, and the MOB-102 non-regression case —
// not of the shipped binary. Keep the copies in sync; they're small and change
// rarely, and a drift shows up as an assertion that no longer describes the
// real code.
//
// It does NOT cover the SwiftUI half, which is where the real risk lives:
// whether .onDisappear actually fires for a LazyVStack row leaving the render
// window or a TabView tab switching away, and whether onChange(initial:)
// re-fires on reappearance. Those need a device or simulator — see
// decisions/2026-08-27-frame-registry-liveness.md.
#import <Foundation/Foundation.h>

static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *g_element_frames = nil;
static NSMutableDictionary<NSString *, NSNumber *> *g_element_frame_seqs = nil;
static uint64_t g_frame_write_seq = 0;
static NSSet<NSString *> *g_live_frame_ids = nil;
static uint64_t g_frame_generation = 1;
static dispatch_once_t g_element_frames_once;

static NSMutableDictionary *mob_frame_registry(void) {
    dispatch_once(&g_element_frames_once, ^{
      g_element_frames = [NSMutableDictionary dictionary];
      g_element_frame_seqs = [NSMutableDictionary dictionary];
    });
    return g_element_frames;
}

static uint64_t mob_frame_generation(void) {
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        return g_frame_generation;
    }
}

static void mob_bump_frame_generation(void) {
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        g_frame_generation++;
    }
}

static uint64_t mob_register_frame(const char *id, uint64_t generation, double x, double y,
                                   double w, double h) {
    if (!id)
        return 0;
    NSString *key = [NSString stringWithUTF8String:id];
    if (!key)
        return 0;
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        if (generation && generation < g_frame_generation)
            return 0;
        if (g_live_frame_ids && ![g_live_frame_ids containsObject:key])
            return 0;

        reg[key] = @[ @(x), @(y), @(w), @(h) ];
        uint64_t seq = ++g_frame_write_seq;
        g_element_frame_seqs[key] = @(seq);
        return seq;
    }
}

static void mob_unregister_frame(const char *id, uint64_t seq) {
    if (!id || seq == 0)
        return;
    NSString *key = [NSString stringWithUTF8String:id];
    if (!key)
        return;
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        NSNumber *owner = g_element_frame_seqs[key];
        if (!owner || owner.unsignedLongLongValue != seq)
            return;
        [reg removeObjectForKey:key];
        [g_element_frame_seqs removeObjectForKey:key];
    }
}

static void mob_adopt_frame_ids(NSSet<NSString *> *liveIds) {
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        NSMutableArray<NSString *> *stale = [NSMutableArray array];
        for (NSString *key in reg)
            if (![liveIds containsObject:key])
                [stale addObject:key];
        [reg removeObjectsForKeys:stale];
        [g_element_frame_seqs removeObjectsForKeys:stale];
        g_live_frame_ids = [liveIds copy];
    }
}

// ── harness ──────────────────────────────────────────────────────────────────

static int g_failures = 0;

static void check(BOOL cond, const char *what) {
    printf("%s  %s\n", cond ? " ok " : "FAIL", what);
    if (!cond)
        g_failures++;
}

static BOOL present(const char *id) {
    return mob_frame_registry()[[NSString stringWithUTF8String:id]] != nil;
}

static double yOf(const char *id) {
    NSArray *f = mob_frame_registry()[[NSString stringWithUTF8String:id]];
    return f ? [f[1] doubleValue] : -1;
}

static void reset(void) {
    [mob_frame_registry() removeAllObjects];
    [g_element_frame_seqs removeAllObjects];
    g_live_frame_ids = nil;
    g_frame_generation = 1;
}

int main(void) {
    @autoreleasepool {
        uint64_t g = mob_frame_generation();

        // 1. A row that scrolls out of range drops its own entry.
        reset();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"row_3" ]]);
        uint64_t s = mob_register_frame("row_3", g, 0, 300, 393, 56);
        check(s != 0, "register returns a non-zero seq");
        check(present("row_3"), "registered row is present");
        mob_unregister_frame("row_3", s);
        check(!present("row_3"), "MOB-103: offscreen lazy row is dropped on disappear");

        // 2. An outgoing screen must not delete an entry the incoming screen
        //    just claimed under the same :id.
        reset();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"save" ]]);
        uint64_t outgoing = mob_register_frame("save", g, 24, 720, 327, 48);
        uint64_t incoming = mob_register_frame("save", g, 24, 640, 327, 48);
        check(outgoing != incoming, "second write gets a distinct seq");
        mob_unregister_frame("save", outgoing);
        check(present("save"), "MOB-103: stale owner's disappear does NOT delete the new entry");
        check(yOf("save") == 640.0, "the incoming screen's frame is the one retained");
        mob_unregister_frame("save", incoming);
        check(!present("save"), "the current owner CAN delete its own entry");

        // 3. A screen animating out after the purge can't re-register itself.
        reset();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"screen_a_btn" ]]);
        mob_register_frame("screen_a_btn", g, 10, 10, 100, 40);
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"screen_b_btn" ]]);  // nav push
        check(!present("screen_a_btn"), "outgoing screen's id purged by adopt");
        check(mob_register_frame("screen_a_btn", g, -393, 10, 100, 40) == 0,
              "MOB-103: mid-animation re-register from a dead id is rejected");
        check(!present("screen_a_btn"), "...and leaves no stale offscreen entry");

        // 4. The shared-:id nav case — the one tree membership alone can't
        //    reject, because the id IS in the new tree. The outgoing screen's
        //    generation is superseded, so its slide-out writes are refused and
        //    its .onDisappear (seq 0) is a no-op.
        reset();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"save" ]]);
        uint64_t oldGen = mob_frame_generation();
        mob_register_frame("save", oldGen, 24, 720, 327, 48);
        mob_bump_frame_generation();  // nav push: non-"none" transition
        uint64_t newGen = mob_frame_generation();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"save" ]]);  // still present
        uint64_t incomingSeq = mob_register_frame("save", newGen, 24, 640, 327, 48);
        check(incomingSeq != 0, "incoming screen registers under the new generation");
        uint64_t lateSeq = mob_register_frame("save", oldGen, -393, 720, 327, 48);
        check(lateSeq == 0, "MOB-103: outgoing screen's slide-out write is refused (shared id)");
        check(yOf("save") == 640.0, "the incoming screen's frame survives the animation");
        mob_unregister_frame("save", lateSeq);  // lateSeq == 0 → no-op
        check(present("save"), "MOB-103: refused write leaves seq 0, so disappear can't delete");

        // 5. MOB-102 must not regress: a static, unmoved element survives an
        //    unrelated re-render without re-registering. An ordinary re-render
        //    is transition "none", so the generation does NOT move.
        reset();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"static", @"sibling" ]]);
        uint64_t sg = mob_frame_generation();
        mob_register_frame("static", sg, 5, 5, 50, 20);
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"static", @"sibling" ]]);
        check(present("static"), "MOB-102 preserved: unmoved element survives a re-render");
        check(mob_register_frame("static", sg, 5, 5, 50, 20) != 0,
              "MOB-102 preserved: a survivor's later writes are still accepted");

        // 6. List delete: index-keyed ForEach shifts ids under trackers, so the
        //    tracker that inherits an id re-registers it (onChange(of: id)).
        //    The departing tracker's disappear must not win.
        reset();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"a", @"b" ]]);
        uint64_t lg = mob_frame_generation();
        mob_register_frame("a", lg, 0, 50, 393, 50);
        uint64_t bSeq = mob_register_frame("b", lg, 0, 100, 393, 50);
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"b" ]]);  // "a" deleted
        uint64_t bReclaimed = mob_register_frame("b", lg, 0, 50, 393, 50);  // idx0 takes over "b"
        mob_unregister_frame("b", bSeq);  // idx1 tears down with its old seq
        check(present("b"), "MOB-103: surviving element keeps its entry after a list delete");
        check(yOf("b") == 50.0, "...at its NEW position, not the previous occupant's");
        check(bReclaimed != bSeq, "the re-registration took ownership");

        // 7. Purge clears the seq side table too.
        reset();
        mob_adopt_frame_ids([NSSet setWithArray:@[ @"tmp" ]]);
        mob_register_frame("tmp", mob_frame_generation(), 1, 1, 1, 1);
        mob_adopt_frame_ids([NSSet set]);
        check(g_element_frame_seqs[@"tmp"] == nil, "purge drops the seq side-table entry too");

        printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "ALL PASSED", g_failures,
               g_failures == 1 ? "" : "s");
        return g_failures ? 1 : 0;
    }
}
