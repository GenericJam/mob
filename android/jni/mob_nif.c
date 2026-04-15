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
    LOGI("mob_ui_cache_class: %s cached OK", bridge_class);
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

// ── NIF table & load ─────────────────────────────────────────────────────────

static ErlNifFunc nif_funcs[] = {
    {"platform",       0, nif_platform,       0},
    {"log",            1, nif_log,            0},
    {"log",            2, nif_log2,           0},
    {"set_transition", 1, nif_set_transition, 0},
    {"set_root",       1, nif_set_root,       0},
    {"register_tap",   1, nif_register_tap,   0},
    {"clear_taps",     0, nif_clear_taps,     0},
    {"exit_app",       0, nif_exit_app,       0},
    {"safe_area",      0, nif_safe_area,      0},
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

    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);

    LOGI("Mob NIF loaded (Compose backend)");
    return 0;
}

ERL_NIF_INIT(mob_nif, nif_funcs, nif_load, NULL, NULL, NULL)
