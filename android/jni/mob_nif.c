// mob_nif.c — Mob UI NIF for Android (Jetpack Compose backend).
//
// NIF functions:
//   platform/0         — returns :android
//   log/1, log/2       — Android logcat
//   set_root/1         — pass JSON node tree to Compose
//   register_tap/1     — register ErlNifPid, get integer handle back
//   clear_taps/0       — clear tap registry before each render

#include <jni.h>
#include <android/log.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "erl_nif.h"
#include "mob_beam.h"

#define LOG_TAG "MobNIF"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ── Cached JNI method IDs ────────────────────────────────────────────────────

static struct {
    jclass    cls;
    jmethodID set_root;
    jmethodID move_to_back;
    jmethodID get_safe_area;
    jmethodID haptic;
    jmethodID clipboard_put;
    jmethodID clipboard_get;
    jmethodID share_text;
    jmethodID request_permission;
    jmethodID biometric_authenticate;
    jmethodID location_get_once;
    jmethodID location_start;
    jmethodID location_stop;
    jmethodID camera_capture_photo;
    jmethodID camera_capture_video;
    jmethodID photos_pick;
    jmethodID files_pick;
    jmethodID audio_start_recording;
    jmethodID audio_stop_recording;
    jmethodID motion_start;
    jmethodID motion_stop;
    jmethodID scanner_scan;
    jmethodID notify_schedule;
    jmethodID notify_cancel;
    jmethodID notify_register_push;
    jmethodID take_launch_notification;
    // Cached before nif_load (used during BEAM startup before NIFs are loaded)
    jmethodID set_startup_phase;
    jmethodID set_startup_error;
    // ── Test harness ──────────────────────────────────────────────────────────
    jmethodID ui_tree;
    jmethodID tap_xy;
    jmethodID tap_by_label;
    jmethodID type_text;
    jmethodID delete_backward;
    jmethodID clear_text;
    jmethodID long_press_xy;
    jmethodID swipe_xy;
} Bridge;

// ── Tap handle registry ───────────────────────────────────────────────────────
// Cleared before every render. Max 256 tappable elements per frame.
//
// Each handle stores a pid and an optional tag term (copied into a persistent
// NIF env). When tapped, sends {:tap, tag} to pid.
// Backwards compat: register_tap(pid) stores tag = :ok.

#define MAX_TAP_HANDLES 256

typedef struct {
    ErlNifPid    pid;
    ErlNifEnv*   tag_env;   // persistent env owning tag; NULL when not in use
    ERL_NIF_TERM tag;       // the term sent as the second element of {:tap, tag}
} TapHandle;

static TapHandle    tap_handles[MAX_TAP_HANDLES];
static int          tap_handle_next = 0;
static ErlNifMutex* tap_mutex       = NULL;
static char         g_transition[16] = "none";  // set by set_transition/1, read+reset by set_root/1

// Called from the app's Java_..._MobBridge_nativeSendTap JNI stub
// (declared in mob_beam.h, defined here).
void mob_send_tap(int handle) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid    pid     = tap_handles[handle].pid;
    ErlNifEnv*   tag_env = tap_handles[handle].tag_env;
    ERL_NIF_TERM tag     = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env,
        enif_make_atom(msg_env, "tap"),
        enif_make_copy(msg_env, tag));
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
    (void)tag_env; // owned by tap_handles; freed in clear_taps
}

// ── Change senders ────────────────────────────────────────────────────────────
// Called from beam_jni.c JNI stubs when an input widget fires an onChange event.
// Each builds {:change, tag, value} and sends it to the registered pid.

static void send_change(int handle, ERL_NIF_TERM value_term) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid    pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env,
        enif_make_atom(msg_env, "change"),
        enif_make_copy(msg_env, tag),
        enif_make_copy(msg_env, value_term));
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

void mob_send_change_str(int handle, const char* utf8) {
    ErlNifEnv* tmp = enif_alloc_env();
    ErlNifBinary bin;
    size_t len = strlen(utf8);
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    ERL_NIF_TERM term = enif_make_binary(tmp, &bin);
    send_change(handle, term);
    enif_free_env(tmp);
}

void mob_send_change_bool(int handle, int bool_val) {
    ErlNifEnv* tmp = enif_alloc_env();
    ERL_NIF_TERM term = enif_make_atom(tmp, bool_val ? "true" : "false");
    send_change(handle, term);
    enif_free_env(tmp);
}

void mob_send_change_float(int handle, double value) {
    ErlNifEnv* tmp = enif_alloc_env();
    ERL_NIF_TERM term = enif_make_double(tmp, value);
    send_change(handle, term);
    enif_free_env(tmp);
}

// ── Focus / blur / submit senders ────────────────────────────────────────────
// Called from beam_jni.c JNI stubs when a text field gains/loses focus or
// the return key is pressed. Sends a {:event, tag} 2-tuple to the registered pid.

static void send_event(int handle, const char* atom) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid    pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env,
        enif_make_atom(msg_env, atom),
        enif_make_copy(msg_env, tag));
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

void mob_send_focus(int handle)  { send_event(handle, "focus"); }
void mob_send_blur(int handle)   { send_event(handle, "blur"); }
void mob_send_submit(int handle) { send_event(handle, "submit"); }

// ── Back gesture sender ───────────────────────────────────────────────────────
// Called from beam_jni.c's nativeHandleBack JNI stub when the Android back
// gesture fires. Looks up the :mob_screen registered process and sends
// {:mob, :back} — Mob.Screen.handle_info/2 handles popping or exiting.

void mob_handle_back(void) {
    ErlNifEnv* env = enif_alloc_env();
    ErlNifPid pid;
    if (enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
        ERL_NIF_TERM msg = enif_make_tuple2(env,
            enif_make_atom(env, "mob"),
            enif_make_atom(env, "back"));
        enif_send(NULL, &pid, env, msg);
    }
    enif_free_env(env);
}

// ── JNI helpers ──────────────────────────────────────────────────────────────

static JNIEnv* get_jenv(int* attached) {
    JNIEnv* env = NULL;
    *attached = 0;
    if ((*g_jvm)->GetEnv(g_jvm, (void**)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        (*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL);
        *attached = 1;
    }
    return env;
}

// ── Cache MobBridge class (called from mob_beam.c) ───────────────────────────

void _mob_ui_cache_class_impl(JNIEnv* jenv, const char* bridge_class) {
    LOGI("mob_ui_cache_class: looking up %s", bridge_class);
    jclass cls = (*jenv)->FindClass(jenv, bridge_class);
    if (!cls) { LOGE("mob_ui_cache_class: %s not found", bridge_class); return; }
    Bridge.cls = (*jenv)->NewGlobalRef(jenv, cls);
    (*jenv)->DeleteLocalRef(jenv, cls);
    // Cache startup status methods now — they're needed before nif_load runs.
    // These are optional (older MobBridge versions may not have them); clear
    // any pending exception rather than aborting.
    Bridge.set_startup_phase = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setStartupPhase", "(Ljava/lang/String;)V");
    if (!Bridge.set_startup_phase) (*jenv)->ExceptionClear(jenv);
    Bridge.set_startup_error  = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setStartupError",  "(Ljava/lang/String;)V");
    if (!Bridge.set_startup_error)  (*jenv)->ExceptionClear(jenv);
    LOGI("mob_ui_cache_class: %s cached OK", bridge_class);
}

void mob_set_startup_phase(const char* phase) {
    if (!g_jvm || !Bridge.cls || !Bridge.set_startup_phase) return;
    int att; JNIEnv* env = get_jenv(&att);
    jstring js = (*env)->NewStringUTF(env, phase);
    (*env)->CallStaticVoidMethod(env, Bridge.cls, Bridge.set_startup_phase, js);
    (*env)->DeleteLocalRef(env, js);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    LOGI("startup: %s", phase);
}

void mob_set_startup_error(const char* error) {
    if (!g_jvm || !Bridge.cls || !Bridge.set_startup_error) return;
    int att; JNIEnv* env = get_jenv(&att);
    jstring js = (*env)->NewStringUTF(env, error);
    (*env)->CallStaticVoidMethod(env, Bridge.cls, Bridge.set_startup_error, js);
    (*env)->DeleteLocalRef(env, js);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    LOGE("startup ERROR: %s", error);
}

// ── Initialize bridge with Activity (called from mob_beam.c) ─────────────────

void _mob_bridge_init_activity(JNIEnv* env, jobject activity) {
    if (!Bridge.cls) { LOGE("_mob_bridge_init_activity: Bridge.cls not cached"); return; }
    jmethodID init = (*env)->GetStaticMethodID(env, Bridge.cls, "init",
        "(Landroid/app/Activity;)V");
    (*env)->CallStaticVoidMethod(env, Bridge.cls, init, activity);
    LOGI("_mob_bridge_init_activity: MobBridge.init called");
}

// ── NIF: platform/0 ──────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_platform(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "android");
}

// ── NIF: log/1 ───────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_log(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char buf[4096] = {0};
    ErlNifBinary bin;
    if (enif_inspect_binary(env, argv[0], &bin)) {
        size_t len = bin.size < sizeof(buf) - 1 ? bin.size : sizeof(buf) - 1;
        memcpy(buf, bin.data, len);
        buf[len] = 0;
    } else if (!enif_get_string(env, argv[0], buf, sizeof(buf), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }
    __android_log_print(ANDROID_LOG_INFO, "Elixir", "%s", buf);
    return enif_make_atom(env, "ok");
}

// ── NIF: log/2 ───────────────────────────────────────────────────────────────

static int atom_to_android_priority(ErlNifEnv* env, ERL_NIF_TERM level_atom) {
    char level[16];
    if (!enif_get_atom(env, level_atom, level, sizeof(level), ERL_NIF_LATIN1))
        return ANDROID_LOG_INFO;
    if (strcmp(level, "debug")   == 0) return ANDROID_LOG_DEBUG;
    if (strcmp(level, "warning") == 0) return ANDROID_LOG_WARN;
    if (strcmp(level, "error")   == 0) return ANDROID_LOG_ERROR;
    return ANDROID_LOG_INFO;
}

static ERL_NIF_TERM nif_log2(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char buf[4096] = {0};
    int priority = atom_to_android_priority(env, argv[0]);
    ErlNifBinary bin;
    if (enif_inspect_binary(env, argv[1], &bin)) {
        size_t len = bin.size < sizeof(buf) - 1 ? bin.size : sizeof(buf) - 1;
        memcpy(buf, bin.data, len);
        buf[len] = 0;
    } else if (!enif_get_string(env, argv[1], buf, sizeof(buf), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }
    __android_log_print(priority, "Elixir", "%s", buf);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_root/1 ──────────────────────────────────────────────────────────
// Accepts a JSON binary and passes it to MobBridge.setRootJson(String) on the
// Kotlin side. Compose state update is thread-safe — no main-thread hop needed.

static ERL_NIF_TERM nif_set_root(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    // Null-terminate for NewStringUTF
    char* json = (char*)malloc(bin.size + 1);
    if (!json) return enif_make_atom(env, "error");
    memcpy(json, bin.data, bin.size);
    json[bin.size] = 0;

    // Snapshot the current transition (set by set_transition/1 before this call)
    enif_mutex_lock(tap_mutex);
    char transition[16];
    strncpy(transition, g_transition, sizeof(transition) - 1);
    transition[sizeof(transition) - 1] = 0;
    strncpy(g_transition, "none", sizeof(g_transition));  // reset to none
    enif_mutex_unlock(tap_mutex);

    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jjson       = (*jenv)->NewStringUTF(jenv, json);
    jstring jtransition = (*jenv)->NewStringUTF(jenv, transition);
    free(json);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_root, jjson, jtransition);
    (*jenv)->DeleteLocalRef(jenv, jjson);
    (*jenv)->DeleteLocalRef(jenv, jtransition);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: register_tap/1 ──────────────────────────────────────────────────────
// Accepts pid (tag = :ok) or {pid, tag} (any Erlang term used as the tag).

static ERL_NIF_TERM nif_register_tap(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid    pid;
    ERL_NIF_TERM tag_term;

    // Try plain pid first
    if (enif_get_local_pid(env, argv[0], &pid)) {
        // No explicit tag — use :ok
        tag_term = enif_make_atom(env, "ok");
    } else {
        // Try {pid, tag} 2-tuple
        int arity;
        const ERL_NIF_TERM* elems;
        if (!enif_get_tuple(env, argv[0], &arity, &elems) || arity != 2)
            return enif_make_badarg(env);
        if (!enif_get_local_pid(env, elems[0], &pid))
            return enif_make_badarg(env);
        tag_term = elems[1];
    }

    enif_mutex_lock(tap_mutex);
    if (tap_handle_next >= MAX_TAP_HANDLES) {
        enif_mutex_unlock(tap_mutex);
        return enif_make_badarg(env);
    }
    int handle = tap_handle_next++;
    tap_handles[handle].pid     = pid;
    tap_handles[handle].tag_env = enif_alloc_env();
    tap_handles[handle].tag     = enif_make_copy(tap_handles[handle].tag_env, tag_term);
    enif_mutex_unlock(tap_mutex);

    return enif_make_int(env, handle);
}

// ── NIF: clear_taps/0 ────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_clear_taps(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(tap_mutex);
    for (int i = 0; i < tap_handle_next; i++) {
        if (tap_handles[i].tag_env) {
            enif_free_env(tap_handles[i].tag_env);
            tap_handles[i].tag_env = NULL;
        }
    }
    tap_handle_next = 0;
    enif_mutex_unlock(tap_mutex);
    return enif_make_atom(env, "ok");
}

// ── NIF: exit_app/0 ──────────────────────────────────────────────────────────
// Backgrounds the app via MobBridge.moveToBack() → activity.moveTaskToBack(true).
// Called by Mob.Screen when the back gesture fires at the root of the nav stack.

static ERL_NIF_TERM nif_exit_app(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.move_to_back);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_transition/1 ────────────────────────────────────────────────────
// Stores the transition type atom (push/pop/reset/none) to be passed to
// setRootJson on the next set_root call. Must be called before set_root.

static ERL_NIF_TERM nif_set_transition(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(tap_mutex);
    if (!enif_get_atom(env, argv[0], g_transition, sizeof(g_transition), ERL_NIF_LATIN1)) {
        enif_mutex_unlock(tap_mutex);
        return enif_make_badarg(env);
    }
    enif_mutex_unlock(tap_mutex);
    return enif_make_atom(env, "ok");
}

// ── NIF: safe_area/0 ─────────────────────────────────────────────────────────
// Returns {Top, Right, Bottom, Left} in dp via MobBridge.getSafeArea().

static ERL_NIF_TERM nif_safe_area(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    jfloatArray arr = (jfloatArray)(*jenv)->CallStaticObjectMethod(
        jenv, Bridge.cls, Bridge.get_safe_area);
    float vals[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    if (arr) {
        (*jenv)->GetFloatArrayRegion(jenv, arr, 0, 4, vals);
        (*jenv)->DeleteLocalRef(jenv, arr);
    }
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_tuple4(env,
        enif_make_double(env, (double)vals[0]),
        enif_make_double(env, (double)vals[1]),
        enif_make_double(env, (double)vals[2]),
        enif_make_double(env, (double)vals[3])
    );
}

// ── NIF: haptic/1 ─────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_haptic(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char type[32] = {0};
    enif_get_atom(env, argv[0], type, sizeof(type), ERL_NIF_LATIN1);
    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jtype = (*jenv)->NewStringUTF(jenv, type);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.haptic, jtype);
    (*jenv)->DeleteLocalRef(jenv, jtype);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: clipboard_put/1 ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_clipboard_put(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char* text = (char*)malloc(bin.size + 1);
    if (!text) return enif_make_atom(env, "error");
    memcpy(text, bin.data, bin.size);
    text[bin.size] = 0;
    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jtext = (*jenv)->NewStringUTF(jenv, text);
    free(text);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.clipboard_put, jtext);
    (*jenv)->DeleteLocalRef(jenv, jtext);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: clipboard_get/0 ──────────────────────────────────────────────────────
// Returns {:ok, Binary} or :empty.

static ERL_NIF_TERM nif_clipboard_get(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    jstring result = (jstring)(*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.clipboard_get);

    ERL_NIF_TERM ret;
    if (result) {
        const char* utf8 = (*jenv)->GetStringUTFChars(jenv, result, NULL);
        ErlNifBinary bin;
        size_t len = strlen(utf8);
        enif_alloc_binary(len, &bin);
        memcpy(bin.data, utf8, len);
        (*jenv)->ReleaseStringUTFChars(jenv, result, utf8);
        (*jenv)->DeleteLocalRef(jenv, result);
        ret = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &bin));
    } else {
        ret = enif_make_atom(env, "empty");
    }
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ret;
}

// ── NIF: share_text/1 ─────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_share_text(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char* text = (char*)malloc(bin.size + 1);
    if (!text) return enif_make_atom(env, "error");
    memcpy(text, bin.data, bin.size);
    text[bin.size] = 0;
    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jtext = (*jenv)->NewStringUTF(jenv, text);
    free(text);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.share_text, jtext);
    (*jenv)->DeleteLocalRef(jenv, jtext);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ════════════════════════════════════════════════════════════════════════════
// Device capability NIFs (Android JNI bridge)
// Each calls a static method on MobBridge with the PID encoded as a long so
// Kotlin can call mob_nif_deliver_event() with the result.
// ════════════════════════════════════════════════════════════════════════════

// Launch notification global (written by MobBridge.setLaunchNotification, read once)
static char*        g_launch_notif_json  = NULL;
static ErlNifMutex* g_launch_notif_mutex = NULL;

// Called from MobBridge.setLaunchNotification(json)
void mob_set_launch_notification(const char* json) {
    if (!g_launch_notif_mutex) return;
    enif_mutex_lock(g_launch_notif_mutex);
    free(g_launch_notif_json);
    g_launch_notif_json = json ? strdup(json) : NULL;
    enif_mutex_unlock(g_launch_notif_mutex);
}

static ERL_NIF_TERM nif_take_launch_notification(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!g_launch_notif_mutex) return enif_make_atom(env, "none");
    enif_mutex_lock(g_launch_notif_mutex);
    char* json = g_launch_notif_json;
    g_launch_notif_json = NULL;
    enif_mutex_unlock(g_launch_notif_mutex);
    if (!json) return enif_make_atom(env, "none");
    ErlNifBinary bin;
    enif_alloc_binary(strlen(json), &bin);
    memcpy(bin.data, json, strlen(json));
    free(json);
    return enif_make_binary(env, &bin);
}

// Generic helper: call Kotlin static method(pid_long, string_arg)
static ERL_NIF_TERM call_bridge_pid_str(ErlNifEnv* env, jmethodID method,
                                         ErlNifPid pid, const char* arg) {
    int att; JNIEnv* jenv = get_jenv(&att);
    jlong jpid;
    memcpy(&jpid, &pid, sizeof(ErlNifPid) < sizeof(jlong) ? sizeof(ErlNifPid) : sizeof(jlong));
    jstring jarg = arg ? (*jenv)->NewStringUTF(jenv, arg) : NULL;
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, method, jpid, jarg);
    if (jarg) (*jenv)->DeleteLocalRef(jenv, jarg);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM call_bridge_pid_str2(ErlNifEnv* env, jmethodID method,
                                          ErlNifPid pid, const char* a1, const char* a2) {
    int att; JNIEnv* jenv = get_jenv(&att);
    jlong jpid;
    memcpy(&jpid, &pid, sizeof(ErlNifPid) < sizeof(jlong) ? sizeof(ErlNifPid) : sizeof(jlong));
    jstring j1 = a1 ? (*jenv)->NewStringUTF(jenv, a1) : NULL;
    jstring j2 = a2 ? (*jenv)->NewStringUTF(jenv, a2) : NULL;
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, method, jpid, j1, j2);
    if (j1) (*jenv)->DeleteLocalRef(jenv, j1);
    if (j2) (*jenv)->DeleteLocalRef(jenv, j2);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// mob_nif_deliver_event — called from Kotlin with a JSON string result.
// Decodes the JSON and sends the appropriate BEAM message to the pid stored in it.
// JSON format: {"pid": <long>, "event": [...erlang term json...]}
// We use a simpler approach: Kotlin encodes the event as a JSON array describing the term.
// Actually, simplest approach: Kotlin constructs a binary JSON string, and we route
// to pre-stored PIDs in a simple table. But since we pass the PID as a long to Kotlin,
// Kotlin passes it back to us and we reconstruct the ErlNifPid.
//
// mob_nif_deliver_json(pid_long, json_cstr) — send pre-formed JSON event to pid
// This is declared in mob_beam.h for Kotlin to call via JNI.
void mob_nif_deliver_json(jlong pid_long, const char* json_str) {
    // We don't send JSON to the BEAM — we need to build proper Erlang terms.
    // Instead, we use a set of typed delivery functions called from Kotlin.
    // See mob_beam.h for the full set.
}

// Typed event delivery functions called from Kotlin/JNI
// These are declared in mob_beam.h and implemented here.

static ErlNifPid pid_from_long(jlong jpid) {
    ErlNifPid pid;
    memset(&pid, 0, sizeof(pid));
    memcpy(&pid, &jpid, sizeof(ErlNifPid) < sizeof(jlong) ? sizeof(ErlNifPid) : sizeof(jlong));
    return pid;
}

void mob_deliver_atom2(jlong jpid, const char* a1, const char* a2) {
    ErlNifPid pid = pid_from_long(jpid);
    ErlNifEnv* e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e,a1), enif_make_atom(e,a2));
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

void mob_deliver_atom3(jlong jpid, const char* a1, const char* a2, const char* a3) {
    ErlNifPid pid = pid_from_long(jpid);
    ErlNifEnv* e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple3(e,
        enif_make_atom(e,a1), enif_make_atom(e,a2), enif_make_atom(e,a3));
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

void mob_deliver_location(jlong jpid, double lat, double lon, double acc, double alt) {
    ErlNifPid pid = pid_from_long(jpid);
    ErlNifEnv* e = enif_alloc_env();
    ERL_NIF_TERM keys[4] = {
        enif_make_atom(e,"lat"), enif_make_atom(e,"lon"),
        enif_make_atom(e,"accuracy"), enif_make_atom(e,"altitude")
    };
    ERL_NIF_TERM vals[4] = {
        enif_make_double(e,lat), enif_make_double(e,lon),
        enif_make_double(e,acc), enif_make_double(e,alt)
    };
    ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 4, &map);
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e,"location"), map);
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

void mob_deliver_motion(jlong jpid, double ax, double ay, double az,
                         double gx, double gy, double gz, long long ts) {
    ErlNifPid pid = pid_from_long(jpid);
    ErlNifEnv* e = enif_alloc_env();
    ERL_NIF_TERM accel = enif_make_tuple3(e,
        enif_make_double(e,ax), enif_make_double(e,ay), enif_make_double(e,az));
    ERL_NIF_TERM gyro = enif_make_tuple3(e,
        enif_make_double(e,gx), enif_make_double(e,gy), enif_make_double(e,gz));
    ERL_NIF_TERM keys[3] = {
        enif_make_atom(e,"accel"), enif_make_atom(e,"gyro"), enif_make_atom(e,"timestamp")
    };
    ERL_NIF_TERM vals[3] = {accel, gyro, enif_make_int64(e,ts)};
    ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 3, &map);
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e,"motion"), map);
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

void mob_deliver_file_result(jlong jpid, const char* event, // "camera","photos","files","audio","scan"
                              const char* sub,               // "photo","video","picked","recorded","result","cancelled"
                              const char* json_items) {       // JSON array of item maps, or NULL for cancelled
    ErlNifPid pid = pid_from_long(jpid);
    ErlNifEnv* e = enif_alloc_env();
    ERL_NIF_TERM msg;
    if (!json_items || strcmp(json_items, "cancelled") == 0) {
        msg = enif_make_tuple2(e, enif_make_atom(e,event), enif_make_atom(e,"cancelled"));
    } else {
        // Parse JSON array of maps and build Erlang list
        // Simple approach: pass the raw JSON binary as a string; the BEAM can decode it if needed.
        // Better: build proper terms here.
        // For now, pass as binary; Elixir side can use :json.decode.
        // But we want typed data, so let's build a simple list of maps.
        // We'll use a JSON-like binary approach: send the raw JSON and let the BEAM decode it.
        ErlNifBinary jb;
        size_t jlen = strlen(json_items);
        enif_alloc_binary(jlen, &jb);
        memcpy(jb.data, json_items, jlen);
        // Build: {event_atom, sub_atom, json_binary}
        // The Elixir Mob.Screen will need to decode it. Actually, let's send the JSON
        // and have Mob.Screen decode it — but screen doesn't do that for file results.
        // Better: send as a tagged binary that Elixir wrappers decode.
        // We'll send {:mob_file_result, event, sub, json_binary} and add a handler.
        ErlNifBinary eb; size_t el = strlen(event); enif_alloc_binary(el,&eb); memcpy(eb.data,event,el);
        ErlNifBinary sb; size_t sl = strlen(sub);   enif_alloc_binary(sl,&sb); memcpy(sb.data,sub,sl);
        msg = enif_make_tuple4(e,
            enif_make_atom(e,"mob_file_result"),
            enif_make_binary(e,&eb),
            enif_make_binary(e,&sb),
            enif_make_binary(e,&jb));
    }
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

void mob_deliver_push_token(jlong jpid, const char* token) {
    ErlNifPid pid = pid_from_long(jpid);
    ErlNifEnv* e = enif_alloc_env();
    ErlNifBinary tb; size_t tl = strlen(token); enif_alloc_binary(tl,&tb); memcpy(tb.data,token,tl);
    ERL_NIF_TERM msg = enif_make_tuple3(e,
        enif_make_atom(e,"push_token"), enif_make_atom(e,"android"), enif_make_binary(e,&tb));
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

void mob_deliver_notification(jlong jpid, const char* json) {
    ErlNifPid pid = pid_from_long(jpid);
    ErlNifEnv* e = enif_alloc_env();
    ErlNifBinary jb; size_t jl = strlen(json); enif_alloc_binary(jl,&jb); memcpy(jb.data,json,jl);
    ERL_NIF_TERM msg = enif_make_tuple2(e,
        enif_make_atom(e,"mob_launch_notification"), enif_make_binary(e,&jb));
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

// NIF implementations — thin wrappers that pass work to Kotlin

static ERL_NIF_TERM nif_request_permission(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char cap[32]; enif_get_atom(env, argv[0], cap, sizeof(cap), ERL_NIF_LATIN1);
    ErlNifPid pid; enif_self(env, &pid);
    return call_bridge_pid_str(env, Bridge.request_permission, pid, cap);
}

static ERL_NIF_TERM nif_biometric_authenticate(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char reason[256] = "Authenticate";
    if (bin.size < sizeof(reason)) { memcpy(reason, bin.data, bin.size); reason[bin.size] = 0; }
    ErlNifPid pid; enif_self(env, &pid);
    return call_bridge_pid_str(env, Bridge.biometric_authenticate, pid, reason);
}

static ERL_NIF_TERM nif_location_get_once(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    return call_bridge_pid_str(env, Bridge.location_get_once, pid, "balanced");
}

static ERL_NIF_TERM nif_location_start(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char acc[16] = "balanced"; enif_get_atom(env, argv[0], acc, sizeof(acc), ERL_NIF_LATIN1);
    ErlNifPid pid; enif_self(env, &pid);
    return call_bridge_pid_str(env, Bridge.location_start, pid, acc);
}

static ERL_NIF_TERM nif_location_stop(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.location_stop);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_camera_capture_photo(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char qual[16] = "high"; enif_get_atom(env, argv[0], qual, sizeof(qual), ERL_NIF_LATIN1);
    ErlNifPid pid; enif_self(env, &pid);
    return call_bridge_pid_str(env, Bridge.camera_capture_photo, pid, qual);
}

static ERL_NIF_TERM nif_camera_capture_video(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int max_dur = 60; enif_get_int(env, argv[0], &max_dur);
    ErlNifPid pid; enif_self(env, &pid);
    char dur_str[16]; snprintf(dur_str, sizeof(dur_str), "%d", max_dur);
    return call_bridge_pid_str(env, Bridge.camera_capture_video, pid, dur_str);
}

static ERL_NIF_TERM nif_photos_pick(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int max = 1; enif_get_int(env, argv[0], &max);
    ErlNifPid pid; enif_self(env, &pid);
    char max_str[16]; snprintf(max_str, sizeof(max_str), "%d", max);
    return call_bridge_pid_str(env, Bridge.photos_pick, pid, max_str);
}

static ERL_NIF_TERM nif_files_pick(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char* json = malloc(bin.size + 1);
    memcpy(json, bin.data, bin.size); json[bin.size] = 0;
    ErlNifPid pid; enif_self(env, &pid);
    ERL_NIF_TERM result = call_bridge_pid_str(env, Bridge.files_pick, pid, json);
    free(json);
    return result;
}

static ERL_NIF_TERM nif_audio_start_recording(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char* json = malloc(bin.size + 1);
    memcpy(json, bin.data, bin.size); json[bin.size] = 0;
    ErlNifPid pid; enif_self(env, &pid);
    ERL_NIF_TERM result = call_bridge_pid_str(env, Bridge.audio_start_recording, pid, json);
    free(json);
    return result;
}

static ERL_NIF_TERM nif_audio_stop_recording(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.audio_stop_recording);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_motion_start(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int interval_ms = 100; enif_get_int(env, argv[1], &interval_ms);
    char interval_str[16]; snprintf(interval_str, sizeof(interval_str), "%d", interval_ms);
    ErlNifPid pid; enif_self(env, &pid);
    return call_bridge_pid_str(env, Bridge.motion_start, pid, interval_str);
}

static ERL_NIF_TERM nif_motion_stop(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.motion_stop);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_scanner_scan(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char* json = malloc(bin.size + 1);
    memcpy(json, bin.data, bin.size); json[bin.size] = 0;
    ErlNifPid pid; enif_self(env, &pid);
    ERL_NIF_TERM result = call_bridge_pid_str(env, Bridge.scanner_scan, pid, json);
    free(json);
    return result;
}

static ERL_NIF_TERM nif_notify_schedule(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char* json = malloc(bin.size + 1);
    memcpy(json, bin.data, bin.size); json[bin.size] = 0;
    ErlNifPid pid; enif_self(env, &pid);
    ERL_NIF_TERM result = call_bridge_pid_str(env, Bridge.notify_schedule, pid, json);
    free(json);
    return result;
}

static ERL_NIF_TERM nif_notify_cancel(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    char nid[256] = "";
    if (bin.size < sizeof(nid)) { memcpy(nid, bin.data, bin.size); nid[bin.size] = 0; }
    int att; JNIEnv* jenv = get_jenv(&att);
    jstring js = (*jenv)->NewStringUTF(jenv, nid);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.notify_cancel, js);
    (*jenv)->DeleteLocalRef(jenv, js);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_notify_register_push(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    return call_bridge_pid_str(env, Bridge.notify_register_push, pid, NULL);
}

// ── NIF table & load ─────────────────────────────────────────────────────────

// ── Test harness NIFs ─────────────────────────────────────────────────────────
//
// Android implementation notes vs iOS:
//   - View tree walk uses android.view.View hierarchy (Compose exposes Views)
//   - Touch injection via DecorView.dispatchTouchEvent — no INJECT_EVENTS needed
//   - Text input via InputConnection.commitText — works for Compose TextField
//   - All blocking operations use CountDownLatch on the Kotlin side;
//     from C we just call the JNI method which blocks until the latch fires
//   - Coordinates in dp (density-independent pixels), matching iOS convention

// Helper: jstring → ERL_NIF_TERM binary (UTF-8). Deletes local ref.
static ERL_NIF_TERM jstring_to_bin(ErlNifEnv* env, JNIEnv* jenv, jstring js) {
    if (!js) return enif_make_atom(env, "nil");
    const char* utf = (*jenv)->GetStringUTFChars(jenv, js, NULL);
    if (!utf) return enif_make_atom(env, "nil");
    size_t len = strlen(utf);
    ErlNifBinary bin;
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf, len);
    (*jenv)->ReleaseStringUTFChars(jenv, js, utf);
    (*jenv)->DeleteLocalRef(jenv, js);
    return enif_make_binary(env, &bin);
}

// Helper: make a binary term from a C string (does NOT delete jstring).
static ERL_NIF_TERM cstr_to_bin(ErlNifEnv* env, const char* s, size_t len) {
    ErlNifBinary bin;
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, s, len);
    return enif_make_binary(env, &bin);
}

// nif_ui_tree/0 — returns [{type_atom, label_binary, value_binary, {x,y,w,h}}, ...]
//
// Calls MobBridge.uiTree() which returns a newline-separated string:
//   type|label|value|x|y|w|h\n...
// Parses that into a list of 4-tuples matching the iOS ui_tree format.
static ERL_NIF_TERM nif_ui_tree(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.ui_tree) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));

    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jresult = (jstring)(*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.ui_tree);
    if (!jresult) {
        if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
        return enif_make_list(env, 0);
    }

    const char* raw = (*jenv)->GetStringUTFChars(jenv, jresult, NULL);
    ERL_NIF_TERM list = enif_make_list(env, 0);

    // Parse lines in reverse (we'll reverse the list at the end)
    // Format per line: type|label|value|x|y|w|h
    const char* p = raw;
    // Collect all lines into a temp array first (we build list in reverse for efficiency)
    // Simple approach: walk forward, build list, reverse at end
    ERL_NIF_TERM items[512];
    int count = 0;

    while (*p && count < 512) {
        // Find end of line
        const char* nl = strchr(p, '\n');
        if (!nl) break;
        size_t line_len = nl - p;
        char line[512];
        if (line_len >= sizeof(line)) { p = nl + 1; continue; }
        memcpy(line, p, line_len);
        line[line_len] = 0;
        p = nl + 1;

        // Split on '|': type, label, value, x, y, w, h
        char* fields[7];
        int   nf = 0;
        char* tok = line;
        for (int i = 0; i < 7; i++) {
            fields[i] = tok;
            char* sep = (i < 6) ? strchr(tok, '|') : NULL;
            if (sep) { *sep = 0; tok = sep + 1; nf++; }
            else     { nf = i + 1; break; }
        }
        if (nf < 7) continue;

        double x = atof(fields[3]);
        double y = atof(fields[4]);
        double w = atof(fields[5]);
        double h = atof(fields[6]);

        ERL_NIF_TERM frame = enif_make_tuple4(env,
            enif_make_double(env, x), enif_make_double(env, y),
            enif_make_double(env, w), enif_make_double(env, h));

        // label and value: non-empty → binary, empty → atom nil
        size_t llen = strlen(fields[1]);
        size_t vlen = strlen(fields[2]);
        ERL_NIF_TERM label = llen > 0 ? cstr_to_bin(env, fields[1], llen)
                                       : enif_make_atom(env, "nil");
        ERL_NIF_TERM value = vlen > 0 ? cstr_to_bin(env, fields[2], vlen)
                                       : enif_make_atom(env, "nil");

        items[count++] = enif_make_tuple4(env,
            enif_make_atom(env, fields[0]),
            label, value, frame);
    }

    (*jenv)->ReleaseStringUTFChars(jenv, jresult, raw);
    (*jenv)->DeleteLocalRef(jenv, jresult);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);

    // Build list from items array (forward order)
    list = enif_make_list(env, 0);
    for (int i = count - 1; i >= 0; i--)
        list = enif_make_list_cell(env, items[i], list);
    return list;
}

// nif_ui_debug/0 — returns raw uiTree string as a binary (for debugging)
static ERL_NIF_TERM nif_ui_debug(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.ui_tree) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jresult = (jstring)(*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.ui_tree);
    ERL_NIF_TERM result = jstring_to_bin(env, jenv, jresult);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return result;
}

// nif_tap/1 — tap by accessibility label binary
static ERL_NIF_TERM nif_tap(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.tap_by_label) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
    char* label = (char*)malloc(bin.size + 1);
    if (!label) return enif_make_atom(env, "error");
    memcpy(label, bin.data, bin.size);
    label[bin.size] = 0;

    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jlabel = (*jenv)->NewStringUTF(jenv, label);
    free(label);
    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, Bridge.cls, Bridge.tap_by_label, jlabel);
    (*jenv)->DeleteLocalRef(jenv, jlabel);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                      enif_make_atom(env, "no_element_with_label"));
}

// nif_tap_xy/2 — tap at (x, y) dp coordinates
static ERL_NIF_TERM nif_tap_xy(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.tap_xy) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    double x, y;
    if (!enif_get_double(env, argv[0], &x)) { int ix; if (!enif_get_int(env, argv[0], &ix)) return enif_make_badarg(env); x = ix; }
    if (!enif_get_double(env, argv[1], &y)) { int iy; if (!enif_get_int(env, argv[1], &iy)) return enif_make_badarg(env); y = iy; }

    int att; JNIEnv* jenv = get_jenv(&att);
    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, Bridge.cls, Bridge.tap_xy, (jfloat)x, (jfloat)y);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                      enif_make_atom(env, "dispatch_failed"));
}

// nif_type_text/1 — type text into the focused view
static ERL_NIF_TERM nif_type_text(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.type_text) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
    char* text = (char*)malloc(bin.size + 1);
    if (!text) return enif_make_atom(env, "error");
    memcpy(text, bin.data, bin.size);
    text[bin.size] = 0;

    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jtext = (*jenv)->NewStringUTF(jenv, text);
    free(text);
    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, Bridge.cls, Bridge.type_text, jtext);
    (*jenv)->DeleteLocalRef(jenv, jtext);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                      enif_make_atom(env, "no_first_responder"));
}

// nif_delete_backward/0 — delete one character backward
static ERL_NIF_TERM nif_delete_backward(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.delete_backward) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    int att; JNIEnv* jenv = get_jenv(&att);
    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, Bridge.cls, Bridge.delete_backward);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                      enif_make_atom(env, "no_first_responder"));
}

// nif_key_press/1 — not yet implemented on Android (no KeyCharacterMap lookup)
static ERL_NIF_TERM nif_key_press(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_implemented"));
}

// nif_clear_text/0 — select-all + delete in the focused view
static ERL_NIF_TERM nif_clear_text(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.clear_text) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    int att; JNIEnv* jenv = get_jenv(&att);
    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, Bridge.cls, Bridge.clear_text);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                      enif_make_atom(env, "no_first_responder"));
}

// nif_long_press_xy/3 — long press at (x, y) for duration_ms milliseconds
static ERL_NIF_TERM nif_long_press_xy(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.long_press_xy) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    double x, y; int dur;
    if (!enif_get_double(env, argv[0], &x)) { int ix; if (!enif_get_int(env, argv[0], &ix)) return enif_make_badarg(env); x = ix; }
    if (!enif_get_double(env, argv[1], &y)) { int iy; if (!enif_get_int(env, argv[1], &iy)) return enif_make_badarg(env); y = iy; }
    if (!enif_get_int(env, argv[2], &dur)) return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, Bridge.cls, Bridge.long_press_xy,
        (jfloat)x, (jfloat)y, (jlong)dur);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                      enif_make_atom(env, "dispatch_failed"));
}

// nif_swipe_xy/4 — swipe from (x1,y1) to (x2,y2) in dp
static ERL_NIF_TERM nif_swipe_xy(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!Bridge.swipe_xy) return enif_make_tuple2(env,
        enif_make_atom(env, "error"), enif_make_atom(env, "not_loaded"));
    double x1, y1, x2, y2;
    if (!enif_get_double(env, argv[0], &x1)) { int i; if (!enif_get_int(env, argv[0], &i)) return enif_make_badarg(env); x1 = i; }
    if (!enif_get_double(env, argv[1], &y1)) { int i; if (!enif_get_int(env, argv[1], &i)) return enif_make_badarg(env); y1 = i; }
    if (!enif_get_double(env, argv[2], &x2)) { int i; if (!enif_get_int(env, argv[2], &i)) return enif_make_badarg(env); x2 = i; }
    if (!enif_get_double(env, argv[3], &y2)) { int i; if (!enif_get_int(env, argv[3], &i)) return enif_make_badarg(env); y2 = i; }

    int att; JNIEnv* jenv = get_jenv(&att);
    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, Bridge.cls, Bridge.swipe_xy,
        (jfloat)x1, (jfloat)y1, (jfloat)x2, (jfloat)y2);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return ok ? enif_make_atom(env, "ok")
              : enif_make_tuple2(env, enif_make_atom(env, "error"),
                                      enif_make_atom(env, "dispatch_failed"));
}

// ── NIF table & load ──────────────────────────────────────────────────────────

static ErlNifFunc nif_funcs[] = {
    // ── Test harness first (matches iOS nif_funcs[] ordering convention) ──────
    {"ui_tree",          0, nif_ui_tree,          0},
    {"ui_debug",         0, nif_ui_debug,         0},
    {"tap",              1, nif_tap,              0},
    {"tap_xy",           2, nif_tap_xy,           0},
    {"type_text",        1, nif_type_text,        0},
    {"delete_backward",  0, nif_delete_backward,  0},
    {"key_press",        1, nif_key_press,        0},
    {"clear_text",       0, nif_clear_text,       0},
    {"long_press_xy",    3, nif_long_press_xy,    0},
    {"swipe_xy",         4, nif_swipe_xy,         0},
    // ── Core mob functions ────────────────────────────────────────────────────
    {"platform",       0, nif_platform,       0},
    {"log",            1, nif_log,            0},
    {"log",            2, nif_log2,           0},
    {"set_transition", 1, nif_set_transition, 0},
    {"set_root",       1, nif_set_root,       0},
    {"register_tap",   1, nif_register_tap,   0},
    {"clear_taps",     0, nif_clear_taps,     0},
    {"exit_app",       0, nif_exit_app,       0},
    {"safe_area",      0, nif_safe_area,      0},
    {"haptic",                    1, nif_haptic,                    0},
    {"clipboard_put",             1, nif_clipboard_put,             0},
    {"clipboard_get",             0, nif_clipboard_get,             0},
    {"share_text",                1, nif_share_text,                0},
    {"request_permission",        1, nif_request_permission,        0},
    {"biometric_authenticate",    1, nif_biometric_authenticate,    0},
    {"location_get_once",         0, nif_location_get_once,         0},
    {"location_start",            1, nif_location_start,            0},
    {"location_stop",             0, nif_location_stop,             0},
    {"camera_capture_photo",      1, nif_camera_capture_photo,      0},
    {"camera_capture_video",      1, nif_camera_capture_video,      0},
    {"photos_pick",               2, nif_photos_pick,               0},
    {"files_pick",                1, nif_files_pick,                0},
    {"audio_start_recording",     1, nif_audio_start_recording,     0},
    {"audio_stop_recording",      0, nif_audio_stop_recording,      0},
    {"motion_start",              2, nif_motion_start,              0},
    {"motion_stop",               0, nif_motion_stop,               0},
    {"scanner_scan",              1, nif_scanner_scan,              0},
    {"notify_schedule",           1, nif_notify_schedule,           0},
    {"notify_cancel",             1, nif_notify_cancel,             0},
    {"notify_register_push",      0, nif_notify_register_push,      0},
    {"take_launch_notification",  0, nif_take_launch_notification,  0},
};

static int nif_load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
    LOGI("nif_load: entered, Bridge.cls=%p", (void*)Bridge.cls);
    if (!Bridge.cls) { LOGE("Bridge.cls not cached — was mob_ui_cache_class called?"); return -1; }

    tap_mutex = enif_mutex_create("mob_tap_mutex");
    if (!tap_mutex) { LOGE("nif_load: failed to create tap mutex"); return -1; }

    int att; JNIEnv* jenv = get_jenv(&att);
    Bridge.set_root = (*jenv)->GetStaticMethodID(jenv, Bridge.cls,
        "setRootJson", "(Ljava/lang/String;Ljava/lang/String;)V");
    if (!Bridge.set_root) { LOGE("nif_load: setRootJson(String,String) not found on MobBridge"); return -1; }

    Bridge.move_to_back = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "moveToBack", "()V");
    if (!Bridge.move_to_back) { LOGE("nif_load: moveToBack() not found on MobBridge"); return -1; }

    Bridge.get_safe_area = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "getSafeArea", "()[F");
    if (!Bridge.get_safe_area) { LOGE("nif_load: getSafeArea() not found on MobBridge"); return -1; }

    Bridge.haptic = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "haptic", "(Ljava/lang/String;)V");
    if (!Bridge.haptic) { LOGE("nif_load: haptic(String) not found on MobBridge"); return -1; }

    Bridge.clipboard_put = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "clipboardPut", "(Ljava/lang/String;)V");
    if (!Bridge.clipboard_put) { LOGE("nif_load: clipboardPut(String) not found on MobBridge"); return -1; }

    Bridge.clipboard_get = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "clipboardGet", "()Ljava/lang/String;");
    if (!Bridge.clipboard_get) { LOGE("nif_load: clipboardGet() not found on MobBridge"); return -1; }

    Bridge.share_text = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "shareText", "(Ljava/lang/String;)V");
    if (!Bridge.share_text) { LOGE("nif_load: shareText(String) not found on MobBridge"); return -1; }

    #define CACHE(name, sig) \
        Bridge.name = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, #name, sig); \
        if (!Bridge.name) { LOGE("nif_load: " #name " not found"); return -1; }

    CACHE(request_permission,     "(JLjava/lang/String;)V")
    CACHE(biometric_authenticate, "(JLjava/lang/String;)V")
    CACHE(location_get_once,      "(JLjava/lang/String;)V")
    CACHE(location_start,         "(JLjava/lang/String;)V")
    CACHE(location_stop,          "()V")
    CACHE(camera_capture_photo,   "(JLjava/lang/String;)V")
    CACHE(camera_capture_video,   "(JLjava/lang/String;)V")
    CACHE(photos_pick,            "(JLjava/lang/String;)V")
    CACHE(files_pick,             "(JLjava/lang/String;)V")
    CACHE(audio_start_recording,  "(JLjava/lang/String;)V")
    CACHE(audio_stop_recording,   "()V")
    CACHE(motion_start,           "(JLjava/lang/String;)V")
    CACHE(motion_stop,            "()V")
    CACHE(scanner_scan,           "(JLjava/lang/String;)V")
    CACHE(notify_schedule,        "(JLjava/lang/String;)V")
    CACHE(notify_cancel,          "(Ljava/lang/String;)V")
    CACHE(notify_register_push,   "(JLjava/lang/String;)V")
    #undef CACHE

    g_launch_notif_mutex = enif_mutex_create("mob_launch_notif_mutex");
    if (!g_launch_notif_mutex) { LOGE("nif_load: failed to create launch notif mutex"); return -1; }

    // ── Test harness method IDs (optional — clear exception if not present) ────
    #define CACHE_OPT(field, name, sig) \
        Bridge.field = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, name, sig); \
        if (!Bridge.field) { (*jenv)->ExceptionClear(jenv); LOGI("nif_load: %s not found (optional)", name); }

    CACHE_OPT(ui_tree,        "uiTree",       "()Ljava/lang/String;")
    CACHE_OPT(tap_xy,         "tapXy",        "(FF)Z")
    CACHE_OPT(tap_by_label,   "tapByLabel",   "(Ljava/lang/String;)Z")
    CACHE_OPT(type_text,      "typeText",     "(Ljava/lang/String;)Z")
    CACHE_OPT(delete_backward,"deleteBackward","()Z")
    CACHE_OPT(clear_text,     "clearText",    "()Z")
    CACHE_OPT(long_press_xy,  "longPressXy",  "(FFJ)Z")
    CACHE_OPT(swipe_xy,       "swipeXy",      "(FFFF)Z")
    #undef CACHE_OPT

    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);

    LOGI("Mob NIF loaded (Compose backend)");
    return 0;
}

ERL_NIF_INIT(mob_nif, nif_funcs, nif_load, NULL, NULL, NULL)
