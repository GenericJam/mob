// mob_beam.h — Public API for mob's BEAM launcher and UI initialisation.
// Include this in your app's beam_jni.c stub.

#ifndef MOB_BEAM_H
#define MOB_BEAM_H

#include <jni.h>

// Call from JNI_OnLoad (main thread).
// bridge_class: e.g. "com/myapp/MobBridge"
void mob_ui_cache_class(JNIEnv* env, const char* bridge_class);

// Send a tap event to the BEAM process registered for handle.
// Called from the app's Java_..._MobBridge_nativeSendTap JNI stub.
void mob_send_tap(int handle);

// Send a {:change, tag, value} event.  Called from the app's
// Java_..._MobBridge_nativeSendChange* JNI stubs.
void mob_send_change_str(int handle, const char* utf8);
void mob_send_change_bool(int handle, int bool_val);   // 0 = false, 1 = true
void mob_send_change_float(int handle, double value);

// Send {:focus, tag}, {:blur, tag}, {:submit, tag} events.
void mob_send_focus(int handle);
void mob_send_blur(int handle);
void mob_send_submit(int handle);

// Send {:select, tag} for pickers, menus, segmented controls.
void mob_send_select(int handle);

// Send {:compose, tag, %{text, phase}} for IME composition events on text
// fields. phase is "began" | "updating" | "committed" | "cancelled". Apps
// that observe this can implement commit-only behaviour for CJK input
// (ignore on_change while composing, replace text on :committed).
void mob_send_compose(int handle, const char* text, const char* phase);

// ── Gesture senders (Batch 4) ────────────────────────────────────────────
// Called from beam_jni.c JNI stubs when Compose's gesture detector fires.
// Per-widget opt-in — only nodes with the corresponding registered handle emit.
void mob_send_long_press(int handle);
void mob_send_double_tap(int handle);
void mob_send_swipe_left(int handle);
void mob_send_swipe_right(int handle);
void mob_send_swipe_up(int handle);
void mob_send_swipe_down(int handle);
// Direction-aware: emits {:swipe, tag, direction_atom} where direction is
// "left" | "right" | "up" | "down".
void mob_send_swipe_with_direction(int handle, const char* direction);

// ── Batch 5 Tier 1: high-frequency scroll/drag/pinch/rotate/pointer ─────
// Throttling and delta-thresholding are applied native-side BEFORE these
// fire — by the time they're called, the BEAM crossing is justified.
// Defaults (when no explicit config): scroll 33ms/1px, drag 16ms/1px,
// pinch 16ms/0.01, rotate 16ms/1°, pointer_move 33ms/4px.
void mob_set_throttle_config(int handle,
                             int throttle_ms, int debounce_ms,
                             double delta_threshold,
                             int leading, int trailing);
// Phase is "began" | "dragging" | "decelerating" | "ended"
void mob_send_scroll(int handle,
                     double x, double y,
                     double dx, double dy,
                     double vx, double vy,
                     const char* phase);
void mob_send_drag(int handle,
                   double x, double y,
                   double dx, double dy,
                   const char* phase);
void mob_send_pinch(int handle, double scale, double velocity, const char* phase);
void mob_send_rotate(int handle, double degrees, double velocity, const char* phase);
void mob_send_pointer_move(int handle, double x, double y);

// ── Batch 5 Tier 2: semantic single-fire scroll events ──
void mob_send_scroll_began(int handle);
void mob_send_scroll_ended(int handle);
void mob_send_scroll_settled(int handle);
void mob_send_top_reached(int handle);
void mob_send_scrolled_past(int handle);

// Signal a system back gesture to the BEAM screen process.
// The BEAM pops the nav stack or calls exit_app if at root.
void mob_handle_back(void);

// Call from nativeSetActivity.
void mob_init_bridge(JNIEnv* env, jobject activity);

// Call from nativeStartBeam.
// app_module: Erlang module name, e.g. "mob_demo"
void mob_start_beam(const char* app_module);

// Update the startup status shown on screen while BEAM is initialising.
// mob_set_startup_error stalls the screen with an error message (does not crash).
// Both are safe to call from any thread; no-op if MobBridge lacks the method.
void mob_set_startup_phase(const char* phase);
void mob_set_startup_error(const char* error);

// Global JVM pointer — defined in mob_beam.c, extern'd for mob_nif.c.
extern JavaVM* g_jvm;
extern jobject g_activity;

// ── Device capability delivery functions ─────────────────────────────────
// Called from beam_jni.c JNI stubs when Kotlin delivers async results.
// pid is an ErlNifPid passed as jlong through Kotlin.

void mob_deliver_atom2(jlong pid, const char* a1, const char* a2);
void mob_deliver_atom3(jlong pid, const char* a1, const char* a2, const char* a3);
void mob_deliver_location(jlong pid, double lat, double lon, double acc, double alt);
void mob_deliver_motion(jlong pid, double ax, double ay, double az,
                        double gx, double gy, double gz, long long ts);
void mob_deliver_file_result(jlong pid, const char* event, const char* sub,
                             const char* json_items);
void mob_deliver_push_token(jlong pid, const char* token);
void mob_deliver_notification(jlong pid, const char* json);
void mob_set_launch_notification(const char* json);

// Deliver {:alert, action_atom} to the registered :mob_screen process.
// Called from beam_jni.c when a dialog button is tapped.
void mob_deliver_alert_action(const char* action);

// Deliver {:component_event, event, payload_json} to a native view component process.
// Called from beam_jni.c when Kotlin fires a component event via the send callback.
void mob_send_component_event(int handle, const char* event, const char* payload_json);

#endif // MOB_BEAM_H
