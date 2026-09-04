// mob_nif.m — Mob UI NIF for iOS (SwiftUI, JSON backend).
//
// NIF functions (matches mob_nif.erl):
//   platform/0         — returns :ios
//   log/1, log/2       — NSLog
//   set_transition/1   — stores transition atom for next set_root call
//   set_root/1         — accepts JSON binary, parses to MobNode tree, pushes to MobViewModel
//   register_tap/1     — register pid (or {pid,tag}), returns integer handle
//   clear_taps/0       — clear tap registry before each render

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <netdb.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdatomic.h>
#include <sys/socket.h>
// dlopen/dlsym are marked unavailable in iOS SDK headers but exist at runtime
// in the iOS Simulator (macOS). Declare prototypes directly to bypass the header
// restriction. On a real device these will be NULL (weak symbols).
#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void *)-2L)
#define RTLD_LAZY 1
#endif
extern void *dlopen(const char *path, int mode) __attribute__((weak));
extern void *dlsym(void *handle, const char *symbol) __attribute__((weak));
extern char *dlerror(void) __attribute__((weak));
#import "MobApp-Swift.h"
#import "MobNode.h"
// The prototypes Swift sees for every mob_* bridge function. Imported here so
// the compiler diagnoses a definition drifting from its declaration — C has no
// name mangling, so without this a changed signature links fine and Swift reads
// whatever happens to be in the return register.
#import "MobDemo-Bridging-Header.h"
#include "erl_nif.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMotion/CoreMotion.h>
#import <Network/Network.h>
#import <Photos/Photos.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <UserNotifications/UserNotifications.h>
#include <string.h>

#define LOGI(...) NSLog(@"[MobNIF] " __VA_ARGS__)
#define LOGE(...) NSLog(@"[MobNIF][ERROR] " __VA_ARGS__)
#if DEBUG
#define LOGD(...) NSLog(@"[MobNIF][DEBUG] " __VA_ARGS__)
#else
#define LOGD(...)
#endif

// ── Startup status (declared in mob_beam.h, called from mob_beam.m) ───────────
// Implemented here rather than in mob_beam.m because this file is compiled with
// -I $BUILD_DIR so it can import the Swift-generated MobApp-Swift.h header.

void mob_set_startup_phase(const char *phase) {
    NSLog(@"[MobBeam] startup: %s", phase);
    [MobViewModel.shared setStartupPhase:[NSString stringWithUTF8String:phase]];
}

void mob_set_startup_error(const char *error) {
    NSLog(@"[MobBeam] ERROR: %s", error);
    [MobViewModel.shared setStartupError:[NSString stringWithUTF8String:error]];
}

// ── Tap handle registry ───────────────────────────────────────────────────────
// Cleared before every render.
//
// The tables GROW ON DEMAND rather than being a fixed array. They used to be
// 256 entries, and a 200-row list overran that: every interactive element past
// the cap got the -1 "no handler" sentinel and silently stopped responding —
// 359 of 615 on the screen that surfaced this. A fixed array big enough for
// that case would be ~700 KB resident in every app, nearly all of which
// register a few dozen handles, so it is allocated to fit instead.
//
// MOB_TAP_SLOT_LIMIT is the ceiling the handle encoding can address (12 slot
// bits), not a target. Beyond it the sentinel path still applies and set_root
// still reports the count once per frame.
#define MOB_TAP_SLOT_LIMIT 4096
#define MOB_TAP_INITIAL_CAPACITY 256
#define MAX_EVENT_GENERATION 0x7ffffU

typedef struct {
    ErlNifPid pid;
    ErlNifEnv *tag_env; // persistent env owning tag; NULL when slot is free
    ERL_NIF_TERM tag;
    // First generation in the current consecutive run of identical PID/tag
    // registrations at this slot. Identity events can safely outlive the two
    // physical tables while their route remains unchanged.
    uint32_t identity_start_generation;

    // ── Batch 5 throttle state — populated by mob_set_throttle_config ──
    // Set once the app has actually configured this slot. Without it, 0 is
    // ambiguous: `throttle: 0` is a documented escape hatch meaning "raw firing
    // rate", but a zeroed slot also means "never configured, use the default",
    // and the check cannot tell them apart. Mob.Event.Throttle documents
    // `throttle: 0` and has a doctest for it, so the one value a user reaches
    // for was the one value that could not be expressed.
    int throttle_configured;
    int throttle_ms; // 0 = no throttle (raw firing), when throttle_configured
    int debounce_ms; // 0 = no debounce
    double delta_threshold;
    int leading;           // 1 = emit first event of burst
    int trailing;          // 1 = emit final event after debounce
    uint64_t last_emit_ns; // mach_absolute_time of last successful emit
    double last_x;         // last emitted x (for delta check)
    double last_y;         // last emitted y
    uint64_t seq;          // monotonic counter per handle
} TapHandle;

// Double-buffered tap registry (see android/jni/mob_nif.zig for full rationale).
// `tap_handles`/`tap_handle_next` point at the ACTIVE table + its committed
// count — readers (mob_send_*) keep using them unchanged. A render builds into
// the INACTIVE table via register_tap (tap_build_count) and set_root swaps it in
// atomically under tap_mutex, so a concurrent high-frequency send (drag/scroll)
// never observes a half-rebuilt table.
static TapHandle *tap_tables[2] = {NULL, NULL};
static int tap_table_capacity[2] = {0, 0};
static int tap_active = 0;
static TapHandle *tap_handles = NULL; // active table (readers use this)
static int tap_handle_next = 0;       // active committed count (readers' bound)
static int tap_build_count = 0;       // cursor into the building table
static uint32_t tap_table_generations[2] = {0, 0};
// How many slots of each table were actually written, so clear_taps only walks
// those. Walking the whole table every frame is wasted work at any cap and
// would scale with the cap if it were ever raised.
static int tap_table_used[2] = {0, 0};
// Exhausted registrations in the frame being built. Counted rather than logged
// per call: a dense screen overflows the pool hundreds of times per frame, and
// NSLog is a synchronous write to the system log.
static int tap_exhausted_count = 0;
static uint32_t tap_build_generation = 0;
static ErlNifMutex *tap_mutex = NULL;

static uint32_t mob_next_handle_generation(uint32_t generation) {
    return generation == 0 || generation >= MAX_EVENT_GENERATION ? 1 : generation + 1;
}

static uint32_t mob_generation_age(uint32_t active_generation, uint32_t prior_generation) {
    return active_generation >= prior_generation
               ? active_generation - prior_generation
               : MAX_EVENT_GENERATION - prior_generation + active_generation;
}

static int mob_generation_within_identity(uint32_t handle_generation,
                                          uint32_t identity_start_generation,
                                          uint32_t active_generation) {
    if (handle_generation == 0 || handle_generation > MAX_EVENT_GENERATION ||
        identity_start_generation == 0 || identity_start_generation > MAX_EVENT_GENERATION ||
        active_generation == 0 || active_generation > MAX_EVENT_GENERATION)
        return 0;
    return mob_generation_age(active_generation, handle_generation) <=
           mob_generation_age(active_generation, identity_start_generation);
}

// Grow one table to hold at least `needed` slots. Caller holds tap_mutex, which
// is what makes this safe: every reader of tap_handles resolves under the same
// lock, so no one can be holding a pointer into a table while it moves.
//
// Only the table being built is ever grown mid-frame; the active table is left
// alone until the swap in set_root repoints tap_handles at it.
static int mob_tap_grow_locked(int which, int needed) {
    if (needed <= tap_table_capacity[which])
        return 1;
    if (needed > MOB_TAP_SLOT_LIMIT)
        return 0;

    int cap = tap_table_capacity[which] ? tap_table_capacity[which] : MOB_TAP_INITIAL_CAPACITY;
    while (cap < needed)
        cap *= 2;
    if (cap > MOB_TAP_SLOT_LIMIT)
        cap = MOB_TAP_SLOT_LIMIT;

    TapHandle *grown = realloc(tap_tables[which], (size_t)cap * sizeof(TapHandle));
    if (!grown)
        return 0;
    // Zero the new tail: clear_taps and the resolvers both key off tag_env
    // being NULL to decide a slot is free, and realloc leaves it uninitialised.
    memset(grown + tap_table_capacity[which], 0,
           (size_t)(cap - tap_table_capacity[which]) * sizeof(TapHandle));

    // …then restore the two fields whose "unset" value is 1, not 0. clear_taps
    // resets leading/trailing to 1 for reused slots, so without this a slot's
    // default would depend on whether it arrived by growth or by reuse. Nobody
    // re-derives that when these finally get a reader.
    for (int i = tap_table_capacity[which]; i < cap; i++) {
        grown[i].leading = 1;
        grown[i].trailing = 1;
    }

    tap_tables[which] = grown;
    tap_table_capacity[which] = cap;
    if (which == tap_active)
        tap_handles = grown;
    return 1;
}

static int mob_encode_event_handle(uint32_t generation, int slot) {
    if (generation == 0 || generation > MAX_EVENT_GENERATION || slot < 0 ||
        slot >= MOB_TAP_SLOT_LIMIT)
        return -1;
    return (int)((generation << 12) | (uint32_t)slot);
}

static int mob_decode_event_handle(int handle, uint32_t *generation, int *slot) {
    if (handle <= 0)
        return 0;
    uint32_t raw = (uint32_t)handle;
    *generation = raw >> 12;
    *slot = (int)(raw & 0xfffU);
    return *generation != 0;
}

typedef struct {
    ErlNifPid pid;
    ERL_NIF_TERM tag;
    uint64_t seq;
} TapSnap;

static TapHandle *mob_resolve_active_tap_locked(int handle) {
    uint32_t generation;
    int slot;
    if (!mob_decode_event_handle(handle, &generation, &slot) ||
        generation != tap_table_generations[tap_active] || slot >= tap_handle_next ||
        !tap_handles[slot].tag_env)
        return NULL;
    return &tap_handles[slot];
}

// Resolve a handle against the table currently being BUILT, not the active one.
//
// Needed because throttle config arrives during deserialisation. set_root walks
// the JSON — populating the building table's config as it goes — and only swaps
// that table in ~50 lines later. The handles in that JSON therefore carry
// tap_build_generation, while mob_resolve_active_tap_locked compares against
// tap_table_generations[tap_active], which is still the PREVIOUS frame's
// generation (nif_clear_taps zeroed the building slot's). Every lookup returned
// NULL and every `if (tap)` body was skipped, silently, on every frame — so an
// app's throttle/debounce settings never reached a live slot and only the
// built-in defaults ever applied (MOB-134).
static TapHandle *mob_resolve_build_tap_locked(int handle) {
    uint32_t generation;
    int slot;
    TapHandle *build = tap_tables[1 - tap_active];
    if (!build || !mob_decode_event_handle(handle, &generation, &slot) ||
        generation != tap_build_generation || slot >= tap_build_count || !build[slot].tag_env)
        return NULL;
    return &build[slot];
}

static int mob_snap_tap(int handle, ErlNifEnv *msg_env, TapSnap *snap) {
    enif_mutex_lock(tap_mutex);
    TapHandle *active = mob_resolve_active_tap_locked(handle);
    if (!active) {
        enif_mutex_unlock(tap_mutex);
        LOGD(@"rejected stale event handle %d", handle);
        return 0;
    }
    snap->pid = active->pid;
    snap->tag = enif_make_copy(msg_env, active->tag);
    snap->seq = active->seq;
    enif_mutex_unlock(tap_mutex);
    return 1;
}

static int mob_snap_change_tap(int handle, ErlNifEnv *msg_env, TapSnap *snap) {
    enif_mutex_lock(tap_mutex);
    TapHandle *active = mob_resolve_active_tap_locked(handle);
    if (!active) {
        uint32_t generation;
        int slot;
        if (!mob_decode_event_handle(handle, &generation, &slot)) {
            enif_mutex_unlock(tap_mutex);
            LOGD(@"rejected stale event handle %d", handle);
            return 0;
        }
        active = slot >= 0 && slot < tap_handle_next ? &tap_handles[slot] : NULL;
        if (!active || !active->tag_env ||
            !mob_generation_within_identity(generation, active->identity_start_generation,
                                            tap_table_generations[tap_active])) {
            enif_mutex_unlock(tap_mutex);
            LOGD(@"rejected stale event handle %d", handle);
            return 0;
        }
    }
    snap->pid = active->pid;
    snap->tag = enif_make_copy(msg_env, active->tag);
    snap->seq = active->seq;
    enif_mutex_unlock(tap_mutex);
    return 1;
}

// Convert mach absolute time to nanoseconds (initialised once).
static mach_timebase_info_data_t g_timebase = {0, 0};
static uint64_t mob_now_ns(void) {
    if (g_timebase.denom == 0)
        mach_timebase_info(&g_timebase);
    return mach_absolute_time() * g_timebase.numer / g_timebase.denom;
}

// Set throttle config for a handle. Called from the prop deserialiser when
// it sees a *_config sibling prop. Idempotent — safe to call multiple times.
static void mob_set_throttle_config(int handle, int throttle_ms, int debounce_ms,
                                    double delta_threshold, int leading, int trailing) {
    enif_mutex_lock(tap_mutex);
    // Building table first: the only caller is the set_root prop deserialiser,
    // which runs before the swap. The active-table fallback keeps any future
    // caller outside a build working.
    TapHandle *tap = mob_resolve_build_tap_locked(handle);
    if (!tap)
        tap = mob_resolve_active_tap_locked(handle);
    if (tap) {
        tap->throttle_configured = 1;
        tap->throttle_ms = throttle_ms;
        tap->debounce_ms = debounce_ms;
        tap->delta_threshold = delta_threshold;
        tap->leading = leading;
        tap->trailing = trailing;
    }
    enif_mutex_unlock(tap_mutex);
}

// Apply throttle/delta gating. Returns 1 if the event should fire, 0 if
// it should be dropped. Updates per-handle state on accept.
//
// Defaults (when throttle/delta unset on a handle): use reasonable per-event
// fallbacks so widgets that opt in without explicit config still get sane
// gating.
static int mob_throttle_check(int handle, double x, double y, int default_throttle_ms,
                              double default_delta) {
    enif_mutex_lock(tap_mutex);
    TapHandle *h = mob_resolve_active_tap_locked(handle);
    if (!h) {
        enif_mutex_unlock(tap_mutex);
        return 0;
    }

    // An unconfigured slot takes the built-in default; a configured one takes
    // what the app asked for, including 0 (raw) for either field.
    int throttle_ms = h->throttle_configured ? h->throttle_ms : default_throttle_ms;
    double delta_threshold = h->throttle_configured ? h->delta_threshold : default_delta;

    uint64_t now_ns = mob_now_ns();
    double dx = x - h->last_x;
    double dy = y - h->last_y;
    double dist = (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy); // L1 norm

    // Time gate
    if (h->last_emit_ns > 0 && throttle_ms > 0) {
        uint64_t elapsed_ms = (now_ns - h->last_emit_ns) / 1000000ULL;
        if ((int)elapsed_ms < throttle_ms) {
            enif_mutex_unlock(tap_mutex);
            return 0;
        }
    }

    // Delta gate
    if (h->last_emit_ns > 0 && dist < delta_threshold) {
        enif_mutex_unlock(tap_mutex);
        return 0;
    }

    h->last_emit_ns = now_ns;
    h->last_x = x;
    h->last_y = y;
    h->seq++;
    enif_mutex_unlock(tap_mutex);
    return 1;
}

// Read current seq + ts for a handle (for envelope construction).
static void mob_handle_meta(int handle, uint64_t *seq_out, uint64_t *ts_out) {
    enif_mutex_lock(tap_mutex);
    TapHandle *tap = mob_resolve_active_tap_locked(handle);
    if (tap) {
        *seq_out = tap->seq;
        *ts_out = mob_now_ns() / 1000000ULL; // ms since boot
    } else {
        *seq_out = 0;
        *ts_out = 0;
    }
    enif_mutex_unlock(tap_mutex);
}
static char g_transition[16] = "none";

// ── UI-event observation counter (test-harness honesty) ──────────────────────
//
// Every user-originated event we hand to the BEAM bumps this counter. The
// synthetic-input NIFs sample it before and after injecting a touch so they can
// answer "did the app actually react?" instead of "did the injection API not
// return an error?". Without it tap_xy reports :ok whenever the private input
// API accepts the event — which on a physical device is always, even when the
// touch lands on nothing and no handler runs.
//
// Bumped from the send helpers rather than from the SwiftUI callbacks so it
// covers every route into the BEAM (tap, focus, blur, submit, select, change).
static _Atomic uint64_t g_ui_event_seq;

#if !MOB_RELEASE // only the harness reads it; the writers stay unconditional
static uint64_t mob_ui_event_seq(void) {
    return atomic_load_explicit(&g_ui_event_seq, memory_order_relaxed);
}
#endif

static void mob_note_ui_event(void) {
    atomic_fetch_add_explicit(&g_ui_event_seq, 1, memory_order_relaxed);
}

// Called from node onTap blocks — routes tap to BEAM via enif_send.
static void mob_send_tap(int handle) {
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    mob_note_ui_event();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, enif_make_atom(msg_env, "tap"), snap.tag);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

// ── Focus / blur / submit senders ────────────────────────────────────────────
// Called from MobTextField SwiftUI view when focus state changes or return key tapped.

static void mob_send_event(int handle, const char *atom) {
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    mob_note_ui_event();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, enif_make_atom(msg_env, atom), snap.tag);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_identity_event(int handle, const char *atom) {
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_change_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    mob_note_ui_event();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, enif_make_atom(msg_env, atom), snap.tag);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_focus(int handle) {
    mob_send_event(handle, "focus");
}
static void mob_send_blur(int handle) {
    mob_send_event(handle, "blur");
}
static void mob_send_submit(int handle) {
    mob_send_event(handle, "submit");
}
static void mob_send_select(int handle) {
    mob_send_event(handle, "select");
}
static void mob_send_dismiss(int handle) {
    mob_send_identity_event(handle, "dismiss");
}

// IME composition. Sends {compose, tag, %{text: ..., phase: ...}} where
// phase is one of began/updating/committed/cancelled. Called from the
// text-input layer when marked-text state changes.
static void mob_send_compose(int handle, const char *text, const char *phase) {
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    ERL_NIF_TERM keys[2] = {
        enif_make_atom(msg_env, "text"),
        enif_make_atom(msg_env, "phase"),
    };
    ERL_NIF_TERM vals[2] = {
        enif_make_string(msg_env, text ? text : "", ERL_NIF_LATIN1),
        enif_make_atom(msg_env, phase),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 2, &payload);
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "compose"), snap.tag, payload);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

// ── Gesture senders (Batch 4) ───────────────────────────────────────────────
// Each fires {atom, tag} just like tap. SwiftUI converts gesture recognizers
// into onLongPress/onDoubleTap/onSwipe* callbacks on the MobNode.

static void mob_send_long_press(int handle) {
    mob_send_event(handle, "long_press");
}
static void mob_send_double_tap(int handle) {
    mob_send_event(handle, "double_tap");
}
static void mob_send_swipe_left(int handle) {
    mob_send_event(handle, "swipe_left");
}
static void mob_send_swipe_right(int handle) {
    mob_send_event(handle, "swipe_right");
}
static void mob_send_swipe_up(int handle) {
    mob_send_event(handle, "swipe_up");
}
static void mob_send_swipe_down(int handle) {
    mob_send_event(handle, "swipe_down");
}

// Generic on_swipe with direction: emits {swipe, tag, direction} where direction is an atom.
static void mob_send_swipe_with_direction(int handle, const char *direction) {
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "swipe"), snap.tag,
                                        enif_make_atom(msg_env, direction));
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

// ── Batch 5 Tier 1: high-frequency scroll/drag/pinch/rotate senders ─────────
// Each respects the per-handle throttle config set via mob_set_throttle_config.
// The envelope follows the canonical Mob.Event shape but is constructed at
// the legacy {atom, tag, payload} level for now — the bridge will translate.
//
// Default throttle/delta when handle has no explicit config (matching
// Mob.Event.Throttle defaults):
//   :scroll       33 ms / 1 px
//   :drag         16 ms / 1 px
//   :pinch        16 ms / 0.01
//   :rotate       16 ms / 1 deg
//   :pointer_move 33 ms / 4 px

// Build a payload map: %{x, y, dx, dy, velocity_x, velocity_y, phase, ts, seq}
static ERL_NIF_TERM mob_build_scroll_payload(ErlNifEnv *env, double x, double y, double dx,
                                             double dy, double vx, double vy, const char *phase,
                                             uint64_t ts, uint64_t seq) {
    ERL_NIF_TERM keys[9] = {
        enif_make_atom(env, "x"),          enif_make_atom(env, "y"),
        enif_make_atom(env, "dx"),         enif_make_atom(env, "dy"),
        enif_make_atom(env, "velocity_x"), enif_make_atom(env, "velocity_y"),
        enif_make_atom(env, "phase"),      enif_make_atom(env, "ts"),
        enif_make_atom(env, "seq"),
    };
    ERL_NIF_TERM vals[9] = {
        enif_make_double(env, x),   enif_make_double(env, y),  enif_make_double(env, dx),
        enif_make_double(env, dy),  enif_make_double(env, vx), enif_make_double(env, vy),
        enif_make_atom(env, phase), enif_make_uint64(env, ts), enif_make_uint64(env, seq),
    };
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, 9, &map);
    return map;
}

// Send a throttled high-frequency event. Phase is one of:
//   "began" | "dragging" | "decelerating" | "ended"
static void mob_send_scroll(int handle, double x, double y, double dx, double dy, double vx,
                            double vy, const char *phase) {
    // Force-emit for began/ended phases regardless of throttle (semantic
    // boundaries are too important to drop).
    int is_phase_boundary = (strcmp(phase, "began") == 0) || (strcmp(phase, "ended") == 0);

    if (!is_phase_boundary && !mob_throttle_check(handle, x, y, 33, 1.0))
        return;

    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ERL_NIF_TERM payload =
        mob_build_scroll_payload(msg_env, x, y, dx, dy, vx, vy, phase, ts, snap.seq);
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "scroll"), snap.tag, payload);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_drag(int handle, double x, double y, double dx, double dy, const char *phase) {
    int is_phase_boundary = (strcmp(phase, "began") == 0) || (strcmp(phase, "ended") == 0);
    if (!is_phase_boundary && !mob_throttle_check(handle, x, y, 16, 1.0))
        return;

    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    uint64_t ts = mob_now_ns() / 1000000ULL;
    // Drag payload: %{x, y, dx, dy, phase, ts, seq}
    ERL_NIF_TERM keys[7] = {
        enif_make_atom(msg_env, "x"),     enif_make_atom(msg_env, "y"),
        enif_make_atom(msg_env, "dx"),    enif_make_atom(msg_env, "dy"),
        enif_make_atom(msg_env, "phase"), enif_make_atom(msg_env, "ts"),
        enif_make_atom(msg_env, "seq"),
    };
    ERL_NIF_TERM vals[7] = {
        enif_make_double(msg_env, x),        enif_make_double(msg_env, y),
        enif_make_double(msg_env, dx),       enif_make_double(msg_env, dy),
        enif_make_atom(msg_env, phase),      enif_make_uint64(msg_env, ts),
        enif_make_uint64(msg_env, snap.seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 7, &payload);
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "drag"), snap.tag, payload);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_pinch(int handle, double scale, double velocity, const char *phase) {
    int is_phase_boundary = (strcmp(phase, "began") == 0) || (strcmp(phase, "ended") == 0);
    if (!is_phase_boundary && !mob_throttle_check(handle, scale, 0, 16, 0.01))
        return;

    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ERL_NIF_TERM keys[5] = {
        enif_make_atom(msg_env, "scale"), enif_make_atom(msg_env, "velocity"),
        enif_make_atom(msg_env, "phase"), enif_make_atom(msg_env, "ts"),
        enif_make_atom(msg_env, "seq"),
    };
    ERL_NIF_TERM vals[5] = {
        enif_make_double(msg_env, scale),    enif_make_double(msg_env, velocity),
        enif_make_atom(msg_env, phase),      enif_make_uint64(msg_env, ts),
        enif_make_uint64(msg_env, snap.seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 5, &payload);
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "pinch"), snap.tag, payload);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_rotate(int handle, double degrees, double velocity, const char *phase) {
    int is_phase_boundary = (strcmp(phase, "began") == 0) || (strcmp(phase, "ended") == 0);
    if (!is_phase_boundary && !mob_throttle_check(handle, degrees, 0, 16, 1.0))
        return;

    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ERL_NIF_TERM keys[5] = {
        enif_make_atom(msg_env, "degrees"), enif_make_atom(msg_env, "velocity"),
        enif_make_atom(msg_env, "phase"),   enif_make_atom(msg_env, "ts"),
        enif_make_atom(msg_env, "seq"),
    };
    ERL_NIF_TERM vals[5] = {
        enif_make_double(msg_env, degrees),  enif_make_double(msg_env, velocity),
        enif_make_atom(msg_env, phase),      enif_make_uint64(msg_env, ts),
        enif_make_uint64(msg_env, snap.seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 5, &payload);
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "rotate"), snap.tag, payload);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_pointer_move(int handle, double x, double y) {
    if (!mob_throttle_check(handle, x, y, 33, 4.0))
        return;

    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ERL_NIF_TERM keys[4] = {
        enif_make_atom(msg_env, "x"),
        enif_make_atom(msg_env, "y"),
        enif_make_atom(msg_env, "ts"),
        enif_make_atom(msg_env, "seq"),
    };
    ERL_NIF_TERM vals[4] = {
        enif_make_double(msg_env, x),
        enif_make_double(msg_env, y),
        enif_make_uint64(msg_env, ts),
        enif_make_uint64(msg_env, snap.seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 4, &payload);
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "pointer_move"), snap.tag, payload);
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

// ── Batch 5 Tier 2 senders — semantic single-fire scroll events ─────────────
static void mob_send_scroll_began(int handle) {
    mob_send_event(handle, "scroll_began");
}
static void mob_send_scroll_ended(int handle) {
    mob_send_event(handle, "scroll_ended");
}
static void mob_send_scroll_settled(int handle) {
    mob_send_event(handle, "scroll_settled");
}
static void mob_send_top_reached(int handle) {
    mob_send_event(handle, "top_reached");
}
static void mob_send_scrolled_past(int handle) {
    mob_send_event(handle, "scrolled_past");
}

// ── Back gesture sender ───────────────────────────────────────────────────────
// Called from MobHostingController when the left-edge-pan gesture fires.
// Looks up the :mob_screen registered process and sends {:mob, :back}.
// Non-static so Swift can call it via the bridging header.

void mob_handle_back(void) {
    ErlNifEnv *env = enif_alloc_env();
    ErlNifPid pid;
    if (enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
        ERL_NIF_TERM msg =
            enif_make_tuple2(env, enif_make_atom(env, "mob"), enif_make_atom(env, "back"));
        enif_send(NULL, &pid, env, msg);
    }
    enif_free_env(env);
}

// ── Change senders ────────────────────────────────────────────────────────────
// Called from MobNode onChange blocks when an input widget fires.

static void mob_send_change(int handle, ERL_NIF_TERM value_term) {
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env)
        return;
    TapSnap snap;
    if (!mob_snap_change_tap(handle, msg_env, &snap)) {
        enif_free_env(msg_env);
        return;
    }

    mob_note_ui_event();
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "change"), snap.tag,
                                        enif_make_copy(msg_env, value_term));
    enif_send(NULL, &snap.pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_change_str(int handle, const char *utf8) {
    ErlNifEnv *tmp = enif_alloc_env();
    ErlNifBinary bin;
    size_t len = strlen(utf8);
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    ERL_NIF_TERM term = enif_make_binary(tmp, &bin);
    mob_send_change(handle, term);
    enif_free_env(tmp);
}

static void mob_send_change_bool(int handle, int bool_val) {
    ErlNifEnv *tmp = enif_alloc_env();
    ERL_NIF_TERM term = enif_make_atom(tmp, bool_val ? "true" : "false");
    mob_send_change(handle, term);
    enif_free_env(tmp);
}

static void mob_send_change_float(int handle, double value) {
    ErlNifEnv *tmp = enif_alloc_env();
    ERL_NIF_TERM term = enif_make_double(tmp, value);
    mob_send_change(handle, term);
    enif_free_env(tmp);
}

// ── JSON → MobNode parser ─────────────────────────────────────────────────────

static UIColor *color_from_argb(long argb) {
    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8) & 0xFF) / 255.0;
    CGFloat b = ((argb >> 0) & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

// ── Prop key dispatch ────────────────────────────────────────────────────────
// mob_node_from_dict used to probe every one of these keys into a node's
// `props` dictionary, for every node, regardless of node type: ~100 hashed
// lookups to retrieve the three to five props a typical node actually carries.
// Measured at 5.9ms of a 7.7ms set_root on a 1627-node tree — more than four
// times what parsing the whole JSON payload cost in the first place.
//
// Instead the node's own props are enumerated once, each key resolved to a
// slot, and the deserialiser reads slots. The statement order below is
// unchanged, so the three places where prop precedence depends on it (text
// before value for a text field, generic width/height before canvas, generic
// corner_radius before sheet) behave exactly as they did. That is the reason
// for an indexed array rather than a switch inside the enumeration.
typedef NS_ENUM(NSUInteger, MobPropKey) {
    MOB_PROP_accessibility_id,
    MOB_PROP_accessibility_label,
    MOB_PROP_accessibility_role,
    MOB_PROP_active,
    MOB_PROP_align,
    MOB_PROP_allow,
    MOB_PROP_autoplay,
    MOB_PROP_axis,
    MOB_PROP_background,
    MOB_PROP_border_color,
    MOB_PROP_border_width,
    MOB_PROP_color,
    MOB_PROP_component_handle,
    MOB_PROP_content_mode,
    MOB_PROP_controls,
    MOB_PROP_corner_radius,
    MOB_PROP_detents,
    MOB_PROP_disabled,
    MOB_PROP_drag_indicator_color,
    MOB_PROP_drag_indicator_height,
    MOB_PROP_drag_indicator_rail_height,
    MOB_PROP_drag_indicator_width,
    MOB_PROP_draw,
    MOB_PROP_facing,
    MOB_PROP_fade_on_scroll,
    MOB_PROP_fill_height,
    MOB_PROP_fill_width,
    MOB_PROP_font,
    MOB_PROP_font_weight,
    MOB_PROP_glass,
    MOB_PROP_height,
    MOB_PROP_id,
    MOB_PROP_italic,
    MOB_PROP_lazy,
    MOB_PROP_keyboard,
    MOB_PROP_letter_spacing,
    MOB_PROP_line_height,
    MOB_PROP_loop,
    MOB_PROP_max,
    MOB_PROP_min,
    MOB_PROP_module,
    MOB_PROP_name,
    MOB_PROP_offset_x,
    MOB_PROP_offset_y,
    MOB_PROP_on_blur,
    MOB_PROP_on_change,
    MOB_PROP_on_compose,
    MOB_PROP_on_dismiss,
    MOB_PROP_on_double_tap,
    MOB_PROP_on_drag,
    MOB_PROP_on_end_reached,
    MOB_PROP_on_focus,
    MOB_PROP_on_long_press,
    MOB_PROP_on_pinch,
    MOB_PROP_on_pointer_move,
    MOB_PROP_on_rotate,
    MOB_PROP_on_scroll,
    MOB_PROP_on_scroll_began,
    MOB_PROP_on_scroll_ended,
    MOB_PROP_on_scroll_settled,
    MOB_PROP_on_scrolled_past,
    MOB_PROP_on_select,
    MOB_PROP_on_submit,
    MOB_PROP_on_swipe,
    MOB_PROP_on_swipe_down,
    MOB_PROP_on_swipe_left,
    MOB_PROP_on_swipe_right,
    MOB_PROP_on_swipe_up,
    MOB_PROP_on_tab_select,
    MOB_PROP_on_tap,
    MOB_PROP_on_top_reached,
    MOB_PROP_padding,
    MOB_PROP_padding_bottom,
    MOB_PROP_padding_left,
    MOB_PROP_padding_right,
    MOB_PROP_padding_top,
    MOB_PROP_parallax,
    MOB_PROP_placeholder,
    MOB_PROP_placeholder_color,
    MOB_PROP_return_key,
    MOB_PROP_scrolled_past_threshold,
    MOB_PROP_secure,
    MOB_PROP_shader,
    MOB_PROP_show_indicator,
    MOB_PROP_show_url,
    MOB_PROP_size,
    MOB_PROP_src,
    MOB_PROP_sticky_when_scrolled_past,
    MOB_PROP_tabs,
    MOB_PROP_text,
    MOB_PROP_text_align,
    MOB_PROP_text_color,
    MOB_PROP_text_size,
    MOB_PROP_thickness,
    MOB_PROP_title,
    MOB_PROP_uniforms,
    MOB_PROP_url,
    MOB_PROP_value,
    MOB_PROP_weight,
    MOB_PROP_width,
    MOB_PROP__COUNT
};

static NSDictionary<NSString *, NSNumber *> *mob_prop_slots(void) {
    static NSDictionary<NSString *, NSNumber *> *slots = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      // Designated initializers: each entry names the slot it fills, so the
      // enum and this table cannot drift apart. They are two independently
      // ordered lists of 99 strings joined by index — insert a key mid-enum and
      // append it here, the natural mistake when the two are a hundred lines
      // apart, and every slot after the insertion point reads a different
      // prop's value on every node. This makes that unrepresentable.
      NSString *const names[MOB_PROP__COUNT] = {
          [MOB_PROP_accessibility_id] = @"accessibility_id",
          [MOB_PROP_accessibility_label] = @"accessibility_label",
          [MOB_PROP_accessibility_role] = @"accessibility_role",
          [MOB_PROP_active] = @"active",
          [MOB_PROP_align] = @"align",
          [MOB_PROP_allow] = @"allow",
          [MOB_PROP_autoplay] = @"autoplay",
          [MOB_PROP_axis] = @"axis",
          [MOB_PROP_background] = @"background",
          [MOB_PROP_border_color] = @"border_color",
          [MOB_PROP_border_width] = @"border_width",
          [MOB_PROP_color] = @"color",
          [MOB_PROP_component_handle] = @"component_handle",
          [MOB_PROP_content_mode] = @"content_mode",
          [MOB_PROP_controls] = @"controls",
          [MOB_PROP_corner_radius] = @"corner_radius",
          [MOB_PROP_detents] = @"detents",
          [MOB_PROP_disabled] = @"disabled",
          [MOB_PROP_drag_indicator_color] = @"drag_indicator_color",
          [MOB_PROP_drag_indicator_height] = @"drag_indicator_height",
          [MOB_PROP_drag_indicator_rail_height] = @"drag_indicator_rail_height",
          [MOB_PROP_drag_indicator_width] = @"drag_indicator_width",
          [MOB_PROP_draw] = @"draw",
          [MOB_PROP_facing] = @"facing",
          [MOB_PROP_fade_on_scroll] = @"fade_on_scroll",
          [MOB_PROP_fill_height] = @"fill_height",
          [MOB_PROP_fill_width] = @"fill_width",
          [MOB_PROP_font] = @"font",
          [MOB_PROP_font_weight] = @"font_weight",
          [MOB_PROP_glass] = @"glass",
          [MOB_PROP_height] = @"height",
          [MOB_PROP_id] = @"id",
          [MOB_PROP_italic] = @"italic",
          [MOB_PROP_lazy] = @"lazy",
          [MOB_PROP_keyboard] = @"keyboard",
          [MOB_PROP_letter_spacing] = @"letter_spacing",
          [MOB_PROP_line_height] = @"line_height",
          [MOB_PROP_loop] = @"loop",
          [MOB_PROP_max] = @"max",
          [MOB_PROP_min] = @"min",
          [MOB_PROP_module] = @"module",
          [MOB_PROP_name] = @"name",
          [MOB_PROP_offset_x] = @"offset_x",
          [MOB_PROP_offset_y] = @"offset_y",
          [MOB_PROP_on_blur] = @"on_blur",
          [MOB_PROP_on_change] = @"on_change",
          [MOB_PROP_on_compose] = @"on_compose",
          [MOB_PROP_on_dismiss] = @"on_dismiss",
          [MOB_PROP_on_double_tap] = @"on_double_tap",
          [MOB_PROP_on_drag] = @"on_drag",
          [MOB_PROP_on_end_reached] = @"on_end_reached",
          [MOB_PROP_on_focus] = @"on_focus",
          [MOB_PROP_on_long_press] = @"on_long_press",
          [MOB_PROP_on_pinch] = @"on_pinch",
          [MOB_PROP_on_pointer_move] = @"on_pointer_move",
          [MOB_PROP_on_rotate] = @"on_rotate",
          [MOB_PROP_on_scroll] = @"on_scroll",
          [MOB_PROP_on_scroll_began] = @"on_scroll_began",
          [MOB_PROP_on_scroll_ended] = @"on_scroll_ended",
          [MOB_PROP_on_scroll_settled] = @"on_scroll_settled",
          [MOB_PROP_on_scrolled_past] = @"on_scrolled_past",
          [MOB_PROP_on_select] = @"on_select",
          [MOB_PROP_on_submit] = @"on_submit",
          [MOB_PROP_on_swipe] = @"on_swipe",
          [MOB_PROP_on_swipe_down] = @"on_swipe_down",
          [MOB_PROP_on_swipe_left] = @"on_swipe_left",
          [MOB_PROP_on_swipe_right] = @"on_swipe_right",
          [MOB_PROP_on_swipe_up] = @"on_swipe_up",
          [MOB_PROP_on_tab_select] = @"on_tab_select",
          [MOB_PROP_on_tap] = @"on_tap",
          [MOB_PROP_on_top_reached] = @"on_top_reached",
          [MOB_PROP_padding] = @"padding",
          [MOB_PROP_padding_bottom] = @"padding_bottom",
          [MOB_PROP_padding_left] = @"padding_left",
          [MOB_PROP_padding_right] = @"padding_right",
          [MOB_PROP_padding_top] = @"padding_top",
          [MOB_PROP_parallax] = @"parallax",
          [MOB_PROP_placeholder] = @"placeholder",
          [MOB_PROP_placeholder_color] = @"placeholder_color",
          [MOB_PROP_return_key] = @"return_key",
          [MOB_PROP_scrolled_past_threshold] = @"scrolled_past_threshold",
          [MOB_PROP_secure] = @"secure",
          [MOB_PROP_shader] = @"shader",
          [MOB_PROP_show_indicator] = @"show_indicator",
          [MOB_PROP_show_url] = @"show_url",
          [MOB_PROP_size] = @"size",
          [MOB_PROP_src] = @"src",
          [MOB_PROP_sticky_when_scrolled_past] = @"sticky_when_scrolled_past",
          [MOB_PROP_tabs] = @"tabs",
          [MOB_PROP_text] = @"text",
          [MOB_PROP_text_align] = @"text_align",
          [MOB_PROP_text_color] = @"text_color",
          [MOB_PROP_text_size] = @"text_size",
          [MOB_PROP_thickness] = @"thickness",
          [MOB_PROP_title] = @"title",
          [MOB_PROP_uniforms] = @"uniforms",
          [MOB_PROP_url] = @"url",
          [MOB_PROP_value] = @"value",
          [MOB_PROP_weight] = @"weight",
          [MOB_PROP_width] = @"width"};
      NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:MOB_PROP__COUNT];
      for (NSUInteger i = 0; i < MOB_PROP__COUNT; i++) {
          // A gap means an enum entry with no name: that prop would never
          // resolve and would read as absent on every node, silently.
          NSCAssert(names[i] != nil, @"MobPropKey %lu has no name", (unsigned long)i);
          m[names[i]] = @(i);
      }
      slots = [m copy];
    });
    return slots;
}

static MobNode *mob_node_from_dict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]])
        return nil;

    MobNode *node = [[MobNode alloc] init];

    NSString *type = dict[@"type"];
    if ([type isEqualToString:@"column"])
        node.nodeType = MobNodeTypeColumn;
    else if ([type isEqualToString:@"row"])
        node.nodeType = MobNodeTypeRow;
    else if ([type isEqualToString:@"text"] || [type isEqualToString:@"label"])
        node.nodeType = MobNodeTypeLabel;
    else if ([type isEqualToString:@"button"])
        node.nodeType = MobNodeTypeButton;
    else if ([type isEqualToString:@"scroll"])
        node.nodeType = MobNodeTypeScroll;
    else if ([type isEqualToString:@"box"])
        node.nodeType = MobNodeTypeBox;
    else if ([type isEqualToString:@"divider"])
        node.nodeType = MobNodeTypeDivider;
    else if ([type isEqualToString:@"spacer"])
        node.nodeType = MobNodeTypeSpacer;
    else if ([type isEqualToString:@"progress"])
        node.nodeType = MobNodeTypeProgress;
    else if ([type isEqualToString:@"text_field"])
        node.nodeType = MobNodeTypeTextField;
    else if ([type isEqualToString:@"toggle"])
        node.nodeType = MobNodeTypeToggle;
    else if ([type isEqualToString:@"slider"])
        node.nodeType = MobNodeTypeSlider;
    else if ([type isEqualToString:@"image"])
        node.nodeType = MobNodeTypeImage;
    else if ([type isEqualToString:@"lazy_list"])
        node.nodeType = MobNodeTypeLazyList;
    else if ([type isEqualToString:@"tab_bar"])
        node.nodeType = MobNodeTypeTabBar;
    else if ([type isEqualToString:@"video"])
        node.nodeType = MobNodeTypeVideo;
    else if ([type isEqualToString:@"camera_preview"])
        node.nodeType = MobNodeTypeCameraPreview;
    else if ([type isEqualToString:@"web_view"])
        node.nodeType = MobNodeTypeWebView;
    else if ([type isEqualToString:@"native_view"])
        node.nodeType = MobNodeTypeNativeView;
    else if ([type isEqualToString:@"icon"])
        node.nodeType = MobNodeTypeIcon;
    else if ([type isEqualToString:@"canvas"])
        node.nodeType = MobNodeTypeCanvas;
    else if ([type isEqualToString:@"gpu_view"])
        node.nodeType = MobNodeTypeGpuView;
    else if ([type isEqualToString:@"sheet"])
        node.nodeType = MobNodeTypeSheet;

    NSDictionary *props = dict[@"props"];

    // One pass over the props this node actually has, rather than one probe per
    // key it might have had. Unknown keys are ignored, exactly as an absent
    // probe was. A nil or non-dictionary `props` leaves every slot nil, which is
    // what `props[@"..."]` returned before.
    id pv[MOB_PROP__COUNT];
    memset(pv, 0, sizeof(pv));

    if ([props isKindOfClass:[NSDictionary class]]) {
        NSDictionary<NSString *, NSNumber *> *slots = mob_prop_slots();
        for (NSString *key in props) {
            NSNumber *slot = slots[key];
            if (slot)
                pv[slot.unsignedIntegerValue] = props[key];
        }
    }

    if ([props isKindOfClass:[NSDictionary class]]) {
        id text = pv[MOB_PROP_text];
        if (text)
            node.text = [text isKindOfClass:[NSString class]] ? text : [text description];

        // For text_field, `value:` is the controlled-input prop name (matches
        // the React/SwiftUI convention used in app code and demos). Map it
        // to `node.text` so MobTextField sees it as initialText. If both
        // `text:` and `value:` are passed, `value:` wins.
        if (node.nodeType == MobNodeTypeTextField) {
            id valueText = pv[MOB_PROP_value];
            if (valueText)
                node.text = [valueText isKindOfClass:[NSString class]] ? valueText
                                                                       : [valueText description];
        }

        id padding = pv[MOB_PROP_padding];
        if (padding)
            node.padding = [padding doubleValue];

        id paddingTop = pv[MOB_PROP_padding_top];
        if (paddingTop)
            node.paddingTop = [paddingTop doubleValue];
        id paddingRight = pv[MOB_PROP_padding_right];
        if (paddingRight)
            node.paddingRight = [paddingRight doubleValue];
        id paddingBottom = pv[MOB_PROP_padding_bottom];
        if (paddingBottom)
            node.paddingBottom = [paddingBottom doubleValue];
        id paddingLeft = pv[MOB_PROP_padding_left];
        if (paddingLeft)
            node.paddingLeft = [paddingLeft doubleValue];

        id textSize = pv[MOB_PROP_text_size];
        if (textSize)
            node.textSize = [textSize doubleValue];

        id fontFamily = pv[MOB_PROP_font];
        if ([fontFamily isKindOfClass:[NSString class]])
            node.fontFamily = fontFamily;
        id fontWeight = pv[MOB_PROP_font_weight];
        if (fontWeight)
            node.fontWeight = [fontWeight description];
        id textAlign = pv[MOB_PROP_text_align];
        if (textAlign)
            node.textAlign = [textAlign description];
        id italic = pv[MOB_PROP_italic];
        if (italic)
            node.italic = [italic boolValue];
        id lineHeight = pv[MOB_PROP_line_height];
        if (lineHeight)
            node.lineHeight = [lineHeight doubleValue];
        id letterSpacing = pv[MOB_PROP_letter_spacing];
        if (letterSpacing)
            node.letterSpacing = [letterSpacing doubleValue];

        id tabDefs = pv[MOB_PROP_tabs];
        if ([tabDefs isKindOfClass:[NSArray class]])
            node.tabDefs = tabDefs;
        id activeTab = pv[MOB_PROP_active];
        if (activeTab)
            node.activeTab = [activeTab description];
        id onTabSelect = pv[MOB_PROP_on_tab_select];
        if (onTabSelect && [onTabSelect isKindOfClass:[NSNumber class]]) {
            int handle = [onTabSelect intValue];
            node.onTabSelect = ^(NSString *tabId) {
              mob_send_change_str(handle, [tabId UTF8String]);
            };
        }

        id bg = pv[MOB_PROP_background];
        if (bg)
            node.backgroundColor = color_from_argb((long)[bg longLongValue]);

        id borderColor = pv[MOB_PROP_border_color];
        if (borderColor)
            node.borderColor = color_from_argb((long)[borderColor longLongValue]);

        id borderWidth = pv[MOB_PROP_border_width];
        if (borderWidth)
            node.borderWidth = [borderWidth doubleValue];

        id textColor = pv[MOB_PROP_text_color];
        if (textColor)
            node.textColor = color_from_argb((long)[textColor longLongValue]);

        id color = pv[MOB_PROP_color];
        if (color)
            node.color = color_from_argb((long)[color longLongValue]);

        id thickness = pv[MOB_PROP_thickness];
        if (thickness)
            node.thickness = [thickness doubleValue];

        id fixedSize = pv[MOB_PROP_size];
        if (fixedSize)
            node.fixedSize = [fixedSize doubleValue];

        id axis = pv[MOB_PROP_axis];
        if ([axis isKindOfClass:[NSString class]])
            node.axis = axis;

        // `align` plays two roles depending on node type — the Mob renderer
        // sets the same string and the iOS side picks the relevant
        // interpretation per case (rowAlign for HStack, boxAlign for ZStack).
        id alignProp = pv[MOB_PROP_align];
        if ([alignProp isKindOfClass:[NSString class]]) {
            node.rowAlign = alignProp;
            node.boxAlign = alignProp;
        }

        id offsetX = pv[MOB_PROP_offset_x];
        if (offsetX)
            node.offsetX = [offsetX doubleValue];
        id offsetY = pv[MOB_PROP_offset_y];
        if (offsetY)
            node.offsetY = [offsetY doubleValue];

        id showIndicator = pv[MOB_PROP_show_indicator];
        if (showIndicator)
            node.showIndicator = [showIndicator boolValue];

        id value = pv[MOB_PROP_value];
        if (value)
            node.value = [value doubleValue];

        id onTap = pv[MOB_PROP_on_tap];
        if (onTap && [onTap isKindOfClass:[NSNumber class]]) {
            int handle = [onTap intValue];
            node.onTap = ^{
              mob_send_tap(handle);
            };
        }

        id placeholder = pv[MOB_PROP_placeholder];
        if (placeholder)
            node.placeholder = [placeholder isKindOfClass:[NSString class]]
                                   ? placeholder
                                   : [placeholder description];

        // Icon name — logical key (e.g. "settings"), resolved to an SF Symbol
        // by MobIconView at render time. iOS-only string parsing here.
        if (node.nodeType == MobNodeTypeIcon) {
            id iconName = pv[MOB_PROP_name];
            if (iconName)
                node.iconName =
                    [iconName isKindOfClass:[NSString class]] ? iconName : [iconName description];
        }

        id keyboardType = pv[MOB_PROP_keyboard];
        if ([keyboardType isKindOfClass:[NSString class]])
            node.keyboardTypeStr = keyboardType;

        id returnKey = pv[MOB_PROP_return_key];
        if ([returnKey isKindOfClass:[NSString class]])
            node.returnKeyStr = returnKey;

        id secure = pv[MOB_PROP_secure];
        if ([secure isKindOfClass:[NSNumber class]])
            node.isSecure = [secure boolValue];

        id onFocus = pv[MOB_PROP_on_focus];
        if (onFocus && [onFocus isKindOfClass:[NSNumber class]]) {
            int handle = [onFocus intValue];
            node.onFocus = ^{
              mob_send_focus(handle);
            };
        }

        id onBlur = pv[MOB_PROP_on_blur];
        if (onBlur && [onBlur isKindOfClass:[NSNumber class]]) {
            int handle = [onBlur intValue];
            node.onBlur = ^{
              mob_send_blur(handle);
            };
        }

        id onSubmit = pv[MOB_PROP_on_submit];
        if (onSubmit && [onSubmit isKindOfClass:[NSNumber class]]) {
            int handle = [onSubmit intValue];
            node.onSubmit = ^{
              mob_send_submit(handle);
            };
        }

        id onCompose = pv[MOB_PROP_on_compose];
        if (onCompose && [onCompose isKindOfClass:[NSNumber class]]) {
            int handle = [onCompose intValue];
            node.onCompose = ^(NSString *text, NSString *phase) {
              mob_send_compose(handle, text ? [text UTF8String] : "",
                               phase ? [phase UTF8String] : "updating");
            };
        }

        id onSelect = pv[MOB_PROP_on_select];
        if (onSelect && [onSelect isKindOfClass:[NSNumber class]]) {
            int handle = [onSelect intValue];
            node.onSelect = ^{
              mob_send_select(handle);
            };
        }

        // ── Gestures (Batch 4) ──
        id onLongPress = pv[MOB_PROP_on_long_press];
        if (onLongPress && [onLongPress isKindOfClass:[NSNumber class]]) {
            int handle = [onLongPress intValue];
            node.onLongPress = ^{
              mob_send_long_press(handle);
            };
        }

        id onDoubleTap = pv[MOB_PROP_on_double_tap];
        if (onDoubleTap && [onDoubleTap isKindOfClass:[NSNumber class]]) {
            int handle = [onDoubleTap intValue];
            node.onDoubleTap = ^{
              mob_send_double_tap(handle);
            };
        }

        id onSwipe = pv[MOB_PROP_on_swipe];
        if (onSwipe && [onSwipe isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipe intValue];
            node.onSwipe = ^(NSString *direction) {
              mob_send_swipe_with_direction(handle, [direction UTF8String]);
            };
        }

        id onSwipeLeft = pv[MOB_PROP_on_swipe_left];
        if (onSwipeLeft && [onSwipeLeft isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipeLeft intValue];
            node.onSwipeLeft = ^{
              mob_send_swipe_left(handle);
            };
        }

        id onSwipeRight = pv[MOB_PROP_on_swipe_right];
        if (onSwipeRight && [onSwipeRight isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipeRight intValue];
            node.onSwipeRight = ^{
              mob_send_swipe_right(handle);
            };
        }

        id onSwipeUp = pv[MOB_PROP_on_swipe_up];
        if (onSwipeUp && [onSwipeUp isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipeUp intValue];
            node.onSwipeUp = ^{
              mob_send_swipe_up(handle);
            };
        }

        id onSwipeDown = pv[MOB_PROP_on_swipe_down];
        if (onSwipeDown && [onSwipeDown isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipeDown intValue];
            node.onSwipeDown = ^{
              mob_send_swipe_down(handle);
            };
        }

// ── Batch 5 Tier 1: high-frequency events (with throttle config) ──
// Helper macro: read a *_config sibling prop and apply it to the
// handle's throttle state.
#define MOB_APPLY_THROTTLE(HANDLE, CONFIG_KEY)                                                     \
    do {                                                                                           \
        id _cfg = props[CONFIG_KEY];                                                               \
        if ([_cfg isKindOfClass:[NSDictionary class]]) {                                           \
            int t = [(_cfg[@"throttle_ms"] ?: @0) intValue];                                       \
            int d = [(_cfg[@"debounce_ms"] ?: @0) intValue];                                       \
            double dt = [(_cfg[@"delta_threshold"] ?: @0) doubleValue];                            \
            int ld = [(_cfg[@"leading"] ?: @YES) boolValue] ? 1 : 0;                               \
            int tr = [(_cfg[@"trailing"] ?: @YES) boolValue] ? 1 : 0;                              \
            mob_set_throttle_config((HANDLE), t, d, dt, ld, tr);                                   \
        }                                                                                          \
    } while (0)

        id onScroll = pv[MOB_PROP_on_scroll];
        if ([onScroll isKindOfClass:[NSNumber class]]) {
            int handle = [onScroll intValue];
            MOB_APPLY_THROTTLE(handle, @"scroll_config");
            node.onScroll = ^(CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, CGFloat vx, CGFloat vy,
                              NSString *phase) {
              mob_send_scroll(handle, x, y, dx, dy, vx, vy,
                              phase ? [phase UTF8String] : "dragging");
            };
        }

        id onDrag = pv[MOB_PROP_on_drag];
        if ([onDrag isKindOfClass:[NSNumber class]]) {
            int handle = [onDrag intValue];
            MOB_APPLY_THROTTLE(handle, @"drag_config");
            node.onDrag = ^(CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, NSString *phase) {
              mob_send_drag(handle, x, y, dx, dy, phase ? [phase UTF8String] : "dragging");
            };
        }

        id onPinch = pv[MOB_PROP_on_pinch];
        if ([onPinch isKindOfClass:[NSNumber class]]) {
            int handle = [onPinch intValue];
            MOB_APPLY_THROTTLE(handle, @"pinch_config");
            node.onPinch = ^(CGFloat scale, CGFloat velocity, NSString *phase) {
              mob_send_pinch(handle, scale, velocity, phase ? [phase UTF8String] : "dragging");
            };
        }

        id onRotate = pv[MOB_PROP_on_rotate];
        if ([onRotate isKindOfClass:[NSNumber class]]) {
            int handle = [onRotate intValue];
            MOB_APPLY_THROTTLE(handle, @"rotate_config");
            node.onRotate = ^(CGFloat degrees, CGFloat velocity, NSString *phase) {
              mob_send_rotate(handle, degrees, velocity, phase ? [phase UTF8String] : "dragging");
            };
        }

        id onPointerMove = pv[MOB_PROP_on_pointer_move];
        if ([onPointerMove isKindOfClass:[NSNumber class]]) {
            int handle = [onPointerMove intValue];
            MOB_APPLY_THROTTLE(handle, @"pointer_config");
            node.onPointerMove = ^(CGFloat x, CGFloat y) {
              mob_send_pointer_move(handle, x, y);
            };
        }

#undef MOB_APPLY_THROTTLE

        // ── Batch 5 Tier 2: semantic single-fire scroll events ──
        id onScrollBegan = pv[MOB_PROP_on_scroll_began];
        if ([onScrollBegan isKindOfClass:[NSNumber class]]) {
            int handle = [onScrollBegan intValue];
            node.onScrollBegan = ^{
              mob_send_scroll_began(handle);
            };
        }

        id onScrollEnded = pv[MOB_PROP_on_scroll_ended];
        if ([onScrollEnded isKindOfClass:[NSNumber class]]) {
            int handle = [onScrollEnded intValue];
            node.onScrollEnded = ^{
              mob_send_scroll_ended(handle);
            };
        }

        id onScrollSettled = pv[MOB_PROP_on_scroll_settled];
        if ([onScrollSettled isKindOfClass:[NSNumber class]]) {
            int handle = [onScrollSettled intValue];
            node.onScrollSettled = ^{
              mob_send_scroll_settled(handle);
            };
        }

        id onTopReached = pv[MOB_PROP_on_top_reached];
        if ([onTopReached isKindOfClass:[NSNumber class]]) {
            int handle = [onTopReached intValue];
            node.onTopReached = ^{
              mob_send_top_reached(handle);
            };
        }

        id onScrolledPast = pv[MOB_PROP_on_scrolled_past];
        if ([onScrolledPast isKindOfClass:[NSNumber class]]) {
            int handle = [onScrolledPast intValue];
            node.onScrolledPast = ^{
              mob_send_scrolled_past(handle);
            };
        }
        id scrolledPastThreshold = pv[MOB_PROP_scrolled_past_threshold];
        if (scrolledPastThreshold) {
            node.scrolledPastThreshold = [scrolledPastThreshold doubleValue];
        }

        // ── Batch 5 Tier 3: native-side scroll-driven UI configs ──
        // Pass-through to the SwiftUI layer; never round-trips to BEAM.
        id parallax = pv[MOB_PROP_parallax];
        if ([parallax isKindOfClass:[NSDictionary class]]) {
            node.parallaxConfig = parallax;
        }
        id fadeOnScroll = pv[MOB_PROP_fade_on_scroll];
        if ([fadeOnScroll isKindOfClass:[NSDictionary class]]) {
            node.fadeOnScrollConfig = fadeOnScroll;
        }
        id stickyConfig = pv[MOB_PROP_sticky_when_scrolled_past];
        if ([stickyConfig isKindOfClass:[NSDictionary class]]) {
            node.stickyWhenScrolledPastConfig = stickyConfig;
        }

        id checked = pv[MOB_PROP_value];
        if (checked && node.nodeType == MobNodeTypeToggle) {
            // value is a boolean atom serialised as "true"/"false"
            node.checked = [[checked description] isEqualToString:@"true"] ||
                           ([checked isKindOfClass:[NSNumber class]] && [checked boolValue]);
        }

        id minVal = pv[MOB_PROP_min];
        if (minVal)
            node.minValue = [minVal doubleValue];

        id maxVal = pv[MOB_PROP_max];
        if (maxVal)
            node.maxValue = [maxVal doubleValue];

        id src = pv[MOB_PROP_src];
        if ([src isKindOfClass:[NSString class]])
            node.src = src;

        id contentMode = pv[MOB_PROP_content_mode];
        if ([contentMode isKindOfClass:[NSString class]])
            node.contentModeStr = contentMode;

        id fixedWidth = pv[MOB_PROP_width];
        if (fixedWidth)
            node.fixedWidth = [fixedWidth doubleValue];

        id fixedHeight = pv[MOB_PROP_height];
        if (fixedHeight)
            node.fixedHeight = [fixedHeight doubleValue];

        id layoutWeight = pv[MOB_PROP_weight];
        if (layoutWeight)
            node.layoutWeight = [layoutWeight doubleValue];

        id cornerRadius = pv[MOB_PROP_corner_radius];
        if (cornerRadius)
            node.cornerRadius = [cornerRadius doubleValue];

        // Liquid Glass opt-in — set by Mob.Renderer when the active theme
        // has `glass: true`. MobBox swaps a solid background for
        // `.glassEffect()` on iOS 26+, or `.ultraThinMaterial` on iOS 17–25.
        id useGlass = pv[MOB_PROP_glass];
        if (useGlass)
            node.useGlass = [useGlass boolValue];

        id lazyContent = pv[MOB_PROP_lazy];
        if ([lazyContent isKindOfClass:[NSNumber class]])
            node.lazyContent = [lazyContent boolValue];

        id fillWidth = pv[MOB_PROP_fill_width];
        if (fillWidth)
            node.fillWidth = [fillWidth boolValue];

        id fillHeight = pv[MOB_PROP_fill_height];
        if (fillHeight)
            node.fillHeight = [fillHeight boolValue];

        id placeholderColor = pv[MOB_PROP_placeholder_color];
        if (placeholderColor)
            node.placeholderColor = color_from_argb((long)[placeholderColor longLongValue]);

        id videoAutoplay = pv[MOB_PROP_autoplay];
        if (videoAutoplay)
            node.videoAutoplay = [videoAutoplay boolValue];
        id videoLoop = pv[MOB_PROP_loop];
        if (videoLoop)
            node.videoLoop = [videoLoop boolValue];
        id videoControls = pv[MOB_PROP_controls];
        if (videoControls)
            node.videoControls = [videoControls boolValue];

        id cameraFacing = pv[MOB_PROP_facing];
        if ([cameraFacing isKindOfClass:[NSString class]])
            node.cameraFacing = cameraFacing;

        // canvas props
        id canvasDraw = pv[MOB_PROP_draw];
        if ([canvasDraw isKindOfClass:[NSArray class]])
            node.canvasOps = canvasDraw;
        id canvasW = pv[MOB_PROP_width];
        if (canvasW && node.nodeType == MobNodeTypeCanvas)
            node.canvasWidth = [canvasW doubleValue];
        id canvasH = pv[MOB_PROP_height];
        if (canvasH && node.nodeType == MobNodeTypeCanvas)
            node.canvasHeight = [canvasH doubleValue];

        // gpu_view props: shader (string OR %{ios: "..."} map) + uniforms map.
        // Map form is the "I already have hand-tuned MSL" escape hatch.
        if (node.nodeType == MobNodeTypeGpuView) {
            id shader = pv[MOB_PROP_shader];
            if ([shader isKindOfClass:[NSString class]]) {
                node.gpuShaderMSL = shader;
            } else if ([shader isKindOfClass:[NSDictionary class]]) {
                id iosShader = ((NSDictionary *)shader)[@"ios"];
                if ([iosShader isKindOfClass:[NSString class]])
                    node.gpuShaderMSL = iosShader;
            }

            id uniforms = pv[MOB_PROP_uniforms];
            if ([uniforms isKindOfClass:[NSArray class]] ||
                [uniforms isKindOfClass:[NSDictionary class]])
                node.gpuUniforms = uniforms;
        }

        // sheet props. background is read generically above (shared prop
        // name across every node type) — MobSheetView reuses
        // node.backgroundColor directly for the sheet's own container
        // background, see MobRootView.swift. corner_radius is read a
        // second time here into the dedicated sheetCornerRadius (-1 =
        // unset) instead: node.cornerRadius is a plain CGFloat with a 0
        // default, so by the time Swift sees it, an explicit
        // `corner_radius: 0` is indistinguishable from "never set" — a
        // sheet's corners are visibly square-vs-rounded, so that ambiguity
        // needs its own sentinel here (unlike other node types, where 0 and
        // unset render identically).
        if (node.nodeType == MobNodeTypeSheet) {
            id sheetCornerRadius = pv[MOB_PROP_corner_radius];
            if (sheetCornerRadius)
                node.sheetCornerRadius = [sheetCornerRadius doubleValue];

            id detents = pv[MOB_PROP_detents];
            if ([detents isKindOfClass:[NSArray class]])
                node.sheetDetents = detents;

            id indicatorColor = pv[MOB_PROP_drag_indicator_color];
            if (indicatorColor)
                node.dragIndicatorColor = color_from_argb((long)[indicatorColor longLongValue]);

            id indicatorWidth = pv[MOB_PROP_drag_indicator_width];
            if (indicatorWidth)
                node.dragIndicatorWidth = [indicatorWidth doubleValue];
            id indicatorHeight = pv[MOB_PROP_drag_indicator_height];
            if (indicatorHeight)
                node.dragIndicatorHeight = [indicatorHeight doubleValue];
            id indicatorRailHeight = pv[MOB_PROP_drag_indicator_rail_height];
            if (indicatorRailHeight)
                node.dragIndicatorRailHeight = [indicatorRailHeight doubleValue];

            id onDismiss = pv[MOB_PROP_on_dismiss];
            if (onDismiss && [onDismiss isKindOfClass:[NSNumber class]]) {
                int handle = [onDismiss intValue];
                node.onDismiss = ^{
                  mob_send_dismiss(handle);
                };
            }
        }

        // webview props
        id webViewUrl = pv[MOB_PROP_url];
        if ([webViewUrl isKindOfClass:[NSString class]])
            node.webViewUrl = webViewUrl;
        id webViewAllow = pv[MOB_PROP_allow];
        if ([webViewAllow isKindOfClass:[NSString class]])
            node.webViewAllow = webViewAllow;
        id webViewShowUrl = pv[MOB_PROP_show_url];
        if (webViewShowUrl)
            node.webViewShowUrl = [webViewShowUrl boolValue];
        id webViewTitle = pv[MOB_PROP_title];
        if ([webViewTitle isKindOfClass:[NSString class]])
            node.webViewTitle = webViewTitle;

        // native_view props
        id nativeViewModule = pv[MOB_PROP_module];
        if ([nativeViewModule isKindOfClass:[NSString class]])
            node.nativeViewModule = nativeViewModule;
        // The author's `:id`, for EVERY node type — the name is historical and
        // misleading. It is the node identity ForEach keys on (MOB-127) and
        // what MobFrameTracker registers under; only nativeViewProps below is
        // actually gated on the node being a native_view.
        id nativeViewId = pv[MOB_PROP_id];
        if ([nativeViewId isKindOfClass:[NSString class]])
            node.nativeViewId = nativeViewId;
        id nativeViewHandle = pv[MOB_PROP_component_handle];
        if (nativeViewHandle)
            node.nativeViewHandle = [nativeViewHandle intValue];
        if (node.nodeType == MobNodeTypeNativeView)
            node.nativeViewProps = props;

        id onEndReached = pv[MOB_PROP_on_end_reached];
        if (onEndReached && [onEndReached isKindOfClass:[NSNumber class]]) {
            int handle = [onEndReached intValue];
            node.onTap = ^{
              mob_send_tap(handle);
            };
        }

        // For slider, value is the initial position (re-uses node.value property)
        // text_field initial text re-uses node.text property

        id onChange = pv[MOB_PROP_on_change];
        if (onChange && [onChange isKindOfClass:[NSNumber class]]) {
            int handle = [onChange intValue];
            switch (node.nodeType) {
            case MobNodeTypeTextField:
                node.onChangeStr = ^(NSString *v) {
                  mob_send_change_str(handle, [v UTF8String]);
                };
                break;
            case MobNodeTypeToggle:
                node.onChangeBool = ^(BOOL v) {
                  mob_send_change_bool(handle, (int)v);
                };
                break;
            case MobNodeTypeSlider:
                node.onChangeFloat = ^(double v) {
                  mob_send_change_float(handle, v);
                };
                break;
            default:
                break;
            }
        }

        id accessibilityId = pv[MOB_PROP_accessibility_id];
        if ([accessibilityId isKindOfClass:[NSString class]]) {
            node.accessibilityId = accessibilityId;
        }

        id accessibilityLabel = pv[MOB_PROP_accessibility_label];
        if ([accessibilityLabel isKindOfClass:[NSString class]]) {
            node.accessibilityLabel = accessibilityLabel;
        }

        id accessibilityRole = pv[MOB_PROP_accessibility_role];
        if ([accessibilityRole isKindOfClass:[NSString class]]) {
            node.accessibilityRole = accessibilityRole;
        }

        id disabled = pv[MOB_PROP_disabled];
        if ([disabled isKindOfClass:[NSNumber class]]) {
            node.disabled = [disabled boolValue];
        }
    }

    NSArray *children = dict[@"children"];
    if ([children isKindOfClass:[NSArray class]]) {
        for (id child in children) {
            MobNode *childNode = mob_node_from_dict(child);
            if (childNode)
                [node.children addObject:childNode];
        }
    }

    return node;
}

// ── NIF: exit_app/0 ──────────────────────────────────────────────────────────
// iOS apps don't have a programmatic "exit" convention — the home gesture is
// handled by the OS. This is intentionally a no-op; backgrounding on iOS
// happens naturally when the user swipes up.

static ERL_NIF_TERM nif_exit_app(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "ok");
}

// ── NIF: platform/0 ──────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_platform(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "ios");
}

// ── NIF: color_scheme/0 ──────────────────────────────────────────────────────
// Returns :light or :dark based on UIUserInterfaceStyle.
// Falls back to :light when called before any window is on screen.

static ERL_NIF_TERM nif_color_scheme(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    void (^read)(void) = ^{
      // Prefer the key window's trait collection (most accurate once the
      // app is on screen). Fall back to UITraitCollection.current (set
      // during a render pass) and finally UIScreen.mainScreen for the
      // earliest startup edge case before any window exists.
      UIWindow *win = nil;
      for (UIWindowScene *scene in [UIApplication.sharedApplication.connectedScenes allObjects]) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *w in scene.windows) {
              if (w.isKeyWindow) {
                  win = w;
                  break;
              }
          }
          if (win)
              break;
      }
      if (win) {
          style = win.traitCollection.userInterfaceStyle;
      } else {
          UIUserInterfaceStyle current_s =
              UITraitCollection.currentTraitCollection.userInterfaceStyle;
          style = (current_s != UIUserInterfaceStyleUnspecified)
                      ? current_s
                      : UIScreen.mainScreen.traitCollection.userInterfaceStyle;
      }
    };
    if ([NSThread isMainThread])
        read();
    else
        dispatch_sync(dispatch_get_main_queue(), read);
    return enif_make_atom(env, style == UIUserInterfaceStyleDark ? "dark" : "light");
}

// ── NIF: battery_level/0 ─────────────────────────────────────────────────────
// Returns the current battery charge as an integer 0..100, or -1 if the device
// does not report battery info (unlikely on iPhone/iPad).
// Enables battery monitoring if not already enabled. Must run on main thread.

static ERL_NIF_TERM nif_battery_level(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block int level = -1;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIDevice *dev = [UIDevice currentDevice];
      if (!dev.batteryMonitoringEnabled) {
          dev.batteryMonitoringEnabled = YES;
      }
      float f = dev.batteryLevel;
      if (f >= 0.0f) {
          level = (int)roundf(f * 100.0f);
      }
    });
    return enif_make_int(env, level);
}

// ── Mob.Device — lifecycle events + queries ─────────────────────────────────
//
// One registered "dispatcher" pid (the Mob.Device GenServer) receives every
// OS event via enif_send. The GenServer fans out to user-level subscribers.
//
// Each OS notification emits up to two messages:
//   {:mob_device, atom}                 — common, both platforms have it
//   {:mob_device_ios, atom}             — iOS-only (or extra fidelity)
//   {:mob_device_ios, atom, payload}    — when there's data to pass
//
// Observer registration is one-shot via dispatch_once — calling
// device_set_dispatcher/1 a second time just updates the pid, doesn't
// re-register observers (avoids duplicate notifications).

static ErlNifPid g_device_dispatcher_pid;
static BOOL g_device_dispatcher_set = NO;
static dispatch_once_t g_device_observers_once = 0;

static void mob_device_send_atom(const char *tag, const char *atom_name) {
    if (!g_device_dispatcher_set)
        return;
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, tag), enif_make_atom(e, atom_name));
    enif_send(NULL, &g_device_dispatcher_pid, e, msg);
    enif_free_env(e);
}

static void mob_device_send_atom_payload(const char *tag, const char *atom_name,
                                         ERL_NIF_TERM payload, ErlNifEnv *payload_env) {
    if (!g_device_dispatcher_set)
        return;
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM payload_copy = enif_make_copy(e, payload);
    ERL_NIF_TERM msg =
        enif_make_tuple3(e, enif_make_atom(e, tag), enif_make_atom(e, atom_name), payload_copy);
    enif_send(NULL, &g_device_dispatcher_pid, e, msg);
    enif_free_env(e);
    (void)payload_env;
}

static const char *thermal_state_atom(NSProcessInfoThermalState s) {
    switch (s) {
    case NSProcessInfoThermalStateNominal:
        return "nominal";
    case NSProcessInfoThermalStateFair:
        return "fair";
    case NSProcessInfoThermalStateSerious:
        return "serious";
    case NSProcessInfoThermalStateCritical:
        return "critical";
    default:
        return "nominal";
    }
}

static const char *battery_state_atom(UIDeviceBatteryState s) {
    switch (s) {
    case UIDeviceBatteryStateUnplugged:
        return "unplugged";
    case UIDeviceBatteryStateCharging:
        return "charging";
    case UIDeviceBatteryStateFull:
        return "full";
    default:
        return "unknown";
    }
}

// ── Network connectivity (NWPathMonitor) ─────────────────────────────────────
//
// A single process-lifetime NWPathMonitor tracks the active path. Its update
// handler runs on a private serial queue: it caches the latest snapshot (for
// the synchronous device_network_state/0 query) and pushes a
// connectivity_changed event to Mob.Device subscribers. Transport codes:
// 0 none, 1 wifi, 2 cellular, 3 wired, 4 other.
static nw_path_monitor_t g_path_monitor = NULL;
static dispatch_once_t g_path_monitor_once = 0;
static _Atomic(bool) g_net_online = false;
static _Atomic(int) g_net_transport = 0;
static _Atomic(bool) g_net_expensive = false;
static _Atomic(bool) g_net_constrained = false;

static const char *net_transport_atom(int t) {
    switch (t) {
    case 1:
        return "wifi";
    case 2:
        return "cellular";
    case 3:
        return "wired";
    case 4:
        return "other";
    default:
        return "none";
    }
}

static int net_classify_path(nw_path_t path) {
    if (nw_path_get_status(path) != nw_path_status_satisfied)
        return 0;
    if (nw_path_uses_interface_type(path, nw_interface_type_wifi))
        return 1;
    if (nw_path_uses_interface_type(path, nw_interface_type_cellular))
        return 2;
    if (nw_path_uses_interface_type(path, nw_interface_type_wired))
        return 3;
    return 4;
}

// Builds %{online, transport, expensive, validated, constrained}. `validated`
// is always :unavailable on iOS — NWPath reports a usable path but has no
// internet-reachability probe (Android's NET_CAPABILITY_VALIDATED). `constrained`
// is iOS Low Data Mode.
static ERL_NIF_TERM mob_make_network_map(ErlNifEnv *e, bool online, int transport, bool expensive,
                                         bool constrained) {
    ERL_NIF_TERM keys[5] = {enif_make_atom(e, "online"), enif_make_atom(e, "transport"),
                            enif_make_atom(e, "expensive"), enif_make_atom(e, "validated"),
                            enif_make_atom(e, "constrained")};
    ERL_NIF_TERM vals[5] = {enif_make_atom(e, online ? "true" : "false"),
                            enif_make_atom(e, net_transport_atom(transport)),
                            enif_make_atom(e, expensive ? "true" : "false"),
                            enif_make_atom(e, "unavailable"),
                            enif_make_atom(e, constrained ? "true" : "false")};
    ERL_NIF_TERM map;
    if (!enif_make_map_from_arrays(e, keys, vals, 5, &map))
        return enif_make_atom(e, "nil");
    return map;
}

// Starts the shared path monitor exactly once. Safe to call from either the
// dispatcher handshake or a cold query.
static void ensure_path_monitor_once(void) {
    dispatch_once(&g_path_monitor_once, ^{
      g_path_monitor = nw_path_monitor_create();
      dispatch_queue_t nq = dispatch_queue_create("com.mob.netmonitor", DISPATCH_QUEUE_SERIAL);
      nw_path_monitor_set_queue(g_path_monitor, nq);
      nw_path_monitor_set_update_handler(g_path_monitor, ^(nw_path_t path) {
        bool online = nw_path_get_status(path) == nw_path_status_satisfied;
        int transport = net_classify_path(path);
        bool expensive = nw_path_is_expensive(path);
        bool constrained = nw_path_is_constrained(path);
        // NWPathMonitor fires on dns/other changes too; only emit an event when
        // the snapshot we expose actually changed. The cache is still refreshed
        // either way so the synchronous query stays current.
        bool changed = online != atomic_load(&g_net_online) ||
                       transport != atomic_load(&g_net_transport) ||
                       expensive != atomic_load(&g_net_expensive) ||
                       constrained != atomic_load(&g_net_constrained);
        atomic_store(&g_net_online, online);
        atomic_store(&g_net_transport, transport);
        atomic_store(&g_net_expensive, expensive);
        atomic_store(&g_net_constrained, constrained);
        if (!changed)
            return;
        ErlNifEnv *e = enif_alloc_env();
        ERL_NIF_TERM payload = mob_make_network_map(e, online, transport, expensive, constrained);
        mob_device_send_atom_payload("mob_device", "connectivity_changed", payload, e);
        enif_free_env(e);
      });
      nw_path_monitor_start(g_path_monitor);
    });
}

// ── Orientation ────────────────────────────────────────────────────────────
// The locked mask the app shell's root view controller must report from
// -supportedInterfaceOrientations. UIInterfaceOrientationMaskAll means "no
// lock, follow the device". The shell reads this via the exported
// mob_locked_orientation_mask() (see PR notes — the VC override is the
// companion piece that makes the lock actually hold).
static UIInterfaceOrientationMask g_locked_orientation_mask = UIInterfaceOrientationMaskAll;

UIInterfaceOrientationMask mob_locked_orientation_mask(void) {
    return g_locked_orientation_mask;
}

static const char *interface_orientation_atom(UIInterfaceOrientation o) {
    switch (o) {
    case UIInterfaceOrientationPortrait:
        return "portrait";
    case UIInterfaceOrientationPortraitUpsideDown:
        return "portrait_upside_down";
    case UIInterfaceOrientationLandscapeLeft:
        return "landscape_left";
    case UIInterfaceOrientationLandscapeRight:
        return "landscape_right";
    default:
        return "unknown";
    }
}

// Read the foreground window scene's interface orientation (must run on the
// main thread).
static UIInterfaceOrientation mob_current_interface_orientation(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive)
            return ((UIWindowScene *)scene).interfaceOrientation;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
        if ([scene isKindOfClass:[UIWindowScene class]])
            return ((UIWindowScene *)scene).interfaceOrientation;
    return UIInterfaceOrientationUnknown;
}

// Map a lock atom (from Mob.Device.lock_orientation/1, plus :unspecified for
// unlock) to a UIKit mask.
static UIInterfaceOrientationMask orientation_mask_for_atom(const char *name) {
    if (strcmp(name, "portrait") == 0)
        return UIInterfaceOrientationMaskPortrait;
    if (strcmp(name, "portrait_upside_down") == 0)
        return UIInterfaceOrientationMaskPortraitUpsideDown;
    if (strcmp(name, "landscape") == 0)
        return UIInterfaceOrientationMaskLandscape;
    if (strcmp(name, "landscape_left") == 0)
        return UIInterfaceOrientationMaskLandscapeLeft;
    if (strcmp(name, "landscape_right") == 0)
        return UIInterfaceOrientationMaskLandscapeRight;
    return UIInterfaceOrientationMaskAll; // :unspecified -> unlock
}

static void register_device_observers_once(void) {
    dispatch_once(&g_device_observers_once, ^{
      NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
      NSOperationQueue *q = [NSOperationQueue mainQueue];

      // ── App lifecycle ──
      [nc addObserverForName:UIApplicationWillResignActiveNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "will_resign_active");
                    mob_device_send_atom("mob_device_ios", "will_resign_active");
                  }];
      [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "did_become_active");
                    mob_device_send_atom("mob_device_ios", "did_become_active");
                  }];
      [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "did_enter_background");
                    mob_device_send_atom("mob_device_ios", "did_enter_background");
                  }];
      [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "will_enter_foreground");
                    mob_device_send_atom("mob_device_ios", "will_enter_foreground");
                  }];
      [nc addObserverForName:UIApplicationWillTerminateNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "will_terminate");
                    mob_device_send_atom("mob_device_ios", "will_terminate");
                  }];
      [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "memory_warning");
                    mob_device_send_atom("mob_device_ios", "memory_warning");
                  }];

      // ── Display / lock state (iOS proxies via data-protection) ──
      [nc addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "screen_off");
                    mob_device_send_atom("mob_device_ios",
                                         "protected_data_will_become_unavailable");
                  }];
      [nc addObserverForName:UIApplicationProtectedDataDidBecomeAvailable
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    mob_device_send_atom("mob_device", "screen_on");
                    mob_device_send_atom("mob_device_ios", "protected_data_did_become_available");
                  }];

      // ── Power / thermal ──
      [nc addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    const char *s = thermal_state_atom([[NSProcessInfo processInfo] thermalState]);
                    ErlNifEnv *e = enif_alloc_env();
                    ERL_NIF_TERM payload = enif_make_atom(e, s);
                    mob_device_send_atom_payload("mob_device", "thermal_state_changed", payload, e);
                    mob_device_send_atom_payload("mob_device_ios", "thermal_state_changed", payload,
                                                 e);
                    enif_free_env(e);
                  }];
      [nc addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    BOOL low = [[NSProcessInfo processInfo] isLowPowerModeEnabled];
                    ErlNifEnv *e = enif_alloc_env();
                    ERL_NIF_TERM payload = enif_make_atom(e, low ? "true" : "false");
                    mob_device_send_atom_payload("mob_device", "low_power_mode_changed", payload,
                                                 e);
                    mob_device_send_atom_payload("mob_device_ios", "low_power_mode_changed",
                                                 payload, e);
                    enif_free_env(e);
                  }];

      // Ensure battery monitoring is on so the change notifications fire.
      dispatch_async(dispatch_get_main_queue(), ^{
        UIDevice *dev = [UIDevice currentDevice];
        if (!dev.batteryMonitoringEnabled)
            dev.batteryMonitoringEnabled = YES;
      });
      [nc addObserverForName:UIDeviceBatteryStateDidChangeNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    const char *s = battery_state_atom([[UIDevice currentDevice] batteryState]);
                    ErlNifEnv *e = enif_alloc_env();
                    ERL_NIF_TERM payload = enif_make_atom(e, s);
                    mob_device_send_atom_payload("mob_device", "battery_state_changed", payload, e);
                    mob_device_send_atom_payload("mob_device_ios", "battery_state_changed", payload,
                                                 e);
                    enif_free_env(e);
                  }];
      [nc addObserverForName:UIDeviceBatteryLevelDidChangeNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    float lvl = [[UIDevice currentDevice] batteryLevel];
                    int pct = lvl >= 0.0f ? (int)roundf(lvl * 100.0f) : -1;
                    ErlNifEnv *e = enif_alloc_env();
                    ERL_NIF_TERM payload = enif_make_int(e, pct);
                    mob_device_send_atom_payload("mob_device", "battery_level_changed", payload, e);
                    mob_device_send_atom_payload("mob_device_ios", "battery_level_changed", payload,
                                                 e);
                    enif_free_env(e);
                  }];

      // ── Audio session interruptions / route changes ──
      [nc addObserverForName:AVAudioSessionInterruptionNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *note) {
                    AVAudioSessionInterruptionType t =
                        [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                    const char *atom = (t == AVAudioSessionInterruptionTypeBegan)
                                           ? "audio_interrupted"
                                           : "audio_resumed";
                    mob_device_send_atom("mob_device", atom);
                    mob_device_send_atom("mob_device_ios", atom);
                  }];
      [nc addObserverForName:AVAudioSessionRouteChangeNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *note) {
                    mob_device_send_atom("mob_device", "audio_route_changed");
                    mob_device_send_atom("mob_device_ios", "audio_route_changed");
                  }];

      // ── Orientation ──
      dispatch_async(dispatch_get_main_queue(), ^{
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
      });
      [nc addObserverForName:UIDeviceOrientationDidChangeNotification
                      object:nil
                       queue:q
                  usingBlock:^(NSNotification *n) {
                    // Report the *interface* orientation (skips face up/down),
                    // which is the one screens care about.
                    const char *s = interface_orientation_atom(mob_current_interface_orientation());
                    if (strcmp(s, "unknown") == 0)
                        return;
                    ErlNifEnv *e = enif_alloc_env();
                    ERL_NIF_TERM payload = enif_make_atom(e, s);
                    mob_device_send_atom_payload("mob_device", "orientation_changed", payload, e);
                    enif_free_env(e);
                  }];

      // ── Network connectivity ──
      // NWPathMonitor delivers an initial snapshot shortly after start and on
      // every subsequent change; the handler caches it and emits
      // connectivity_changed.
      ensure_path_monitor_once();

      NSLog(@"[mob] Mob.Device observers registered");
    });
}

static ERL_NIF_TERM nif_device_set_dispatcher(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[0], &pid))
        return enif_make_badarg(env);
    g_device_dispatcher_pid = pid;
    g_device_dispatcher_set = YES;
    register_device_observers_once();
    return enif_make_atom(env, "ok");
}

// ── color_scheme_changed (driven from MobRootView.swift's onChange) ──────────
//
// SwiftUI exposes `\.colorScheme` as an environment value that flips when the
// system appearance changes. MobRootView attaches a `.onChange(of:colorScheme)`
// handler that calls into here so we can route the event to Mob.Device
// subscribers without polling. Use this rather than UITraitChange APIs because
// SwiftUI handles iOS 13–17 compatibility for us.
void mob_notify_color_scheme(const char *scheme) {
    if (!g_device_dispatcher_set || !scheme)
        return;
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM payload = enif_make_atom(e, scheme);
    mob_device_send_atom_payload("mob_device", "color_scheme_changed", payload, e);
    mob_device_send_atom_payload("mob_device_ios", "color_scheme_changed", payload, e);
    enif_free_env(e);
}

static ERL_NIF_TERM nif_device_battery_state(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block UIDeviceBatteryState s = UIDeviceBatteryStateUnknown;
    __block int pct = -1;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIDevice *dev = [UIDevice currentDevice];
      if (!dev.batteryMonitoringEnabled)
          dev.batteryMonitoringEnabled = YES;
      s = dev.batteryState;
      float f = dev.batteryLevel;
      if (f >= 0.0f)
          pct = (int)roundf(f * 100.0f);
    });
    return enif_make_tuple2(env, enif_make_atom(env, battery_state_atom(s)),
                            enif_make_int(env, pct));
}

static ERL_NIF_TERM nif_device_thermal_state(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    NSProcessInfoThermalState s = [[NSProcessInfo processInfo] thermalState];
    return enif_make_atom(env, thermal_state_atom(s));
}

static ERL_NIF_TERM nif_device_network_state(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // Start monitoring on the first cold query too, so the value populates even
    // if the dispatcher handshake hasn't run. The first snapshot arrives async,
    // so a query in the first few ms after boot may read the offline default.
    ensure_path_monitor_once();
    return mob_make_network_map(env, atomic_load(&g_net_online), atomic_load(&g_net_transport),
                                atomic_load(&g_net_expensive), atomic_load(&g_net_constrained));
}

static ERL_NIF_TERM nif_device_low_power_mode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    BOOL low = [[NSProcessInfo processInfo] isLowPowerModeEnabled];
    return enif_make_atom(env, low ? "true" : "false");
}

static ERL_NIF_TERM nif_device_foreground(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block UIApplicationState st = UIApplicationStateBackground;
    dispatch_sync(dispatch_get_main_queue(), ^{
      st = [UIApplication sharedApplication].applicationState;
    });
    return enif_make_atom(env, st == UIApplicationStateActive ? "true" : "false");
}

static ERL_NIF_TERM nif_device_os_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    NSString *v = [[UIDevice currentDevice] systemVersion];
    const char *cstr = v.UTF8String;
    return enif_make_string(env, cstr ? cstr : "", ERL_NIF_LATIN1);
}

static ERL_NIF_TERM nif_device_model(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    NSString *m = [[UIDevice currentDevice] model];
    const char *cstr = m.UTF8String;
    return enif_make_string(env, cstr ? cstr : "", ERL_NIF_LATIN1);
}

static ERL_NIF_TERM nif_device_orientation(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    // interfaceOrientation must be read on the main thread.
    __block UIInterfaceOrientation o = UIInterfaceOrientationUnknown;
    if ([NSThread isMainThread])
        o = mob_current_interface_orientation();
    else
        dispatch_sync(dispatch_get_main_queue(), ^{
          o = mob_current_interface_orientation();
        });
    return enif_make_atom(env, interface_orientation_atom(o));
}

static ERL_NIF_TERM nif_device_lock_orientation(ErlNifEnv *env, int argc,
                                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    char name[32];
    if (enif_get_atom(env, argv[0], name, sizeof(name), ERL_NIF_LATIN1) == 0)
        return enif_make_badarg(env);

    UIInterfaceOrientationMask mask = orientation_mask_for_atom(name);
    g_locked_orientation_mask = mask;

    dispatch_async(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          UIWindowScene *ws = (UIWindowScene *)scene;
          UIViewController *root =
              ws.keyWindow.rootViewController ?: ws.windows.firstObject.rootViewController;
          if (@available(iOS 16.0, *)) {
              // The lock holds only if the root VC reports
              // mob_locked_orientation_mask() from -supportedInterfaceOrientations
              // (companion shell change). This requests the actual rotation.
              [root setNeedsUpdateOfSupportedInterfaceOrientations];
              UIWindowSceneGeometryPreferencesIOS *prefs =
                  [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
              [ws requestGeometryUpdateWithPreferences:prefs
                                          errorHandler:^(NSError *err) {
                                            (void)err;
                                          }];
          }
      }
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: device_keep_awake/1 ──────────────────────────────────────────────────
// argv[0] is the boolean atom `true`/`false`. Disables the idle timer (auto-dim
// / auto-lock) while true. Must be set on the main thread.
static ERL_NIF_TERM nif_device_keep_awake(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    char name[8] = {0};
    enif_get_atom(env, argv[0], name, sizeof(name), ERL_NIF_LATIN1);
    BOOL on = (strcmp(name, "true") == 0);

    dispatch_async(dispatch_get_main_queue(), ^{
      [UIApplication sharedApplication].idleTimerDisabled = on;
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: safe_area/0 ─────────────────────────────────────────────────────────
// Returns {Top, Right, Bottom, Left} in logical points (not pixels).
// Must read UIWindow.safeAreaInsets on the main thread.
//
// Called from Mob.Screen.init/1 — i.e. on the boot path, before the first
// screen ever mounts. A plain dispatch_sync here is a deadlock risk: if the
// main thread hasn't reached an idle run-loop tick yet (observed during
// scene-attachment on iPad, including the compatibility-mode window an
// iPhone-only app runs in there), this blocks the BEAM boot thread forever —
// the app never finishes launching. Bound the wait and fall back to zero
// insets on timeout: a screen with wrong insets once is a far smaller bug
// than an app that never boots.
static ERL_NIF_TERM nif_safe_area(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block UIEdgeInsets insets = UIEdgeInsetsZero;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      UIWindow *window = nil;
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if ([scene isKindOfClass:[UIWindowScene class]]) {
              UIWindowScene *ws = (UIWindowScene *)scene;
              window = ws.windows.firstObject;
              break;
          }
      }
      if (window)
          insets = window.safeAreaInsets;
      dispatch_semaphore_signal(done);
    });
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC));
    dispatch_semaphore_wait(done, deadline);
    return enif_make_tuple4(
        env, enif_make_double(env, insets.top), enif_make_double(env, insets.right),
        enif_make_double(env, insets.bottom), enif_make_double(env, insets.left));
}

// ── NIF: log/1 ────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_log(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char buf[4096] = {0};
    ErlNifBinary bin;
    if (enif_inspect_binary(env, argv[0], &bin)) {
        size_t len = bin.size < sizeof(buf) - 1 ? bin.size : sizeof(buf) - 1;
        memcpy(buf, bin.data, len);
        buf[len] = 0;
    } else if (!enif_get_string(env, argv[0], buf, sizeof(buf), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }
    NSLog(@"[mob] %s", buf);
    return enif_make_atom(env, "ok");
}

// ── NIF: log/2 ────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_log2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char level[16] = {0};
    char buf[4096] = {0};
    enif_get_atom(env, argv[0], level, sizeof(level), ERL_NIF_LATIN1);
    ErlNifBinary bin;
    if (enif_inspect_binary(env, argv[1], &bin)) {
        size_t len = bin.size < sizeof(buf) - 1 ? bin.size : sizeof(buf) - 1;
        memcpy(buf, bin.data, len);
        buf[len] = 0;
    } else if (!enif_get_string(env, argv[1], buf, sizeof(buf), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }
    NSLog(@"[%s] %s", level, buf);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_transition/1 ─────────────────────────────────────────────────────

static ERL_NIF_TERM nif_set_transition(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(tap_mutex);
    if (!enif_get_atom(env, argv[0], g_transition, sizeof(g_transition), ERL_NIF_LATIN1)) {
        enif_mutex_unlock(tap_mutex);
        return enif_make_badarg(env);
    }
    enif_mutex_unlock(tap_mutex);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_root/1 ──────────────────────────────────────────────────────────
// Accepts a JSON binary, parses it to a MobNode tree, and pushes it to the
// SwiftUI view model. Runs on the BEAM thread — MobViewModel dispatches to main.

// nif_set_theme/1 — accept the resolved theme palette (as JSON) from
// Mob.Theme.set/1. iOS doesn't use system chrome whose appearance depends
// on a global theme (we render every surface via mob's primitives with
// explicit color props), so the palette itself is unused here — kept for
// symmetry with the Android implementation, which needs it to drive
// Material 3's NavigationBar / Button colour scheme.
//
// `_font_fallback` IS read: it's the ordered list of font names
// MobRootView.swift's `resolvedFont` walks when a node's own font can't be
// loaded (see mob_font_fallback() below and MOB_FONTS.md).
static NSArray<NSString *> *g_font_fallback = nil;

static ERL_NIF_TERM nif_set_theme(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSData *data = [NSData dataWithBytes:bin.data length:bin.size];
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![json isKindOfClass:[NSDictionary class]]) {
        return enif_make_atom(env, "ok");
    }

    id fallback = json[@"_font_fallback"];
    if ([fallback isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (id name in (NSArray *)fallback) {
            if ([name isKindOfClass:[NSString class]])
                [names addObject:name];
        }
        NSArray<NSString *> *resolved = [names copy];
        // g_font_fallback is read from mob_font_fallback() on the main thread
        // during SwiftUI render. This NIF runs on the BEAM's calling thread —
        // an unsynchronized cross-thread write/read on a plain ARC global can
        // release the old array out from under a concurrent reader. Hop the
        // write onto the main thread (same pattern every other NIF here uses
        // for state the main thread touches) so both sides only ever run
        // there, serialized.
        dispatch_sync(dispatch_get_main_queue(), ^{
          g_font_fallback = resolved;
        });
    }

    return enif_make_atom(env, "ok");
}

// Read from MobRootView.swift's resolvedFont — see nif_set_theme above.
// Never nil; empty when no theme has set a font_fallback (the default).
NSArray<NSString *> *mob_font_fallback(void) {
    return g_font_fallback ?: @[];
}

static NSMutableDictionary *mob_frame_registry(void); // all defined with the
static void mob_adopt_frame_ids(NSSet<NSString *> *); // element frame registry below
static NSSet<NSString *> *mob_collect_frame_ids(MobNode *);
static void mob_bump_frame_generation(void);

static ERL_NIF_TERM nif_set_root(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSData *data = [NSData dataWithBytes:bin.data length:bin.size];
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![json isKindOfClass:[NSDictionary class]]) {
        LOGE(@"set_root: JSON parse error: %@", err);
        return enif_make_atom(env, "error");
    }

    MobNode *node = mob_node_from_dict((NSDictionary *)json);
    if (!node)
        return enif_make_atom(env, "error");

    // Purge only the ids absent from this tree, rather than wiping the whole
    // registry and relying on MobFrameTracker to repopulate every surviving
    // element. A wipe-then-repopulate design raced SwiftUI's own teardown:
    // an element being removed can still get one more GeometryReader layout
    // pass as part of that removal, so a repopulation trigger tied to "did I
    // just get (re)rendered" fires for outgoing views too, right as they're
    // disappearing, and their stale frame survives. Purging by id instead
    // never touches a surviving element's existing entry (nothing to race),
    // and correctly drops one that's genuinely gone from the new tree.
    //
    // The retained id set also gates mob_register_frame, so the outgoing
    // screen can't re-register itself while it animates away (setRoot below
    // is dispatched to the main thread async — the teardown animation
    // outlives this call). Elements that stay in the tree but stop being
    // laid out are handled separately, via mob_unregister_frame.
    mob_adopt_frame_ids(mob_collect_frame_ids(node));

    // Snapshot and reset the transition
    enif_mutex_lock(tap_mutex);
    char transition[16];
    strncpy(transition, g_transition, sizeof(transition) - 1);
    transition[sizeof(transition) - 1] = 0;
    strncpy(g_transition, "none", sizeof(g_transition));
    // Commit the freshly-built tap table: register_tap wrote this frame's
    // handlers into 1 - tap_active; make that table active now so events for the
    // new tree resolve against it (readers see a consistent pair under the lock).
    TapHandle *previous = tap_tables[tap_active];
    TapHandle *build = tap_tables[1 - tap_active];

    // Bound the commit by what the tables can actually hold, not by
    // tap_build_count alone.
    //
    // Only clear_taps resets tap_build_count, so a set_root that arrives without
    // an intervening clear_taps carries the previous frame's count. That used to
    // be merely wrong — both tables were a fixed 256, so the worst case was
    // committing the wrong handlers. Now the two tables are separate heap
    // allocations that can differ in size, and an unbounded loop over a stale
    // count reads (and, once tap_handle_next is set from it, writes) past the
    // end of whichever is smaller.
    //
    // Mob.Sender is the single writer today, so this needs two screens racing
    // clear/register/set_root to reach — the race Mob.Sender's own moduledoc
    // describes, whose documented consequence is a mixed-up table. It should
    // stay a correctness bug, not become memory corruption.
    int build_cap = tap_table_capacity[1 - tap_active];
    int prev_cap = tap_table_capacity[tap_active];
    int committed = tap_build_count < build_cap ? tap_build_count : build_cap;

    if (build) {
        for (int slot = 0; slot < committed; slot++) {
            if (previous && slot < tap_handle_next && slot < prev_cap && previous[slot].tag_env &&
                previous[slot].pid.pid == build[slot].pid.pid &&
                enif_compare(previous[slot].tag, build[slot].tag) == 0)
                build[slot].identity_start_generation = previous[slot].identity_start_generation;
        }
    }
    // Snapshot now, log after the mutex is released. NSLog writes synchronously
    // to the system log, and holding tap_mutex across it would block concurrent
    // mob_send_* on the main thread — reintroducing, once per frame, exactly the
    // cost this whole change removed from the per-call path.
    int exhausted_this_frame = tap_exhausted_count;
    tap_exhausted_count = 0;

    tap_active = 1 - tap_active;
    tap_handles = tap_tables[tap_active];
    tap_handle_next = committed;
    tap_table_generations[tap_active] = tap_build_generation;
    // Reset here as well as in clear_taps, so a second set_root without an
    // intervening clear_taps commits an empty table rather than re-committing
    // this frame's handlers against whatever the other table now holds.
    tap_build_count = 0;
    enif_mutex_unlock(tap_mutex);

    // A non-"none" transition is what makes MobViewModel bump navVersion, and
    // MobRootView keys the whole tree on `.id(currentNavVersion)` — so every
    // view identity is destroyed and rebuilt. Bump the frame generation in
    // lockstep: trackers belonging to the outgoing tree captured the old
    // generation and are refused from here on, which is the only thing that
    // stops them re-registering at mid-animation coordinates while they slide
    // away. (`.move` transitions change their global frames continuously, so
    // they keep firing onChange the whole way out; tree membership alone can't
    // reject them when both screens tag the same :id.)
    if (strcmp(transition, "none") != 0)
        mob_bump_frame_generation();

    if (exhausted_this_frame > 0) {
        // One line per frame rather than one per overflowing node. The count is
        // the useful number anyway: it says how many interactive elements are
        // silently inert, which the per-call line never made obvious.
        LOGE(@"register_tap: pool exhausted (cap=%d) — %d interactive element(s) in this "
             @"frame have no handler and will not respond",
             MOB_TAP_SLOT_LIMIT, exhausted_this_frame);
    }

    NSString *transitionStr = [NSString stringWithUTF8String:transition];
    [[MobViewModel shared] setRoot:node transition:transitionStr];

    return enif_make_atom(env, "ok");
}

// ── NIF: register_tap/1 ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_register_tap(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    ERL_NIF_TERM tag_term;

    if (enif_get_local_pid(env, argv[0], &pid)) {
        tag_term = enif_make_atom(env, "ok");
    } else {
        int arity;
        const ERL_NIF_TERM *elems;
        if (!enif_get_tuple(env, argv[0], &arity, &elems) || arity != 2)
            return enif_make_badarg(env);
        if (!enif_get_local_pid(env, elems[0], &pid))
            return enif_make_badarg(env);
        tag_term = elems[1];
    }

    enif_mutex_lock(tap_mutex);
    if (tap_build_count >= MOB_TAP_SLOT_LIMIT ||
        !mob_tap_grow_locked(1 - tap_active, tap_build_count + 1)) {
        // Counted under the mutex, like the Zig side: set_root reads and resets
        // this under the same lock. Mob.Sender serialises every caller today, so
        // an unguarded read-modify-write would be benign — but nothing else in
        // this file leans on that, and it should not start here.
        tap_exhausted_count++;
        enif_mutex_unlock(tap_mutex);
        // MOB-100 follow-up: this used to be enif_make_badarg(env), which
        // crashed Mob.Renderer.render/3 (and the whole screen process) the
        // same way a full component pool used to crash Mob.ComponentServer
        // — an unvirtualized long list or big form with >MOB_TAP_SLOT_LIMIT
        // interactive elements would hit this on every render. Every
        // mob_send_* sender already no-ops on an out-of-range handle (see
        // mob_send_tap et al. above), so -1 is a safe "no handler wired up"
        // sentinel here — the interactive prop silently does nothing
        // instead of taking the screen down.
        // Deliberately not logged here. This is reached once per interactive
        // node beyond the cap — measured at 359 times per frame on a 200-row
        // screen — and NSLog writes synchronously to the system log. That
        // logging alone was 13ms of a 27ms frame, 47% of the whole frame. The
        // count is reported once per frame from set_root instead.
        return enif_make_int(env, -1);
    }
    TapHandle *build = tap_tables[1 - tap_active];
    int slot = tap_build_count;
    int handle = mob_encode_event_handle(tap_build_generation, slot);
    if (handle < 0) {
        enif_mutex_unlock(tap_mutex);
        LOGE(@"register_tap: invalid generation %u", tap_build_generation);
        return enif_make_int(env, -1);
    }
    ErlNifEnv *tag_env = enif_alloc_env();
    if (!tag_env) {
        enif_mutex_unlock(tap_mutex);
        LOGE(@"register_tap: unable to allocate tag environment");
        return enif_make_atom(env, "error");
    }
    build[slot].pid = pid;
    build[slot].tag_env = tag_env;
    build[slot].tag = enif_make_copy(build[slot].tag_env, tag_term);
    build[slot].identity_start_generation = tap_build_generation;
    tap_build_count++;
    // The high-water mark has to be raised HERE, not in set_root. clear_taps
    // frees exactly `used` slots, and a frame can register taps and then never
    // reach set_root — Mob.Renderer.render/4 calls clear_taps, then prepare,
    // then :json.encode, then set_root, and Mob.Sender.commit/1 rescues anything
    // that raises in between. Recording the mark only at set_root left those
    // slots' tag_envs uncleared and unreachable: one leaked ErlNifEnv per tap,
    // per failed frame, forever, on a path deliberately designed to survive.
    tap_table_used[1 - tap_active] = tap_build_count;
    enif_mutex_unlock(tap_mutex);

    return enif_make_int(env, handle);
}

// ── NIF: clear_taps/0 ─────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_clear_taps(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(tap_mutex);
    tap_build_generation = mob_next_handle_generation(tap_build_generation);
    tap_table_generations[1 - tap_active] = 0;
    // Prepare the INACTIVE (building) table for a fresh frame; leave the active
    // table intact so concurrent mob_send_* keep resolving the last committed
    // frame. The freshly built table is swapped in at set_root.
    TapHandle *build = tap_tables[1 - tap_active];
    int used = tap_table_used[1 - tap_active];
    for (int i = 0; i < used; i++) {
        if (build[i].tag_env) {
            enif_free_env(build[i].tag_env);
            build[i].tag_env = NULL;
        }
        // Reset throttle state — slots get reused across renders.
        build[i].throttle_configured = 0;
        build[i].throttle_ms = 0;
        build[i].debounce_ms = 0;
        build[i].delta_threshold = 0;
        build[i].leading = 1;
        build[i].trailing = 1;
        build[i].last_emit_ns = 0;
        build[i].last_x = 0;
        build[i].last_y = 0;
        build[i].seq = 0;
    }
    tap_table_used[1 - tap_active] = 0;
    // Reset here, not only in set_root. set_root reports and clears the count,
    // but a frame that overflows and then never reaches set_root would otherwise
    // carry its overflow into the next frame's report — which claims to describe
    // "this frame". clear_taps is the one entry point every frame runs.
    tap_exhausted_count = 0;
    tap_build_count = 0;
    enif_mutex_unlock(tap_mutex);
    return enif_make_atom(env, "ok");
}

// ── NIF: haptic/1 ─────────────────────────────────────────────────────────────
// Triggers haptic feedback. Fire-and-forget; dispatched async to main thread.

static ERL_NIF_TERM nif_haptic(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char type[32] = {0};
    enif_get_atom(env, argv[0], type, sizeof(type), ERL_NIF_LATIN1);
    NSString *typeStr = [NSString stringWithUTF8String:type];

    dispatch_async(dispatch_get_main_queue(), ^{
      if ([typeStr isEqualToString:@"success"] || [typeStr isEqualToString:@"error"] ||
          [typeStr isEqualToString:@"warning"]) {
          UINotificationFeedbackGenerator *g = [[UINotificationFeedbackGenerator alloc] init];
          [g prepare];
          if ([typeStr isEqualToString:@"success"])
              [g notificationOccurred:UINotificationFeedbackTypeSuccess];
          else if ([typeStr isEqualToString:@"error"])
              [g notificationOccurred:UINotificationFeedbackTypeError];
          else
              [g notificationOccurred:UINotificationFeedbackTypeWarning];
      } else {
          UIImpactFeedbackStyle style = UIImpactFeedbackStyleMedium;
          if ([typeStr isEqualToString:@"light"])
              style = UIImpactFeedbackStyleLight;
          if ([typeStr isEqualToString:@"heavy"])
              style = UIImpactFeedbackStyleHeavy;
          UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
          [g prepare];
          [g impactOccurred];
      }
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: torch/1 ──────────────────────────────────────────────────────────────
// Toggle the rear-camera torch. argv[0] is the atom `on` or `off`. No capture
// session and no camera permission needed. No-op (not an error) on a device
// without a torch — the simulator and most tablets have none.
static ERL_NIF_TERM nif_torch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char state[8] = {0};
    enif_get_atom(env, argv[0], state, sizeof(state), ERL_NIF_LATIN1);
    BOOL on = (strcmp(state, "on") == 0);

    dispatch_async(dispatch_get_main_queue(), ^{
      AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
      if (!device || !device.hasTorch || !device.isTorchAvailable)
          return;
      NSError *err = nil;
      if (![device lockForConfiguration:&err])
          return;
      if (on) {
          // setTorchModeOnWithLevel: validates the level and is preferred over
          // the torchMode setter; max level = full brightness.
          [device setTorchModeOnWithLevel:AVCaptureMaxAvailableTorchLevel error:NULL];
      } else {
          device.torchMode = AVCaptureTorchModeOff;
      }
      [device unlockForConfiguration];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: clipboard_put/1 ──────────────────────────────────────────────────────
// Writes a UTF-8 binary to the system clipboard. Fire-and-forget.

static ERL_NIF_TERM nif_clipboard_put(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSString *text = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      [UIPasteboard generalPasteboard].string = text;
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: clipboard_get/0 ──────────────────────────────────────────────────────
// Returns {:ok, Binary} or :empty. Synchronous (dispatch_sync to main thread).

static ERL_NIF_TERM nif_clipboard_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      text = [UIPasteboard generalPasteboard].string;
    });

    if (text) {
        const char *utf8 = [text UTF8String];
        ErlNifBinary bin;
        size_t len = strlen(utf8);
        enif_alloc_binary(len, &bin);
        memcpy(bin.data, utf8, len);
        ERL_NIF_TERM text_term = enif_make_binary(env, &bin);
        return enif_make_tuple2(env, enif_make_atom(env, "ok"), text_term);
    }
    return enif_make_atom(env, "empty");
}

// ── NIF: tts_speak/2 ──────────────────────────────────────────────────────────
// Speaks UTF-8 text via AVSpeechSynthesizer. opts is a JSON object, all keys
// optional: {"rate": float, "pitch": float, "voice": "en-US"}. Fire-and-forget;
// a synthesizer is created lazily and kept alive so utterances can queue.

static AVSpeechSynthesizer *g_tts_synth = nil;

static ERL_NIF_TERM nif_tts_speak(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary text_bin, opts_bin;
    if (!enif_inspect_binary(env, argv[0], &text_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &text_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &opts_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &opts_bin))
        return enif_make_badarg(env);

    NSString *text = [[NSString alloc] initWithBytes:text_bin.data
                                              length:text_bin.size
                                            encoding:NSUTF8StringEncoding];
    NSData *optsData = [NSData dataWithBytes:opts_bin.data length:opts_bin.size];

    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_tts_synth)
          g_tts_synth = [[AVSpeechSynthesizer alloc] init];

      AVSpeechUtterance *utt = [AVSpeechUtterance speechUtteranceWithString:text];

      NSDictionary *opts = [NSJSONSerialization JSONObjectWithData:optsData options:0 error:nil];
      if ([opts isKindOfClass:[NSDictionary class]]) {
          NSNumber *rate = opts[@"rate"];
          if ([rate isKindOfClass:[NSNumber class]])
              utt.rate = [rate floatValue];
          NSNumber *pitch = opts[@"pitch"];
          if ([pitch isKindOfClass:[NSNumber class]])
              utt.pitchMultiplier = [pitch floatValue];
          NSString *voice = opts[@"voice"];
          if ([voice isKindOfClass:[NSString class]]) {
              AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithLanguage:voice];
              if (v)
                  utt.voice = v;
          }
      }

      [g_tts_synth speakUtterance:utt];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: tts_stop/0 ───────────────────────────────────────────────────────────
// Stops any in-progress speech immediately. Fire-and-forget.

static ERL_NIF_TERM nif_tts_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [g_tts_synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: open_url/1 ───────────────────────────────────────────────────────────
// Hands a URL to the OS to open in the user's default browser/app.
// Fire-and-forget; returns :ok immediately.

static ERL_NIF_TERM nif_open_url(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSString *str = [[NSString alloc] initWithBytes:bin.data
                                             length:bin.size
                                           encoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:str];
    if (!url)
        return enif_make_badarg(env);

    dispatch_async(dispatch_get_main_queue(), ^{
      [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: open_settings/1 ──────────────────────────────────────────────────────
// Opens this app's settings page. The target arg (app|notifications|exact_alarm)
// is honored on Android; iOS exposes only the single app settings page, so the
// target is validated but otherwise ignored. Fire-and-forget; returns :ok.

static ERL_NIF_TERM nif_open_settings(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    dispatch_async(dispatch_get_main_queue(), ^{
      NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
      if (url)
          [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    });
    return enif_make_atom(env, "ok");
}

// nif_audio_output_status/0 — {Volume, Muted, RouteCode, OtherAudio} as four
// doubles (decoded by Mob.Audio.output_status/0). iOS has no direct mute flag,
// so Muted is inferred from outputVolume == 0. RouteCode mirrors the Android
// encoding: 1=speaker, 2=headphones, 3=bluetooth, 4=receiver, 0=none.
static ERL_NIF_TERM nif_audio_output_status(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    double volume = (double)session.outputVolume;
    double other = session.isOtherAudioPlaying ? 1.0 : 0.0;
    double route = 0.0;
    for (AVAudioSessionPortDescription *out in session.currentRoute.outputs) {
        NSString *t = out.portType;
        if ([t isEqualToString:AVAudioSessionPortBuiltInSpeaker])
            route = 1.0;
        else if ([t isEqualToString:AVAudioSessionPortHeadphones])
            route = 2.0;
        else if ([t isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                 [t isEqualToString:AVAudioSessionPortBluetoothLE] ||
                 [t isEqualToString:AVAudioSessionPortBluetoothHFP])
            route = 3.0;
        else if ([t isEqualToString:AVAudioSessionPortBuiltInReceiver])
            route = 4.0;
        if (route != 0.0)
            break;
    }
    double muted = (volume <= 0.0) ? 1.0 : 0.0;
    return enif_make_tuple4(env, enif_make_double(env, volume), enif_make_double(env, muted),
                            enif_make_double(env, route), enif_make_double(env, other));
}

// nif_audio_output_level/1 — {RmsDb, PeakDb} as two doubles, or an error atom.
// iOS cannot tap the global output mix (sandbox), so "mix" is unsupported;
// "mob" meters Mob.Audio's own AVAudioPlayer (metering is enabled when the
// player is created).
//
// Forward-declare the play/1 player: it lives with the audio-playback globals
// defined further below, but output_level/1 (here) meters that same player.
static AVAudioPlayer *g_audio_player;
static ERL_NIF_TERM nif_audio_output_level(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString *source = [[NSString alloc] initWithBytes:bin.data
                                                length:bin.size
                                              encoding:NSUTF8StringEncoding];
    if (![source isEqualToString:@"mob"])
        return enif_make_atom(env, "unsupported_on_platform");

    __block double rms = -160.0;
    __block double peak = -160.0;
    __block BOOL playing = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      AVAudioPlayer *player = g_audio_player;
      if (player && player.playing) {
          playing = YES;
          [player updateMeters];
          rms = (double)[player averagePowerForChannel:0];
          peak = (double)[player peakPowerForChannel:0];
      }
    });
    if (!playing)
        return enif_make_atom(env, "not_playing");
    return enif_make_tuple2(env, enif_make_double(env, rms), enif_make_double(env, peak));
}

// ── NIF: share_text/1 ─────────────────────────────────────────────────────────
// Opens the iOS share sheet with plain text. Fire-and-forget.

static ERL_NIF_TERM nif_share_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSString *text = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      UIActivityViewController *vc =
          [[UIActivityViewController alloc] initWithActivityItems:@[ text ]
                                            applicationActivities:nil];
      UIViewController *root = nil;
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if ([scene isKindOfClass:[UIWindowScene class]]) {
              root = ((UIWindowScene *)scene).windows.firstObject.rootViewController;
              break;
          }
      }
      if (root) {
          if (vc.popoverPresentationController) {
              vc.popoverPresentationController.sourceView = root.view;
              CGRect r = root.view.bounds;
              vc.popoverPresentationController.sourceRect =
                  CGRectMake(CGRectGetMidX(r), CGRectGetMidY(r), 0, 0);
          }
          [root presentViewController:vc animated:YES completion:nil];
      }
    });
    return enif_make_atom(env, "ok");
}

// ════════════════════════════════════════════════════════════════════════════
// Device capability NIFs
// ════════════════════════════════════════════════════════════════════════════

// ── Shared helpers ─────────────────────────────────────────────────────────

// Build and send {atom1, atom2} to a pid from any thread.
static void mob_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
    enif_send(NULL, (ErlNifPid *)pid, e, msg);
    enif_free_env(e);
}

// Build and send {atom1, atom2, atom3} to a pid from any thread.
static void mob_send3(const ErlNifPid *pid, const char *a1, const char *a2, const char *a3) {
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg =
        enif_make_tuple3(e, enif_make_atom(e, a1), enif_make_atom(e, a2), enif_make_atom(e, a3));
    enif_send(NULL, (ErlNifPid *)pid, e, msg);
    enif_free_env(e);
}

// Return the root view controller of the key window in the first active scene.
static UIViewController *mob_root_vc(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            UIWindow *w = ws.keyWindow ?: ws.windows.firstObject;
            if (w.rootViewController)
                return w.rootViewController;
        }
    }
    return nil;
}

// ── Launch notification global ─────────────────────────────────────────────
// Written by mob_set_launch_notification_json() (called from app delegate);
// read and cleared by nif_take_launch_notification.
static char *g_launch_notification_json = NULL;
static ErlNifMutex *g_launch_notif_mutex = NULL;

@interface MobNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@property(nonatomic) ErlNifPid screenPid;
@end
static MobNotificationDelegate *g_notif_delegate;

// Called from AppDelegate didRegisterForRemoteNotificationsWithDeviceToken.
// Sends {:push_token, :ios, token_hex_string} to the registered screen process.
void mob_send_push_token(const char *hex_token) {
    if (!g_notif_delegate)
        return;
    ErlNifPid p = g_notif_delegate.screenPid;
    ErlNifEnv *e = enif_alloc_env();
    size_t len = strlen(hex_token);
    ErlNifBinary tb;
    enif_alloc_binary(len, &tb);
    memcpy(tb.data, hex_token, len);
    ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "push_token"),
                                        enif_make_atom(e, "ios"), enif_make_binary(e, &tb));
    enif_send(NULL, &p, e, msg);
    enif_free_env(e);
}

void mob_set_launch_notification_json(const char *json) {
    // Store even before nif_load created the mutex: on a cold start from a
    // notification tap, the app delegate calls this before the BEAM starts,
    // and nothing reads the global until take_launch_notification
    // (post-nif_load), so there's no concurrent access in that window. The
    // previous early return silently dropped exactly that cold-start payload
    // — tap-to-open from a killed app never worked.
    if (g_launch_notif_mutex)
        enif_mutex_lock(g_launch_notif_mutex);
    free(g_launch_notification_json);
    g_launch_notification_json = json ? strdup(json) : NULL;
    if (g_launch_notif_mutex)
        enif_mutex_unlock(g_launch_notif_mutex);
}

static ERL_NIF_TERM nif_take_launch_notification(ErlNifEnv *env, int argc,
                                                 const ERL_NIF_TERM argv[]) {
    if (!g_launch_notif_mutex)
        return enif_make_atom(env, "none");
    enif_mutex_lock(g_launch_notif_mutex);
    char *json = g_launch_notification_json;
    g_launch_notification_json = NULL;
    enif_mutex_unlock(g_launch_notif_mutex);
    if (!json)
        return enif_make_atom(env, "none");
    ErlNifBinary bin;
    size_t len = strlen(json);
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, json, len);
    free(json);
    return enif_make_binary(env, &bin);
}

// ── Opened-document ("open with") ──────────────────────────────────────────
//
// When another app hands us a file to open — e.g. a `.livemd` emailed to the
// user and tapped, routed to us because Info.plist declares the document type —
// iOS calls `application:openURL:options:`, which forwards the URL here.
//
// Two delivery paths, because the file can arrive either before or after the
// root screen has mounted:
//   * Cold launch: store the item JSON; `nif_take_opened_document` hands it to
//     the screen at mount (same store-and-take shape as the launch notification).
//   * Warm (app already running): if the screen registered a pid (it does so by
//     calling take_opened_document/0 at mount), also `enif_send` it immediately
//     as `{:files, :opened, %{path,name,mime,size}}` — parallel to files_pick's
//     `{:files, :picked, …}`.
static char *g_opened_document_json = NULL;
static ErlNifMutex *g_opened_doc_mutex = NULL;
static ErlNifPid g_opened_doc_pid;
static BOOL g_opened_doc_pid_set = NO;

// Build the `{:files, :opened, %{...}}` map term in `e` from an item NSDictionary.
static ERL_NIF_TERM mob_opened_doc_term(ErlNifEnv *e, NSString *path, NSString *name,
                                        NSString *mime, long long size) {
    const char *cpath = path.UTF8String, *cname = name.UTF8String, *cmime = mime.UTF8String;
    ErlNifBinary pb, nb, mb;
    enif_alloc_binary(strlen(cpath), &pb);
    memcpy(pb.data, cpath, strlen(cpath));
    enif_alloc_binary(strlen(cname), &nb);
    memcpy(nb.data, cname, strlen(cname));
    enif_alloc_binary(strlen(cmime), &mb);
    memcpy(mb.data, cmime, strlen(cmime));
    ERL_NIF_TERM keys[4] = {enif_make_atom(e, "path"), enif_make_atom(e, "name"),
                            enif_make_atom(e, "mime"), enif_make_atom(e, "size")};
    ERL_NIF_TERM vals[4] = {enif_make_binary(e, &pb), enif_make_binary(e, &nb),
                            enif_make_binary(e, &mb), enif_make_int64(e, size)};
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(e, keys, vals, 4, &map);
    return map;
}

// Called from AppDelegate application:openURL:options:. Copies the (possibly
// security-scoped) file into the app's tmp dir so the BEAM can read it after the
// originating app's grant goes away, then stores it for take + warm-sends it.
void mob_handle_opened_url(const char *url_cstr) {
    if (!url_cstr)
        return;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:url_cstr]];
    if (!url.isFileURL) {
        url = [NSURL URLWithString:[NSString stringWithUTF8String:url_cstr]];
        if (!url.isFileURL)
            return;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"document";
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    NSError *err = nil;
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&err];
    if (scoped)
        [url stopAccessingSecurityScopedResource];
    if (err) {
        NSLog(@"[Mob] open: copy failed for %@: %@", url, err);
        return;
    }
    long long sz =
        [[[NSFileManager defaultManager] attributesOfItemAtPath:tmp
                                                          error:nil][NSFileSize] longLongValue];
    NSString *mime = @"application/octet-stream";
    UTType *ut = [UTType typeWithFilenameExtension:url.pathExtension];
    if (ut.preferredMIMEType)
        mime = ut.preferredMIMEType;

    NSDictionary *item = @{@"path" : tmp, @"name" : name, @"mime" : mime, @"size" : @(sz)};
    NSData *jd = [NSJSONSerialization dataWithJSONObject:item options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];

    if (json) {
        // Store even if the mutex isn't up yet: at a cold launch openURL can
        // fire before the BEAM has loaded the NIF (nif_load creates the mutex),
        // and nothing reads the global until take_opened_document, so there's no
        // concurrent access to guard against in that window.
        if (g_opened_doc_mutex)
            enif_mutex_lock(g_opened_doc_mutex);
        free(g_opened_document_json);
        g_opened_document_json = strdup(json.UTF8String);
        if (g_opened_doc_mutex)
            enif_mutex_unlock(g_opened_doc_mutex);
    }

    if (g_opened_doc_pid_set) {
        ErlNifPid p = g_opened_doc_pid;
        ErlNifEnv *e = enif_alloc_env();
        ERL_NIF_TERM map = mob_opened_doc_term(e, tmp, name, mime, sz);
        ERL_NIF_TERM msg =
            enif_make_tuple3(e, enif_make_atom(e, "files"), enif_make_atom(e, "opened"), map);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
    }
}

// take_opened_document/0 — returns the pending opened-document item JSON binary
// (or :none), AND registers the caller as the warm-delivery pid for any file
// opened later while the app is running. Call once from the root screen mount.
static ERL_NIF_TERM nif_take_opened_document(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    enif_self(env, &g_opened_doc_pid);
    g_opened_doc_pid_set = YES;
    if (!g_opened_doc_mutex)
        return enif_make_atom(env, "none");
    enif_mutex_lock(g_opened_doc_mutex);
    char *json = g_opened_document_json;
    g_opened_document_json = NULL;
    enif_mutex_unlock(g_opened_doc_mutex);
    if (!json)
        return enif_make_atom(env, "none");
    ErlNifBinary bin;
    size_t len = strlen(json);
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, json, len);
    free(json);
    return enif_make_binary(env, &bin);
}

// ── Permission request ────────────────────────────────────────────────────

// ── Plugin permission registry ────────────────────────────────────────────
// A plugin that owns a runtime permission capability (e.g. mob_location) ships
// its own C/ObjC permission handler and registers it from its NIF's load
// callback via mob_register_permission_handler. nif_request_permission falls
// through to this table for any capability core does not handle directly, so a
// capability can leave core without losing the unified
// Mob.Permissions.request/2 API. The handler drives the native permission API
// and delivers {:permission, cap, :granted|:denied} to `pid` itself (the plugin
// links erl_nif). Registration happens once at NIF load (BEAM boot); lookup
// happens later on a scheduler thread — single-write-then-read, no lock (same
// pattern as core's other boot-time globals).

typedef void (*MobPermissionHandler)(ErlNifPid pid);

#define MOB_MAX_PERMISSION_HANDLERS 16
static struct {
    char cap[32];
    MobPermissionHandler fn;
} g_permission_handlers[MOB_MAX_PERMISSION_HANDLERS];
static int g_permission_handler_count = 0;

// Exported (non-static) so a plugin object linked into the same static binary
// can call it. A plugin declares:
//   extern void mob_register_permission_handler(const char *cap,
//                                               void (*fn)(ErlNifPid));
void mob_register_permission_handler(const char *cap, MobPermissionHandler fn) {
    if (!cap || !fn)
        return;
    for (int i = 0; i < g_permission_handler_count; i++) {
        if (strcmp(g_permission_handlers[i].cap, cap) == 0) {
            g_permission_handlers[i].fn = fn; // last registration wins
            return;
        }
    }
    if (g_permission_handler_count >= MOB_MAX_PERMISSION_HANDLERS)
        return;
    strncpy(g_permission_handlers[g_permission_handler_count].cap, cap, 31);
    g_permission_handlers[g_permission_handler_count].cap[31] = '\0';
    g_permission_handlers[g_permission_handler_count].fn = fn;
    g_permission_handler_count++;
}

// Invokes a plugin-registered handler for `cap`. Returns YES if one ran.
static BOOL mob_dispatch_plugin_permission(const char *cap, ErlNifPid pid) {
    for (int i = 0; i < g_permission_handler_count; i++) {
        if (strcmp(g_permission_handlers[i].cap, cap) == 0) {
            g_permission_handlers[i].fn(pid);
            return YES;
        }
    }
    return NO;
}

static ERL_NIF_TERM nif_request_permission(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char cap[32];
    if (!enif_get_atom(env, argv[0], cap, sizeof(cap), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    ErlNifPid pid;
    enif_self(env, &pid);

    if (strcmp(cap, "microphone") == 0) {
        // :microphone stays in core (audio recording needs it). :camera moved to
        // the mob_camera plugin — it falls through to mob_dispatch_plugin_permission.
        [AVCaptureDevice
            requestAccessForMediaType:AVMediaTypeAudio
                    completionHandler:^(BOOL granted) {
                      mob_send3(&pid, "permission", "microphone", granted ? "granted" : "denied");
                    }];
    } else if (strcmp(cap, "photo_library") == 0) {
        [PHPhotoLibrary
            requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                       handler:^(PHAuthorizationStatus status) {
                                         BOOL ok = (status == PHAuthorizationStatusAuthorized ||
                                                    status == PHAuthorizationStatusLimited);
                                         mob_send3(&pid, "permission", "photo_library",
                                                   ok ? "granted" : "denied");
                                       }];
    } else if (strcmp(cap, "notifications") == 0) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center
            requestAuthorizationWithOptions:UNAuthorizationOptionAlert |
                                            UNAuthorizationOptionSound | UNAuthorizationOptionBadge
                          completionHandler:^(BOOL granted, NSError *err) {
                            mob_send3(&pid, "permission", "notifications",
                                      granted ? "granted" : "denied");
                          }];
    } else {
        // Fall through to a plugin-registered capability (e.g. mob_location
        // once :location leaves core). Unknown → badarg.
        if (!mob_dispatch_plugin_permission(cap, pid))
            return enif_make_badarg(env);
    }
    return enif_make_atom(env, "ok");
}

// ── File picker ───────────────────────────────────────────────────────────

@interface MobFilesDelegate : NSObject <UIDocumentPickerDelegate>
@property(nonatomic) ErlNifPid pid;
@end

static MobFilesDelegate *g_files_delegate = nil;

@implementation MobFilesDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)ctrl
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        mob_send2(&_pid, "files", "cancelled");
        g_files_delegate = nil;
        return;
    }
    ErlNifPid p = self.pid;
    g_files_delegate = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      ErlNifEnv *e = enif_alloc_env();
      ERL_NIF_TERM list = enif_make_list(e, 0);
      for (NSURL *url in urls.reverseObjectEnumerator) {
          [url startAccessingSecurityScopedResource];
          NSString *name = url.lastPathComponent;
          NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
          [[NSFileManager defaultManager] copyItemAtURL:url
                                                  toURL:[NSURL fileURLWithPath:tmp]
                                                  error:nil];
          [url stopAccessingSecurityScopedResource];
          NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tmp
                                                                                 error:nil];
          long long sz = [attrs[NSFileSize] longLongValue];
          const char *path = tmp.UTF8String;
          const char *nm = name.UTF8String;
          ErlNifBinary pb;
          enif_alloc_binary(strlen(path), &pb);
          memcpy(pb.data, path, strlen(path));
          ErlNifBinary nb;
          enif_alloc_binary(strlen(nm), &nb);
          memcpy(nb.data, nm, strlen(nm));
          ERL_NIF_TERM keys[3] = {enif_make_atom(e, "path"), enif_make_atom(e, "name"),
                                  enif_make_atom(e, "size")};
          ERL_NIF_TERM vals[3] = {enif_make_binary(e, &pb), enif_make_binary(e, &nb),
                                  enif_make_int64(e, sz)};
          ERL_NIF_TERM map;
          enif_make_map_from_arrays(e, keys, vals, 3, &map);
          list = enif_make_list_cell(e, map, list);
      }
      ERL_NIF_TERM msg =
          enif_make_tuple3(e, enif_make_atom(e, "files"), enif_make_atom(e, "picked"), list);
      enif_send(NULL, &p, e, msg);
      enif_free_env(e);
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)ctrl {
    mob_send2(&_pid, "files", "cancelled");
    g_files_delegate = nil;
}
@end

// Map a semantic group name (from Mob.Files' normalized envelope) to a UTType.
static UTType *mob_semantic_uttype(NSString *group) {
    if ([group isEqualToString:@"images"])
        return UTTypeImage;
    if ([group isEqualToString:@"video"])
        return UTTypeMovie;
    if ([group isEqualToString:@"audio"])
        return UTTypeAudio;
    if ([group isEqualToString:@"pdf"])
        return UTTypePDF;
    if ([group isEqualToString:@"text"])
        return UTTypePlainText;
    return nil;
}

// Turn Mob.Files' JSON type envelope into the content types the picker offers.
// The envelope is a list of {"kind","value"} maps; an empty list (the :any
// default) means no filter, which we represent as UTTypeData (every file).
static NSArray<UTType *> *mob_uttypes_from_json(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![parsed isKindOfClass:[NSArray class]])
        return @[ UTTypeData ];

    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (id entry in (NSArray *)parsed) {
        if (![entry isKindOfClass:[NSDictionary class]])
            continue;
        NSString *kind = entry[@"kind"];
        NSString *value = entry[@"value"];
        if (![value isKindOfClass:[NSString class]])
            continue;

        UTType *t = nil;
        if ([kind isEqualToString:@"extension"]) {
            t = [UTType typeWithFilenameExtension:value];
        } else if ([kind isEqualToString:@"mime"]) {
            t = [UTType typeWithMIMEType:value];
        } else if ([kind isEqualToString:@"uti"]) {
            t = [UTType typeWithIdentifier:value];
        } else if ([kind isEqualToString:@"semantic"]) {
            t = mob_semantic_uttype(value);
        }
        if (t)
            [types addObject:t];
    }

    // Every spec failed to resolve (e.g. an unknown MIME) — fall back to "any"
    // rather than presenting a picker that can offer nothing.
    return types.count > 0 ? types : @[ UTTypeData ];
}

static ERL_NIF_TERM nif_files_pick(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);

    NSArray<UTType *> *contentTypes = @[ UTTypeData ];
    ErlNifBinary jbin;
    if (argc >= 1 && enif_inspect_iolist_as_binary(env, argv[0], &jbin)) {
        NSString *json = [[NSString alloc] initWithBytes:jbin.data
                                                  length:jbin.size
                                                encoding:NSUTF8StringEncoding];
        if (json)
            contentTypes = mob_uttypes_from_json(json);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      UIDocumentPickerViewController *vc =
          [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes
                                                                      asCopy:YES];
      vc.allowsMultipleSelection = YES;
      g_files_delegate = [[MobFilesDelegate alloc] init];
      g_files_delegate.pid = pid;
      vc.delegate = g_files_delegate;
      [mob_root_vc() presentViewController:vc animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── Audio recording ───────────────────────────────────────────────────────

static AVAudioRecorder *g_audio_recorder = nil;
static ErlNifPid g_audio_pid;
static NSString *g_audio_path = nil;
static NSDate *g_audio_start = nil;

static ERL_NIF_TERM nif_audio_start_recording(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);
    g_audio_pid = pid;
    dispatch_async(dispatch_get_main_queue(), ^{
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:nil];
      [[AVAudioSession sharedInstance] setActive:YES error:nil];
      NSString *tmp = [NSTemporaryDirectory()
          stringByAppendingPathComponent:[NSString stringWithFormat:@"mob_audio_%@.m4a",
                                                                    [NSUUID UUID].UUIDString]];
      g_audio_path = tmp;
      g_audio_start = [NSDate date];
      NSURL *url = [NSURL fileURLWithPath:tmp];
      NSDictionary *settings = @{
          AVFormatIDKey : @(kAudioFormatMPEG4AAC),
          AVSampleRateKey : @44100,
          AVNumberOfChannelsKey : @1,
          AVEncoderAudioQualityKey : @(AVAudioQualityMedium)
      };
      g_audio_recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:nil];
      [g_audio_recorder record];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_audio_stop_recording(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_audio_recorder)
          return;
      NSTimeInterval dur = -[g_audio_start timeIntervalSinceNow];
      [g_audio_recorder stop];
      [[AVAudioSession sharedInstance] setActive:NO error:nil];
      NSString *path = g_audio_path;
      g_audio_recorder = nil;
      ErlNifPid p = g_audio_pid;
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv *e = enif_alloc_env();
        const char *cpath = path.UTF8String;
        ErlNifBinary pb;
        enif_alloc_binary(strlen(cpath), &pb);
        memcpy(pb.data, cpath, strlen(cpath));
        ERL_NIF_TERM keys[2] = {enif_make_atom(e, "path"), enif_make_atom(e, "duration")};
        ERL_NIF_TERM vals[2] = {enif_make_binary(e, &pb), enif_make_double(e, dur)};
        ERL_NIF_TERM map;
        enif_make_map_from_arrays(e, keys, vals, 2, &map);
        ERL_NIF_TERM msg =
            enif_make_tuple3(e, enif_make_atom(e, "audio"), enif_make_atom(e, "recorded"), map);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
      });
    });
    return enif_make_atom(env, "ok");
}

// ── Audio input metering (mic level probe, no recording kept) ──────────────
// A metering-only AVAudioRecorder: records to a throwaway temp file with
// metering enabled and reads averagePower/peakPower (dBFS). Shares the mic
// session with recording — callers must not run both at once. (A future
// AVAudioEngine input tap would avoid the temp file; see MOB-35.)
static AVAudioRecorder *g_meter_recorder = nil;
static NSString *g_meter_path = nil;

static ERL_NIF_TERM nif_audio_start_input_metering(ErlNifEnv *env, int argc,
                                                   const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:nil];
      [[AVAudioSession sharedInstance] setActive:YES error:nil];
      NSString *tmp = [NSTemporaryDirectory()
          stringByAppendingPathComponent:[NSString stringWithFormat:@"mob_meter_%@.m4a",
                                                                    [NSUUID UUID].UUIDString]];
      g_meter_path = tmp;
      NSURL *url = [NSURL fileURLWithPath:tmp];
      NSDictionary *settings = @{
          AVFormatIDKey : @(kAudioFormatMPEG4AAC),
          AVSampleRateKey : @44100,
          AVNumberOfChannelsKey : @1,
          AVEncoderAudioQualityKey : @(AVAudioQualityMin)
      };
      g_meter_recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:nil];
      g_meter_recorder.meteringEnabled = YES;
      [g_meter_recorder record];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_audio_input_level(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    AVAudioRecorder *rec = g_meter_recorder;
    if (!rec || !rec.isRecording)
        return enif_make_atom(env, "not_metering");
    [rec updateMeters];
    double avg = [rec averagePowerForChannel:0];
    double peak = [rec peakPowerForChannel:0];
    return enif_make_tuple2(env, enif_make_double(env, avg), enif_make_double(env, peak));
}

static ERL_NIF_TERM nif_audio_stop_input_metering(ErlNifEnv *env, int argc,
                                                  const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_meter_recorder) {
          [g_meter_recorder stop];
          g_meter_recorder = nil;
      }
      [[AVAudioSession sharedInstance] setActive:NO error:nil];
      if (g_meter_path) {
          [[NSFileManager defaultManager] removeItemAtPath:g_meter_path error:nil];
          g_meter_path = nil;
      }
    });
    return enif_make_atom(env, "ok");
}

// ── Audio playback ────────────────────────────────────────────────────────

@interface MobAudioPlayerDelegate : NSObject <AVAudioPlayerDelegate>
@end

static AVAudioPlayer *g_audio_player = nil;
static AVPlayer *g_av_player = nil;
static id g_av_observer = nil;
static ErlNifPid g_playback_pid;
static NSString *g_playback_path = nil;
static MobAudioPlayerDelegate *g_player_delegate = nil;

// Forward declarations: defined in the "Scheduled audio playback"
// section below but referenced by nif_audio_stop_playback /
// nif_audio_set_volume above it.
static NSMutableArray *g_scheduled_players;
static dispatch_queue_t g_scheduled_players_queue;

@implementation MobAudioPlayerDelegate
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    NSString *path = g_playback_path;
    ErlNifPid p = g_playback_pid;
    g_audio_player = nil;
    g_playback_path = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      ErlNifEnv *e = enif_alloc_env();
      const char *cpath = path.UTF8String;
      ErlNifBinary pb;
      enif_alloc_binary(strlen(cpath), &pb);
      memcpy(pb.data, cpath, strlen(cpath));
      ERL_NIF_TERM keys[1] = {enif_make_atom(e, "path")};
      ERL_NIF_TERM vals[1] = {enif_make_binary(e, &pb)};
      ERL_NIF_TERM map;
      enif_make_map_from_arrays(e, keys, vals, 1, &map);
      ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "audio"),
                                          enif_make_atom(e, "playback_finished"), map);
      enif_send(NULL, &p, e, msg);
      enif_free_env(e);
    });
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    ErlNifPid p = g_playback_pid;
    NSString *reason = error ? error.localizedDescription : @"decode_error";
    g_audio_player = nil;
    g_playback_path = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      ErlNifEnv *e = enif_alloc_env();
      const char *cr = reason.UTF8String;
      ErlNifBinary rb;
      enif_alloc_binary(strlen(cr), &rb);
      memcpy(rb.data, cr, strlen(cr));
      ERL_NIF_TERM keys[1] = {enif_make_atom(e, "reason")};
      ERL_NIF_TERM vals[1] = {enif_make_binary(e, &rb)};
      ERL_NIF_TERM map;
      enif_make_map_from_arrays(e, keys, vals, 1, &map);
      ERL_NIF_TERM msg =
          enif_make_tuple3(e, enif_make_atom(e, "audio"), enif_make_atom(e, "playback_error"), map);
      enif_send(NULL, &p, e, msg);
      enif_free_env(e);
    });
}
@end

static ERL_NIF_TERM nif_audio_play(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary path_bin, opts_bin;
    if (!enif_inspect_binary(env, argv[0], &path_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &path_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &opts_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &opts_bin))
        return enif_make_badarg(env);

    NSString *path = [[NSString alloc] initWithBytes:path_bin.data
                                              length:path_bin.size
                                            encoding:NSUTF8StringEncoding];
    NSString *opts = [[NSString alloc] initWithBytes:opts_bin.data
                                              length:opts_bin.size
                                            encoding:NSUTF8StringEncoding];

    ErlNifPid pid;
    enif_self(env, &pid);
    g_playback_pid = pid;
    g_playback_path = path;

    dispatch_async(dispatch_get_main_queue(), ^{
      NSDictionary *o =
          [NSJSONSerialization JSONObjectWithData:[opts dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0
                                            error:nil];
      BOOL loop = [o[@"loop"] boolValue];
      double volume = o[@"volume"] ? [o[@"volume"] doubleValue] : 1.0;

      // Stop any in-flight players.
      [g_audio_player stop];
      g_audio_player = nil;
      if (g_av_observer) {
          [[NSNotificationCenter defaultCenter] removeObserver:g_av_observer];
          g_av_observer = nil;
      }
      [g_av_player pause];
      g_av_player = nil;

      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
      [[AVAudioSession sharedInstance] setActive:YES error:nil];

      BOOL isRemote = [path hasPrefix:@"http://"] || [path hasPrefix:@"https://"];
      if (isRemote) {
          // Remote URL — use AVPlayer (AVAudioPlayer cannot stream HTTP).
          NSURL *url = [NSURL URLWithString:path];
          AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
          AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
          player.volume = (float)volume;
          g_av_player = player;

          ErlNifPid p = g_playback_pid;
          NSString *pPath = path;
          g_av_observer = [[NSNotificationCenter defaultCenter]
              addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                          object:item
                           queue:nil
                      usingBlock:^(NSNotification *n) {
                        if (loop) {
                            [g_av_player seekToTime:kCMTimeZero];
                            [g_av_player play];
                        } else {
                            g_av_player = nil;
                            dispatch_async(
                                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                  ErlNifEnv *e = enif_alloc_env();
                                  const char *cp = pPath.UTF8String;
                                  ErlNifBinary pb;
                                  enif_alloc_binary(strlen(cp), &pb);
                                  memcpy(pb.data, cp, strlen(cp));
                                  ERL_NIF_TERM keys[1] = {enif_make_atom(e, "path")};
                                  ERL_NIF_TERM vals[1] = {enif_make_binary(e, &pb)};
                                  ERL_NIF_TERM map;
                                  enif_make_map_from_arrays(e, keys, vals, 1, &map);
                                  enif_send(NULL, &p, e,
                                            enif_make_tuple3(e, enif_make_atom(e, "audio"),
                                                             enif_make_atom(e, "playback_finished"),
                                                             map));
                                  enif_free_env(e);
                                });
                        }
                      }];
          [player play];
          return;
      }

      // Local file — use AVAudioPlayer.
      NSURL *url = [NSURL fileURLWithPath:path];
      NSError *err = nil;
      AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
      if (!player || err) {
          NSString *reason = err ? err.localizedDescription : @"open_failed";
          ErlNifPid p = g_playback_pid;
          dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            ErlNifEnv *e = enif_alloc_env();
            const char *cr = reason.UTF8String;
            ErlNifBinary rb;
            enif_alloc_binary(strlen(cr), &rb);
            memcpy(rb.data, cr, strlen(cr));
            ERL_NIF_TERM keys[1] = {enif_make_atom(e, "reason")};
            ERL_NIF_TERM vals[1] = {enif_make_binary(e, &rb)};
            ERL_NIF_TERM map;
            enif_make_map_from_arrays(e, keys, vals, 1, &map);
            enif_send(NULL, &p, e,
                      enif_make_tuple3(e, enif_make_atom(e, "audio"),
                                       enif_make_atom(e, "playback_error"), map));
            enif_free_env(e);
          });
          return;
      }

      if (!g_player_delegate)
          g_player_delegate = [[MobAudioPlayerDelegate alloc] init];
      player.delegate = g_player_delegate;
      player.volume = (float)volume;
      player.numberOfLoops = loop ? -1 : 0;
      // Enable metering so Mob.Audio.output_level(source: :mob) can read the
      // signal level without a separate tap. Cheap; off by default otherwise.
      player.meteringEnabled = YES;
      g_audio_player = player;
      [player play];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_audio_stop_playback(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [g_audio_player stop];
      g_audio_player = nil;
      if (g_av_observer) {
          [[NSNotificationCenter defaultCenter] removeObserver:g_av_observer];
          g_av_observer = nil;
      }
      [g_av_player pause];
      g_av_player = nil;
      g_playback_path = nil;
      // Stop and drop every scheduled play_at player too.
      if (g_scheduled_players) {
          dispatch_sync(g_scheduled_players_queue, ^{
            for (AVAudioPlayer *p in g_scheduled_players)
                [p stop];
            [g_scheduled_players removeAllObjects];
          });
      }
      [[AVAudioSession sharedInstance] setActive:NO error:nil];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_audio_set_volume(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    double vol = 1.0;
    enif_get_double(env, argv[0], &vol);
    dispatch_async(dispatch_get_main_queue(), ^{
      g_audio_player.volume = (float)vol;
      g_av_player.volume = (float)vol;
      // Mirror onto every currently-scheduled play_at player.
      if (g_scheduled_players) {
          dispatch_sync(g_scheduled_players_queue, ^{
            for (AVAudioPlayer *p in g_scheduled_players)
                p.volume = (float)vol;
          });
      }
    });
    return enif_make_atom(env, "ok");
}

// ── Scheduled audio playback (sample-accurate sync) ────────────────────────
//
// AVAudioPlayer's `-playAtTime:` schedules playback against the audio
// hardware clock (`deviceCurrentTime`). The first `AVAudioEngine` +
// `scheduleBuffer:atTime:` cut of this code crashed the BEAM whenever a
// scheduled buffer hit playback time on a physical iPhone — likely a
// thread / audio-session interaction we never fully diagnosed. The
// `playAtTime:` path is simpler (no engine, no PCM buffers, no
// completionHandler reaching back into Erlang from an audio thread),
// well-documented since iOS 4, and gives the same sample-accurate
// scheduling guarantee.
//
// One `AVAudioPlayer` per scheduled note. The player is retained in a
// global mutable array so ARC doesn't release it before the audio
// hardware reads it; it's removed `duration + 1s` after its scheduled
// fire time.

static NSMutableArray *g_scheduled_players = nil;
static dispatch_queue_t g_scheduled_players_queue = NULL;

static void ensure_scheduled_players(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      g_scheduled_players = [NSMutableArray array];
      g_scheduled_players_queue =
          dispatch_queue_create("mob.audio.scheduled_players", DISPATCH_QUEUE_SERIAL);
    });
}

// audio_play_at(Path, OptsJson, AtWallMs)
//
// Schedules `Path` to begin playback at absolute local wall-clock time
// `AtWallMs` (in `System.system_time(:millisecond)` terms — caller is
// responsible for converting from server time via `Mob.ClockSync` or
// equivalent). Past targets play ASAP.
//
// Successive calls schedule independent players; they mix together. Use
// `audio_stop_playback` to interrupt anything currently in flight.
static ERL_NIF_TERM nif_audio_play_at(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary path_bin, opts_bin, at_bin;

    if (!enif_inspect_binary(env, argv[0], &path_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &path_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &opts_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &opts_bin))
        return enif_make_badarg(env);
    // `at_wall_ms` arrives as a binary string. Marshaling as a string
    // sidesteps cross-platform NIF symbol differences (Mob's Android
    // ERTS build doesn't dynamically export `enif_get_int64`); we keep
    // the iOS side on the same wire format for symmetry.
    if (!enif_inspect_binary(env, argv[2], &at_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[2], &at_bin))
        return enif_make_badarg(env);

    NSString *at_str = [[NSString alloc] initWithBytes:at_bin.data
                                                length:at_bin.size
                                              encoding:NSUTF8StringEncoding];
    int64_t at_wall_ms = (int64_t)at_str.longLongValue;

    NSString *path = [[NSString alloc] initWithBytes:path_bin.data
                                              length:path_bin.size
                                            encoding:NSUTF8StringEncoding];
    NSString *opts_str = [[NSString alloc] initWithBytes:opts_bin.data
                                                  length:opts_bin.size
                                                encoding:NSUTF8StringEncoding];

    dispatch_async(dispatch_get_main_queue(), ^{
      ensure_scheduled_players();

      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
      [[AVAudioSession sharedInstance] setActive:YES error:nil];

      NSDictionary *o =
          [NSJSONSerialization JSONObjectWithData:[opts_str dataUsingEncoding:NSUTF8StringEncoding]
                                          options:0
                                            error:nil];
      double volume = o[@"volume"] ? [o[@"volume"] doubleValue] : 1.0;

      NSURL *url = [NSURL fileURLWithPath:path];
      NSError *err = nil;
      AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
      if (!player || err) {
          NSLog(@"[mob audio] play_at open failed: %@", err);
          return;
      }
      player.volume = (float)volume;
      [player prepareToPlay];

      // Convert wall-clock target → player's audio-clock domain. The
      // player's `deviceCurrentTime` ticks at the audio hardware rate;
      // adding (target_wall - now_wall) seconds gives the corresponding
      // moment on that clock. Time skew between gettimeofday and the
      // audio clock is irrelevant over the few seconds we schedule.
      NSTimeInterval now_device = player.deviceCurrentTime;
      struct timeval tv;
      gettimeofday(&tv, NULL);
      NSTimeInterval now_wall = (NSTimeInterval)tv.tv_sec + (NSTimeInterval)tv.tv_usec / 1e6;
      NSTimeInterval target_wall = (NSTimeInterval)at_wall_ms / 1000.0;
      NSTimeInterval delta = target_wall - now_wall;

      if (delta <= 0) {
          [player play];
      } else {
          NSTimeInterval target_device = now_device + delta;
          [player playAtTime:target_device];
      }

      dispatch_async(g_scheduled_players_queue, ^{
        [g_scheduled_players addObject:player];
      });

      // Release this player after it's done playing. `+ 1.0` provides
      // generous slack so a slightly-late dispatch doesn't release a
      // still-playing player.
      NSTimeInterval clear_after = MAX(0.0, delta) + player.duration + 1.0;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(clear_after * NSEC_PER_SEC)),
                     g_scheduled_players_queue, ^{
                       [g_scheduled_players removeObject:player];
                     });
    });

    return enif_make_atom(env, "ok");
}

// ── Motion sensors ────────────────────────────────────────────────────────

static CMMotionManager *g_motion_manager = nil;
static ErlNifPid g_motion_pid;

// True if `name` appears in the Erlang list of sensor-name binaries (argv[0]).
static bool motion_sensor_requested(ErlNifEnv *env, ERL_NIF_TERM list, const char *name) {
    ERL_NIF_TERM head, tail = list;
    ErlNifBinary bin;
    size_t namelen = strlen(name);
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        if (enif_inspect_binary(env, head, &bin) && bin.size == namelen &&
            memcmp(bin.data, name, namelen) == 0) {
            return true;
        }
    }
    return false;
}

static ERL_NIF_TERM nif_motion_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);
    g_motion_pid = pid;
    int interval_ms = 100;
    // argv[0] is a list of sensor name binaries; argv[1] is interval_ms int
    enif_get_int(env, argv[1], &interval_ms);
    bool want_mag = motion_sensor_requested(env, argv[0], "magnetometer");

    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_motion_manager)
          g_motion_manager = [[CMMotionManager alloc] init];
      NSTimeInterval interval = interval_ms / 1000.0;
      g_motion_manager.deviceMotionUpdateInterval = interval;

      // The magnetic-north reference frame fuses accel+gyro+magnetometer and yields
      // a calibrated field + a heading on the same stream — but only if the device
      // has a magnetometer. Fall back to the plain accel/gyro stream otherwise.
      BOOL magOK = want_mag && ([CMMotionManager availableAttitudeReferenceFrames] &
                                CMAttitudeReferenceFrameXMagneticNorthZVertical);

      CMDeviceMotionHandler handler = ^(CMDeviceMotion *motion, NSError *err) {
        if (!motion)
            return;
        ErlNifPid p = g_motion_pid;
        // Normalize to Android's SensorManager convention so `accel` means the same
        // thing on both platforms:
        //   * units — CoreMotion is in G (~1.0 at rest); Android TYPE_ACCELEROMETER is
        //     m/s² (~9.81). Scale by g (9.80665).
        //   * sign  — Android reports specific force / proper acceleration, a_coord −
        //     g_field, so at rest it reads +g on the axis pointing UP (away from the
        //     ground). CoreMotion splits this into userAcceleration (a_coord) and
        //     gravity (the gravity field vector, pointing DOWN). So the Android-
        //     equivalent reading is userAcceleration − gravity, NOT + gravity (which is
        //     iOS's own "total acceleration" convention, sign-flipped from Android and
        //     what made a tilt-driven UI move backwards). Subtracting gravity matches
        //     Android for both the static tilt term and the dynamic linear term.
        double ax = (motion.userAcceleration.x - motion.gravity.x) * 9.80665;
        double ay = (motion.userAcceleration.y - motion.gravity.y) * 9.80665;
        double az = (motion.userAcceleration.z - motion.gravity.z) * 9.80665;
        double gx = motion.rotationRate.x;
        double gy = motion.rotationRate.y;
        double gz = motion.rotationRate.z;
        ErlNifEnv *e = enif_alloc_env();
        ERL_NIF_TERM accel = enif_make_tuple3(e, enif_make_double(e, ax), enif_make_double(e, ay),
                                              enif_make_double(e, az));
        ERL_NIF_TERM gyro = enif_make_tuple3(e, enif_make_double(e, gx), enif_make_double(e, gy),
                                             enif_make_double(e, gz));
        long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        ERL_NIF_TERM map;
        if (want_mag) {
            // When :magnetometer was requested, always emit the 5-key map so the
            // mag/heading keys are a stable contract — nil when there's no reading
            // (device has no magnetometer, i.e. !magOK, or heading not yet fused).
            ERL_NIF_TERM mag, heading;
            if (magOK) {
                // CoreMotion reports the field in µT; heading is degrees [0,360), or -1.
                CMMagneticField f = motion.magneticField.field;
                double hd = motion.heading;
                mag = enif_make_tuple3(e, enif_make_double(e, f.x), enif_make_double(e, f.y),
                                       enif_make_double(e, f.z));
                heading = (hd >= 0.0) ? enif_make_double(e, hd) : enif_make_atom(e, "nil");
            } else {
                mag = enif_make_atom(e, "nil");
                heading = enif_make_atom(e, "nil");
            }
            ERL_NIF_TERM keys[5] = {enif_make_atom(e, "accel"), enif_make_atom(e, "gyro"),
                                    enif_make_atom(e, "mag"), enif_make_atom(e, "heading"),
                                    enif_make_atom(e, "timestamp")};
            ERL_NIF_TERM vals[5] = {accel, gyro, mag, heading, enif_make_int64(e, ts)};
            enif_make_map_from_arrays(e, keys, vals, 5, &map);
        } else {
            ERL_NIF_TERM keys[3] = {enif_make_atom(e, "accel"), enif_make_atom(e, "gyro"),
                                    enif_make_atom(e, "timestamp")};
            ERL_NIF_TERM vals[3] = {accel, gyro, enif_make_int64(e, ts)};
            enif_make_map_from_arrays(e, keys, vals, 3, &map);
        }
        ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, "motion"), map);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
      };

      if (magOK) {
          [g_motion_manager startDeviceMotionUpdatesUsingReferenceFrame:
                                CMAttitudeReferenceFrameXMagneticNorthZVertical
                                                                toQueue:[NSOperationQueue new]
                                                            withHandler:handler];
      } else {
          [g_motion_manager startDeviceMotionUpdatesToQueue:[NSOperationQueue new]
                                                withHandler:handler];
      }
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_motion_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [g_motion_manager stopDeviceMotionUpdates];
    });
    return enif_make_atom(env, "ok");
}

// ── Notifications ─────────────────────────────────────────────────────────

@implementation MobNotificationDelegate
// Foreground delivery
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))handler {
    handler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
    [self deliverNotification:notification.request.content
                       source:@"local"
                           id:notification.request.identifier];
}
// Tap on notification (foreground or background)
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))handler {
    [self deliverNotification:response.notification.request.content
                       source:@"local"
                           id:response.notification.request.identifier];
    handler();
}
- (void)deliverNotification:(UNNotificationContent *)content
                     source:(NSString *)src
                         id:(NSString *)nid {
    ErlNifPid p = self.screenPid;
    ErlNifEnv *e = enif_alloc_env();
    // Build data map from userInfo
    ERL_NIF_TERM data_map = enif_make_new_map(e);
    NSDictionary *ui = content.userInfo;
    for (NSString *key in ui) {
        id val = ui[key];
        const char *ck = key.UTF8String;
        ERL_NIF_TERM kterm = enif_make_atom(e, ck);
        ERL_NIF_TERM vterm;
        if ([val isKindOfClass:[NSString class]]) {
            const char *cv = [val UTF8String];
            ErlNifBinary b;
            enif_alloc_binary(strlen(cv), &b);
            memcpy(b.data, cv, strlen(cv));
            vterm = enif_make_binary(e, &b);
        } else if ([val isKindOfClass:[NSNumber class]]) {
            vterm = enif_make_int64(e, [val longLongValue]);
        } else {
            vterm = enif_make_atom(e, "nil");
        }
        enif_make_map_put(e, data_map, kterm, vterm, &data_map);
    }
    const char *cid = nid.UTF8String;
    const char *csrc = src.UTF8String;
    ErlNifBinary ib;
    enif_alloc_binary(strlen(cid), &ib);
    memcpy(ib.data, cid, strlen(cid));
    ERL_NIF_TERM keys[3] = {enif_make_atom(e, "id"), enif_make_atom(e, "source"),
                            enif_make_atom(e, "data")};
    ERL_NIF_TERM vals[3] = {enif_make_binary(e, &ib), enif_make_atom(e, csrc), data_map};
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(e, keys, vals, 3, &map);
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, "notification"), map);
    enif_send(NULL, &p, e, msg);
    enif_free_env(e);
}
@end

// Plugin seam (mob_notify): ensure the core-owned notification-center
// delegate exists and point deliveries (foreground present + tap) at pid.
// The scheduling/cancel/register NIFs moved to the mob_notify plugin; the
// DELEGATE, mob_send_push_token (host AppDelegate) and the launch-
// notification handoff stay here. Counterpart of the generated Android
// io.mob.plugin.MobNotifyHub.
void mob_notify_set_screen_pid(ErlNifPid pid) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_notif_delegate) {
          g_notif_delegate = [[MobNotificationDelegate alloc] init];
          [UNUserNotificationCenter currentNotificationCenter].delegate = g_notif_delegate;
      }
      g_notif_delegate.screenPid = pid;
    });
}

// ════════════════════════════════════════════════════════════════════════════
// TEST HARNESS — compiled out of release builds (MOB_RELEASE).
// ════════════════════════════════════════════════════════════════════════════
//
// Everything from here through `nif_swipe_xy` exists for the agent test
// harness (Mob.Test): walk the iOS accessibility tree, query screen
// geometry, synthesize taps/swipes/text input. The synthetic-input NIFs
// reach into UIKit's private `_addTouch:`, `_setHIDEvent:`, `_touchesEvent`,
// `_clearTouches` and friends — which is fine for development and CI but
// gets the binary auto-rejected by the App Store validator (error code 50:
// "non-public selectors").
//
// Mob.Test's Erlang-side functions remain exported in mob_nif.erl; calling
// them in a release build raises `:nif_error` cleanly because the
// nif_funcs[] table further down also wraps the test-harness entries in
// the same `#if !MOB_RELEASE`. That's by design — the test harness isn't
// supposed to work in shipped apps.
#if !MOB_RELEASE

// ── Test harness helpers (a11y walk, nsstring_to_term, AX framework) ───────────
static ERL_NIF_TERM nsstring_to_term(ErlNifEnv *env, NSString *s) {
    if (!s)
        return enif_make_atom(env, "nil");
    const char *utf8 = [s UTF8String];
    if (!utf8)
        return enif_make_atom(env, "nil");
    size_t len = strlen(utf8);
    ErlNifBinary bin;
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    return enif_make_binary(env, &bin);
}

static void walk_a11y(ErlNifEnv *env, id obj, ERL_NIF_TERM *list, int depth) {
    if (!obj || depth > 30)
        return;

    // Collect leaf accessibility elements (visible, interactive, or labelled nodes)
    BOOL isElem = [obj respondsToSelector:@selector(isAccessibilityElement)] &&
                  [(id)obj isAccessibilityElement];
    if (isElem) {
        NSString *label = [obj respondsToSelector:@selector(accessibilityLabel)]
                              ? [(id)obj accessibilityLabel]
                              : nil;
        NSString *value = [obj respondsToSelector:@selector(accessibilityValue)]
                              ? [(id)obj accessibilityValue]
                              : nil;
        UIAccessibilityTraits traits = [obj respondsToSelector:@selector(accessibilityTraits)]
                                           ? [(id)obj accessibilityTraits]
                                           : 0;
        CGRect frame = [obj respondsToSelector:@selector(accessibilityFrame)]
                           ? [(id)obj accessibilityFrame]
                           : CGRectZero;

        const char *type_str = "element";
        if (traits & UIAccessibilityTraitButton)
            type_str = "button";
        else if (traits & UIAccessibilityTraitStaticText)
            type_str = "text";
        else if (traits & UIAccessibilityTraitImage)
            type_str = "image";
        else if (traits & UIAccessibilityTraitHeader)
            type_str = "header";
        else if (traits & UIAccessibilityTraitSearchField)
            type_str = "text_field";

        ERL_NIF_TERM frame_tup = enif_make_tuple4(
            env, enif_make_double(env, frame.origin.x), enif_make_double(env, frame.origin.y),
            enif_make_double(env, frame.size.width), enif_make_double(env, frame.size.height));

        ERL_NIF_TERM elem =
            enif_make_tuple4(env, enif_make_atom(env, type_str), nsstring_to_term(env, label),
                             nsstring_to_term(env, value), frame_tup);

        *list = enif_make_list_cell(env, elem, *list);
    }

    // Walk children via exactly one path to avoid duplicates.
    // Prefer accessibilityElements array, fall back to count/index, then UIView subviews.
    BOOL walked = NO;

    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [(id)obj accessibilityElements];
        if (elems.count > 0) {
            for (id child in elems) {
                if (child && child != obj)
                    walk_a11y(env, child, list, depth + 1);
            }
            walked = YES;
        }
    }

    if (!walked && [obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [(id)obj accessibilityElementCount];
        if (count != NSNotFound && count > 0) {
            for (NSInteger i = 0; i < count; i++) {
                id child = [(id)obj accessibilityElementAtIndex:i];
                if (child && child != obj)
                    walk_a11y(env, child, list, depth + 1);
            }
            walked = YES;
        }
    }

    if (!walked && [obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)obj subviews]) {
            walk_a11y(env, sub, list, depth + 1);
        }
    }
}

// ── NIF: ui_debug/0 — diagnostic: dumps window/view/a11y structure to NSLog ──
static void debug_walk(id obj, int depth) {
    if (!obj || depth > 8)
        return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@"  " startingAtIndex:0];
    NSString *cls = NSStringFromClass([obj class]);
    NSString *label =
        [obj respondsToSelector:@selector(accessibilityLabel)] ? [obj accessibilityLabel] : @"-";
    NSString *value =
        [obj respondsToSelector:@selector(accessibilityValue)] ? [obj accessibilityValue] : @"-";
    BOOL isElem =
        [obj respondsToSelector:@selector(isAccessibilityElement)] && [obj isAccessibilityElement];
    NSInteger a11yCount = [obj respondsToSelector:@selector(accessibilityElementCount)]
                              ? [obj accessibilityElementCount]
                              : -99;
    NSArray *a11yArr = [obj respondsToSelector:@selector(accessibilityElements)]
                           ? [obj accessibilityElements]
                           : nil;
    NSInteger subCount = [obj isKindOfClass:[UIView class]] ? [(UIView *)obj subviews].count : -1;
    NSLog(@"[ui_debug]%@%@ isElem=%d a11yCount=%ld a11yArr=%ld subs=%ld label=%@ value=%@", indent,
          cls, isElem, (long)a11yCount, (long)a11yArr.count, (long)subCount, label, value);
    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger cnt = [obj accessibilityElementCount];
        if (cnt != NSNotFound && cnt > 0) {
            for (NSInteger i = 0; i < cnt; i++)
                debug_walk([obj accessibilityElementAtIndex:i], depth + 1);
        }
    }
    for (id child in [obj respondsToSelector:@selector(accessibilityElements)]
             ? [obj accessibilityElements]
             : @[])
        debug_walk(child, depth + 1);
    if ([obj isKindOfClass:[UIView class]])
        for (UIView *sub in [(UIView *)obj subviews])
            debug_walk(sub, depth + 1);
}

// Walk macOS AXUIElement tree (works because the iOS Simulator IS a macOS process).
// We load ApplicationServices from the Mac host path (not the simulator runtime root).
typedef void *AXUIElementRef_t;
typedef int AXError_t;
typedef void *(*AXUIElementCreateApplicationFn)(pid_t pid);
typedef AXError_t (*AXUIElementCopyAttributeValueFn)(AXUIElementRef_t elem, void *attr,
                                                     void **value);
typedef AXError_t (*AXUIElementCopyAttributeNamesFn)(AXUIElementRef_t elem, void **names);
typedef Boolean (*AXIsProcessTrustedFn)(void);
static void *g_AppSvc = NULL;
static AXUIElementCreateApplicationFn g_AXCreateApp = NULL;
static AXUIElementCopyAttributeValueFn g_AXCopyAttr = NULL;
static AXIsProcessTrustedFn g_AXIsTrusted = NULL;

static NSString *g_ax_load_error = nil;
static void load_ax(void) {
    if (g_AppSvc)
        return;
    // The iOS Simulator is a macOS process. Check if AX symbols are already available
    // in the process image (RTLD_DEFAULT searches all loaded libraries).
    if (dlsym) {
        void *fn = dlsym(RTLD_DEFAULT, "AXUIElementCreateApplication");
        if (fn) {
            g_AppSvc = RTLD_DEFAULT; // sentinel: symbols are available
        } else {
            const char *err = dlerror ? dlerror() : "no dlerror";
            g_ax_load_error =
                [NSString stringWithFormat:@"RTLD_DEFAULT AXUIElementCreateApplication: %s", err];
        }
    }
    if (!g_AppSvc)
        return;
    g_AXCreateApp = (AXUIElementCreateApplicationFn)dlsym(g_AppSvc, "AXUIElementCreateApplication");
    g_AXCopyAttr =
        (AXUIElementCopyAttributeValueFn)dlsym(g_AppSvc, "AXUIElementCopyAttributeValue");
    g_AXIsTrusted = (AXIsProcessTrustedFn)dlsym(g_AppSvc, "AXIsProcessTrusted");
}

static void ax_walk(void *elem, ErlNifEnv *env, ERL_NIF_TERM *list, int depth) {
    if (!elem || depth > 20)
        return;
    // role
    void *role = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXRole"), &role);
    // label
    void *label = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXLabel"), &label);
    // value
    void *value = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXValue"), &value);
    // frame via AXFrame (CFDictionaryRef with x/y/w/h)
    void *frameVal = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXFrame"), &frameVal);

    // Only emit if we have a role (leaf or intermediate)
    if (role) {
        // CF types loaded via dlopen — bridge via CFStringRef intermediate (no ARC transfer)
        NSString *roleStr = (__bridge NSString *)((CFStringRef)role);
        NSString *labelStr = label ? (__bridge NSString *)((CFStringRef)label) : @"";
        NSString *valueStr = value ? (__bridge NSString *)((CFStringRef)value) : @"";
        CGRect frame = CGRectZero;
        if (frameVal) {
            // AXFrame value is an AXValue (AXValueType kAXValueCGRectType == 3)
            typedef Boolean (*AXValueGetValueFn)(CFTypeRef axval, int type, void *out);
            AXValueGetValueFn axGetVal = (AXValueGetValueFn)dlsym(g_AppSvc, "AXValueGetValue");
            if (axGetVal)
                axGetVal((CFTypeRef)frameVal, 3, &frame);
            CFRelease((CFTypeRef)frameVal);
        }
        ERL_NIF_TERM frame_tup = enif_make_tuple4(
            env, enif_make_double(env, frame.origin.x), enif_make_double(env, frame.origin.y),
            enif_make_double(env, frame.size.width), enif_make_double(env, frame.size.height));
        ERL_NIF_TERM elem_tup =
            enif_make_tuple4(env, nsstring_to_term(env, roleStr), nsstring_to_term(env, labelStr),
                             nsstring_to_term(env, valueStr), frame_tup);
        *list = enif_make_list_cell(env, elem_tup, *list);
        if (role)
            CFRelease((CFTypeRef)role);
        if (label)
            CFRelease((CFTypeRef)label);
        if (value)
            CFRelease((CFTypeRef)value);
    }
    // recurse into children
    void *children = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXChildren"), &children);
    if (children) {
        CFIndex count = CFArrayGetCount((CFArrayRef)children);
        for (CFIndex i = 0; i < count; i++) {
            void *child = (void *)CFArrayGetValueAtIndex((CFArrayRef)children, i);
            ax_walk(child, env, list, depth + 1);
        }
        CFRelease((CFTypeRef)children);
    }
}

// ── view-tree walker (no AX activation needed) ───────────────────────────────
//
// Walks UIView.subviews directly instead of going through the accessibility
// subsystem. Returns a nested map per node — the "natural" output of a tree
// walk. No AX activation needed, so this is the path that works without
// VoiceOver toggled on.
//
// Why both ui_tree (AX walk) and ui_view_tree (View walk) coexist:
//   - ui_tree returns a flat list of accessibility leaves; useful when an
//     agent wants the same view of the world VoiceOver/XCUITest see.
//   - ui_view_tree returns the full UIView hierarchy as a nested map,
//     including non-accessible containers, with frames in window coords and
//     the colours actually painted (bg_color / text_color, 0xAARRGGBB).
//     Strict superset of what AX exposes — class names, hidden subviews,
//     things AX wouldn't surface.

static const char *classify_view_type(UIView *view) {
    if ([view isKindOfClass:[UIButton class]])
        return "button";
    if ([view isKindOfClass:[UISwitch class]])
        return "switch";
    if ([view isKindOfClass:[UISlider class]])
        return "slider";
    if ([view isKindOfClass:[UITextField class]])
        return "text_field";
    if ([view isKindOfClass:[UITextView class]])
        return "text_field";
    if ([view isKindOfClass:[UILabel class]])
        return "text";
    if ([view isKindOfClass:[UIImageView class]])
        return "image";
    if ([view isKindOfClass:[UIScrollView class]])
        return "scroll";
    if ([view isKindOfClass:[UIPickerView class]])
        return "picker";
    if ([view isKindOfClass:[UIWindow class]])
        return "window";
    return "view";
}

static NSString *extract_view_text(UIView *view) {
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *t = [btn titleForState:UIControlStateNormal];
        return t.length ? t : btn.titleLabel.text;
    }
    if ([view isKindOfClass:[UILabel class]])
        return ((UILabel *)view).text;
    if ([view isKindOfClass:[UITextField class]])
        return ((UITextField *)view).text;
    if ([view isKindOfClass:[UITextView class]])
        return ((UITextView *)view).text;
    if (view.accessibilityLabel.length)
        return view.accessibilityLabel;
    return nil;
}

// ── Drawn colour extraction for ui_view_tree ─────────────────────────────────
//
// Inverse of color_from_argb: packs a resolved UIColor into the repo's
// canonical 0xAARRGGBB integer (guides/theming.md — alpha first, NOT CSS
// #RRGGBBAA). Returns the atom nil when there is no colour, or when the colour
// is a pattern (or otherwise unconvertible) one with no single RGBA value.
//
// Must run on the main thread: dynamic colours (UIColor.labelColor, anything
// from an asset catalog) resolve against the current trait collection.
static ERL_NIF_TERM argb_term_from_uicolor(ErlNifEnv *env, UIColor *color) {
    if (!color)
        return enif_make_atom(env, "nil");
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a])
        return enif_make_atom(env, "nil");
    // Wide-gamut (Display P3) colours can land outside 0..1 once converted to
    // sRGB components; clamp so the packed byte is always in range.
    CGFloat comps[4] = {a, r, g, b};
    unsigned long argb = 0;
    for (int i = 0; i < 4; i++) {
        CGFloat c = comps[i] < 0 ? 0 : (comps[i] > 1 ? 1 : comps[i]);
        argb = (argb << 8) | (unsigned long)(c * 255.0 + 0.5);
    }
    return enif_make_ulong(env, argb);
}

// ── Where the paint actually lives ───────────────────────────────────────────
//
// UIKit puts colour on the view (`UILabel.textColor`, `UIView.backgroundColor`).
// SwiftUI mostly doesn't: `.background(Color, in: shape)` and `.foregroundColor`
// (which is what `MobRootView` uses for every Box and Text) go through SwiftUI's
// own renderer, and the resulting colour lands on a CALayer — usually a
// CAShapeLayer fill — hanging off a structural view whose own backgroundColor
// stays nil. Reading only the view is why a 443-node dump came back with two
// colours, both system chrome.
//
// So each node harvests from its own layer subtree as well. A view's
// `layer.sublayers` includes its subviews' layers; those are excluded so a
// container never claims a child's paint as its own.

// Depth cap: SwiftUI stacks a handful of layers per view, never dozens. Bounding
// the walk keeps ui_view_tree's cost linear in views, not in the whole layer graph.
#define MOB_LAYER_WALK_DEPTH 6

static BOOL mob_all_gradient_stops_equal(CAGradientLayer *gradient) {
    if (gradient.colors.count < 2)
        return YES;
    id first = gradient.colors.firstObject;
    for (id c in gradient.colors) {
        if (!CGColorEqualToColor((__bridge CGColorRef)c, (__bridge CGColorRef)first))
            return NO;
    }
    return YES;
}

// The single colour this layer paints, or NULL. A gradient with distinct stops
// has no single colour, so it reports none rather than inventing one from a stop.
static CGColorRef mob_layer_fill_color(CALayer *layer) {
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CGColorRef fill = ((CAShapeLayer *)layer).fillColor;
        if (fill && CGColorGetAlpha(fill) > 0)
            return fill;
    }
    if ([layer isKindOfClass:[CAGradientLayer class]]) {
        CAGradientLayer *gradient = (CAGradientLayer *)layer;
        if (gradient.colors.count && mob_all_gradient_stops_equal(gradient))
            return (__bridge CGColorRef)gradient.colors.firstObject;
    }
    if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0)
        return layer.backgroundColor;
    return NULL;
}

static CGColorRef mob_layer_text_color(CALayer *layer) {
    if ([layer isKindOfClass:[CATextLayer class]])
        return ((CATextLayer *)layer).foregroundColor;
    return NULL;
}

typedef CGColorRef (*MobLayerColorFn)(CALayer *);

// First colour `probe` finds in this layer subtree, skipping layers owned by
// subviews (they are visited as their own nodes).
static CGColorRef mob_walk_layers(CALayer *layer, NSSet *subviewLayers, MobLayerColorFn probe,
                                  int depth) {
    if (!layer || depth > MOB_LAYER_WALK_DEPTH)
        return NULL;
    CGColorRef own = probe(layer);
    if (own)
        return own;
    for (CALayer *sub in layer.sublayers) {
        if ([subviewLayers containsObject:sub])
            continue;
        CGColorRef found = mob_walk_layers(sub, subviewLayers, probe, depth + 1);
        if (found)
            return found;
    }
    return NULL;
}

static NSSet *mob_subview_layers(UIView *view) {
    NSMutableSet *layers = [NSMutableSet setWithCapacity:view.subviews.count];
    for (UIView *sub in view.subviews) {
        if (sub.layer)
            [layers addObject:sub.layer];
    }
    return layers;
}

static ERL_NIF_TERM extract_view_bg_color(ErlNifEnv *env, UIView *view) {
    if (view.backgroundColor && CGColorGetAlpha(view.backgroundColor.CGColor) > 0)
        return argb_term_from_uicolor(env, view.backgroundColor);
    CGColorRef painted =
        mob_walk_layers(view.layer, mob_subview_layers(view), mob_layer_fill_color, 0);
    if (painted)
        return argb_term_from_uicolor(env, [UIColor colorWithCGColor:painted]);
    return enif_make_atom(env, "nil");
}

static ERL_NIF_TERM extract_view_text_color(ErlNifEnv *env, UIView *view) {
    if ([view isKindOfClass:[UILabel class]])
        return argb_term_from_uicolor(env, ((UILabel *)view).textColor);
    if ([view isKindOfClass:[UITextField class]])
        return argb_term_from_uicolor(env, ((UITextField *)view).textColor);
    if ([view isKindOfClass:[UITextView class]])
        return argb_term_from_uicolor(env, ((UITextView *)view).textColor);
    if ([view isKindOfClass:[UIButton class]])
        return argb_term_from_uicolor(env,
                                      [(UIButton *)view titleColorForState:UIControlStateNormal]);
    CGColorRef painted =
        mob_walk_layers(view.layer, mob_subview_layers(view), mob_layer_text_color, 0);
    if (painted)
        return argb_term_from_uicolor(env, [UIColor colorWithCGColor:painted]);
    return enif_make_atom(env, "nil");
}

static ERL_NIF_TERM build_view_node(ErlNifEnv *env, UIView *view, int depth) {
    if (!view || depth > 50)
        return enif_make_atom(env, "nil");

    CGRect win_frame = [view convertRect:view.bounds toView:nil];
    NSString *text = extract_view_text(view);
    NSString *value = view.accessibilityValue;
    const char *type_str = classify_view_type(view);

    ERL_NIF_TERM frame = enif_make_tuple4(
        env, enif_make_double(env, win_frame.origin.x), enif_make_double(env, win_frame.origin.y),
        enif_make_double(env, win_frame.size.width), enif_make_double(env, win_frame.size.height));

    NSArray *subs = view.subviews;
    ERL_NIF_TERM children = enif_make_list(env, 0);
    for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
        ERL_NIF_TERM child = build_view_node(env, subs[i], depth + 1);
        children = enif_make_list_cell(env, child, children);
    }

    // `class` is the concrete UIView subclass. On SwiftUI it's the only thing
    // that says what a node actually is (`type` collapses everything unknown to
    // "view"), and it's what tells you which renderer drew a node when a colour
    // comes back nil.
    ERL_NIF_TERM keys[8] = {enif_make_atom(env, "type"),       enif_make_atom(env, "class"),
                            enif_make_atom(env, "label"),      enif_make_atom(env, "value"),
                            enif_make_atom(env, "frame"),      enif_make_atom(env, "bg_color"),
                            enif_make_atom(env, "text_color"), enif_make_atom(env, "children")};
    ERL_NIF_TERM vals[8] = {enif_make_atom(env, type_str),
                            nsstring_to_term(env, NSStringFromClass(object_getClass(view))),
                            nsstring_to_term(env, text),
                            nsstring_to_term(env, value),
                            frame,
                            extract_view_bg_color(env, view),
                            extract_view_text_color(env, view),
                            children};
    ERL_NIF_TERM result;
    enif_make_map_from_arrays(env, keys, vals, 8, &result);
    return result;
}

static ERL_NIF_TERM nif_ui_view_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block ERL_NIF_TERM windows_list = enif_make_list(env, 0);
    __block CGSize screen_size = CGSizeZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
      screen_size = [UIScreen mainScreen].bounds.size;
      NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
      for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
          if (![s isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *w in [(UIWindowScene *)s windows]) {
              if (!w.isHidden)
                  [wins addObject:w];
          }
      }
      for (NSInteger i = (NSInteger)wins.count - 1; i >= 0; i--) {
          ERL_NIF_TERM wnode = build_view_node(env, wins[i], 0);
          windows_list = enif_make_list_cell(env, wnode, windows_list);
      }
    });

    // Synthetic root wrapping all top-level windows. Frame is the screen size
    // so consumers always have a valid bounding box for the whole UI.
    // The synthetic root paints nothing and has no class, so those are always
    // nil — but the keys are present so consumers can read them on any node.
    ERL_NIF_TERM root_keys[8] = {
        enif_make_atom(env, "type"),       enif_make_atom(env, "class"),
        enif_make_atom(env, "label"),      enif_make_atom(env, "value"),
        enif_make_atom(env, "frame"),      enif_make_atom(env, "bg_color"),
        enif_make_atom(env, "text_color"), enif_make_atom(env, "children")};
    ERL_NIF_TERM root_vals[8] = {enif_make_atom(env, "root"),
                                 enif_make_atom(env, "nil"),
                                 enif_make_atom(env, "nil"),
                                 enif_make_atom(env, "nil"),
                                 enif_make_tuple4(env, enif_make_double(env, 0.0),
                                                  enif_make_double(env, 0.0),
                                                  enif_make_double(env, screen_size.width),
                                                  enif_make_double(env, screen_size.height)),
                                 enif_make_atom(env, "nil"),
                                 enif_make_atom(env, "nil"),
                                 windows_list};
    ERL_NIF_TERM root;
    enif_make_map_from_arrays(env, root_keys, root_vals, 8, &root);
    return root;
}

// ── ui_paint_debug/0 — census of where colour lives in this app's view tree ──
//
// When ui_view_tree reports nil colours you need to know *why* before changing
// the extractor: which view classes the renderer produced, what layers hang off
// them, and which colour-bearing properties are actually set. Guessing at
// SwiftUI's private class names across device rebuilds is the slow way to find
// that out; this answers it in one RPC.
//
// Returns a JSON binary, grouped by (view class, layer class, sublayer classes)
// with a count and a tally of which paint properties were non-nil in that group:
//
//   {"total_views":443,
//    "groups":[{"view":"SwiftUI.CGDrawingView","layer":"SwiftUI.CGDrawingLayer",
//               "sublayers":["CAShapeLayer"],"count":40,
//               "view_bg":0,"layer_bg":0,"shape_fill":40,"gradient":0,
//               "text_layer_fg":0,"uikit_text":0,"has_contents":40}, ...]}
//
// Read it as: for these 40 views, colour is only in CAShapeLayer.fillColor, so
// that is what the extractor has to read.
static void mob_paint_census(UIView *view, NSMutableDictionary *groups, int depth) {
    if (!view || depth > 50)
        return;

    NSMutableArray<NSString *> *sublayerClasses = [NSMutableArray array];
    NSSet *ownedBySubviews = mob_subview_layers(view);
    BOOL shapeFill = NO, gradient = NO, textLayerFg = NO, layerBg = NO, contents = NO;
    for (CALayer *sub in view.layer.sublayers) {
        if ([ownedBySubviews containsObject:sub])
            continue;
        NSString *cls = NSStringFromClass(object_getClass(sub));
        if (![sublayerClasses containsObject:cls])
            [sublayerClasses addObject:cls];
        if ([sub isKindOfClass:[CAShapeLayer class]] && ((CAShapeLayer *)sub).fillColor)
            shapeFill = YES;
        if ([sub isKindOfClass:[CAGradientLayer class]] && ((CAGradientLayer *)sub).colors.count)
            gradient = YES;
        if ([sub isKindOfClass:[CATextLayer class]] && ((CATextLayer *)sub).foregroundColor)
            textLayerFg = YES;
        if (sub.backgroundColor)
            layerBg = YES;
        if (sub.contents)
            contents = YES;
    }
    if (view.layer.backgroundColor)
        layerBg = YES;
    if (view.layer.contents)
        contents = YES;
    if ([view.layer isKindOfClass:[CAShapeLayer class]] && ((CAShapeLayer *)view.layer).fillColor)
        shapeFill = YES;

    BOOL uikitText =
        [view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UITextField class]] ||
        [view isKindOfClass:[UITextView class]] || [view isKindOfClass:[UIButton class]];

    NSString *viewClass = NSStringFromClass(object_getClass(view));
    NSString *layerClass = NSStringFromClass(object_getClass(view.layer));
    NSArray *sortedSublayers = [sublayerClasses sortedArrayUsingSelector:@selector(compare:)];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", viewClass, layerClass,
                                               [sortedSublayers componentsJoinedByString:@","]];

    NSMutableDictionary *group = groups[key];
    if (!group) {
        group = [NSMutableDictionary dictionaryWithDictionary:@{
            @"view" : viewClass,
            @"layer" : layerClass,
            @"sublayers" : sortedSublayers,
            @"count" : @0,
            @"view_bg" : @0,
            @"layer_bg" : @0,
            @"shape_fill" : @0,
            @"gradient" : @0,
            @"text_layer_fg" : @0,
            @"uikit_text" : @0,
            @"has_contents" : @0
        }];
        groups[key] = group;
    }
    group[@"count"] = @([group[@"count"] intValue] + 1);
    if (view.backgroundColor)
        group[@"view_bg"] = @([group[@"view_bg"] intValue] + 1);
    if (layerBg)
        group[@"layer_bg"] = @([group[@"layer_bg"] intValue] + 1);
    if (shapeFill)
        group[@"shape_fill"] = @([group[@"shape_fill"] intValue] + 1);
    if (gradient)
        group[@"gradient"] = @([group[@"gradient"] intValue] + 1);
    if (textLayerFg)
        group[@"text_layer_fg"] = @([group[@"text_layer_fg"] intValue] + 1);
    if (uikitText)
        group[@"uikit_text"] = @([group[@"uikit_text"] intValue] + 1);
    if (contents)
        group[@"has_contents"] = @([group[@"has_contents"] intValue] + 1);

    for (UIView *sub in view.subviews)
        mob_paint_census(sub, groups, depth + 1);
}

static ERL_NIF_TERM nif_ui_paint_debug(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    __block NSData *jsonData = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      NSMutableDictionary *groups = [NSMutableDictionary dictionary];
      for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
          if (![s isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *w in [(UIWindowScene *)s windows]) {
              if (!w.isHidden)
                  mob_paint_census(w, groups, 0);
          }
      }
      int total = 0;
      for (NSDictionary *g in groups.allValues)
          total += [g[@"count"] intValue];
      NSArray *sorted = [groups.allValues
          sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"count"] compare:a[@"count"]];
          }];
      jsonData = [NSJSONSerialization dataWithJSONObject:@{
          @"total_views" : @(total),
          @"groups" : sorted
      }
                                                 options:0
                                                   error:nil];
    });

    if (!jsonData)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "encode_failed"));
    ErlNifBinary bin;
    if (!enif_alloc_binary(jsonData.length, &bin))
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "alloc_failed"));
    memcpy(bin.data, jsonData.bytes, jsonData.length);
    return enif_make_binary(env, &bin);
}

// ── screen_info/0 — unified screen/safe-area shape ───────────────────────────
//
// Returns: %{width, height, scale, safe_area: %{top, bottom, left, right}}
// Width/height are in logical points (already pre-divided by scale on iOS).
// Android returns the equivalent with px→dp conversion done in the JNI layer.
static ERL_NIF_TERM nif_screen_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block CGRect bounds = CGRectZero;
    __block CGFloat scale = 1.0;
    __block UIEdgeInsets insets = UIEdgeInsetsZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIScreen *screen = [UIScreen mainScreen];
      bounds = screen.bounds;
      scale = screen.scale;
      // Pull safe-area from the first visible window we find.
      for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
          if (![s isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *w in [(UIWindowScene *)s windows]) {
              if (!w.isHidden) {
                  insets = w.safeAreaInsets;
                  goto done;
              }
          }
      }
  done:;
    });

    ERL_NIF_TERM sa_keys[4] = {enif_make_atom(env, "top"), enif_make_atom(env, "bottom"),
                               enif_make_atom(env, "left"), enif_make_atom(env, "right")};
    ERL_NIF_TERM sa_vals[4] = {
        enif_make_double(env, insets.top), enif_make_double(env, insets.bottom),
        enif_make_double(env, insets.left), enif_make_double(env, insets.right)};
    ERL_NIF_TERM safe_area;
    enif_make_map_from_arrays(env, sa_keys, sa_vals, 4, &safe_area);

    ERL_NIF_TERM keys[4] = {enif_make_atom(env, "width"), enif_make_atom(env, "height"),
                            enif_make_atom(env, "scale"), enif_make_atom(env, "safe_area")};
    ERL_NIF_TERM vals[4] = {enif_make_double(env, bounds.size.width),
                            enif_make_double(env, bounds.size.height), enif_make_double(env, scale),
                            safe_area};
    ERL_NIF_TERM result;
    enif_make_map_from_arrays(env, keys, vals, 4, &result);
    return result;
}

// ── Test harness (ui_tree, tap, tap_xy, type_text, swipe_xy, etc.) ─────────────
static ERL_NIF_TERM nif_ui_debug(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    load_ax();

    __block ERL_NIF_TERM result = enif_make_list(env, 0);
    // Probe via macOS AXUIElement — runs on NIF thread, no main-queue needed.
    Boolean trusted = g_AXIsTrusted ? g_AXIsTrusted() : NO;
    ERL_NIF_TERM trusted_t = enif_make_atom(env, trusted ? "trusted" : "not_trusted");
    ERL_NIF_TERM appsvc_t = enif_make_atom(env, g_AppSvc ? "loaded" : "not_loaded");
    result = enif_make_list_cell(env,
                                 enif_make_tuple2(env, enif_make_atom(env, "ax_status"),
                                                  enif_make_tuple2(env, appsvc_t, trusted_t)),
                                 result);
    if (g_ax_load_error) {
        result = enif_make_list_cell(env, nsstring_to_term(env, g_ax_load_error), result);
    }

    if (g_AXCreateApp && g_AXCopyAttr && trusted) {
        void *appElem = g_AXCreateApp(getpid());
        if (appElem) {
            ax_walk(appElem, env, &result, 0);
            CFRelease((CFTypeRef)appElem);
        }
    }

    ERL_NIF_TERM reversed;
    enif_make_reverse_list(env, result, &reversed);
    return reversed;
}

// ensure_a11y_enabled: no-op in the NIF itself.
// Accessibility must be activated from the Mac side before calling ui_tree():
//   xcrun simctl spawn <udid> defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool
//   YES xcrun simctl spawn <udid> notifyutil -p com.apple.accessibility.voiceover.status.changed
// pegleg_dev's `mix mob.connect` will do this automatically.
static void ensure_a11y_enabled(void) {
}

static ERL_NIF_TERM nif_ui_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block ERL_NIF_TERM list = enif_make_list(env, 0);
    dispatch_sync(dispatch_get_main_queue(), ^{
      ensure_a11y_enabled();
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *window in [(UIWindowScene *)scene windows]) {
              if (window.isHidden)
                  continue;
              walk_a11y(env, window, &list, 0);
          }
      }
    });
    ERL_NIF_TERM reversed;
    enif_make_reverse_list(env, list, &reversed);
    return reversed;
}

// ─── tap/1 — activate element by accessibility label (PUBLIC API) ─────────────
//
// Walks the same a11y tree as ui_tree() and calls -accessibilityActivate on the
// first element whose accessibilityLabel matches the given binary string.
//
// -accessibilityActivate is fully public (UIAccessibilityAction protocol, iOS 4+).
// For SwiftUI buttons it fires the button's action. The app cannot tell this from
// a real tap, though it bypasses the touch event system entirely (no gesture
// recognizer involvement, no UITouch objects).
//
// Use this for Phase 2 (driving apps from tests). For interactions that require
// real UITouch events (custom gesture recognizers, scroll view momentum, etc.)
// use tap_xy/2 instead.

// Returns the deepest accessibility element whose frame contains 'pt'.
// Walks children depth-first (deepest/most-specific match wins).
static id find_a11y_at_point(id obj, CGPoint pt, int depth) {
    if (!obj || depth > 30)
        return nil;

    // Recurse into children first (deepest match wins)
    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [(id)obj accessibilityElements];
        if (elems.count > 0) {
            for (id child in elems) {
                if (child && child != obj) {
                    id found = find_a11y_at_point(child, pt, depth + 1);
                    if (found)
                        return found;
                }
            }
            goto check_self;
        }
    }
    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [(id)obj accessibilityElementCount];
        if (count != NSNotFound && count > 0) {
            for (NSInteger i = 0; i < count; i++) {
                id child = [(id)obj accessibilityElementAtIndex:i];
                if (child && child != obj) {
                    id found = find_a11y_at_point(child, pt, depth + 1);
                    if (found)
                        return found;
                }
            }
            goto check_self;
        }
    }
    if ([obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)obj subviews]) {
            id found = find_a11y_at_point(sub, pt, depth + 1);
            if (found)
                return found;
        }
    }

check_self:
    if ([obj respondsToSelector:@selector(isAccessibilityElement)] &&
        [(id)obj isAccessibilityElement] &&
        [obj respondsToSelector:@selector(accessibilityFrame)]) {
        CGRect frame = [(id)obj accessibilityFrame];
        if (CGRectContainsPoint(frame, pt))
            return obj;
    }
    return nil;
}

// Single attempt: search every window in every connected scene for an
// accessibility element at `pt`. No retry, no dispatch of its own — callers
// run this from inside their own dispatch_sync (see mob_retry_main_thread_*
// below), so a retry never has to re-derive "the" window independently of
// where the element was actually found (MOB-99 review: a second, separate
// window scan for post-processing could resolve a different window than
// the one the element came from, e.g. with an overlapping keyboard window).
static id find_a11y_at_point_in_current_windows(CGPoint pt, UIWindow *_Nullable *out_window) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *win in [(UIWindowScene *)scene windows]) {
            if (win.isHidden)
                continue;
            id elem = find_a11y_at_point(win, pt, 0);
            if (elem) {
                if (out_window)
                    *out_window = win;
                return elem;
            }
        }
    }
    return nil;
}

// Retry tuning for point-based accessibility lookups (MOB-99): SwiftUI's
// accessibility tree can lag a layout/navigation pass by a run loop tick or
// more — a synthetic tap issued the instant a screen mounts (the common
// automated-test pattern) can race it, even though the element's *frame*
// (tracked separately via MobFrameTracker's GeometryReader callback — see
// mob_register_frame) is already correct by then. Unrelated to the ~500ms
// settle delay mob_dev waits after activating VoiceOver post-connect
// (CLAUDE.md) — that's a one-time per-session propagation wait; this is a
// per-call retry ceiling, deliberately much shorter.
static const int kA11yLookupMaxAttempts = 4;
static const NSTimeInterval kA11yLookupRetryDelay = 0.05;

typedef BOOL (^MobRetryBlock)(void);

// Retries `attempt` on the main thread up to kA11yLookupMaxAttempts times,
// kA11yLookupRetryDelay apart, stopping at the first YES. `attempt` must do
// its own find-then-act atomically inside the one dispatch_sync call it
// runs in — never split "find" and "act" across two separate dispatch_sync
// calls (with a retry-sleep gap between them), or a later attempt can act
// on a window/element resolved by an earlier, now-stale attempt.
//
// The retry sleep happens on the CALLING (NIF) thread between dispatch_sync
// calls, never inside one: sleeping on the main thread blocks the run loop
// SwiftUI needs to finish building the tree, guaranteeing the wait never
// resolves.
//
// Use when "found" and "succeeded" are the same signal (tap_xy,
// long_press_xy's atomic find+act-or-fallback). See
// mob_retry_main_thread_found_action below when they need to be told apart
// — e.g. ax_action_at_xy, where "found an element that doesn't support this
// action" is a stable outcome that retrying won't change, unlike "nothing
// at this point yet."
static BOOL mob_retry_main_thread_bool(const char *label, MobRetryBlock attempt) {
    for (int i = 0; i < kA11yLookupMaxAttempts; i++) {
        if (i > 0)
            [NSThread sleepForTimeInterval:kA11yLookupRetryDelay];

        __block BOOL ok = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
          ok = attempt();
        });
        if (ok) {
            if (i > 0)
                LOGI(@"%s: succeeded on attempt %d/%d", label, i + 1, kA11yLookupMaxAttempts);
            return YES;
        }
    }
    LOGI(@"%s: nothing found after %d attempts (~%dms)", label, kA11yLookupMaxAttempts,
         (int)((kA11yLookupMaxAttempts - 1) * kA11yLookupRetryDelay * 1000));
    return NO;
}

typedef BOOL (^MobFoundActionBlock)(BOOL *found);

// Same retry shape as mob_retry_main_thread_bool, but distinguishes "not
// found yet" (worth retrying) from "found, but the requested action isn't
// supported or failed" (a stable outcome, not a timing race — retrying
// won't change whether accessibilityIncrement exists on this element).
// Stops retrying as soon as *found is YES on an attempt, regardless of
// that attempt's own action result; *out_found tells the caller which
// terminal case it landed in.
static BOOL mob_retry_main_thread_found_action(const char *label, BOOL *out_found,
                                               MobFoundActionBlock attempt) {
    for (int i = 0; i < kA11yLookupMaxAttempts; i++) {
        if (i > 0)
            [NSThread sleepForTimeInterval:kA11yLookupRetryDelay];

        __block BOOL found = NO;
        __block BOOL ok = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
          ok = attempt(&found);
        });
        if (found) {
            if (i > 0)
                LOGI(@"%s: found on attempt %d/%d", label, i + 1, kA11yLookupMaxAttempts);
            *out_found = YES;
            return ok;
        }
    }
    LOGI(@"%s: nothing found after %d attempts (~%dms)", label, kA11yLookupMaxAttempts,
         (int)((kA11yLookupMaxAttempts - 1) * kA11yLookupRetryDelay * 1000));
    *out_found = NO;
    return NO;
}

static id find_a11y_by_label(id obj, NSString *target, int depth) {
    if (!obj || depth > 30)
        return nil;

    if ([obj respondsToSelector:@selector(isAccessibilityElement)] &&
        [(id)obj isAccessibilityElement]) {
        NSString *lbl = [obj respondsToSelector:@selector(accessibilityLabel)]
                            ? [(id)obj accessibilityLabel]
                            : nil;
        if ([lbl isEqualToString:target])
            return obj;
    }

    // Walk children via the same single-path logic as walk_a11y() to avoid duplicates.
    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [(id)obj accessibilityElements];
        if (elems.count > 0) {
            for (id child in elems) {
                if (child && child != obj) {
                    id found = find_a11y_by_label(child, target, depth + 1);
                    if (found)
                        return found;
                }
            }
            return nil;
        }
    }
    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [(id)obj accessibilityElementCount];
        if (count != NSNotFound && count > 0) {
            for (NSInteger i = 0; i < count; i++) {
                id child = [(id)obj accessibilityElementAtIndex:i];
                if (child && child != obj) {
                    id found = find_a11y_by_label(child, target, depth + 1);
                    if (found)
                        return found;
                }
            }
            return nil;
        }
    }
    if ([obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)obj subviews]) {
            id found = find_a11y_by_label(sub, target, depth + 1);
            if (found)
                return found;
        }
    }
    return nil;
}

static ERL_NIF_TERM nif_tap(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // Accept Elixir binary strings (the normal case)
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString *label = [[NSString alloc] initWithBytes:bin.data
                                               length:bin.size
                                             encoding:NSUTF8StringEncoding];
    if (!label)
        return enif_make_badarg(env);

    __block BOOL activated = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *window in [(UIWindowScene *)scene windows]) {
              if (window.isHidden)
                  continue;
              id elem = find_a11y_by_label(window, label, 0);
              if (elem) {
                  [elem accessibilityActivate];
                  activated = YES;
                  return;
              }
          }
      }
    });

    if (activated)
        return enif_make_atom(env, "ok");
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "not_found"));
}

// ── ax_action/2 — invoke an accessibility action on an element ────────────────
//
// Finds the first AX element whose label OR value contains `match`, then sends
// the action selector for `action`. Useful for controls where synthetic touches
// don't reach the gesture recognizer (sliders, scrolls, modal escapes, etc.).
//
// Supported actions:
//   :increment        → accessibilityIncrement (sliders, steppers, pickers)
//   :decrement        → accessibilityDecrement
//   :activate         → accessibilityActivate (same as tap/1, here for symmetry)
//   :escape           → accessibilityPerformEscape (dismiss popovers/sheets)
//   :scroll_up        → accessibilityScroll: with UIAccessibilityScrollDirectionUp
//   :scroll_down      → ... Direction Down
//   :scroll_left      → ... Direction Left
//   :scroll_right     → ... Direction Right
//
// Returns: :ok | {:error, :not_found} | {:error, :unsupported_action}
//          | {:error, :action_failed}
//
// IMPORTANT: this requires accessibility to be activated (VoiceOver on, or
// similar AX-client toggle). Same constraint as ui_tree/0.
static id find_a11y_by_label_or_value(id obj, NSString *target, int depth) {
    if (!obj || depth > 30)
        return nil;

    if ([obj respondsToSelector:@selector(isAccessibilityElement)] &&
        [(id)obj isAccessibilityElement]) {
        NSString *lbl = [obj respondsToSelector:@selector(accessibilityLabel)]
                            ? [(id)obj accessibilityLabel]
                            : nil;
        NSString *val = [obj respondsToSelector:@selector(accessibilityValue)]
                            ? [(id)obj accessibilityValue]
                            : nil;
        if ((lbl && [lbl rangeOfString:target].location != NSNotFound) ||
            (val && [val rangeOfString:target].location != NSNotFound)) {
            return obj;
        }
    }

    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [(id)obj accessibilityElements];
        if (elems.count > 0) {
            for (id child in elems) {
                if (child && child != obj) {
                    id found = find_a11y_by_label_or_value(child, target, depth + 1);
                    if (found)
                        return found;
                }
            }
            return nil;
        }
    }
    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [(id)obj accessibilityElementCount];
        if (count != NSNotFound && count > 0) {
            for (NSInteger i = 0; i < count; i++) {
                id child = [(id)obj accessibilityElementAtIndex:i];
                if (child && child != obj) {
                    id found = find_a11y_by_label_or_value(child, target, depth + 1);
                    if (found)
                        return found;
                }
            }
            return nil;
        }
    }
    if ([obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)obj subviews]) {
            id found = find_a11y_by_label_or_value(sub, target, depth + 1);
            if (found)
                return found;
        }
    }
    return nil;
}

static ERL_NIF_TERM nif_ax_action(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString *match = [[NSString alloc] initWithBytes:bin.data
                                               length:bin.size
                                             encoding:NSUTF8StringEncoding];
    if (!match)
        return enif_make_badarg(env);

    char action_buf[32] = {0};
    if (!enif_get_atom(env, argv[1], action_buf, sizeof(action_buf), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    NSString *action = [NSString stringWithUTF8String:action_buf];

    __block id elem = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              elem = find_a11y_by_label_or_value(win, match, 0);
              if (elem)
                  return;
          }
      }
    });

    if (!elem)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "not_found"));

    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      if ([action isEqualToString:@"increment"]) {
          if ([elem respondsToSelector:@selector(accessibilityIncrement)]) {
              [elem accessibilityIncrement];
              ok = YES;
          }
      } else if ([action isEqualToString:@"decrement"]) {
          if ([elem respondsToSelector:@selector(accessibilityDecrement)]) {
              [elem accessibilityDecrement];
              ok = YES;
          }
      } else if ([action isEqualToString:@"activate"]) {
          if ([elem respondsToSelector:@selector(accessibilityActivate)]) {
              ok = [elem accessibilityActivate];
          }
      } else if ([action isEqualToString:@"escape"]) {
          if ([elem respondsToSelector:@selector(accessibilityPerformEscape)]) {
              ok = [elem accessibilityPerformEscape];
          }
      } else if ([action hasPrefix:@"scroll_"]) {
          NSString *dir_str = [action substringFromIndex:7];
          UIAccessibilityScrollDirection dir = 0;
          if ([dir_str isEqualToString:@"up"])
              dir = UIAccessibilityScrollDirectionUp;
          else if ([dir_str isEqualToString:@"down"])
              dir = UIAccessibilityScrollDirectionDown;
          else if ([dir_str isEqualToString:@"left"])
              dir = UIAccessibilityScrollDirectionLeft;
          else if ([dir_str isEqualToString:@"right"])
              dir = UIAccessibilityScrollDirectionRight;
          if (dir && [elem respondsToSelector:@selector(accessibilityScroll:)]) {
              ok = [elem accessibilityScroll:dir];
          }
      }
    });

    if (ok)
        return enif_make_atom(env, "ok");
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "action_failed"));
}

// ── ax_action_at_xy/3 — invoke an AX action on whatever element is at (x, y) ──
//
// Useful when label/value substring matching can't disambiguate (e.g. multiple
// sliders that all read "50%", a toggle whose accessibility label is empty).
// Caller looks up coordinates from `ui_tree/0` and points at the exact element.
//
// Returns: same as ax_action/2.
static ERL_NIF_TERM nif_ax_action_at_xy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    double x, y;
    if (!enif_get_double(env, argv[0], &x) || !enif_get_double(env, argv[1], &y))
        return enif_make_badarg(env);

    char action_buf[32] = {0};
    if (!enif_get_atom(env, argv[2], action_buf, sizeof(action_buf), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    NSString *action = [NSString stringWithUTF8String:action_buf];

    CGPoint pt = CGPointMake((CGFloat)x, (CGFloat)y);

    // Find-then-act atomically inside ONE dispatch_sync per attempt (see
    // mob_retry_main_thread_found_action) — a separate find/act split with
    // a retry-sleep gap between them let a UITableView/UICollectionView
    // cell get recycled for a different row in that gap, silently firing
    // the action on the wrong item while still returning :ok (MOB-98
    // review). "Found but action unsupported" is a stable outcome — the
    // helper only retries the "not found yet" case.
    BOOL found = NO;
    BOOL ok = mob_retry_main_thread_found_action("ax_action_at_xy", &found, ^BOOL(BOOL *out_found) {
      id elem = find_a11y_at_point_in_current_windows(pt, NULL);
      if (!elem) {
          *out_found = NO;
          return NO;
      }
      *out_found = YES;

      if ([action isEqualToString:@"increment"]) {
          if ([elem respondsToSelector:@selector(accessibilityIncrement)]) {
              [elem accessibilityIncrement];
              return YES;
          }
      } else if ([action isEqualToString:@"decrement"]) {
          if ([elem respondsToSelector:@selector(accessibilityDecrement)]) {
              [elem accessibilityDecrement];
              return YES;
          }
      } else if ([action isEqualToString:@"activate"]) {
          if ([elem respondsToSelector:@selector(accessibilityActivate)]) {
              return [elem accessibilityActivate];
          }
      } else if ([action isEqualToString:@"escape"]) {
          if ([elem respondsToSelector:@selector(accessibilityPerformEscape)]) {
              return [elem accessibilityPerformEscape];
          }
      } else if ([action hasPrefix:@"scroll_"]) {
          NSString *dir_str = [action substringFromIndex:7];
          UIAccessibilityScrollDirection dir = 0;
          if ([dir_str isEqualToString:@"up"])
              dir = UIAccessibilityScrollDirectionUp;
          else if ([dir_str isEqualToString:@"down"])
              dir = UIAccessibilityScrollDirectionDown;
          else if ([dir_str isEqualToString:@"left"])
              dir = UIAccessibilityScrollDirectionLeft;
          else if ([dir_str isEqualToString:@"right"])
              dir = UIAccessibilityScrollDirectionRight;
          if (dir && [elem respondsToSelector:@selector(accessibilityScroll:)]) {
              return [elem accessibilityScroll:dir];
          }
      }
      return NO;
    });

    if (!found)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_element_at_point"));
    if (ok)
        return enif_make_atom(env, "ok");
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "action_failed"));
}

// ─── tap_xy/2 — Phase 3: real UITouch injection at screen coordinates ─────────
//
// Synthesises genuine UITouch/UIEvent objects and delivers them through UIKit's
// full event dispatch pipeline:
//
//   UIWindow.sendEvent: → UIGestureRecognizer → UIResponder.touchesBegan/Ended
//
// The app sees these as indistinguishable from a real finger. Scroll view
// momentum, custom gesture recognizers, drag & drop — all work.
//
// ⚠️  PRIVATE API throughout — read before modifying ⚠️
//
// Private interfaces declared via categories below. Using categories (not
// performSelector:) gives the compiler type information and avoids ARC leaks.
//
// BREAKAGE SIGNALS AND FALLBACKS (most → least likely):
//
//   _setLocationInWindow:resetPrevious: renamed:
//     Try _setLocationInWindow: (no resetPrevious), or KVC:
//     [touch setValue:[NSValue valueWithCGPoint:pt] forKey:@"locationInWindow"]
//
//   _setPhase: renamed:
//     Try KVC: [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"]
//     The backing ivar has been "_phase" since iOS 8.
//
//   _setView: / _setWindow: renamed:
//     Try KVC with keys @"view" and @"window" — UITouch KVC has been stable.
//
//   _touchesEvent not found on UIApplication:
//     Try [UIEvent eventWithType:UIEventTypeTouches subtype:0 timestamp:ts]
//     or [[UIApplication sharedApplication] _makeTouchEvent]
//
//   _clearTouches / _addTouch:forDelayedDelivery: renamed:
//     Try [event _removeAllTouches] or building a fresh UIEvent each time.
//
//   Everything above breaks at once:
//     Fall back to the IOHIDEvent path (works on real device, not simulator):
//     dlopen IOKit → IOHIDEventCreateDigitizerFingerEvent →
//     [UIApplication.sharedApplication _handleHIDEvent:event] via objc_msgSend.
//     Coordinates may need scaling by [UIScreen mainScreen].scale on device.
//
// COORDINATES: UIKit screen points, same space as ui_tree() frames.
//   Centre of a frame: tap_xy(x + w/2, y + h/2).

// ── Private category declarations ─────────────────────────────────────────────
// iOS 26 promoted many UITouch setters to public API. The remaining private
// pieces are declared here so the compiler has type information.
//
// iOS 26 availability notes (from runtime enumeration 2026-04-21):
//   PUBLIC (no underscore):  setWindow:  setView:  setPhase:  setTimestamp:  setTapCount:
//   STILL PRIVATE:           _setLocationInWindow:resetPrevious:
//   NEW (UIEvent):           _initWithEvent:touches:  (replaces _clearTouches + _addTouch:)
//   GONE (UITouch):          _setWindow: _setView: _setPhase: _setTimestamp: _setTapCount:
//   GONE (UIEvent):          _clearTouches  _addTouch:forDelayedDelivery:
//
// On older iOS (< 26), the _-prefixed versions are used and the public ones
// may not exist — both paths are guarded with respondsToSelector:.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

@interface UIApplication (MobPhase3)
// iOS <26 only (still present on iOS 26 but unused in the new path)
- (UIEvent *)_touchesEvent;
@end

@interface UIEvent (MobPhase3)
// iOS <26 path — touch management on a shared UIEvent
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
// iOS 26+ — create bare event backed by IOHIDEvent
- (instancetype)_init;
- (void)_setHIDEvent:(CFTypeRef)hidEvent; // back UIEvent with IOHIDEventRef
@end

@interface UITouch (MobPhase3)
// Private on all iOS versions
- (void)_setLocationInWindow:(CGPoint)pt resetPrevious:(BOOL)reset;
- (void)_setHidEvent:(CFTypeRef)hidEvent; // per-touch HID backing (lowercase 'id')
// Private on iOS < 26, GONE on iOS 26 (replaced by public setters below)
- (void)_setWindow:(UIWindow *)window;
- (void)_setView:(UIView *)view;
- (void)_setPhase:(UITouchPhase)phase;
- (void)_setTimestamp:(NSTimeInterval)ts;
- (void)_setTapCount:(NSUInteger)n;
// iOS 26+ public setters (exist at runtime, not yet in UITouch.h SDK headers)
- (void)setPhase:(UITouchPhase)phase;
- (void)setTimestamp:(NSTimeInterval)ts;
- (void)setTapCount:(NSUInteger)n;
@end

#pragma clang diagnostic pop

// Preserved UITouch from Began phase — reused for Ended/Cancelled so that
// the touch object's pointer identity remains stable across phases.
static UITouch *__strong sSavedTouch = nil;

// IOHIDEventCreateDigitizerFingerEvent — resolved once via dlsym.
typedef CFTypeRef IOHIDEventRef_t;
typedef IOHIDEventRef_t (*IOHIDCreateFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                               uint32_t, double, double, double, double, double,
                                               bool, bool, uint32_t);
static IOHIDCreateFingerFn sIOHIDCreateFinger;
static dispatch_once_t sIOHIDOnce;

// ── Core touch-phase helper ────────────────────────────────────────────────────
// Delivers one touch phase to UIKit.
//
// iOS 26+ path: IOHIDDigitizerFingerEvent → UIApplication._handleHIDEvent:
//   UIKit creates UITouch/UIEvent internally from the HID event. This path is
//   indistinguishable from a real touch because it enters UIKit at the same
//   level as hardware-generated events.
//
// iOS <26 path: manual UITouch + UIEvent construction via private setters,
//   then [UIWindow sendEvent:].
//
// Returns NO if the required APIs are missing on this iOS version.
static BOOL mob_send_touch_phase(UIWindow *window, UIView *hitView, CGPoint pt,
                                 UITouchPhase phase) {
    // ── iOS 26+ path: pure IOHIDEvent → _handleHIDEvent: ─────────────────────────
    // Let UIKit create UITouch and dispatch through its full pipeline.
    // Both Began and Ended go through _handleHIDEvent: — no manual UITouch injection,
    // no [window sendEvent:].  UIKit routes based on the window's contextId.
    {
        dispatch_once(&sIOHIDOnce, ^{
          sIOHIDCreateFinger = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        });

        SEL handleSel = NSSelectorFromString(@"_handleHIDEvent:");
        UIApplication *app = [UIApplication sharedApplication];

        if (!sIOHIDCreateFinger || ![app respondsToSelector:handleSel]) {
            LOGE(@"tap_xy: IOHIDCreateFinger=%p handleHIDEvent=%d", (void *)sIOHIDCreateFinger,
                 (int)[app respondsToSelector:handleSel]);
            return NO;
        }

        CGSize screen = [UIScreen mainScreen].bounds.size;
        double normX = pt.x / screen.width;
        double normY = pt.y / screen.height;
        uint64_t ts = mach_absolute_time();

        // fingerDown=YES for Began/Moved, NO for Ended/Cancelled
        BOOL fingerDown = (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved);

        IOHIDEventRef_t hidEvent =
            sIOHIDCreateFinger(kCFAllocatorDefault, ts,
                               0u,           // fingerIndex
                               1u,           // identity
                               1u | 2u | 4u, // eventMask: Range | Touch | Position
                               normX, normY, 0.0,
                               fingerDown ? 1.0 : 0.0, // tipPressure: 1.0 down, 0.0 up
                               0.0,
                               (bool)fingerDown, // range: finger in digitizer range?
                               (bool)fingerDown, // touch: finger touching?
                               0u);
        if (!hidEvent) {
            LOGE(@"tap_xy: IOHIDEventCreateDigitizerFingerEvent returned nil");
            return NO;
        }

        LOGI(@"tap_xy: _handleHIDEvent: phase=%d normX=%.3f normY=%.3f fingerDown=%d", (int)phase,
             normX, normY, (int)fingerDown);

        typedef void (*HandleFn)(id, SEL, CFTypeRef);
        ((HandleFn)objc_msgSend)(app, handleSel, hidEvent);

        // Check what UIKit created — did it produce a UITouch?
        if ([app respondsToSelector:@selector(_touchesEvent)]) {
            UIEvent *ev = [app _touchesEvent];
            LOGI(@"tap_xy: post-handleHID: _touchesEvent=%p allTouches=%lu", (__bridge void *)ev,
                 (unsigned long)ev.allTouches.count);
            if (ev && ev.allTouches.count > 0) {
                // UIKit created a UITouch — dispatch via the correct window
                LOGI(@"tap_xy: dispatching via [window sendEvent:] with UIKit-created touch");
                [window sendEvent:ev];
            }
        }

        CFRelease(hidEvent);
        return YES;
    } // end iOS 26+ pure-HID block

    // ── iOS <26 path: manual UITouch + UIEvent ────────────────────────────────
    // UITouch private setters + _touchesEvent + _addTouch:forDelayedDelivery:.
    // These APIs were removed in iOS 26 (confirmed by probe), so this path only
    // runs on older devices/OS versions.
    UIApplication *app = [UIApplication sharedApplication];
    NSTimeInterval ts = [NSProcessInfo processInfo].systemUptime;
    UITouch *touch = [[UITouch alloc] init];

    // window setter
    if ([touch respondsToSelector:@selector(_setWindow:)])
        [touch _setWindow:window];
    else {
        LOGE(@"tap_xy (<26): no _setWindow: on UITouch");
        return NO;
    }

    // view setter (best-effort; nil is tolerated by some iOS versions)
    if ([touch respondsToSelector:@selector(_setView:)])
        [touch _setView:hitView];

    // phase setter
    if ([touch respondsToSelector:@selector(_setPhase:)])
        [touch _setPhase:phase];
    else {
        LOGE(@"tap_xy (<26): no _setPhase: on UITouch");
        return NO;
    }

    // timestamp
    if ([touch respondsToSelector:@selector(_setTimestamp:)])
        [touch _setTimestamp:ts];

    // tap count
    if ([touch respondsToSelector:@selector(_setTapCount:)])
        [touch _setTapCount:1];

    // location
    if ([touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)])
        [touch _setLocationInWindow:pt resetPrevious:(phase == UITouchPhaseBegan)];
    else {
        LOGE(@"tap_xy (<26): no _setLocationInWindow:resetPrevious: on UITouch");
        return NO;
    }

    // build UIEvent
    if (![app respondsToSelector:@selector(_touchesEvent)]) {
        LOGE(@"tap_xy (<26): no _touchesEvent on UIApplication");
        return NO;
    }
    UIEvent *event = [app _touchesEvent];
    if ([event respondsToSelector:@selector(_clearTouches)])
        [event _clearTouches];
    if ([event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)])
        [event _addTouch:touch forDelayedDelivery:NO];
    else {
        LOGE(@"tap_xy (<26): no _addTouch:forDelayedDelivery:");
        return NO;
    }

    [window sendEvent:event];
    return YES;
}

// Temporary diagnostic: returns which Phase 3 private selectors are available.
// Call as: :rpc.call(node, :pegleg_nif, :tap_xy, [:probe])  — not real NIF arg,
// just probe by passing atom; actual impl checks argc.
static ERL_NIF_TERM nif_tap_xy_enumerate(ErlNifEnv *env, Class cls, const char *filter) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (!filter || strstr(name, filter)) {
            list = enif_make_list_cell(env, enif_make_atom(env, name), list);
        }
    }
    free(methods);
    return list;
}

static ERL_NIF_TERM nif_tap_xy_probe(ErlNifEnv *env) {
    UIApplication *app = [UIApplication sharedApplication];
    UITouch *touch = [[UITouch alloc] init];
    UIEvent *fakeEvent = [UIEvent new];

    struct {
        const char *name;
        BOOL found;
    } checks[] = {
        {"UIApp._touchesEvent", [app respondsToSelector:@selector(_touchesEvent)]},
        // UITouch — old private names (iOS <26)
        {"UITouch._setWindow:", [touch respondsToSelector:@selector(_setWindow:)]},
        {"UITouch._setView:", [touch respondsToSelector:@selector(_setView:)]},
        {"UITouch._setPhase:", [touch respondsToSelector:@selector(_setPhase:)]},
        {"UITouch._setTimestamp:", [touch respondsToSelector:@selector(_setTimestamp:)]},
        {"UITouch._setTapCount:", [touch respondsToSelector:@selector(_setTapCount:)]},
        {"UITouch._setLocationInWindow:resetPrevious:",
         [touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]},
        // UITouch — iOS 26+ names (no underscore)
        {"UITouch.setWindow:", [touch respondsToSelector:@selector(setWindow:)]},
        {"UITouch.setView:", [touch respondsToSelector:@selector(setView:)]},
        {"UITouch.setPhase:", [touch respondsToSelector:@selector(setPhase:)]},
        {"UITouch.setTimestamp:", [touch respondsToSelector:@selector(setTimestamp:)]},
        {"UITouch.setTapCount:", [touch respondsToSelector:@selector(setTapCount:)]},
        // UIEvent — old private names (iOS <26)
        {"UIEvent._clearTouches", [fakeEvent respondsToSelector:@selector(_clearTouches)]},
        {"UIEvent._addTouch:forDelayedDelivery:",
         [fakeEvent respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]},
        // UIEvent — iOS 26+
        {"UIEvent._initWithEvent:touches:",
         [UIEvent instancesRespondToSelector:@selector(_initWithEvent:touches:)]},
        // UITouch HID backing
        {"UITouch._setHidEvent:", [touch respondsToSelector:@selector(_setHidEvent:)]},
        {"UITouch._hidEvent", [touch respondsToSelector:@selector(_hidEvent)]},
    };

    ERL_NIF_TERM list = enif_make_list(env, 0);
    int n = sizeof(checks) / sizeof(checks[0]);
    for (int i = n - 1; i >= 0; i--) {
        ERL_NIF_TERM key = enif_make_atom(env, checks[i].name);
        ERL_NIF_TERM val = enif_make_atom(env, checks[i].found ? "true" : "false");
        list = enif_make_list_cell(env, enif_make_tuple2(env, key, val), list);
    }

    // Inspect the type encoding of _initWithEvent:touches: to learn what first arg type it wants.
    // "@" = id (object), "^" = pointer, etc.
    {
        Method m = class_getInstanceMethod([UIEvent class], @selector(_initWithEvent:touches:));
        if (m) {
            const char *enc = method_getTypeEncoding(m);
            // enc looks like "@24@0:8@16@16" — arg0 is return (id), arg2 is self,
            // arg3 is SEL, arg4 is first real arg. We want arg4's type.
            ERL_NIF_TERM enc_term = enif_make_string(env, enc ? enc : "(null)", ERL_NIF_LATIN1);
            list = enif_make_list_cell(
                env,
                enif_make_tuple2(
                    env, enif_make_atom(env, "UIEvent._initWithEvent:touches:.encoding"), enc_term),
                list);
        }
    }

    // Test _initWithEvent: with empty NSSet to isolate whether UITouch or base causes nil return.
    {
        UIEvent *baseInit =
            [UIEvent instancesRespondToSelector:@selector(_init)] ? [[UIEvent alloc] _init] : nil;
        SEL initWithEvSel = NSSelectorFromString(@"_initWithEvent:touches:");
        typedef UIEvent *(*InitWithEvFn)(id, SEL, void *, NSSet *);
        UIEvent *testEmpty =
            [UIEvent instancesRespondToSelector:initWithEvSel]
                ? ((InitWithEvFn)objc_msgSend)([[UIEvent alloc] init], initWithEvSel,
                                               (__bridge void *)baseInit, [NSSet set])
                : nil;
        ERL_NIF_TERM val = enif_make_atom(env, testEmpty ? "non_nil" : "nil");
        list = enif_make_list_cell(
            env, enif_make_tuple2(env, enif_make_atom(env, "_initWithEvent:emptySet"), val), list);
    }

    // Type encoding of UIEvent._setHIDEvent: to learn what it takes.
    {
        Method m = class_getInstanceMethod([UIEvent class], @selector(_setHIDEvent:));
        if (m) {
            const char *enc = method_getTypeEncoding(m);
            list = enif_make_list_cell(
                env,
                enif_make_tuple2(env, enif_make_atom(env, "UIEvent._setHIDEvent:.encoding"),
                                 enif_make_string(env, enc ? enc : "(null)", ERL_NIF_LATIN1)),
                list);
        }
    }

    // Check if IOHIDEventCreate* functions are available (for direct HID injection).
    {
        BOOL hasCreateFinger = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent") != NULL;
        BOOL hasCreateFingerQ =
            dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality") != NULL;
        list = enif_make_list_cell(
            env,
            enif_make_tuple2(env, enif_make_atom(env, "dlsym.IOHIDEventCreateDigitizerFingerEvent"),
                             enif_make_atom(env, hasCreateFinger ? "true" : "false")),
            list);
        list = enif_make_list_cell(
            env,
            enif_make_tuple2(
                env, enif_make_atom(env, "dlsym.IOHIDEventCreateDigitizerFingerEventWithQuality"),
                enif_make_atom(env, hasCreateFingerQ ? "true" : "false")),
            list);
    }

    // Check for UIApplication._handleHIDEvent:
    {
        UIApplication *a = [UIApplication sharedApplication];
        BOOL hasHandle = [a respondsToSelector:NSSelectorFromString(@"_handleHIDEvent:")];
        list =
            enif_make_list_cell(env,
                                enif_make_tuple2(env, enif_make_atom(env, "UIApp._handleHIDEvent:"),
                                                 enif_make_atom(env, hasHandle ? "true" : "false")),
                                list);
    }

    // Check for GSSendSystemEvent / GSSynthesizeSystemEvent via dlsym.
    {
        const char *gsFuncs[] = {
            "GSSendSystemEvent", "GSSynthesizeSystemEvent", "GSSendEvent",
            "GSEventDispatch",   "GSSendSystemEventFast",
        };
        for (int i = 0; i < 5; i++) {
            BOOL found = dlsym(RTLD_DEFAULT, gsFuncs[i]) != NULL;
            list =
                enif_make_list_cell(env,
                                    enif_make_tuple2(env, enif_make_atom(env, gsFuncs[i]),
                                                     enif_make_atom(env, found ? "true" : "false")),
                                    list);
        }
    }

    return list;
}

// Block until a UI event reaches the BEAM, or timeout_ms elapses.
//
// Synthetic input is delivered on the main runloop; the SwiftUI gesture handler
// that ends up calling mob_send_tap has usually NOT run by the time the
// dispatch_sync that injected the touch returns. Polling (rather than a fixed
// sleep) keeps a landed tap fast — the common case returns in one step.
static BOOL mob_await_ui_event(uint64_t seq_before, int timeout_ms) {
    for (int waited = 0; waited < timeout_ms; waited += 5) {
        if (mob_ui_event_seq() != seq_before)
            return YES;
        [NSThread sleepForTimeInterval:0.005];
    }
    return mob_ui_event_seq() != seq_before;
}

// How long tap_xy waits for the app to react before reporting :no_effect.
// 300ms is well past a SwiftUI tap gesture's recognition delay while staying
// short enough for the tight loops the harness runs.
#define MOB_TAP_SETTLE_MS 300

static ERL_NIF_TERM nif_tap_xy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // Diagnostics mode — pass :probe or :enumerate_touch or :enumerate_event
    if (enif_is_atom(env, argv[0])) {
        char atom[64];
        enif_get_atom(env, argv[0], atom, sizeof(atom), ERL_NIF_LATIN1);
        if (strcmp(atom, "enumerate_touch") == 0)
            return nif_tap_xy_enumerate(env, [UITouch class], NULL);
        if (strcmp(atom, "enumerate_event") == 0)
            return nif_tap_xy_enumerate(env, [UIEvent class], NULL);
        if (strcmp(atom, "enumerate_app_event") == 0)
            return nif_tap_xy_enumerate(env, [UIApplication class], "Event");
        if (strcmp(atom, "enumerate_app_hid") == 0)
            return nif_tap_xy_enumerate(env, [UIApplication class], "HID");
        if (strcmp(atom, "enumerate_app_touch") == 0)
            return nif_tap_xy_enumerate(env, [UIApplication class], "ouch");
        if (strcmp(atom, "enumerate_touch_set") == 0)
            return nif_tap_xy_enumerate(env, [UITouch class], "set");
        if (strcmp(atom, "enumerate_touch_init") == 0)
            return nif_tap_xy_enumerate(env, [UITouch class], "init");
        if (strcmp(atom, "enumerate_event_ivars") == 0) {
            // Dump UIEvent instance variable names and offsets
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList([UIEvent class], &count);
            ERL_NIF_TERM list = enif_make_list(env, 0);
            for (unsigned int i = 0; i < count; i++) {
                const char *name = ivar_getName(ivars[i]);
                ptrdiff_t off = ivar_getOffset(ivars[i]);
                const char *type = ivar_getTypeEncoding(ivars[i]);
                char buf[256];
                snprintf(buf, sizeof(buf), "%s@%td(%s)", name ? name : "?", off, type ? type : "?");
                list = enif_make_list_cell(env, enif_make_atom(env, buf), list);
            }
            free(ivars);
            return list;
        }
        // Enumerate UIWindow methods (useful for finding contextId getter)
        if (strcmp(atom, "enumerate_window") == 0) {
            return nif_tap_xy_enumerate(env, [UIWindow class], NULL);
        }
        if (strcmp(atom, "enumerate_window_context") == 0) {
            return nif_tap_xy_enumerate(env, [UIWindow class], "context");
        }
        // Return contextId and class of the key window — for HID event routing
        if (strcmp(atom, "window_info") == 0) {
            __block ERL_NIF_TERM result = enif_make_atom(env, "no_window");
            dispatch_sync(dispatch_get_main_queue(), ^{
              UIWindow *win = nil;
              for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                  if ([sc isKindOfClass:[UIWindowScene class]]) {
                      for (UIWindow *w in [(UIWindowScene *)sc windows]) {
                          if (!w.isHidden) {
                              win = w;
                              break;
                          }
                      }
                      if (win)
                          break;
                  }
              }
              if (!win)
                  return;

              // Try various contextId getters
              uint32_t ctxId = 0;
              SEL ctxSels[] = {
                  @selector(_contextId),
                  @selector(_windowContextID),
                  @selector(contextId),
                  @selector(_displayID),
              };
              NSString *ctxSelName = @"none";
              for (int i = 0; i < 4; i++) {
                  if ([win respondsToSelector:ctxSels[i]]) {
                      typedef uint32_t (*GetU32Fn)(id, SEL);
                      ctxId = ((GetU32Fn)objc_msgSend)(win, ctxSels[i]);
                      ctxSelName = NSStringFromSelector(ctxSels[i]);
                      break;
                  }
              }

              char buf[256];
              snprintf(buf, sizeof(buf), "win=%p class=%s ctxSel=%s ctxId=0x%08x",
                       (__bridge void *)win, class_getName(object_getClass(win)),
                       [ctxSelName UTF8String], ctxId);
              result = enif_make_string(env, buf, ERL_NIF_LATIN1);
            });
            return result;
        }
        return nif_tap_xy_probe(env);
    }
    double x, y;
    if (!enif_get_double(env, argv[0], &x)) {
        int ix;
        if (!enif_get_int(env, argv[0], &ix))
            return enif_make_badarg(env);
        x = ix;
    }
    if (!enif_get_double(env, argv[1], &y)) {
        int iy;
        if (!enif_get_int(env, argv[1], &iy))
            return enif_make_badarg(env);
        y = iy;
    }

    CGPoint pt = CGPointMake(x, y);

    // Sampled before any injection so we can tell a tap that ran a handler from
    // one the input API merely accepted. See mob_note_ui_event.
    const uint64_t seq_before = mob_ui_event_seq();

    // Hit-test on both platforms first: a coordinate outside every visible window
    // can never do anything, and saying so beats reporting :no_effect.
    __block UIWindow *targetWindow = nil;
    __block UIView *hitView = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              UIView *hit = [win hitTest:pt withEvent:nil];
              if (hit) {
                  targetWindow = win;
                  hitView = hit;
                  return;
              }
          }
      }
    });
    if (!hitView) {
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_view_at_point"));
    }

#if TARGET_OS_SIMULATOR
    // ── Simulator: accessibility-based activation by coordinates ─────────────────
    // The iOS simulator rejects in-process synthetic IOHIDEvents (no valid display
    // context) and SwiftUI on iOS 26 ignores direct touchesBegan: calls without
    // proper event system backing. Accessibility activation is the reliable path
    // for the simulator; for scroll views and custom GRs that lack accessibility,
    // a simulator-specific event injection mechanism would be needed.
    //
    // Find-then-act atomically inside ONE dispatch_sync per attempt (see
    // mob_retry_main_thread_bool) — using the SAME window the element was
    // found in for the text-field focus walk below, not a second,
    // independently-resolved window (MOB-99 review: with an overlapping
    // keyboard window, an independent re-scan could land on the wrong one).
    //
    // accessibilityActivate returning YES does NOT mean the app reacted: SwiftUI
    // only maps it to a default action for Button-like views. A plain
    // `.onTapGesture` (what Mob's Box/Row/Column use for on_tap) has no AX action,
    // so activation "succeeds" and the handler never fires — true even for a Box
    // given accessibility_role "button" (#94: real AX element, .isButton trait,
    // still no accessibilityAction; verified on-simulator). That is why the
    // outcome is decided by the event counter below, not by `activated`.
    BOOL activated = mob_retry_main_thread_bool("tap_xy(sim)", ^BOOL {
      UIWindow *win = nil;
      id elem = find_a11y_at_point_in_current_windows(pt, &win);
      if (!elem)
          return NO;

      LOGI(@"tap_xy(sim): accessibilityActivate on %@ frame=%@ hitWindow=%@",
           NSStringFromClass(object_getClass(elem)), NSStringFromCGRect([elem accessibilityFrame]),
           NSStringFromClass(object_getClass(targetWindow)));
      [elem accessibilityActivate];
      // For text fields: accessibilityActivate on UITextFieldLabel (the hint
      // label inside UITextField) doesn't focus the field. Walk the
      // responder chain up from the hit view to find the first
      // UITextField/UITextView and focus it.
      UIView *hv = [win hitTest:pt withEvent:nil];
      UIResponder *r = hv;
      while (r) {
          if ([r isKindOfClass:[UITextField class]] || [r isKindOfClass:[UITextView class]]) {
              [(UIView *)r becomeFirstResponder];
              break;
          }
          r = r.nextResponder;
      }
      return YES;
    });
    if (!activated) {
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_element_at_point"));
    }
    if (!mob_await_ui_event(seq_before, MOB_TAP_SETTLE_MS)) {
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_effect"));
    }
    return enif_make_atom(env, "ok");

#else
    // ── Real device: UITouch injection via IOHIDEvent ─────────────────────────────
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      ok = mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseBegan);
    });
    if (!ok) {
        return enif_make_tuple2(env, enif_make_atom(env, "error"), nif_tap_xy_probe(env));
    }

    [NSThread sleepForTimeInterval:0.10];

    dispatch_sync(dispatch_get_main_queue(), ^{
      mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseEnded);
    });

    // mob_send_touch_phase's YES only means "the private input API exists and
    // accepted the event" — on iOS 26 devices UIKit routinely swallows the
    // in-process IOHID event and no touch is ever delivered (decisions/
    // 2026-08-09-ios-device-tap-injection-has-no-effect.md). The counter is the
    // only thing that distinguishes a real tap from an accepted no-op.
    if (!mob_await_ui_event(seq_before, MOB_TAP_SETTLE_MS)) {
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_effect"));
    }
    return enif_make_atom(env, "ok");
#endif
}

static id find_first_responder_in(UIView *view) {
    if (view.isFirstResponder)
        return view;
    for (UIView *sub in view.subviews) {
        id fr = find_first_responder_in(sub);
        if (fr)
            return fr;
    }
    return nil;
}

// ─── delete_backward/0 — delete one character behind the cursor ──────────────
//
// Calls deleteBackward: on the current first responder. Equivalent to pressing
// the backspace key. Repeating gives "hold backspace" behaviour.
//
// Returns: ok | {error, no_first_responder} | {error, not_text_input}

static ERL_NIF_TERM nif_delete_backward(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block BOOL done = NO;
    __block BOOL found = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              id fr = find_first_responder_in(win);
              if (!fr)
                  continue;
              found = YES;
              if ([fr respondsToSelector:@selector(deleteBackward)]) {
                  [fr deleteBackward];
                  done = YES;
              }
              return;
          }
      }
    });
    if (done)
        return enif_make_atom(env, "ok");
    if (found)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_first_responder"));
}

// ─── key_press/1 — send a special key to the focused text input ───────────────
//
// Accepts an atom:
//   return   — submit / next field (inserts "\n", triggers textFieldShouldReturn:)
//   tab      — move to next field (inserts "\t")
//   escape   — dismiss keyboard (resignFirstResponder)
//   space    — insert a space character
//
// Returns: ok | {error, no_first_responder} | {error, unknown_key} |
//          {error, not_text_input}

static ERL_NIF_TERM nif_key_press(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char keybuf[32];
    if (!enif_get_atom(env, argv[0], keybuf, sizeof(keybuf), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    NSString *key = [NSString stringWithUTF8String:keybuf];

    __block BOOL done = NO;
    __block BOOL found = NO;
    __block BOOL unknown = NO;

    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              id fr = find_first_responder_in(win);
              if (!fr)
                  continue;
              found = YES;

              if ([key isEqualToString:@"return"]) {
                  if ([fr respondsToSelector:@selector(insertText:)]) {
                      [fr insertText:@"\n"];
                      done = YES;
                  }
              } else if ([key isEqualToString:@"tab"]) {
                  if ([fr respondsToSelector:@selector(insertText:)]) {
                      [fr insertText:@"\t"];
                      done = YES;
                  }
              } else if ([key isEqualToString:@"space"]) {
                  if ([fr respondsToSelector:@selector(insertText:)]) {
                      [fr insertText:@" "];
                      done = YES;
                  }
              } else if ([key isEqualToString:@"escape"]) {
                  [fr resignFirstResponder];
                  done = YES;
              } else {
                  unknown = YES;
              }
              return;
          }
      }
    });

    if (unknown)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "unknown_key"));
    if (done)
        return enif_make_atom(env, "ok");
    if (found)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_first_responder"));
}

// ─── clear_text/0 — erase all text in the focused input ──────────────────────
//
// Calls selectAll: then deleteBackward: on the first responder. Works on
// UITextField, UITextView, and UIKeyInput adopters.
//
// Returns: ok | {error, no_first_responder} | {error, not_text_input}

static ERL_NIF_TERM nif_clear_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block BOOL done = NO;
    __block BOOL found = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              id fr = find_first_responder_in(win);
              if (!fr)
                  continue;
              found = YES;
              BOOL canClear = [fr respondsToSelector:@selector(selectAll:)] &&
                              [fr respondsToSelector:@selector(deleteBackward)];
              if (canClear) {
                  [fr selectAll:nil];
                  // selectAll: is async in UITextView — yield once to let selection settle
                  // before deleting.
                  dispatch_async(dispatch_get_main_queue(), ^{
                    [fr deleteBackward];
                  });
                  done = YES;
              }
              return;
          }
      }
    });
    if (done)
        return enif_make_atom(env, "ok");
    if (found)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_first_responder"));
}

// ─── long_press_xy/3 — hold touch at (x, y) for duration_ms milliseconds ─────
//
// Simulator: finds UILongPressGestureRecognizer on the hit view or its ancestors
// and forces state transitions via the private _setState: selector, which fires
// the target/action pairs without needing HID events.
//
// Real device: emits Began → sleep(duration_ms) → Ended via IOHIDEvent, same
// path as tap_xy.
//
// Returns: ok | {error, no_view_at_point} | {error, no_long_press_recognizer}

static ERL_NIF_TERM nif_long_press_xy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    double x, y;
    int duration_ms;
    if (!enif_get_double(env, argv[0], &x) || !enif_get_double(env, argv[1], &y) ||
        !enif_get_int(env, argv[2], &duration_ms))
        return enif_make_badarg(env);

    CGPoint pt = CGPointMake((CGFloat)x, (CGFloat)y);

#if TARGET_OS_SIMULATOR
    // Already atomic (hitTest, GR search, and the accessibility fallback all
    // ran inside one dispatch_sync pre-MOB-99) — the gap this closes is that
    // it never retried, so the exact "screen just mounted, tree/GR list not
    // settled yet" race this whole file works around elsewhere could still
    // produce a false no_long_press_recognizer here.
    BOOL fired = mob_retry_main_thread_bool("long_press_xy(sim)", ^BOOL {
      UIView *hitView = nil;
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              UIView *h = [win hitTest:pt withEvent:nil];
              if (h) {
                  hitView = h;
                  break;
              }
          }
          if (hitView)
              break;
      }
      if (!hitView)
          return NO;

      // Walk up the responder chain looking for any UILongPressGestureRecognizer
      SEL setStateSel = NSSelectorFromString(@"_setState:");
      for (UIView *v = hitView; v; v = v.superview) {
          for (UIGestureRecognizer *gr in v.gestureRecognizers) {
              if (![gr isKindOfClass:[UILongPressGestureRecognizer class]])
                  continue;
              if (![gr respondsToSelector:setStateSel])
                  continue;
              typedef void (*SetStateFn)(id, SEL, NSInteger);
              SetStateFn setState = (SetStateFn)objc_msgSend;
              LOGI(@"long_press_xy(sim): firing LPGR on %@", NSStringFromClass([v class]));
              setState(gr, setStateSel, UIGestureRecognizerStateBegan);
              setState(gr, setStateSel, UIGestureRecognizerStateEnded);
              return YES;
          }
      }

      // SwiftUI onLongPressGesture may also surface as an accessibility custom action.
      // Try accessibilityActivate as a fallback — limited but better than nothing.
      id elem = find_a11y_at_point(hitView, pt, 0);
      if (elem && [elem respondsToSelector:@selector(accessibilityActivate)]) {
          LOGI(@"long_press_xy(sim): fallback to accessibilityActivate on %@",
               NSStringFromClass(object_getClass(elem)));
          [elem accessibilityActivate];
          return YES;
      }
      return NO;
    });

    if (fired)
        return enif_make_atom(env, "ok");
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_long_press_recognizer"));

#else
    // Real device: Began → hold → Ended
    __block UIWindow *targetWindow = nil;
    __block UIView *hitView = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              UIView *h = [win hitTest:pt withEvent:nil];
              if (h) {
                  targetWindow = win;
                  hitView = h;
                  return;
              }
          }
      }
    });

    if (!hitView)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_view_at_point"));

    dispatch_sync(dispatch_get_main_queue(), ^{
      mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseBegan);
    });

    [NSThread sleepForTimeInterval:(double)duration_ms / 1000.0];

    dispatch_sync(dispatch_get_main_queue(), ^{
      mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseEnded);
    });

    return enif_make_atom(env, "ok");
#endif
}

// ─── type_text/1 — type into whatever UITextField/UITextView has focus ────────
//
// Finds the current first responder in the view hierarchy and calls insertText:
// on it. Works for UITextField, UITextView, and any custom view that adopts
// UIKeyInput. The caller should tap the field first to give it focus.
//
// Returns: ok | {error, no_first_responder} | {error, not_text_input}

static ERL_NIF_TERM nif_type_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSString *text = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    if (!text)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "invalid_utf8"));

    __block BOOL typed = NO;
    __block BOOL found = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              id fr = find_first_responder_in(win);
              if (!fr)
                  continue;
              found = YES;
              if ([fr respondsToSelector:@selector(insertText:)]) {
                  LOGI(@"type_text: inserting %lu chars into %@", (unsigned long)text.length,
                       NSStringFromClass([fr class]));
                  [fr insertText:text];
                  typed = YES;
              }
              return;
          }
      }
    });

    if (typed)
        return enif_make_atom(env, "ok");
    if (found)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_first_responder"));
}

// ─── swipe_xy/4 — scroll gesture from (x1,y1) to (x2,y2) ────────────────────
//
// Simulator: walks the hit-test chain up from the touch point to find a
// UIScrollView and adjusts its contentOffset by the swipe delta.
//
// Real device: synthesises Began + multiple Moved + Ended IOHIDEvents through
// the same mob_send_touch_phase path used by tap_xy.
//
// Returns: ok | {error, no_scroll_view} | {error, no_view_at_point}

static UIScrollView *find_scroll_view_at(CGPoint pt) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *win in [(UIWindowScene *)scene windows]) {
            if (win.isHidden)
                continue;
            UIView *hit = [win hitTest:pt withEvent:nil];
            UIView *v = hit;
            while (v) {
                if ([v isKindOfClass:[UIScrollView class]])
                    return (UIScrollView *)v;
                v = v.superview;
            }
        }
    }
    return nil;
}

static ERL_NIF_TERM nif_swipe_xy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    double x1, y1, x2, y2;
    if (!enif_get_double(env, argv[0], &x1) || !enif_get_double(env, argv[1], &y1) ||
        !enif_get_double(env, argv[2], &x2) || !enif_get_double(env, argv[3], &y2))
        return enif_make_badarg(env);

    CGFloat dx = (CGFloat)(x2 - x1);
    CGFloat dy = (CGFloat)(y2 - y1);
    // Center of swipe for hit-testing
    CGPoint mid = CGPointMake((CGFloat)((x1 + x2) / 2.0), (CGFloat)((y1 + y2) / 2.0));

#if TARGET_OS_SIMULATOR
    __block BOOL scrolled = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIScrollView *sv = find_scroll_view_at(mid);
      if (!sv) {
          // Also try start point
          sv = find_scroll_view_at(CGPointMake((CGFloat)x1, (CGFloat)y1));
      }
      if (!sv)
          return;

      CGPoint cur = sv.contentOffset;
      // Swiping up (dy < 0) means content moves down (contentOffset.y increases)
      CGFloat newX = cur.x - dx;
      CGFloat newY = cur.y - dy;
      // Clamp to valid range
      CGFloat maxX = MAX(0.0f, sv.contentSize.width - sv.bounds.size.width);
      CGFloat maxY = MAX(0.0f, sv.contentSize.height - sv.bounds.size.height);
      newX = MAX(0.0f, MIN(newX, maxX));
      newY = MAX(0.0f, MIN(newY, maxY));
      LOGI(@"swipe_xy(sim): sv=%@ offset (%.1f,%.1f) → (%.1f,%.1f)", NSStringFromClass([sv class]),
           cur.x, cur.y, newX, newY);
      [sv setContentOffset:CGPointMake(newX, newY) animated:YES];
      scrolled = YES;
    });
    if (scrolled)
        return enif_make_atom(env, "ok");
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_scroll_view"));

#else
    // Real device: emit Began → 10 Moved steps → Ended via HID events
    __block UIWindow *targetWindow = nil;
    __block UIView *hitView = nil;
    CGPoint startPt = CGPointMake((CGFloat)x1, (CGFloat)y1);
    CGPoint endPt = CGPointMake((CGFloat)x2, (CGFloat)y2);

    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              UIView *hit = [win hitTest:startPt withEvent:nil];
              if (hit) {
                  targetWindow = win;
                  hitView = hit;
                  return;
              }
          }
      }
    });

    if (!hitView)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_view_at_point"));

    // Began
    dispatch_sync(dispatch_get_main_queue(), ^{
      mob_send_touch_phase(targetWindow, hitView, startPt, UITouchPhaseBegan);
    });

    // 10 evenly-spaced Moved steps
    int steps = 10;
    for (int i = 1; i <= steps; i++) {
        [NSThread sleepForTimeInterval:0.016]; // ~60fps
        CGPoint movePt =
            CGPointMake((CGFloat)(x1 + dx * i / steps), (CGFloat)(y1 + dy * i / steps));
        dispatch_sync(dispatch_get_main_queue(), ^{
          mob_send_touch_phase(targetWindow, hitView, movePt, UITouchPhaseMoved);
        });
    }

    [NSThread sleepForTimeInterval:0.016];

    // Ended
    dispatch_sync(dispatch_get_main_queue(), ^{
      mob_send_touch_phase(targetWindow, hitView, endPt, UITouchPhaseEnded);
    });

    return enif_make_atom(env, "ok");
#endif
}

// ── In-process screenshot + scroll control (agent driving over dist) ─────────
//
// screenshot/3, scroll_info/1, scroll_to/3 give a remotely-connected agent
// pixels and deterministic scroll without adb/xcrun, using only public UIKit
// APIs (UIGraphicsImageRenderer, UIScrollView.contentOffset). scroll_* stay in
// the debug-only harness; screenshot/3 is carved out just below so a host can
// opt it into release with -DMOB_ENABLE_SCREENSHOT — an agent needs to SEE the
// screen to error-correct even in a shipped build, while still being unable to
// DRIVE it (the synthetic-input NIFs above stay stripped in release).

// Recursively collect every UIScrollView under `view` into `acc`.
static void mob_collect_scroll_views(UIView *view, NSMutableArray<UIScrollView *> *acc) {
    if ([view isKindOfClass:[UIScrollView class]])
        [acc addObject:(UIScrollView *)view];
    for (UIView *sub in view.subviews)
        mob_collect_scroll_views(sub, acc);
}

// Find the scroll view addressed by `identifier` (the node's :id, which the
// SwiftUI renderer applies as accessibilityIdentifier). If `identifier` is
// empty, fall back to the largest scroll view — the main content scroller.
// Returns nil if none match. Main-thread only.
static UIScrollView *mob_find_scroll_view(NSString *identifier) {
    NSMutableArray<UIScrollView *> *all = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *win in [(UIWindowScene *)scene windows]) {
            if (!win.isHidden)
                mob_collect_scroll_views(win, all);
        }
    }
    if (all.count == 0)
        return nil;

    if (identifier.length > 0) {
        for (UIScrollView *sv in all) {
            if ([sv.accessibilityIdentifier isEqualToString:identifier])
                return sv;
        }
        // SwiftUI does not reliably propagate `.accessibilityIdentifier` onto the
        // backing UIScrollView, so an explicit id may not match even when set on
        // the Mob node. Fall through to the largest scroll view (the main content
        // scroller) rather than failing — correct for the common one-scroll screen.
    }

    UIScrollView *best = nil;
    CGFloat bestArea = -1.0;
    for (UIScrollView *sv in all) {
        CGFloat area = sv.bounds.size.width * sv.bounds.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = sv;
        }
    }
    return best;
}
#endif // !MOB_RELEASE — end of the debug-only synthetic-input + scroll harness

// Screen capture — public UIKit only (UIGraphicsImageRenderer + drawViewHierarchy),
// no private selectors, so it is App-Store-safe. Carved out of the harness so a host
// can opt it into release builds via -DMOB_ENABLE_SCREENSHOT (mob_dev config
// `ios_release_screenshot: true`); OFF by default. It captures the app's own key window
// with no OS prompt or indicator, so shipping a remotely-triggerable capture must be a
// conscious build choice, never a silent default. In release this lets an agent SEE the
// screen to error-correct while remaining unable to DRIVE it (tap/type stay stripped).
#if !MOB_RELEASE || defined(MOB_ENABLE_SCREENSHOT)
// The window capture reads from: the key window, else the first visible one.
// Main-thread only.
static UIWindow *mob_capture_window(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *win in [(UIWindowScene *)scene windows]) {
            if (win.isHidden)
                continue;
            if (win.isKeyWindow)
                return win;
            if (!fallback)
                fallback = win;
        }
    }
    return fallback;
}

// Render `crop` (a rect in window points — pass `window.bounds` for the whole
// surface) at `scale` × the native screen scale. The window is drawn offset by
// -crop.origin so the cropped region lands at the context origin, which makes
// the returned image exactly that region. Main-thread only.
static UIImage *mob_capture_image(UIWindow *window, CGRect crop, CGFloat scale) {
    UIGraphicsImageRendererFormat *rf = [UIGraphicsImageRendererFormat preferredFormat];
    rf.scale = [UIScreen mainScreen].scale * scale;
    rf.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:crop.size
                                                                               format:rf];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull ctx) {
      (void)ctx;
      CGRect r = window.bounds;
      r.origin.x -= crop.origin.x;
      r.origin.y -= crop.origin.y;
      [window drawViewHierarchyInRect:r afterScreenUpdates:YES];
    }];
}

static ERL_NIF_TERM nif_screenshot(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char fmt[8] = {0};
    int quality = 90;
    double scale = 1.0;
    if (!enif_get_atom(env, argv[0], fmt, sizeof(fmt), ERL_NIF_LATIN1) ||
        !enif_get_int(env, argv[1], &quality) || !enif_get_double(env, argv[2], &scale))
        return enif_make_badarg(env);

    BOOL jpeg = (strcmp(fmt, "jpeg") == 0);
    if (scale <= 0.0)
        scale = 1.0;

    __block NSData *imageData = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIWindow *window = mob_capture_window();
      if (!window)
          return;

      // `scale` is a multiplier of the native screen scale: 1.0 = crisp native
      // resolution, 0.5 = half (smaller payload over dist).
      UIImage *img = mob_capture_image(window, window.bounds, (CGFloat)scale);
      imageData = jpeg ? UIImageJPEGRepresentation(img, (CGFloat)quality / 100.0)
                       : UIImagePNGRepresentation(img);
    });

    if (!imageData)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_window"));

    ErlNifBinary bin;
    enif_alloc_binary(imageData.length, &bin);
    memcpy(bin.data, imageData.bytes, imageData.length);
    return enif_make_binary(env, &bin);
}
#endif // !MOB_RELEASE || MOB_ENABLE_SCREENSHOT

// Storage and the two Swift-callable entry points live OUTSIDE the debug-only
// harness guard below, deliberately. MobViewModel calls both on every set_root
// with no knowledge of MOB_RELEASE: the release pipeline compiles ios/*.swift
// without the flag and mob_nif.m with it, so defining these inside the guard
// links fine in debug and fails every release build with an undefined symbol.
// This file already states the rule where g_ui_event_seq is declared: "only the
// harness reads it; the writers stay unconditional". Only the two NIFs that
// READ the samples are gated, alongside the rest of the harness.

// ── Native frame timing (the half Mob.RenderStats cannot see) ────────────────
//
// `Mob.RenderStats` stops at the BEAM boundary. Its `set_root_us` covers the
// ObjC half of `nif_set_root` only — JSON parse, node construction, the tap
// table swap — because `[MobViewModel setRoot:transition:]` dispatches to the
// main thread and returns immediately. Everything SwiftUI then does to build,
// lay out and display the tree happens after that measurement has closed, so
// the entire native half of a frame has never been measured on either platform.
//
// That is the quantity MOB-126 and MOB-129 are arguing about: whether tearing
// the view tree down on navigation costs enough to be worth retaining trees per
// screen. MOB-130 says the wire-format decision must be made on evidence only.
// None of those can be settled against a number nobody has.
//
// What is recorded here is **main-thread busy time**: from the instant the new
// tree is applied to the view model to the instant the main run loop goes idle
// again, which is after SwiftUI has built the view tree, laid it out and handed
// it to Core Animation. That is deliberately the pessimistic reading — anything
// else queued on the main thread in that window is counted too — because it is
// also the honest one: a frame is dropped when the main thread is busy, whoever
// made it busy. Treat a sample as an upper bound on this frame's native cost,
// not as an attribution.
//
// Cost when disabled is one relaxed atomic load per `set_root`. The run loop
// observer, the timestamps and the lock are all downstream of that check, so an
// app that never enables this pays for a single integer read per navigation.

#define MOB_NATIVE_FRAME_SAMPLES 240

typedef struct {
    double apply_us;
    uint64_t seq;
    char transition[16];
} mob_native_frame_t;

// Ring buffer. `g_native_frame_seq` counts every sample ever recorded, so a
// reader can tell "240 samples, that is all there were" from "240 samples, and
// 5000 more scrolled past" — the difference decides whether a percentile over
// this window means anything.
static mob_native_frame_t g_native_frames[MOB_NATIVE_FRAME_SAMPLES];
static uint64_t g_native_frame_seq = 0;

// Read on the main thread on every set_root, written from a NIF thread. Atomic
// rather than lock-guarded so the disabled path costs a load and no more; the
// relaxed ordering is fine because a sample recorded a frame either side of the
// flag flipping is not a correctness problem.
static _Atomic int g_native_stats_enabled = 0;

static NSObject *g_native_stats_lock = nil;
static dispatch_once_t g_native_stats_once;

static NSObject *mob_native_stats_lock(void) {
    dispatch_once(&g_native_stats_once, ^{
      g_native_stats_lock = [NSObject new];
    });
    return g_native_stats_lock;
}

int mob_native_stats_enabled(void) {
    return atomic_load_explicit(&g_native_stats_enabled, memory_order_relaxed);
}

void mob_record_native_frame(double apply_us, const char *transition) {
    NSObject *lock = mob_native_stats_lock();
    @synchronized(lock) {
        mob_native_frame_t *slot = &g_native_frames[g_native_frame_seq % MOB_NATIVE_FRAME_SAMPLES];
        slot->apply_us = apply_us;
        slot->seq = g_native_frame_seq;
        // strncpy rather than strlcpy so this stays portable to the Android
        // build if the same shape is ported; the explicit terminator is what
        // strncpy does not guarantee.
        strncpy(slot->transition, transition ? transition : "none", sizeof(slot->transition) - 1);
        slot->transition[sizeof(slot->transition) - 1] = '\0';
        g_native_frame_seq++;
    }
}

#if !MOB_RELEASE // resume the debug-only harness (sampling + scroll + element frames)

// sample_region(X, Y, W, H) -> {ok, PixelW, PixelH, RGBA} | {error, Reason}
//
// Raw pixels for one region of the app's own surface. This is the only reliable
// way to verify what colour was actually drawn: on iOS 26 SwiftUI paints through
// SDFLayer or rasterises into `contents`, so neither the view nor the layer tree
// exposes a readable colour — see
// decisions/2026-08-09-view-tree-colour-needs-screenshot-sampling.md.
//
// The crop happens in the render, not after it, so what crosses distribution is
// one element's worth of pixels instead of a whole framebuffer. Coordinates are
// window points (the same space element_frames/0 reports); the returned buffer is
// PixelW*PixelH*4 bytes of 8-bit RGBA at the native screen scale, so its size is
// W*H*scale^2*4 — a 100x50pt element is ~180 KB at 3x.
//
// Rects are clamped to the window, so a partly-scrolled-off element samples the
// visible part and reports the pixel dimensions it actually got. A rect entirely
// outside the window is `offscreen` rather than a plausible-looking black.
//
// Unlike screenshot/3 this stays strictly debug-only: it is a screen-capture
// primitive, and a release build shipping it could reconstruct the screen region
// by region, silently defeating the MOB_ENABLE_SCREENSHOT opt-in.
static ERL_NIF_TERM nif_sample_region(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    double x = 0.0, y = 0.0, w = 0.0, h = 0.0;
    if (!enif_get_double(env, argv[0], &x) || !enif_get_double(env, argv[1], &y) ||
        !enif_get_double(env, argv[2], &w) || !enif_get_double(env, argv[3], &h))
        return enif_make_badarg(env);

    __block const char *err = NULL;
    __block NSMutableData *rgba = nil;
    __block size_t pw = 0, ph = 0;

    if (w <= 0.0 || h <= 0.0)
        err = "empty_region";

    if (!err)
        dispatch_sync(dispatch_get_main_queue(), ^{
          UIWindow *window = mob_capture_window();
          if (!window) {
              err = "no_window";
              return;
          }
          CGRect crop = CGRectIntersection(window.bounds, CGRectMake(x, y, w, h));
          if (CGRectIsNull(crop) || CGRectIsEmpty(crop)) {
              err = "offscreen";
              return;
          }

          CGImageRef cg = mob_capture_image(window, crop, 1.0).CGImage;
          if (!cg) {
              err = "capture_failed";
              return;
          }
          pw = CGImageGetWidth(cg);
          ph = CGImageGetHeight(cg);

          // Redraw into a bitmap context of known layout: a UIImage's own backing
          // store has no guaranteed byte order or component count, so reading it
          // directly would make the returned bytes device-dependent.
          size_t stride = pw * 4;
          rgba = [NSMutableData dataWithLength:stride * ph];
          CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
          CGContextRef bmp =
              CGBitmapContextCreate(rgba.mutableBytes, pw, ph, 8, stride, cs,
                                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
          CGColorSpaceRelease(cs);
          if (!bmp) {
              rgba = nil;
              err = "capture_failed";
              return;
          }
          CGContextDrawImage(bmp, CGRectMake(0, 0, pw, ph), cg);
          CGContextRelease(bmp);
        });

    if (err || !rgba)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, err ?: "capture_failed"));

    ErlNifBinary bin;
    if (!enif_alloc_binary(rgba.length, &bin))
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "alloc_failed"));
    memcpy(bin.data, rgba.mutableBytes, rgba.length);
    return enif_make_tuple4(env, enif_make_atom(env, "ok"), enif_make_ulong(env, pw),
                            enif_make_ulong(env, ph), enif_make_binary(env, &bin));
}

static ERL_NIF_TERM nif_scroll_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary idb;
    if (!enif_inspect_binary(env, argv[0], &idb))
        return enif_make_badarg(env);
    NSString *identifier = [[NSString alloc] initWithBytes:idb.data
                                                    length:idb.size
                                                  encoding:NSUTF8StringEncoding]
                               ?: @"";

    __block NSData *jsonData = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIScrollView *sv = mob_find_scroll_view(identifier);
      if (!sv)
          return;

      // Normalize so offset 0 == content top, regardless of inset.
      UIEdgeInsets in = sv.adjustedContentInset;
      CGFloat vw = sv.bounds.size.width - in.left - in.right;
      CGFloat vh = sv.bounds.size.height - in.top - in.bottom;
      CGFloat cw = sv.contentSize.width;
      CGFloat ch = sv.contentSize.height;
      NSDictionary *d = @{
          @"offset_x" : @(sv.contentOffset.x + in.left),
          @"offset_y" : @(sv.contentOffset.y + in.top),
          @"content_w" : @(cw),
          @"content_h" : @(ch),
          @"viewport_w" : @(vw),
          @"viewport_h" : @(vh),
          @"max_x" : @(MAX(0.0, cw - vw)),
          @"max_y" : @(MAX(0.0, ch - vh)),
          @"kind" : @"pixel"
      };
      jsonData = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    });

    if (!jsonData)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "scroll_view_not_found"));

    ErlNifBinary bin;
    enif_alloc_binary(jsonData.length, &bin);
    memcpy(bin.data, jsonData.bytes, jsonData.length);
    return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM nif_scroll_to(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary idb;
    double x, y;
    if (!enif_inspect_binary(env, argv[0], &idb) || !enif_get_double(env, argv[1], &x) ||
        !enif_get_double(env, argv[2], &y))
        return enif_make_badarg(env);
    NSString *identifier = [[NSString alloc] initWithBytes:idb.data
                                                    length:idb.size
                                                  encoding:NSUTF8StringEncoding]
                               ?: @"";

    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIScrollView *sv = mob_find_scroll_view(identifier);
      if (!sv)
          return;
      // Caller works in normalized coords (0 == top); convert to offset space.
      UIEdgeInsets in = sv.adjustedContentInset;
      [sv setContentOffset:CGPointMake((CGFloat)x - in.left, (CGFloat)y - in.top) animated:NO];
      ok = YES;
    });

    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                 enif_make_atom(env, "scroll_view_not_found"));
}

// nif_native_stats_enable/1 — turn native frame timing on or off.
//
// Off by default. See the ring buffer above for what is measured and why the
// disabled path is a single atomic load.
static ERL_NIF_TERM nif_native_stats_enable(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char flag[8] = {0};
    if (!enif_get_atom(env, argv[0], flag, sizeof(flag), ERL_NIF_LATIN1))
        return enif_make_badarg(env);

    int on = (strcmp(flag, "true") == 0);
    if (!on && strcmp(flag, "false") != 0)
        return enif_make_badarg(env);

    // Reset the window when enabling, so a measurement run never reports
    // samples from an earlier one. Enabling is the natural "start measuring
    // here" marker and callers reasonably read it that way.
    if (on) {
        NSObject *lock = mob_native_stats_lock();
        @synchronized(lock) {
            g_native_frame_seq = 0;
        }
    }
    atomic_store_explicit(&g_native_stats_enabled, on, memory_order_relaxed);
    return enif_make_atom(env, "ok");
}

// nif_native_stats/0 — JSON of the recorded native frame samples, newest first.
//
// {"enabled":bool,"recorded":N,"dropped":M,"samples":[{"apply_us":f,"transition":s,"seq":n},...]}
//
// `recorded` is every sample since the window opened; `dropped` is how many
// scrolled out of the ring. A percentile over `samples` describes the tail of
// the run only, and `dropped > 0` is what tells the reader that.
static ERL_NIF_TERM nif_native_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    mob_native_frame_t snapshot[MOB_NATIVE_FRAME_SAMPLES];
    uint64_t total = 0;

    // Snapshot under the lock, serialize outside it: the main thread takes this
    // same lock once per set_root, and JSON-encoding 240 samples from a dirty
    // scheduler while holding it would stall UI work on a thread with no QoS
    // relationship to it. Same reasoning as nif_element_frames.
    NSObject *lock = mob_native_stats_lock();
    @synchronized(lock) {
        total = g_native_frame_seq;
        memcpy(snapshot, g_native_frames, sizeof(snapshot));
    }

    uint64_t held = total < MOB_NATIVE_FRAME_SAMPLES ? total : MOB_NATIVE_FRAME_SAMPLES;
    NSMutableArray *samples = [NSMutableArray arrayWithCapacity:(NSUInteger)held];
    // Newest first, matching Mob.RenderStats.frames/0.
    for (uint64_t i = 0; i < held; i++) {
        uint64_t seq = total - 1 - i;
        mob_native_frame_t *f = &snapshot[seq % MOB_NATIVE_FRAME_SAMPLES];
        [samples addObject:@{
            @"apply_us" : @(f->apply_us),
            @"transition" : [NSString stringWithUTF8String:f->transition] ?: @"none",
            @"seq" : @(f->seq)
        }];
    }

    NSDictionary *payload = @{
        @"enabled" : @(mob_native_stats_enabled() ? YES : NO),
        @"recorded" : @(total),
        @"dropped" : @(total > MOB_NATIVE_FRAME_SAMPLES ? total - MOB_NATIVE_FRAME_SAMPLES : 0),
        @"samples" : samples
    };

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!jsonData)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "encode_failed"));

    ErlNifBinary bin;
    enif_alloc_binary(jsonData.length, &bin);
    memcpy(bin.data, jsonData.bytes, jsonData.length);
    return enif_make_binary(env, &bin);
}

// nif_element_frames/0 — JSON {"id":[x,y,w,h],...} of tagged element frames
// (logical points). Recorded by MobFrameTracker; see mob_register_frame.
static ERL_NIF_TERM nif_element_frames(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    NSMutableDictionary *reg = mob_frame_registry();
    // Snapshot under the lock, serialize outside it. The main thread takes this
    // same lock on every frame write — once per tracked element per display
    // frame during a transition — and the docs tell callers to poll this NIF
    // until a frame settles, so holding it across a JSON encode of the whole
    // registry from a dirty scheduler would stall UI layout on a thread with no
    // QoS relationship to it.
    NSDictionary *snapshot = nil;
    @synchronized(reg) {
        snapshot = [reg copy];
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (!jsonData)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "encode_failed"));

    ErlNifBinary bin;
    enif_alloc_binary(jsonData.length, &bin);
    memcpy(bin.data, jsonData.bytes, jsonData.length);
    return enif_make_binary(env, &bin);
}

#endif // !MOB_RELEASE — end of test harness block (started near line 2780)

// ── Storage ───────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_storage_dir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char loc[32];
    enif_get_atom(env, argv[0], loc, sizeof(loc), ERL_NIF_LATIN1);

    NSString *path = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (strcmp(loc, "temp") == 0) {
        path = NSTemporaryDirectory();
    } else if (strcmp(loc, "documents") == 0) {
        path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
            firstObject];
    } else if (strcmp(loc, "cache") == 0) {
        path = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)
            firstObject];
    } else if (strcmp(loc, "app_support") == 0) {
        path = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask,
                                                    YES) firstObject];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    } else if (strcmp(loc, "icloud") == 0) {
        NSURL *url = [fm URLForUbiquityContainerIdentifier:nil];
        if (url) {
            path = [url URLByAppendingPathComponent:@"Documents"].path;
            [fm createDirectoryAtPath:path
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:nil];
        }
    }

    if (!path)
        return enif_make_atom(env, "nil");
    const char *cpath = path.UTF8String;
    ErlNifBinary bin;
    enif_alloc_binary(strlen(cpath), &bin);
    memcpy(bin.data, cpath, strlen(cpath));
    return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM nif_storage_save_to_photo_library(ErlNifEnv *env, int argc,
                                                      const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString *path = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    ErlNifPid pid;
    enif_self(env, &pid);

    [PHPhotoLibrary
        requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                   handler:^(PHAuthorizationStatus status) {
                                     if (status != PHAuthorizationStatusAuthorized &&
                                         status != PHAuthorizationStatusLimited) {
                                         ErlNifEnv *e = enif_alloc_env();
                                         ERL_NIF_TERM msg = enif_make_tuple4(
                                             e, enif_make_atom(e, "storage"),
                                             enif_make_atom(e, "error"),
                                             enif_make_atom(e, "save_to_library"),
                                             enif_make_atom(e, "permission_denied"));
                                         enif_send(NULL, &pid, e, msg);
                                         enif_free_env(e);
                                         return;
                                     }
                                     [[PHPhotoLibrary sharedPhotoLibrary]
                                         performChanges:^{
                                           NSURL *url = [NSURL fileURLWithPath:path];
                                           NSString *ext = path.pathExtension.lowercaseString;
                                           BOOL isVideo =
                                               [@[ @"mp4", @"mov", @"m4v" ] containsObject:ext];
                                           if (isVideo)
                                               [PHAssetChangeRequest
                                                   creationRequestForAssetFromVideoAtFileURL:url];
                                           else
                                               [PHAssetChangeRequest
                                                   creationRequestForAssetFromImageAtFileURL:url];
                                         }
                                         completionHandler:^(BOOL success, NSError *err) {
                                           ErlNifEnv *e = enif_alloc_env();
                                           ERL_NIF_TERM msg;
                                           if (success) {
                                               const char *cpath = path.UTF8String;
                                               ErlNifBinary pb;
                                               enif_alloc_binary(strlen(cpath), &pb);
                                               memcpy(pb.data, cpath, strlen(cpath));
                                               msg = enif_make_tuple3(
                                                   e, enif_make_atom(e, "storage"),
                                                   enif_make_atom(e, "saved_to_library"),
                                                   enif_make_binary(e, &pb));
                                           } else {
                                               msg = enif_make_tuple4(
                                                   e, enif_make_atom(e, "storage"),
                                                   enif_make_atom(e, "error"),
                                                   enif_make_atom(e, "save_to_library"),
                                                   enif_make_atom(e, "save_failed"));
                                           }
                                           enif_send(NULL, &pid, e, msg);
                                           enif_free_env(e);
                                         }];
                                   }];
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_storage_save_to_media_store(ErlNifEnv *env, int argc,
                                                    const ERL_NIF_TERM argv[]) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "not_supported"));
}

static ERL_NIF_TERM nif_storage_external_files_dir(ErlNifEnv *env, int argc,
                                                   const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "nil");
}

// ── WebView ───────────────────────────────────────────────────────────────────
// g_webview is set by MobWebView (MobRootView.swift) when the component is created.
// mob_deliver_webview_message / _blocked are called from Swift (via bridging header).

static void deliver_webview_binary(const char *tag, const char *utf8) {
    ErlNifEnv *env = enif_alloc_env();
    ErlNifPid pid;
    if (!enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
        enif_free_env(env);
        return;
    }
    size_t len = strlen(utf8);
    ErlNifBinary bin;
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    ERL_NIF_TERM msg = enif_make_tuple3(env, enif_make_atom(env, "webview"),
                                        enif_make_atom(env, tag), enif_make_binary(env, &bin));
    enif_send(NULL, &pid, env, msg);
    enif_free_env(env);
}

void mob_deliver_webview_message(const char *json_utf8) {
    deliver_webview_binary("message", json_utf8);
}

void mob_deliver_webview_blocked(const char *url_utf8) {
    deliver_webview_binary("blocked", url_utf8);
}

WKWebView *g_webview = nil;

// Camera preview session — OWNED by the mob_camera plugin (its NIF supplies the
// strong definition and drives start/stop_preview). Defined weak here so core
// still links when mob_camera isn't activated: the symbol resolves to nil and the
// preview shows black. The weak *declaration* in MobNode.h is not enough on its
// own — swiftc compiles MobRootView's reference into a *strong* undefined symbol
// (the weak attribute doesn't cross the C→Swift interop boundary), so a definition
// must exist in core. The plugin's non-weak definition overrides this one when linked.
AVCaptureSession *g_preview_session __attribute__((weak)) = nil;

// ── Alert delivery (called from UIAlertAction blocks) ────────────────────────

static void mob_deliver_alert_action(const char *action) {
    ErlNifEnv *env = enif_alloc_env();
    ErlNifPid pid;
    if (enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
        ERL_NIF_TERM msg =
            enif_make_tuple2(env, enif_make_atom(env, "alert"), enif_make_atom(env, action));
        enif_send(NULL, &pid, env, msg);
    }
    enif_free_env(env);
}

// Returns the root UIViewController for presenting dialogs.
static UIViewController *root_vc(void) {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            UIWindow *win = scene.windows.firstObject;
            UIViewController *vc = win.rootViewController;
            while (vc.presentedViewController)
                vc = vc.presentedViewController;
            return vc;
        }
    }
    return nil;
}

// ── NIF: alert_show/3 ────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_alert_show(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary title_bin, msg_bin, btns_bin;
    if (!enif_inspect_binary(env, argv[0], &title_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &title_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &msg_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &msg_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[2], &btns_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[2], &btns_bin))
        return enif_make_badarg(env);

    NSString *title = [[NSString alloc] initWithBytes:title_bin.data
                                               length:title_bin.size
                                             encoding:NSUTF8StringEncoding];
    NSString *message = msg_bin.size > 0 ? [[NSString alloc] initWithBytes:msg_bin.data
                                                                    length:msg_bin.size
                                                                  encoding:NSUTF8StringEncoding]
                                         : nil;
    NSData *btns_d = [NSData dataWithBytes:btns_bin.data length:btns_bin.size];

    dispatch_async(dispatch_get_main_queue(), ^{
      NSArray *buttons = [NSJSONSerialization JSONObjectWithData:btns_d options:0 error:nil];
      if (![buttons isKindOfClass:[NSArray class]])
          return;

      UIAlertController *ac =
          [UIAlertController alertControllerWithTitle:title
                                              message:message
                                       preferredStyle:UIAlertControllerStyleAlert];
      for (NSDictionary *btn in buttons) {
          NSString *label = btn[@"label"] ?: @"";
          NSString *action = btn[@"action"] ?: @"dismiss";
          NSString *style = btn[@"style"] ?: @"default";
          UIAlertActionStyle as = UIAlertActionStyleDefault;
          if ([style isEqualToString:@"cancel"])
              as = UIAlertActionStyleCancel;
          if ([style isEqualToString:@"destructive"])
              as = UIAlertActionStyleDestructive;
          const char *act_c = [action UTF8String];
          [ac addAction:[UIAlertAction actionWithTitle:label
                                                 style:as
                                               handler:^(UIAlertAction *_) {
                                                 mob_deliver_alert_action(act_c);
                                               }]];
      }
      UIViewController *vc = root_vc();
      if (vc)
          [vc presentViewController:ac animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: action_sheet_show/2 ─────────────────────────────────────────────────

static ERL_NIF_TERM nif_action_sheet_show(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary title_bin, btns_bin;
    if (!enif_inspect_binary(env, argv[0], &title_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &title_bin))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &btns_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &btns_bin))
        return enif_make_badarg(env);

    NSString *title = title_bin.size > 0 ? [[NSString alloc] initWithBytes:title_bin.data
                                                                    length:title_bin.size
                                                                  encoding:NSUTF8StringEncoding]
                                         : nil;
    NSData *btns_d = [NSData dataWithBytes:btns_bin.data length:btns_bin.size];

    dispatch_async(dispatch_get_main_queue(), ^{
      NSArray *buttons = [NSJSONSerialization JSONObjectWithData:btns_d options:0 error:nil];
      if (![buttons isKindOfClass:[NSArray class]])
          return;

      UIAlertController *ac =
          [UIAlertController alertControllerWithTitle:title
                                              message:nil
                                       preferredStyle:UIAlertControllerStyleActionSheet];
      for (NSDictionary *btn in buttons) {
          NSString *label = btn[@"label"] ?: @"";
          NSString *action = btn[@"action"] ?: @"dismiss";
          NSString *style = btn[@"style"] ?: @"default";
          UIAlertActionStyle as = UIAlertActionStyleDefault;
          if ([style isEqualToString:@"cancel"])
              as = UIAlertActionStyleCancel;
          if ([style isEqualToString:@"destructive"])
              as = UIAlertActionStyleDestructive;
          const char *act_c = [action UTF8String];
          [ac addAction:[UIAlertAction actionWithTitle:label
                                                 style:as
                                               handler:^(UIAlertAction *_) {
                                                 mob_deliver_alert_action(act_c);
                                               }]];
      }
      UIViewController *vc = root_vc();
      if (!vc)
          return;
      // iPad requires a source view for action sheets
      if (ac.popoverPresentationController) {
          ac.popoverPresentationController.sourceView = vc.view;
          ac.popoverPresentationController.sourceRect =
              CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height, 0, 0);
      }
      [vc presentViewController:ac animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: toast_show/2 ────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_toast_show(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary msg_bin;
    char dur[8] = "short";
    if (!enif_inspect_binary(env, argv[0], &msg_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &msg_bin))
        return enif_make_badarg(env);
    enif_get_atom(env, argv[1], dur, sizeof(dur), ERL_NIF_LATIN1);

    NSString *message = [[NSString alloc] initWithBytes:msg_bin.data
                                                 length:msg_bin.size
                                               encoding:NSUTF8StringEncoding];
    double seconds = strcmp(dur, "long") == 0 ? 3.5 : 2.0;

    dispatch_async(dispatch_get_main_queue(), ^{
      // Find the key window
      UIWindow *window = nil;
      for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (scene.activationState == UISceneActivationStateForegroundActive) {
              window = scene.windows.firstObject;
              break;
          }
      }
      if (!window)
          return;

      UILabel *label = [[UILabel alloc] init];
      label.text = message;
      label.textColor = [UIColor whiteColor];
      label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
      label.textAlignment = NSTextAlignmentCenter;
      label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
      label.layer.cornerRadius = 12;
      label.layer.masksToBounds = YES;
      label.numberOfLines = 0;

      CGFloat maxW = window.bounds.size.width - 48;
      CGSize fit = [label sizeThatFits:CGSizeMake(maxW - 32, 200)];
      CGFloat w = MIN(fit.width + 32, maxW);
      CGFloat h = fit.height + 16;
      CGFloat x = (window.bounds.size.width - w) / 2;
      CGFloat y = window.bounds.size.height - h - 80; // above home indicator
      label.frame = CGRectMake(x, y, w, h);
      label.alpha = 0;

      [window addSubview:label];
      [UIView animateWithDuration:0.25
          animations:^{
            label.alpha = 1.0;
          }
          completion:^(BOOL _) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                             [UIView animateWithDuration:0.25
                                 animations:^{
                                   label.alpha = 0;
                                 }
                                 completion:^(BOOL _) {
                                   [label removeFromSuperview];
                                 }];
                           });
          }];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_webview_eval_js(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString *code = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      [g_webview evaluateJavaScript:code completionHandler:nil];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_webview_post_message(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString *json = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    // Escape for single-quoted JS string: backslash then apostrophe
    NSString *escaped = [json stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:@"window.mob&&window.mob._dispatch('%@')", escaped];
    dispatch_async(dispatch_get_main_queue(), ^{
      [g_webview evaluateJavaScript:js completionHandler:nil];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_webview_can_go_back(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // dispatch_sync blocks this BEAM scheduler thread until the main queue drains.
    // Intentional — the caller (Mob.Screen back handler) needs the boolean before deciding
    // whether to pop the nav stack. Same pattern as clipboard_get and safe_area.
    // The main thread is expected to be idle during a back gesture.
    __block BOOL result = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      result = g_webview ? [g_webview canGoBack] : NO;
    });
    return enif_make_atom(env, result ? "true" : "false");
}

static ERL_NIF_TERM nif_webview_go_back(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [g_webview goBack];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF table & load ──────────────────────────────────────────────────────────

// ── Native view component registry ───────────────────────────────────────────
// Persistent handle table — not cleared between renders (unlike tap handles).
// register_component/1 allocates a slot; deregister_component/1 frees it.
// mob_send_component_event is called from Swift when the native view fires an event.

// MOB-100: bumped from 64 — a single screen legitimately rendering ~60
// components (e.g. an icon catalog) plus a few leftover slots from prior
// navigation could tip over the old cap. Keep in sync with the identical
// constant in android/jni/mob_nif.zig. Still fixed-size: a growable pool
// or component recycling is a longer-term follow-up, not this fix.
#define MAX_COMPONENT_HANDLES 256

typedef struct {
    ErlNifPid pid;
    uint32_t generation;
    int active;
} ComponentHandle;

static ComponentHandle component_handles[MAX_COMPONENT_HANDLES];
static ErlNifMutex *component_mutex = NULL;

// Returns {ok, Handle} on success, {error, component_slots_exhausted} when
// the pool is full — MOB-100: a full pool used to return the same
// enif_make_badarg(env) as a malformed pid argument, which crashed
// Mob.ComponentServer.init (and, via the unhandled {:error, _} tuple
// unmatched in Mob.Component.ensure_started, the whole screen process)
// instead of failing just the one component that couldn't get a slot.
static ERL_NIF_TERM nif_register_component(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[0], &pid))
        return enif_make_badarg(env);

    enif_mutex_lock(component_mutex);
    for (int i = 0; i < MAX_COMPONENT_HANDLES; i++) {
        if (!component_handles[i].active) {
            component_handles[i].generation =
                mob_next_handle_generation(component_handles[i].generation);
            int handle = mob_encode_event_handle(component_handles[i].generation, i);
            component_handles[i].pid = pid;
            component_handles[i].active = 1;
            enif_mutex_unlock(component_mutex);
            return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_int(env, handle));
        }
    }
    enif_mutex_unlock(component_mutex);
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "component_slots_exhausted"));
}

static ERL_NIF_TERM nif_deregister_component(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int handle;
    uint32_t generation;
    int slot;
    if (!enif_get_int(env, argv[0], &handle) ||
        !mob_decode_event_handle(handle, &generation, &slot))
        return enif_make_badarg(env);

    enif_mutex_lock(component_mutex);
    if (!component_handles[slot].active || component_handles[slot].generation != generation) {
        enif_mutex_unlock(component_mutex);
        return enif_make_badarg(env);
    }
    component_handles[slot].active = 0;
    enif_mutex_unlock(component_mutex);
    return enif_make_atom(env, "ok");
}

// ── NIF: resolve_ipv4/1 ──────────────────────────────────────────────────────
//
// In-process IPv4 DNS resolution via Darwin's libc getaddrinfo. Exists
// because BEAM's normal DNS path (`inet_gethost`, a port-program subprocess)
// is unrunnable on iOS — the sandbox forbids execve of bundled helper
// binaries. getaddrinfo is a libc function that runs in the app process
// with no exec / no sandbox interaction, so DNS via this NIF works where
// BEAM's built-in path doesn't.
//
// Callers should not invoke this NIF directly in app code. Use
// `Mob.DNS.resolve/1` (Elixir wrapper) which also seeds `:inet_db` so
// subsequent `:inet.getaddr/2` lookups by Req / Finch / Mint find the
// host. See `guides/dns_on_ios.md`.
//
// Dirty-scheduled because getaddrinfo can block on network for the full
// resolver timeout (sometimes seconds). Keeping it off regular schedulers
// avoids head-of-line blocking on every other BEAM activity.
//
// Returns:
//   {:ok, {a, b, c, d}}
//   {:error, :badarg}        — host arg isn't a string/charlist
//   {:error, :nxdomain}      — no such hostname
//   {:error, :timeout}       — getaddrinfo TRY_AGAIN
//   {:error, :no_address}    — got a result but no IPv4 in the chain
//   {:error, {:gai, code}}   — anything else; `code` is the raw EAI_* int

static ERL_NIF_TERM nif_resolve_ipv4(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char host[256];
    int got = enif_get_string(env, argv[0], host, sizeof(host), ERL_NIF_LATIN1);

    if (got <= 0) {
        // got == 0 means the term wasn't a string; got < 0 means truncation.
        return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "badarg"));
    }

    struct addrinfo hints = {0};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *result = NULL;
    int err = getaddrinfo(host, NULL, &hints, &result);

    if (err != 0) {
        const char *atom = NULL;
        switch (err) {
        case EAI_NONAME:
        case EAI_NODATA:
            atom = "nxdomain";
            break;
        case EAI_AGAIN:
            atom = "timeout";
            break;
        default:
            break;
        }
        if (atom) {
            return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, atom));
        }
        // Anything else: surface the raw EAI_* code so the caller can
        // distinguish or log it.
        return enif_make_tuple2(
            env, enif_make_atom(env, "error"),
            enif_make_tuple2(env, enif_make_atom(env, "gai"), enif_make_int(env, err)));
    }

    // Walk the result chain for the first AF_INET. getaddrinfo with
    // ai_family=AF_INET should only return AF_INET entries but be
    // defensive in case the resolver returns IPv6-mapped records.
    ERL_NIF_TERM out_term = 0;
    for (struct addrinfo *ai = result; ai != NULL; ai = ai->ai_next) {
        if (ai->ai_family != AF_INET)
            continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)ai->ai_addr;
        uint32_t addr = ntohl(sin->sin_addr.s_addr);
        out_term = enif_make_tuple2(env, enif_make_atom(env, "ok"),
                                    enif_make_tuple4(env, enif_make_int(env, (addr >> 24) & 0xFF),
                                                     enif_make_int(env, (addr >> 16) & 0xFF),
                                                     enif_make_int(env, (addr >> 8) & 0xFF),
                                                     enif_make_int(env, addr & 0xFF)));
        break;
    }
    freeaddrinfo(result);

    if (out_term == 0) {
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_address"));
    }
    return out_term;
}

void mob_send_component_event(int handle, const char *event, const char *payload_json) {
    uint32_t generation;
    int slot;
    if (!mob_decode_event_handle(handle, &generation, &slot))
        return;

    enif_mutex_lock(component_mutex);
    if (!component_handles[slot].active || component_handles[slot].generation != generation) {
        enif_mutex_unlock(component_mutex);
        return;
    }
    ErlNifPid pid = component_handles[slot].pid;
    enif_mutex_unlock(component_mutex);

    ErlNifEnv *env = enif_alloc_env();
    // Binaries, not charlists (enif_make_string) — Mob.ComponentServer decodes
    // payload_json with :json.decode/1, which requires a binary.
    size_t event_len = strlen(event);
    size_t payload_len = strlen(payload_json);
    ErlNifBinary event_bin, payload_bin;
    if (!enif_alloc_binary(event_len, &event_bin)) {
        enif_free_env(env);
        return;
    }
    memcpy(event_bin.data, event, event_len);
    if (!enif_alloc_binary(payload_len, &payload_bin)) {
        enif_release_binary(&event_bin);
        enif_free_env(env);
        return;
    }
    memcpy(payload_bin.data, payload_json, payload_len);

    ERL_NIF_TERM msg =
        enif_make_tuple3(env, enif_make_atom(env, "component_event"),
                         enif_make_binary(env, &event_bin), enif_make_binary(env, &payload_bin));
    enif_send(NULL, &pid, env, msg);
    enif_free_env(env);
}

// ── Element frame registry (positions without a screenshot) ──────────────────
//
// mob_register_frame is called from MobFrameTracker (SwiftUI) on the main thread
// as a tagged element lays out; the element_frames NIF reads it from a NIF
// thread. Both use only public APIs, so this is compiled unconditionally (the
// reading NIF is still debug-gated). @synchronized guards the shared dictionary.
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *g_element_frames = nil;

// Side table: id -> the seq of the write that produced g_element_frames[id].
// Kept separate from g_element_frames so nif_element_frames can go on
// JSON-encoding that dictionary directly and the {"id":[x,y,w,h]} wire shape
// stays unchanged.
static NSMutableDictionary<NSString *, NSNumber *> *g_element_frame_seqs = nil;
static uint64_t g_frame_write_seq = 0;

// The id set from the most recent nif_set_root; nil until the first render.
// Guarded by the same lock as the registry.
static NSSet<NSString *> *g_live_frame_ids = nil;

// Bumped by nif_set_root on any identity-destroying (non-"none") transition,
// in lockstep with MobViewModel's navVersion. A tracker captures the value
// current when it appeared; writes stamped with an older one are refused, so
// an outgoing screen can't keep reporting itself as it animates away. Starts
// at 1 so 0 can mean "not captured yet".
static uint64_t g_frame_generation = 1;

static dispatch_once_t g_element_frames_once;

static NSMutableDictionary *mob_frame_registry(void) {
    dispatch_once(&g_element_frames_once, ^{
      g_element_frames = [NSMutableDictionary dictionary];
      g_element_frame_seqs = [NSMutableDictionary dictionary];
    });
    return g_element_frames;
}

// Read the current generation so a tracker can stamp its writes with the one
// that was current when it appeared.
uint64_t mob_frame_generation(void) {
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

uint64_t mob_register_frame(const char *id, uint64_t generation, double x, double y, double w,
                            double h) {
    if (!id)
        return 0;
    NSString *key = [NSString stringWithUTF8String:id];
    if (!key)
        return 0;
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        // Refuse a tracker from a superseded tree. Tree membership alone can't
        // do this: when the outgoing and incoming screens both tag an element
        // with the same :id, that id IS in the new tree, so the outgoing
        // screen's mid-animation writes would sail through the check below and
        // clobber the incoming element's frame with coordinates from halfway
        // off the screen. `generation == 0` means "not captured yet" and is
        // allowed through, so a tracker that registers before its onAppear
        // runs still records something.
        if (generation && generation < g_frame_generation)
            return 0;

        // Ignore writes for an id that isn't in the tree BEAM most recently
        // sent. MobViewModel.setRoot dispatches to the main thread
        // asynchronously, so a screen being animated out is still sliding
        // offscreen well after nif_set_root purged it.
        if (g_live_frame_ids && ![g_live_frame_ids containsObject:key])
            return 0;

        reg[key] = @[ @(x), @(y), @(w), @(h) ];
        uint64_t seq = ++g_frame_write_seq;
        g_element_frame_seqs[key] = @(seq);
        return seq;
    }
}

// Drop a tracked element's frame when it stops being laid out while its :id is
// still in the tree — a lazy-list row scrolled out of range (LazyVStack
// discards it), an inactive tab's subtree (TabView keeps every tab in the tree
// at once), a dismissed sheet's content (the sheet node stays mounted). Purging
// by id alone can't see any of these: the id is still present, so
// mob_adopt_frame_ids never drops it, and MobFrameTracker's onChange won't fire
// for it again. Its last on-screen frame would otherwise be reported forever,
// and Mob.Test.tap_id would tap whatever occupies those coordinates now.
//
// Compare-and-delete on `seq`: remove only if this caller's write is still the
// current one. An outgoing screen's .onDisappear therefore can't delete an
// entry an incoming screen just claimed under the same :id.
void mob_unregister_frame(const char *id, uint64_t seq) {
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

// Recursively collect every :id present in a freshly-parsed tree, so
// nif_set_root can purge just the registry entries that fell out of the new
// tree instead of wiping everything (see mob_adopt_frame_ids below for
// why: a wipe-everything + MobFrameTracker-repopulates design races
// SwiftUI's own removal pass for an outgoing element).
static void mob_collect_frame_ids_into(MobNode *node, NSMutableSet<NSString *> *ids) {
    if (node.nativeViewId)
        [ids addObject:node.nativeViewId];
    for (MobNode *child in node.children)
        mob_collect_frame_ids_into(child, ids);
}

static NSSet<NSString *> *mob_collect_frame_ids(MobNode *root) {
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    mob_collect_frame_ids_into(root, ids);
    return ids;
}

// Adopt the incoming tree's id set (called from nif_set_root): drop every
// registered frame whose id fell out of the tree, and retain the set so
// mob_register_frame can reject writes from views that are no longer in it.
// A surviving element's entry is never touched here — no race, no dependency
// on it re-registering itself — only genuinely-removed ids are dropped.
//
// Being in the tree is necessary but not sufficient for a frame to be live:
// see mob_unregister_frame for the elements that stay in the tree but stop
// being laid out.
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

// ── Mob.Peripheral.VendorUsb (iOS stubs) ──────────────────────────────────────
//
// iOS exposes no public USB-host API equivalent to Android's UsbManager.
// All seven NIFs below send {:peripheral, :vendor_usb, :error, nil, :unsupported}
// back to the caller and return :ok. Cross-platform screens see the error
// event and degrade gracefully via Mob.Peripheral.capabilities/0.

static void send_vendor_usb_unsupported(ErlNifPid pid) {
    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple5(e, enif_make_atom(e, "peripheral"),
                                        enif_make_atom(e, "vendor_usb"), enif_make_atom(e, "error"),
                                        enif_make_atom(e, "nil"), enif_make_atom(e, "unsupported"));
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

static ERL_NIF_TERM nif_vendor_usb_list_devices(ErlNifEnv *env, int argc,
                                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    ErlNifPid pid;
    enif_self(env, &pid);
    send_vendor_usb_unsupported(pid);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_vendor_usb_request_permission(ErlNifEnv *env, int argc,
                                                      const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    ErlNifPid pid;
    enif_self(env, &pid);
    send_vendor_usb_unsupported(pid);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_vendor_usb_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    ErlNifPid pid;
    enif_self(env, &pid);
    send_vendor_usb_unsupported(pid);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_vendor_usb_bulk_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    ErlNifPid pid;
    enif_self(env, &pid);
    send_vendor_usb_unsupported(pid);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_vendor_usb_start_reading(ErlNifEnv *env, int argc,
                                                 const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    ErlNifPid pid;
    enif_self(env, &pid);
    send_vendor_usb_unsupported(pid);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_vendor_usb_stop_reading(ErlNifEnv *env, int argc,
                                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_vendor_usb_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "ok");
}

// Scheduling notes for nif_funcs[] below — see docs/decisions/0001-dirty-nifs.md
// for the full rationale. Short version: most NIFs here either dispatch_async
// to the main queue and return in microseconds, or dispatch_sync but read a
// single property. Those stay on a regular scheduler.
//
// Four NIFs do non-trivial CPU work *on the BEAM thread* before any dispatch,
// or recurse through hundreds of accessibility elements while holding the
// main queue. They're marked ERL_NIF_DIRTY_JOB_CPU_BOUND so the regular
// scheduler isn't parked while they run:
//
//   * set_root        — JSON parse + MobNode tree construction; called per render
//   * set_transition  — sibling of set_root, same call pattern
//   * ui_tree         — recursive UIAccessibility walk (variable, can be 10s of ms)
//   * ui_debug        — same walk, more output
//
// Synthetic-input NIFs (swipe_xy, long_press_xy, type_text, key_press,
// delete_backward, clear_text) dispatch_sync to the main queue but also do
// some pre-dispatch work; they're left on regular schedulers for now because
// the test harness calls them in tight loops and dirty-dispatch overhead would
// add up. Re-evaluate if benchmarks show scheduler stalls under heavy harness use.
//
// tap_xy is the exception: it blocks up to MOB_TAP_SETTLE_MS waiting for the
// app to react (that wait is what makes its :ok trustworthy), which is far too
// long to hold a normal scheduler.
static ErlNifFunc nif_funcs[] = {
#if !MOB_RELEASE
    // ── Test harness (listed first to survive linker dead-code stripping) ──────
    // Compiled out of release builds — Erlang stubs in mob_nif.erl raise
    // :nif_error when these aren't loaded, which is the right thing for
    // shipped apps (the harness uses private UIKit APIs and Apple's
    // App Store validator rejects binaries that reference them).
    {"ui_tree", 0, nif_ui_tree, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"ui_view_tree", 0, nif_ui_view_tree, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"ui_paint_debug", 0, nif_ui_paint_debug, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"ui_debug", 0, nif_ui_debug, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"screen_info", 0, nif_screen_info, 0},
    {"tap", 1, nif_tap, 0},
    {"ax_action", 2, nif_ax_action, 0},
    {"ax_action_at_xy", 3, nif_ax_action_at_xy, 0},
    {"tap_xy", 2, nif_tap_xy, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"type_text", 1, nif_type_text, 0},
    {"delete_backward", 0, nif_delete_backward, 0},
    {"key_press", 1, nif_key_press, 0},
    {"clear_text", 0, nif_clear_text, 0},
    {"long_press_xy", 3, nif_long_press_xy, 0},
    {"swipe_xy", 4, nif_swipe_xy, 0},
#endif
#if !MOB_RELEASE || defined(MOB_ENABLE_SCREENSHOT)
    {"screenshot", 3, nif_screenshot, ERL_NIF_DIRTY_JOB_CPU_BOUND},
#endif
#if !MOB_RELEASE
    {"sample_region", 4, nif_sample_region, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"scroll_info", 1, nif_scroll_info, 0},
    {"scroll_to", 3, nif_scroll_to, 0},
    {"element_frames", 0, nif_element_frames, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"native_stats", 0, nif_native_stats, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"native_stats_enable", 1, nif_native_stats_enable, 0},
#endif
    // ── Core mob functions ───────────────────────────────────────────────────
    {"battery_level", 0, nif_battery_level, 0},
    // ── Mob.Device — lifecycle events + queries ──────────────────────────────
    {"device_set_dispatcher", 1, nif_device_set_dispatcher, 0},
    {"device_battery_state", 0, nif_device_battery_state, 0},
    {"device_thermal_state", 0, nif_device_thermal_state, 0},
    {"device_network_state", 0, nif_device_network_state, 0},
    {"device_low_power_mode", 0, nif_device_low_power_mode, 0},
    {"device_foreground", 0, nif_device_foreground, 0},
    {"device_os_version", 0, nif_device_os_version, 0},
    {"device_model", 0, nif_device_model, 0},
    {"device_orientation", 0, nif_device_orientation, 0},
    {"device_lock_orientation", 1, nif_device_lock_orientation, 0},
    {"device_keep_awake", 1, nif_device_keep_awake, 0},
    {"platform", 0, nif_platform, 0},
    {"color_scheme", 0, nif_color_scheme, 0},
    {"log", 1, nif_log, 0},
    {"log", 2, nif_log2, 0},
    {"set_transition", 1, nif_set_transition, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"set_root", 1, nif_set_root, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"set_theme", 1, nif_set_theme, 0},
    {"register_tap", 1, nif_register_tap, 0},
    {"clear_taps", 0, nif_clear_taps, 0},
    {"exit_app", 0, nif_exit_app, 0},
    {"safe_area", 0, nif_safe_area, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"haptic", 1, nif_haptic, 0},
    {"torch", 1, nif_torch, 0},
    {"clipboard_put", 1, nif_clipboard_put, 0},
    {"clipboard_get", 0, nif_clipboard_get, 0},
    {"share_text", 1, nif_share_text, 0},
    {"open_url", 1, nif_open_url, 0},
    {"open_settings", 1, nif_open_settings, 0},
    {"request_permission", 1, nif_request_permission, 0},
    {"files_pick", 1, nif_files_pick, 0},
    {"audio_start_recording", 1, nif_audio_start_recording, 0},
    {"audio_stop_recording", 0, nif_audio_stop_recording, 0},
    {"audio_start_input_metering", 0, nif_audio_start_input_metering, 0},
    {"audio_input_level", 0, nif_audio_input_level, 0},
    {"audio_stop_input_metering", 0, nif_audio_stop_input_metering, 0},
    {"audio_play", 2, nif_audio_play, 0},
    {"audio_play_at", 3, nif_audio_play_at, 0},
    {"audio_stop_playback", 0, nif_audio_stop_playback, 0},
    {"audio_set_volume", 1, nif_audio_set_volume, 0},
    {"audio_output_status", 0, nif_audio_output_status, 0},
    {"audio_output_level", 1, nif_audio_output_level, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"tts_speak", 2, nif_tts_speak, 0},
    {"tts_stop", 0, nif_tts_stop, 0},
    {"motion_start", 2, nif_motion_start, 0},
    {"motion_stop", 0, nif_motion_stop, 0},
    {"take_launch_notification", 0, nif_take_launch_notification, 0},
    {"take_opened_document", 0, nif_take_opened_document, 0},
    {"storage_dir", 1, nif_storage_dir, 0},
    {"storage_save_to_photo_library", 1, nif_storage_save_to_photo_library, 0},
    {"storage_save_to_media_store", 2, nif_storage_save_to_media_store, 0},
    {"storage_external_files_dir", 1, nif_storage_external_files_dir, 0},
    {"alert_show", 3, nif_alert_show, 0},
    {"action_sheet_show", 2, nif_action_sheet_show, 0},
    {"toast_show", 2, nif_toast_show, 0},
    {"webview_eval_js", 1, nif_webview_eval_js, 0},
    {"webview_post_message", 1, nif_webview_post_message, 0},
    {"webview_can_go_back", 0, nif_webview_can_go_back, 0},
    {"webview_go_back", 0, nif_webview_go_back, 0},
    {"register_component", 1, nif_register_component, 0},
    {"deregister_component", 1, nif_deregister_component, 0},
    // ── Mob.Peripheral.VendorUsb (iOS stubs — emit :unsupported) ──────────────
    {"vendor_usb_list_devices", 1, nif_vendor_usb_list_devices, 0},
    {"vendor_usb_request_permission", 1, nif_vendor_usb_request_permission, 0},
    {"vendor_usb_open", 1, nif_vendor_usb_open, 0},
    {"vendor_usb_bulk_write", 3, nif_vendor_usb_bulk_write, 0},
    {"vendor_usb_start_reading", 2, nif_vendor_usb_start_reading, 0},
    {"vendor_usb_stop_reading", 1, nif_vendor_usb_stop_reading, 0},
    {"vendor_usb_close", 1, nif_vendor_usb_close, 0},
    // getaddrinfo can block on the resolver for seconds — dirty-IO so it
    // doesn't head-of-line-block the regular schedulers. See the impl
    // above for the iOS rationale.
    {"resolve_ipv4", 1, nif_resolve_ipv4, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

static int nif_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    LOGI(@"nif_load: initialising mob_nif (iOS/SwiftUI JSON backend)");
    tap_mutex = enif_mutex_create("mob_tap_mutex");
    if (!tap_mutex) {
        LOGE(@"nif_load: failed to create tap mutex");
        return -1;
    }
    component_mutex = enif_mutex_create("mob_component_mutex");
    if (!component_mutex) {
        LOGE(@"nif_load: failed to create component mutex");
        return -1;
    }
    g_launch_notif_mutex = enif_mutex_create("mob_launch_notif_mutex");
    g_opened_doc_mutex = enif_mutex_create("mob_opened_doc_mutex");
    if (!g_launch_notif_mutex) {
        LOGE(@"nif_load: failed to create launch notif mutex");
        return -1;
    }
    LOGI(@"nif_load: mob_nif ready");
    return 0;
}

ERL_NIF_INIT(mob_nif, nif_funcs, nif_load, NULL, NULL, NULL)
