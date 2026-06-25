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
#include "erl_nif.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMotion/CoreMotion.h>
#import <Photos/Photos.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <UserNotifications/UserNotifications.h>
#include <string.h>

#define LOGI(...) NSLog(@"[MobNIF] " __VA_ARGS__)
#define LOGE(...) NSLog(@"[MobNIF][ERROR] " __VA_ARGS__)

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
// Cleared before every render. Max 256 tappable elements per frame.

#define MAX_TAP_HANDLES 256

typedef struct {
    ErlNifPid pid;
    ErlNifEnv *tag_env; // persistent env owning tag; NULL when slot is free
    ERL_NIF_TERM tag;

    // ── Batch 5 throttle state — populated by mob_set_throttle_config ──
    int throttle_ms; // 0 = no throttle (raw firing)
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
static TapHandle tap_tables[2][MAX_TAP_HANDLES];
static int tap_active = 0;
static TapHandle *tap_handles = tap_tables[0]; // active table (readers use this)
static int tap_handle_next = 0;                // active committed count (readers' bound)
static int tap_build_count = 0;                // cursor into the building table
static ErlNifMutex *tap_mutex = NULL;

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
    if (handle >= 0 && handle < tap_handle_next && tap_handles[handle].tag_env) {
        tap_handles[handle].throttle_ms = throttle_ms;
        tap_handles[handle].debounce_ms = debounce_ms;
        tap_handles[handle].delta_threshold = delta_threshold;
        tap_handles[handle].leading = leading;
        tap_handles[handle].trailing = trailing;
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
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return 0;
    }
    TapHandle *h = &tap_handles[handle];

    int throttle_ms = h->throttle_ms ? h->throttle_ms : default_throttle_ms;
    double delta_threshold = h->delta_threshold > 0 ? h->delta_threshold : default_delta;

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
    if (handle >= 0 && handle < tap_handle_next && tap_handles[handle].tag_env) {
        *seq_out = tap_handles[handle].seq;
        *ts_out = mob_now_ns() / 1000000ULL; // ms since boot
    } else {
        *seq_out = 0;
        *ts_out = 0;
    }
    enif_mutex_unlock(tap_mutex);
}
static char g_transition[16] = "none";

// Called from node onTap blocks — routes tap to BEAM via enif_send.
static void mob_send_tap(int handle) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM msg =
        enif_make_tuple2(msg_env, enif_make_atom(msg_env, "tap"), enif_make_copy(msg_env, tag));
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

// ── Focus / blur / submit senders ────────────────────────────────────────────
// Called from MobTextField SwiftUI view when focus state changes or return key tapped.

static void mob_send_event(int handle, const char *atom) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM msg =
        enif_make_tuple2(msg_env, enif_make_atom(msg_env, atom), enif_make_copy(msg_env, tag));
    enif_send(NULL, &pid, msg_env, msg);
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

// IME composition. Sends {compose, tag, %{text: ..., phase: ...}} where
// phase is one of began/updating/committed/cancelled. Called from the
// text-input layer when marked-text state changes.
static void mob_send_compose(int handle, const char *text, const char *phase) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv *msg_env = enif_alloc_env();
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
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "compose"),
                                        enif_make_copy(msg_env, tag), payload);
    enif_send(NULL, &pid, msg_env, msg);
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
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "swipe"), enif_make_copy(msg_env, tag),
                         enif_make_atom(msg_env, direction));
    enif_send(NULL, &pid, msg_env, msg);
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

    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    uint64_t seq = tap_handles[handle].seq;
    enif_mutex_unlock(tap_mutex);

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM payload = mob_build_scroll_payload(msg_env, x, y, dx, dy, vx, vy, phase, ts, seq);
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "scroll"),
                                        enif_make_copy(msg_env, tag), payload);
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_drag(int handle, double x, double y, double dx, double dy, const char *phase) {
    int is_phase_boundary = (strcmp(phase, "began") == 0) || (strcmp(phase, "ended") == 0);
    if (!is_phase_boundary && !mob_throttle_check(handle, x, y, 16, 1.0))
        return;

    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    uint64_t seq = tap_handles[handle].seq;
    enif_mutex_unlock(tap_mutex);

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ErlNifEnv *msg_env = enif_alloc_env();
    // Drag payload: %{x, y, dx, dy, phase, ts, seq}
    ERL_NIF_TERM keys[7] = {
        enif_make_atom(msg_env, "x"),     enif_make_atom(msg_env, "y"),
        enif_make_atom(msg_env, "dx"),    enif_make_atom(msg_env, "dy"),
        enif_make_atom(msg_env, "phase"), enif_make_atom(msg_env, "ts"),
        enif_make_atom(msg_env, "seq"),
    };
    ERL_NIF_TERM vals[7] = {
        enif_make_double(msg_env, x),   enif_make_double(msg_env, y),
        enif_make_double(msg_env, dx),  enif_make_double(msg_env, dy),
        enif_make_atom(msg_env, phase), enif_make_uint64(msg_env, ts),
        enif_make_uint64(msg_env, seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 7, &payload);
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "drag"),
                                        enif_make_copy(msg_env, tag), payload);
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_pinch(int handle, double scale, double velocity, const char *phase) {
    int is_phase_boundary = (strcmp(phase, "began") == 0) || (strcmp(phase, "ended") == 0);
    if (!is_phase_boundary && !mob_throttle_check(handle, scale, 0, 16, 0.01))
        return;

    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    uint64_t seq = tap_handles[handle].seq;
    enif_mutex_unlock(tap_mutex);

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM keys[5] = {
        enif_make_atom(msg_env, "scale"), enif_make_atom(msg_env, "velocity"),
        enif_make_atom(msg_env, "phase"), enif_make_atom(msg_env, "ts"),
        enif_make_atom(msg_env, "seq"),
    };
    ERL_NIF_TERM vals[5] = {
        enif_make_double(msg_env, scale), enif_make_double(msg_env, velocity),
        enif_make_atom(msg_env, phase),   enif_make_uint64(msg_env, ts),
        enif_make_uint64(msg_env, seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 5, &payload);
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "pinch"),
                                        enif_make_copy(msg_env, tag), payload);
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_rotate(int handle, double degrees, double velocity, const char *phase) {
    int is_phase_boundary = (strcmp(phase, "began") == 0) || (strcmp(phase, "ended") == 0);
    if (!is_phase_boundary && !mob_throttle_check(handle, degrees, 0, 16, 1.0))
        return;

    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    uint64_t seq = tap_handles[handle].seq;
    enif_mutex_unlock(tap_mutex);

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM keys[5] = {
        enif_make_atom(msg_env, "degrees"), enif_make_atom(msg_env, "velocity"),
        enif_make_atom(msg_env, "phase"),   enif_make_atom(msg_env, "ts"),
        enif_make_atom(msg_env, "seq"),
    };
    ERL_NIF_TERM vals[5] = {
        enif_make_double(msg_env, degrees), enif_make_double(msg_env, velocity),
        enif_make_atom(msg_env, phase),     enif_make_uint64(msg_env, ts),
        enif_make_uint64(msg_env, seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 5, &payload);
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "rotate"),
                                        enif_make_copy(msg_env, tag), payload);
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_pointer_move(int handle, double x, double y) {
    if (!mob_throttle_check(handle, x, y, 33, 4.0))
        return;

    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    uint64_t seq = tap_handles[handle].seq;
    enif_mutex_unlock(tap_mutex);

    uint64_t ts = mob_now_ns() / 1000000ULL;
    ErlNifEnv *msg_env = enif_alloc_env();
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
        enif_make_uint64(msg_env, seq),
    };
    ERL_NIF_TERM payload;
    enif_make_map_from_arrays(msg_env, keys, vals, 4, &payload);
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "pointer_move"),
                                        enif_make_copy(msg_env, tag), payload);
    enif_send(NULL, &pid, msg_env, msg);
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
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM msg =
        enif_make_tuple3(msg_env, enif_make_atom(msg_env, "change"), enif_make_copy(msg_env, tag),
                         enif_make_copy(msg_env, value_term));
    enif_send(NULL, &pid, msg_env, msg);
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

    NSDictionary *props = dict[@"props"];
    if ([props isKindOfClass:[NSDictionary class]]) {
        id text = props[@"text"];
        if (text)
            node.text = [text isKindOfClass:[NSString class]] ? text : [text description];

        // For text_field, `value:` is the controlled-input prop name (matches
        // the React/SwiftUI convention used in app code and demos). Map it
        // to `node.text` so MobTextField sees it as initialText. If both
        // `text:` and `value:` are passed, `value:` wins.
        if (node.nodeType == MobNodeTypeTextField) {
            id valueText = props[@"value"];
            if (valueText)
                node.text = [valueText isKindOfClass:[NSString class]] ? valueText
                                                                       : [valueText description];
        }

        id padding = props[@"padding"];
        if (padding)
            node.padding = [padding doubleValue];

        id paddingTop = props[@"padding_top"];
        if (paddingTop)
            node.paddingTop = [paddingTop doubleValue];
        id paddingRight = props[@"padding_right"];
        if (paddingRight)
            node.paddingRight = [paddingRight doubleValue];
        id paddingBottom = props[@"padding_bottom"];
        if (paddingBottom)
            node.paddingBottom = [paddingBottom doubleValue];
        id paddingLeft = props[@"padding_left"];
        if (paddingLeft)
            node.paddingLeft = [paddingLeft doubleValue];

        id textSize = props[@"text_size"];
        if (textSize)
            node.textSize = [textSize doubleValue];

        id fontFamily = props[@"font"];
        if ([fontFamily isKindOfClass:[NSString class]])
            node.fontFamily = fontFamily;
        id fontWeight = props[@"font_weight"];
        if (fontWeight)
            node.fontWeight = [fontWeight description];
        id textAlign = props[@"text_align"];
        if (textAlign)
            node.textAlign = [textAlign description];
        id italic = props[@"italic"];
        if (italic)
            node.italic = [italic boolValue];
        id lineHeight = props[@"line_height"];
        if (lineHeight)
            node.lineHeight = [lineHeight doubleValue];
        id letterSpacing = props[@"letter_spacing"];
        if (letterSpacing)
            node.letterSpacing = [letterSpacing doubleValue];

        id tabDefs = props[@"tabs"];
        if ([tabDefs isKindOfClass:[NSArray class]])
            node.tabDefs = tabDefs;
        id activeTab = props[@"active"];
        if (activeTab)
            node.activeTab = [activeTab description];
        id onTabSelect = props[@"on_tab_select"];
        if (onTabSelect && [onTabSelect isKindOfClass:[NSNumber class]]) {
            int handle = [onTabSelect intValue];
            node.onTabSelect = ^(NSString *tabId) {
              mob_send_change_str(handle, [tabId UTF8String]);
            };
        }

        id bg = props[@"background"];
        if (bg)
            node.backgroundColor = color_from_argb((long)[bg longLongValue]);

        id borderColor = props[@"border_color"];
        if (borderColor)
            node.borderColor = color_from_argb((long)[borderColor longLongValue]);

        id borderWidth = props[@"border_width"];
        if (borderWidth)
            node.borderWidth = [borderWidth doubleValue];

        id textColor = props[@"text_color"];
        if (textColor)
            node.textColor = color_from_argb((long)[textColor longLongValue]);

        id color = props[@"color"];
        if (color)
            node.color = color_from_argb((long)[color longLongValue]);

        id thickness = props[@"thickness"];
        if (thickness)
            node.thickness = [thickness doubleValue];

        id fixedSize = props[@"size"];
        if (fixedSize)
            node.fixedSize = [fixedSize doubleValue];

        id axis = props[@"axis"];
        if ([axis isKindOfClass:[NSString class]])
            node.axis = axis;

        // `align` plays two roles depending on node type — the Mob renderer
        // sets the same string and the iOS side picks the relevant
        // interpretation per case (rowAlign for HStack, boxAlign for ZStack).
        id alignProp = props[@"align"];
        if ([alignProp isKindOfClass:[NSString class]]) {
            node.rowAlign = alignProp;
            node.boxAlign = alignProp;
        }

        id offsetX = props[@"offset_x"];
        if (offsetX)
            node.offsetX = [offsetX doubleValue];
        id offsetY = props[@"offset_y"];
        if (offsetY)
            node.offsetY = [offsetY doubleValue];

        id showIndicator = props[@"show_indicator"];
        if (showIndicator)
            node.showIndicator = [showIndicator boolValue];

        id value = props[@"value"];
        if (value)
            node.value = [value doubleValue];

        id onTap = props[@"on_tap"];
        if (onTap && [onTap isKindOfClass:[NSNumber class]]) {
            int handle = [onTap intValue];
            node.onTap = ^{
              mob_send_tap(handle);
            };
        }

        id placeholder = props[@"placeholder"];
        if (placeholder)
            node.placeholder = [placeholder isKindOfClass:[NSString class]]
                                   ? placeholder
                                   : [placeholder description];

        // Icon name — logical key (e.g. "settings"), resolved to an SF Symbol
        // by MobIconView at render time. iOS-only string parsing here.
        if (node.nodeType == MobNodeTypeIcon) {
            id iconName = props[@"name"];
            if (iconName)
                node.iconName =
                    [iconName isKindOfClass:[NSString class]] ? iconName : [iconName description];
        }

        id keyboardType = props[@"keyboard"];
        if ([keyboardType isKindOfClass:[NSString class]])
            node.keyboardTypeStr = keyboardType;

        id returnKey = props[@"return_key"];
        if ([returnKey isKindOfClass:[NSString class]])
            node.returnKeyStr = returnKey;

        id secure = props[@"secure"];
        if ([secure isKindOfClass:[NSNumber class]])
            node.isSecure = [secure boolValue];

        id onFocus = props[@"on_focus"];
        if (onFocus && [onFocus isKindOfClass:[NSNumber class]]) {
            int handle = [onFocus intValue];
            node.onFocus = ^{
              mob_send_focus(handle);
            };
        }

        id onBlur = props[@"on_blur"];
        if (onBlur && [onBlur isKindOfClass:[NSNumber class]]) {
            int handle = [onBlur intValue];
            node.onBlur = ^{
              mob_send_blur(handle);
            };
        }

        id onSubmit = props[@"on_submit"];
        if (onSubmit && [onSubmit isKindOfClass:[NSNumber class]]) {
            int handle = [onSubmit intValue];
            node.onSubmit = ^{
              mob_send_submit(handle);
            };
        }

        id onCompose = props[@"on_compose"];
        if (onCompose && [onCompose isKindOfClass:[NSNumber class]]) {
            int handle = [onCompose intValue];
            node.onCompose = ^(NSString *text, NSString *phase) {
              mob_send_compose(handle, text ? [text UTF8String] : "",
                               phase ? [phase UTF8String] : "updating");
            };
        }

        id onSelect = props[@"on_select"];
        if (onSelect && [onSelect isKindOfClass:[NSNumber class]]) {
            int handle = [onSelect intValue];
            node.onSelect = ^{
              mob_send_select(handle);
            };
        }

        // ── Gestures (Batch 4) ──
        id onLongPress = props[@"on_long_press"];
        if (onLongPress && [onLongPress isKindOfClass:[NSNumber class]]) {
            int handle = [onLongPress intValue];
            node.onLongPress = ^{
              mob_send_long_press(handle);
            };
        }

        id onDoubleTap = props[@"on_double_tap"];
        if (onDoubleTap && [onDoubleTap isKindOfClass:[NSNumber class]]) {
            int handle = [onDoubleTap intValue];
            node.onDoubleTap = ^{
              mob_send_double_tap(handle);
            };
        }

        id onSwipe = props[@"on_swipe"];
        if (onSwipe && [onSwipe isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipe intValue];
            node.onSwipe = ^(NSString *direction) {
              mob_send_swipe_with_direction(handle, [direction UTF8String]);
            };
        }

        id onSwipeLeft = props[@"on_swipe_left"];
        if (onSwipeLeft && [onSwipeLeft isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipeLeft intValue];
            node.onSwipeLeft = ^{
              mob_send_swipe_left(handle);
            };
        }

        id onSwipeRight = props[@"on_swipe_right"];
        if (onSwipeRight && [onSwipeRight isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipeRight intValue];
            node.onSwipeRight = ^{
              mob_send_swipe_right(handle);
            };
        }

        id onSwipeUp = props[@"on_swipe_up"];
        if (onSwipeUp && [onSwipeUp isKindOfClass:[NSNumber class]]) {
            int handle = [onSwipeUp intValue];
            node.onSwipeUp = ^{
              mob_send_swipe_up(handle);
            };
        }

        id onSwipeDown = props[@"on_swipe_down"];
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

        id onScroll = props[@"on_scroll"];
        if ([onScroll isKindOfClass:[NSNumber class]]) {
            int handle = [onScroll intValue];
            MOB_APPLY_THROTTLE(handle, @"scroll_config");
            node.onScroll = ^(CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, CGFloat vx, CGFloat vy,
                              NSString *phase) {
              mob_send_scroll(handle, x, y, dx, dy, vx, vy,
                              phase ? [phase UTF8String] : "dragging");
            };
        }

        id onDrag = props[@"on_drag"];
        if ([onDrag isKindOfClass:[NSNumber class]]) {
            int handle = [onDrag intValue];
            MOB_APPLY_THROTTLE(handle, @"drag_config");
            node.onDrag = ^(CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, NSString *phase) {
              mob_send_drag(handle, x, y, dx, dy, phase ? [phase UTF8String] : "dragging");
            };
        }

        id onPinch = props[@"on_pinch"];
        if ([onPinch isKindOfClass:[NSNumber class]]) {
            int handle = [onPinch intValue];
            MOB_APPLY_THROTTLE(handle, @"pinch_config");
            node.onPinch = ^(CGFloat scale, CGFloat velocity, NSString *phase) {
              mob_send_pinch(handle, scale, velocity, phase ? [phase UTF8String] : "dragging");
            };
        }

        id onRotate = props[@"on_rotate"];
        if ([onRotate isKindOfClass:[NSNumber class]]) {
            int handle = [onRotate intValue];
            MOB_APPLY_THROTTLE(handle, @"rotate_config");
            node.onRotate = ^(CGFloat degrees, CGFloat velocity, NSString *phase) {
              mob_send_rotate(handle, degrees, velocity, phase ? [phase UTF8String] : "dragging");
            };
        }

        id onPointerMove = props[@"on_pointer_move"];
        if ([onPointerMove isKindOfClass:[NSNumber class]]) {
            int handle = [onPointerMove intValue];
            MOB_APPLY_THROTTLE(handle, @"pointer_config");
            node.onPointerMove = ^(CGFloat x, CGFloat y) {
              mob_send_pointer_move(handle, x, y);
            };
        }

#undef MOB_APPLY_THROTTLE

        // ── Batch 5 Tier 2: semantic single-fire scroll events ──
        id onScrollBegan = props[@"on_scroll_began"];
        if ([onScrollBegan isKindOfClass:[NSNumber class]]) {
            int handle = [onScrollBegan intValue];
            node.onScrollBegan = ^{
              mob_send_scroll_began(handle);
            };
        }

        id onScrollEnded = props[@"on_scroll_ended"];
        if ([onScrollEnded isKindOfClass:[NSNumber class]]) {
            int handle = [onScrollEnded intValue];
            node.onScrollEnded = ^{
              mob_send_scroll_ended(handle);
            };
        }

        id onScrollSettled = props[@"on_scroll_settled"];
        if ([onScrollSettled isKindOfClass:[NSNumber class]]) {
            int handle = [onScrollSettled intValue];
            node.onScrollSettled = ^{
              mob_send_scroll_settled(handle);
            };
        }

        id onTopReached = props[@"on_top_reached"];
        if ([onTopReached isKindOfClass:[NSNumber class]]) {
            int handle = [onTopReached intValue];
            node.onTopReached = ^{
              mob_send_top_reached(handle);
            };
        }

        id onScrolledPast = props[@"on_scrolled_past"];
        if ([onScrolledPast isKindOfClass:[NSNumber class]]) {
            int handle = [onScrolledPast intValue];
            node.onScrolledPast = ^{
              mob_send_scrolled_past(handle);
            };
        }
        id scrolledPastThreshold = props[@"scrolled_past_threshold"];
        if (scrolledPastThreshold) {
            node.scrolledPastThreshold = [scrolledPastThreshold doubleValue];
        }

        // ── Batch 5 Tier 3: native-side scroll-driven UI configs ──
        // Pass-through to the SwiftUI layer; never round-trips to BEAM.
        id parallax = props[@"parallax"];
        if ([parallax isKindOfClass:[NSDictionary class]]) {
            node.parallaxConfig = parallax;
        }
        id fadeOnScroll = props[@"fade_on_scroll"];
        if ([fadeOnScroll isKindOfClass:[NSDictionary class]]) {
            node.fadeOnScrollConfig = fadeOnScroll;
        }
        id stickyConfig = props[@"sticky_when_scrolled_past"];
        if ([stickyConfig isKindOfClass:[NSDictionary class]]) {
            node.stickyWhenScrolledPastConfig = stickyConfig;
        }

        id checked = props[@"value"];
        if (checked && node.nodeType == MobNodeTypeToggle) {
            // value is a boolean atom serialised as "true"/"false"
            node.checked = [[checked description] isEqualToString:@"true"] ||
                           ([checked isKindOfClass:[NSNumber class]] && [checked boolValue]);
        }

        id minVal = props[@"min"];
        if (minVal)
            node.minValue = [minVal doubleValue];

        id maxVal = props[@"max"];
        if (maxVal)
            node.maxValue = [maxVal doubleValue];

        id src = props[@"src"];
        if ([src isKindOfClass:[NSString class]])
            node.src = src;

        id contentMode = props[@"content_mode"];
        if ([contentMode isKindOfClass:[NSString class]])
            node.contentModeStr = contentMode;

        id fixedWidth = props[@"width"];
        if (fixedWidth)
            node.fixedWidth = [fixedWidth doubleValue];

        id fixedHeight = props[@"height"];
        if (fixedHeight)
            node.fixedHeight = [fixedHeight doubleValue];

        id cornerRadius = props[@"corner_radius"];
        if (cornerRadius)
            node.cornerRadius = [cornerRadius doubleValue];

        // Liquid Glass opt-in — set by Mob.Renderer when the active theme
        // has `glass: true`. MobBox swaps a solid background for
        // `.glassEffect()` on iOS 26+, or `.ultraThinMaterial` on iOS 17–25.
        id useGlass = props[@"glass"];
        if (useGlass)
            node.useGlass = [useGlass boolValue];

        id fillWidth = props[@"fill_width"];
        if (fillWidth)
            node.fillWidth = [fillWidth boolValue];

        id fillHeight = props[@"fill_height"];
        if (fillHeight)
            node.fillHeight = [fillHeight boolValue];

        id placeholderColor = props[@"placeholder_color"];
        if (placeholderColor)
            node.placeholderColor = color_from_argb((long)[placeholderColor longLongValue]);

        id videoAutoplay = props[@"autoplay"];
        if (videoAutoplay)
            node.videoAutoplay = [videoAutoplay boolValue];
        id videoLoop = props[@"loop"];
        if (videoLoop)
            node.videoLoop = [videoLoop boolValue];
        id videoControls = props[@"controls"];
        if (videoControls)
            node.videoControls = [videoControls boolValue];

        id cameraFacing = props[@"facing"];
        if ([cameraFacing isKindOfClass:[NSString class]])
            node.cameraFacing = cameraFacing;

        // canvas props
        id canvasDraw = props[@"draw"];
        if ([canvasDraw isKindOfClass:[NSArray class]])
            node.canvasOps = canvasDraw;
        id canvasW = props[@"width"];
        if (canvasW && node.nodeType == MobNodeTypeCanvas)
            node.canvasWidth = [canvasW doubleValue];
        id canvasH = props[@"height"];
        if (canvasH && node.nodeType == MobNodeTypeCanvas)
            node.canvasHeight = [canvasH doubleValue];

        // gpu_view props: shader (string OR %{ios: "..."} map) + uniforms map.
        // Map form is the "I already have hand-tuned MSL" escape hatch.
        if (node.nodeType == MobNodeTypeGpuView) {
            id shader = props[@"shader"];
            if ([shader isKindOfClass:[NSString class]]) {
                node.gpuShaderMSL = shader;
            } else if ([shader isKindOfClass:[NSDictionary class]]) {
                id iosShader = ((NSDictionary *)shader)[@"ios"];
                if ([iosShader isKindOfClass:[NSString class]])
                    node.gpuShaderMSL = iosShader;
            }

            id uniforms = props[@"uniforms"];
            if ([uniforms isKindOfClass:[NSArray class]] ||
                [uniforms isKindOfClass:[NSDictionary class]])
                node.gpuUniforms = uniforms;
        }

        // webview props
        id webViewUrl = props[@"url"];
        if ([webViewUrl isKindOfClass:[NSString class]])
            node.webViewUrl = webViewUrl;
        id webViewAllow = props[@"allow"];
        if ([webViewAllow isKindOfClass:[NSString class]])
            node.webViewAllow = webViewAllow;
        id webViewShowUrl = props[@"show_url"];
        if (webViewShowUrl)
            node.webViewShowUrl = [webViewShowUrl boolValue];
        id webViewTitle = props[@"title"];
        if ([webViewTitle isKindOfClass:[NSString class]])
            node.webViewTitle = webViewTitle;

        // native_view props
        id nativeViewModule = props[@"module"];
        if ([nativeViewModule isKindOfClass:[NSString class]])
            node.nativeViewModule = nativeViewModule;
        id nativeViewId = props[@"id"];
        if ([nativeViewId isKindOfClass:[NSString class]])
            node.nativeViewId = nativeViewId;
        id nativeViewHandle = props[@"component_handle"];
        if (nativeViewHandle)
            node.nativeViewHandle = [nativeViewHandle intValue];
        if (node.nodeType == MobNodeTypeNativeView)
            node.nativeViewProps = props;

        id onEndReached = props[@"on_end_reached"];
        if (onEndReached && [onEndReached isKindOfClass:[NSNumber class]]) {
            int handle = [onEndReached intValue];
            node.onTap = ^{
              mob_send_tap(handle);
            };
        }

        // For slider, value is the initial position (re-uses node.value property)
        // text_field initial text re-uses node.text property

        id onChange = props[@"on_change"];
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

        id accessibilityId = props[@"accessibility_id"];
        if ([accessibilityId isKindOfClass:[NSString class]]) {
            node.accessibilityId = accessibilityId;
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

// ── NIF: safe_area/0 ─────────────────────────────────────────────────────────
// Returns {Top, Right, Bottom, Left} in logical points (not pixels).
// Must read UIWindow.safeAreaInsets on the main thread.

static ERL_NIF_TERM nif_safe_area(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block UIEdgeInsets insets = UIEdgeInsetsZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
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
    });
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
// Mob.Theme.set/1 and push it to the SwiftUI side. iOS doesn't use system
// chrome whose appearance depends on a global theme (we render every
// surface via mob's primitives with explicit color props), so the iOS
// implementation is a no-op that just confirms receipt. Kept here for
// symmetry with the Android implementation, which needs it to drive
// Material 3's NavigationBar / Button colour scheme.
static ERL_NIF_TERM nif_set_theme(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "ok");
}

static NSMutableDictionary *mob_frame_registry(void); // both defined with the
static void mob_clear_frames(void);                   // element frame registry below

static ERL_NIF_TERM nif_set_root(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    // New render tree — drop stale element frames; MobFrameTracker repopulates
    // on the next layout pass.
    mob_clear_frames();

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

    // Snapshot and reset the transition
    enif_mutex_lock(tap_mutex);
    char transition[16];
    strncpy(transition, g_transition, sizeof(transition) - 1);
    transition[sizeof(transition) - 1] = 0;
    strncpy(g_transition, "none", sizeof(g_transition));
    // Commit the freshly-built tap table: register_tap wrote this frame's
    // handlers into 1 - tap_active; make that table active now so events for the
    // new tree resolve against it (readers see a consistent pair under the lock).
    tap_active = 1 - tap_active;
    tap_handles = tap_tables[tap_active];
    tap_handle_next = tap_build_count;
    enif_mutex_unlock(tap_mutex);

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
    if (tap_build_count >= MAX_TAP_HANDLES) {
        enif_mutex_unlock(tap_mutex);
        return enif_make_badarg(env);
    }
    TapHandle *build = tap_tables[1 - tap_active];
    int handle = tap_build_count++;
    build[handle].pid = pid;
    build[handle].tag_env = enif_alloc_env();
    build[handle].tag = enif_make_copy(build[handle].tag_env, tag_term);
    enif_mutex_unlock(tap_mutex);

    return enif_make_int(env, handle);
}

// ── NIF: clear_taps/0 ─────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_clear_taps(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(tap_mutex);
    // Prepare the INACTIVE (building) table for a fresh frame; leave the active
    // table intact so concurrent mob_send_* keep resolving the last committed
    // frame. The freshly built table is swapped in at set_root.
    TapHandle *build = tap_tables[1 - tap_active];
    for (int i = 0; i < MAX_TAP_HANDLES; i++) {
        if (build[i].tag_env) {
            enif_free_env(build[i].tag_env);
            build[i].tag_env = NULL;
        }
        // Reset throttle state — slots get reused across renders.
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
    if (!g_launch_notif_mutex)
        return;
    enif_mutex_lock(g_launch_notif_mutex);
    free(g_launch_notification_json);
    g_launch_notification_json = json ? strdup(json) : NULL;
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

static ERL_NIF_TERM nif_motion_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);
    g_motion_pid = pid;
    int interval_ms = 100;
    // argv[0] is a list of sensor name binaries; argv[1] is interval_ms int
    enif_get_int(env, argv[1], &interval_ms);

    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_motion_manager)
          g_motion_manager = [[CMMotionManager alloc] init];
      NSTimeInterval interval = interval_ms / 1000.0;
      g_motion_manager.deviceMotionUpdateInterval = interval;
      [g_motion_manager
          startDeviceMotionUpdatesToQueue:[NSOperationQueue new]
                              withHandler:^(CMDeviceMotion *motion, NSError *err) {
                                if (!motion)
                                    return;
                                ErlNifPid p = g_motion_pid;
                                double ax = motion.userAcceleration.x + motion.gravity.x;
                                double ay = motion.userAcceleration.y + motion.gravity.y;
                                double az = motion.userAcceleration.z + motion.gravity.z;
                                double gx = motion.rotationRate.x;
                                double gy = motion.rotationRate.y;
                                double gz = motion.rotationRate.z;
                                ErlNifEnv *e = enif_alloc_env();
                                ERL_NIF_TERM accel = enif_make_tuple3(e, enif_make_double(e, ax),
                                                                      enif_make_double(e, ay),
                                                                      enif_make_double(e, az));
                                ERL_NIF_TERM gyro = enif_make_tuple3(e, enif_make_double(e, gx),
                                                                     enif_make_double(e, gy),
                                                                     enif_make_double(e, gz));
                                long long ts =
                                    (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
                                ERL_NIF_TERM keys[3] = {enif_make_atom(e, "accel"),
                                                        enif_make_atom(e, "gyro"),
                                                        enif_make_atom(e, "timestamp")};
                                ERL_NIF_TERM vals[3] = {accel, gyro, enif_make_int64(e, ts)};
                                ERL_NIF_TERM map;
                                enif_make_map_from_arrays(e, keys, vals, 3, &map);
                                ERL_NIF_TERM msg =
                                    enif_make_tuple2(e, enif_make_atom(e, "motion"), map);
                                enif_send(NULL, &p, e, msg);
                                enif_free_env(e);
                              }];
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
//     including non-accessible containers, with frames in window coords.
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

    ERL_NIF_TERM keys[5] = {enif_make_atom(env, "type"), enif_make_atom(env, "label"),
                            enif_make_atom(env, "value"), enif_make_atom(env, "frame"),
                            enif_make_atom(env, "children")};
    ERL_NIF_TERM vals[5] = {enif_make_atom(env, type_str), nsstring_to_term(env, text),
                            nsstring_to_term(env, value), frame, children};
    ERL_NIF_TERM result;
    enif_make_map_from_arrays(env, keys, vals, 5, &result);
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
    ERL_NIF_TERM root_keys[5] = {enif_make_atom(env, "type"), enif_make_atom(env, "label"),
                                 enif_make_atom(env, "value"), enif_make_atom(env, "frame"),
                                 enif_make_atom(env, "children")};
    ERL_NIF_TERM root_vals[5] = {
        enif_make_atom(env, "root"), enif_make_atom(env, "nil"), enif_make_atom(env, "nil"),
        enif_make_tuple4(env, enif_make_double(env, 0.0), enif_make_double(env, 0.0),
                         enif_make_double(env, screen_size.width),
                         enif_make_double(env, screen_size.height)),
        windows_list};
    ERL_NIF_TERM root;
    enif_make_map_from_arrays(env, root_keys, root_vals, 5, &root);
    return root;
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
    __block id elem = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              elem = find_a11y_at_point(win, pt, 0);
              if (elem)
                  return;
          }
      }
    });

    if (!elem)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "no_element_at_point"));

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

#if TARGET_OS_SIMULATOR
    // ── Simulator: accessibility-based activation by coordinates ─────────────────
    // The iOS simulator rejects in-process synthetic IOHIDEvents (no valid display
    // context) and SwiftUI on iOS 26 ignores direct touchesBegan: calls without
    // proper event system backing. Accessibility activation is the reliable path
    // for the simulator; for scroll views and custom GRs that lack accessibility,
    // a simulator-specific event injection mechanism would be needed.
    __block BOOL activated = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              id elem = find_a11y_at_point(win, pt, 0);
              if (elem) {
                  LOGI(@"tap_xy(sim): accessibilityActivate on %@ frame=%@",
                       NSStringFromClass(object_getClass(elem)),
                       NSStringFromCGRect([elem accessibilityFrame]));
                  [elem accessibilityActivate];
                  // For text fields: accessibilityActivate on UITextFieldLabel
                  // (the hint label inside UITextField) doesn't focus the
                  // field. Walk the responder chain up from the hit view to
                  // find the first UITextField/UITextView and focus it.
                  UIView *hv = [win hitTest:pt withEvent:nil];
                  UIResponder *r = hv;
                  while (r) {
                      if ([r isKindOfClass:[UITextField class]] ||
                          [r isKindOfClass:[UITextView class]]) {
                          [(UIView *)r becomeFirstResponder];
                          break;
                      }
                      r = r.nextResponder;
                  }
                  activated = YES;
                  return;
              }
          }
      }
    });
    if (activated)
        return enif_make_atom(env, "ok");
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_element_at_point"));

#else
    // ── Real device: UITouch injection via IOHIDEvent ─────────────────────────────
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
    __block BOOL fired = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
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
          return;

      // Walk up the responder chain looking for any UILongPressGestureRecognizer
      SEL setStateSel = NSSelectorFromString(@"_setState:");
      UIView *v = hitView;
      while (v && !fired) {
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
              fired = YES;
              break;
          }
          v = v.superview;
      }

      // SwiftUI onLongPressGesture may also surface as an accessibility custom action.
      // Try accessibilityActivate as a fallback — limited but better than nothing.
      if (!fired) {
          id elem = find_a11y_at_point(hitView, pt, 0);
          if (elem && [elem respondsToSelector:@selector(accessibilityActivate)]) {
              LOGI(@"long_press_xy(sim): fallback to accessibilityActivate on %@",
                   NSStringFromClass(object_getClass(elem)));
              [elem accessibilityActivate];
              fired = YES;
          }
      }
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
// pixels and deterministic scroll without adb/xcrun. They use only public
// UIKit APIs (UIGraphicsImageRenderer, UIScrollView.contentOffset) but live in
// the debug-only harness block alongside the other driving NIFs.

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
      UIWindow *window = nil;
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
          if (![scene isKindOfClass:[UIWindowScene class]])
              continue;
          for (UIWindow *win in [(UIWindowScene *)scene windows]) {
              if (win.isHidden)
                  continue;
              if (win.isKeyWindow) {
                  window = win;
                  break;
              }
              if (!window)
                  window = win; // first visible window as fallback
          }
          if (window.isKeyWindow)
              break;
      }
      if (!window)
          return;

      // `scale` is a multiplier of the native screen scale: 1.0 = crisp native
      // resolution, 0.5 = half (smaller payload over dist).
      UIGraphicsImageRendererFormat *rf = [UIGraphicsImageRendererFormat preferredFormat];
      rf.scale = [UIScreen mainScreen].scale * (CGFloat)scale;
      rf.opaque = YES;
      UIGraphicsImageRenderer *renderer =
          [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:rf];
      UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull ctx) {
        (void)ctx;
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
      }];
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

// nif_element_frames/0 — JSON {"id":[x,y,w,h],...} of tagged element frames
// (logical points). Recorded by MobFrameTracker; see mob_register_frame.
static ERL_NIF_TERM nif_element_frames(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    NSMutableDictionary *reg = mob_frame_registry();
    NSData *jsonData = nil;
    @synchronized(reg) {
        jsonData = [NSJSONSerialization dataWithJSONObject:reg options:0 error:nil];
    }
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

#define MAX_COMPONENT_HANDLES 64

typedef struct {
    ErlNifPid pid;
    int active;
} ComponentHandle;

static ComponentHandle component_handles[MAX_COMPONENT_HANDLES];
static ErlNifMutex *component_mutex = NULL;

static ERL_NIF_TERM nif_register_component(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[0], &pid))
        return enif_make_badarg(env);

    enif_mutex_lock(component_mutex);
    for (int i = 0; i < MAX_COMPONENT_HANDLES; i++) {
        if (!component_handles[i].active) {
            component_handles[i].pid = pid;
            component_handles[i].active = 1;
            enif_mutex_unlock(component_mutex);
            return enif_make_int(env, i);
        }
    }
    enif_mutex_unlock(component_mutex);
    return enif_make_badarg(env);
}

static ERL_NIF_TERM nif_deregister_component(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int handle;
    if (!enif_get_int(env, argv[0], &handle) || handle < 0 || handle >= MAX_COMPONENT_HANDLES)
        return enif_make_badarg(env);

    enif_mutex_lock(component_mutex);
    component_handles[handle].active = 0;
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
    if (handle < 0 || handle >= MAX_COMPONENT_HANDLES)
        return;

    enif_mutex_lock(component_mutex);
    if (!component_handles[handle].active) {
        enif_mutex_unlock(component_mutex);
        return;
    }
    ErlNifPid pid = component_handles[handle].pid;
    enif_mutex_unlock(component_mutex);

    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple3(env, enif_make_atom(env, "component_event"),
                                        enif_make_string(env, event, ERL_NIF_LATIN1),
                                        enif_make_string(env, payload_json, ERL_NIF_LATIN1));
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
static dispatch_once_t g_element_frames_once;

static NSMutableDictionary *mob_frame_registry(void) {
    dispatch_once(&g_element_frames_once, ^{
      g_element_frames = [NSMutableDictionary dictionary];
    });
    return g_element_frames;
}

void mob_register_frame(const char *id, double x, double y, double w, double h) {
    if (!id)
        return;
    NSString *key = [NSString stringWithUTF8String:id];
    if (!key)
        return;
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        reg[key] = @[ @(x), @(y), @(w), @(h) ];
    }
}

// Drop stale frames when the render tree changes (called from nif_set_root).
static void mob_clear_frames(void) {
    NSMutableDictionary *reg = mob_frame_registry();
    @synchronized(reg) {
        [reg removeAllObjects];
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
// Synthetic-input NIFs (tap_xy, swipe_xy, long_press_xy, type_text, key_press,
// delete_backward, clear_text) dispatch_sync to the main queue but also do
// some pre-dispatch work; they're left on regular schedulers for now because
// the test harness calls them in tight loops and dirty-dispatch overhead would
// add up. Re-evaluate if benchmarks show scheduler stalls under heavy harness use.
static ErlNifFunc nif_funcs[] = {
#if !MOB_RELEASE
    // ── Test harness (listed first to survive linker dead-code stripping) ──────
    // Compiled out of release builds — Erlang stubs in mob_nif.erl raise
    // :nif_error when these aren't loaded, which is the right thing for
    // shipped apps (the harness uses private UIKit APIs and Apple's
    // App Store validator rejects binaries that reference them).
    {"ui_tree", 0, nif_ui_tree, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"ui_view_tree", 0, nif_ui_view_tree, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"ui_debug", 0, nif_ui_debug, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"screen_info", 0, nif_screen_info, 0},
    {"tap", 1, nif_tap, 0},
    {"ax_action", 2, nif_ax_action, 0},
    {"ax_action_at_xy", 3, nif_ax_action_at_xy, 0},
    {"tap_xy", 2, nif_tap_xy, 0},
    {"type_text", 1, nif_type_text, 0},
    {"delete_backward", 0, nif_delete_backward, 0},
    {"key_press", 1, nif_key_press, 0},
    {"clear_text", 0, nif_clear_text, 0},
    {"long_press_xy", 3, nif_long_press_xy, 0},
    {"swipe_xy", 4, nif_swipe_xy, 0},
    {"screenshot", 3, nif_screenshot, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"scroll_info", 1, nif_scroll_info, 0},
    {"scroll_to", 3, nif_scroll_to, 0},
    {"element_frames", 0, nif_element_frames, ERL_NIF_DIRTY_JOB_CPU_BOUND},
#endif
    // ── Core mob functions ───────────────────────────────────────────────────
    {"battery_level", 0, nif_battery_level, 0},
    // ── Mob.Device — lifecycle events + queries ──────────────────────────────
    {"device_set_dispatcher", 1, nif_device_set_dispatcher, 0},
    {"device_battery_state", 0, nif_device_battery_state, 0},
    {"device_thermal_state", 0, nif_device_thermal_state, 0},
    {"device_low_power_mode", 0, nif_device_low_power_mode, 0},
    {"device_foreground", 0, nif_device_foreground, 0},
    {"device_os_version", 0, nif_device_os_version, 0},
    {"device_model", 0, nif_device_model, 0},
    {"device_orientation", 0, nif_device_orientation, 0},
    {"device_lock_orientation", 1, nif_device_lock_orientation, 0},
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
    {"safe_area", 0, nif_safe_area, 0},
    {"haptic", 1, nif_haptic, 0},
    {"clipboard_put", 1, nif_clipboard_put, 0},
    {"clipboard_get", 0, nif_clipboard_get, 0},
    {"share_text", 1, nif_share_text, 0},
    {"open_url", 1, nif_open_url, 0},
    {"request_permission", 1, nif_request_permission, 0},
    {"files_pick", 1, nif_files_pick, 0},
    {"audio_start_recording", 1, nif_audio_start_recording, 0},
    {"audio_stop_recording", 0, nif_audio_stop_recording, 0},
    {"audio_play", 2, nif_audio_play, 0},
    {"audio_play_at", 3, nif_audio_play_at, 0},
    {"audio_stop_playback", 0, nif_audio_stop_playback, 0},
    {"audio_set_volume", 1, nif_audio_set_volume, 0},
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
