// mob_nif.c — Mob UI NIF for Android.
// Module name: mob_nif
//
// NIF functions:
//   create_column/0, create_row/0, create_label/1, create_button/1,
//   create_scroll/0, add_child/2, remove_child/1, set_text/2,
//   set_text_size/2, set_text_color/2, set_background_color/2,
//   set_padding/2, on_tap/2, set_root/1

#include <jni.h>
#include <android/log.h>
#include <stdint.h>
#include <string.h>
#include "erl_nif.h"
#include "mob_beam.h"

#define LOG_TAG "MobNIF"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ── View resource ────────────────────────────────────────────────────────────

typedef enum { VTYPE_GENERIC = 0, VTYPE_SCROLL = 1 } VType;

typedef struct {
    jobject view;
    jobject scroll_inner;
    VType   vtype;
    int     is_row;
    ErlNifPid tap_pid;
    int has_tap_pid;
} ViewRes;

static ErlNifResourceType* view_res_type = NULL;

// ── Cached JNI method IDs ────────────────────────────────────────────────────

static struct {
    jclass    cls;
    jmethodID create_column;
    jmethodID create_row;
    jmethodID create_label;
    jmethodID create_button;
    jmethodID create_scroll_view;
    jmethodID add_child;
    jmethodID remove_child;
    jmethodID set_text;
    jmethodID set_text_size;
    jmethodID set_text_color;
    jmethodID set_background_color;
    jmethodID set_padding;
    jmethodID set_on_tap_listener;
    jmethodID set_root;
    jmethodID get_tag;
} Bridge;

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

static int get_string(ErlNifEnv* env, ERL_NIF_TERM term, char* buf, size_t size) {
    ErlNifBinary bin;
    if (enif_inspect_binary(env, term, &bin)) {
        size_t len = bin.size < size - 1 ? bin.size : size - 1;
        memcpy(buf, bin.data, len);
        buf[len] = 0;
        return 1;
    }
    return enif_get_string(env, term, buf, size, ERL_NIF_UTF8) > 0;
}

// ── Resource destructor ──────────────────────────────────────────────────────

static void view_destructor(ErlNifEnv* env, void* ptr) {
    ViewRes* res = (ViewRes*)ptr;
    int att; JNIEnv* jenv = get_jenv(&att);
    if (res->view)         (*jenv)->DeleteGlobalRef(jenv, res->view);
    if (res->scroll_inner) (*jenv)->DeleteGlobalRef(jenv, res->scroll_inner);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
}

// ── Tap callback — registered via RegisterNatives, not by JNI name ──────────

void mob_native_on_tap(JNIEnv* jenv, jclass cls, jlong ptr) {
    ViewRes* res = (ViewRes*)(uintptr_t)ptr;
    if (!res || !res->has_tap_pid) return;

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env,
        enif_make_atom(msg_env, "tap"),
        enif_make_atom(msg_env, "ok"));
    enif_send(NULL, &res->tap_pid, msg_env, msg);
    enif_free_env(msg_env);
}

// ── Cache MobBridge class and method IDs (called from mob_beam.c) ────────────

void _mob_ui_cache_class_impl(JNIEnv* jenv, const char* bridge_class) {
    LOGI("mob_ui_cache_class: looking up %s", bridge_class);
    jclass cls = (*jenv)->FindClass(jenv, bridge_class);
    if (!cls) { LOGE("mob_ui_cache_class: %s not found", bridge_class); return; }
    Bridge.cls = (*jenv)->NewGlobalRef(jenv, cls);
    (*jenv)->DeleteLocalRef(jenv, cls);
    LOGI("mob_ui_cache_class: %s cached OK", bridge_class);
}

// ── Call MobBridge.init(activity) using the cached class ref ─────────────────

void _mob_bridge_init_activity(JNIEnv* env, jobject activity) {
    if (!Bridge.cls) { LOGE("_mob_bridge_init_activity: Bridge.cls not cached"); return; }
    jmethodID init = (*env)->GetStaticMethodID(env, Bridge.cls, "init",
        "(Landroid/app/Activity;)V");
    (*env)->CallStaticVoidMethod(env, Bridge.cls, init, activity);
    LOGI("_mob_bridge_init_activity: MobBridge.init called");
}

// ── Wrap a local jobject into an Erlang resource term ───────────────────────

static ERL_NIF_TERM make_view(ErlNifEnv* env, JNIEnv* jenv,
                               jobject local, VType vtype, int is_row) {
    ViewRes* res = enif_alloc_resource(view_res_type, sizeof(ViewRes));
    res->view = (*jenv)->NewGlobalRef(jenv, local);
    res->scroll_inner = NULL;
    res->vtype = vtype;
    res->is_row = is_row;
    res->has_tap_pid = 0;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return term;
}

// ── NIF: create_column/0 ─────────────────────────────────────────────────────

static ERL_NIF_TERM nif_create_column(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    jobject v = (*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.create_column);
    if (!v) { if (att) (*g_jvm)->DetachCurrentThread(g_jvm); return enif_make_badarg(env); }
    ERL_NIF_TERM t = make_view(env, jenv, v, VTYPE_GENERIC, 0);
    (*jenv)->DeleteLocalRef(jenv, v);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), t);
}

// ── NIF: create_row/0 ────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_create_row(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    jobject v = (*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.create_row);
    if (!v) { if (att) (*g_jvm)->DetachCurrentThread(g_jvm); return enif_make_badarg(env); }
    ERL_NIF_TERM t = make_view(env, jenv, v, VTYPE_GENERIC, 1);
    (*jenv)->DeleteLocalRef(jenv, v);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), t);
}

// ── NIF: create_label/1 ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_create_label(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char text[512] = {0};
    if (!get_string(env, argv[0], text, sizeof(text)))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jtext = (*jenv)->NewStringUTF(jenv, text);
    jobject v = (*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.create_label, jtext);
    (*jenv)->DeleteLocalRef(jenv, jtext);
    ERL_NIF_TERM t = make_view(env, jenv, v, VTYPE_GENERIC, 0);
    (*jenv)->DeleteLocalRef(jenv, v);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), t);
}

// ── NIF: create_button/1 ─────────────────────────────────────────────────────

static ERL_NIF_TERM nif_create_button(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char text[256] = {0};
    if (!get_string(env, argv[0], text, sizeof(text)))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jtext = (*jenv)->NewStringUTF(jenv, text);
    jobject v = (*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.create_button, jtext);
    (*jenv)->DeleteLocalRef(jenv, jtext);
    ERL_NIF_TERM t = make_view(env, jenv, v, VTYPE_GENERIC, 0);
    (*jenv)->DeleteLocalRef(jenv, v);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), t);
}

// ── NIF: create_scroll/0 ─────────────────────────────────────────────────────

static ERL_NIF_TERM nif_create_scroll(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int att; JNIEnv* jenv = get_jenv(&att);
    jobject sv = (*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.create_scroll_view);
    jobject inner = (*jenv)->CallStaticObjectMethod(jenv, Bridge.cls, Bridge.get_tag, sv);

    ViewRes* res = enif_alloc_resource(view_res_type, sizeof(ViewRes));
    res->view         = (*jenv)->NewGlobalRef(jenv, sv);
    res->scroll_inner = (*jenv)->NewGlobalRef(jenv, inner);
    res->vtype        = VTYPE_SCROLL;
    res->is_row       = 0;
    res->has_tap_pid  = 0;
    ERL_NIF_TERM t = enif_make_resource(env, res);
    enif_release_resource(res);

    (*jenv)->DeleteLocalRef(jenv, sv);
    (*jenv)->DeleteLocalRef(jenv, inner);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), t);
}

// ── NIF: add_child/2 ─────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_add_child(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes *parent, *child;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&parent) ||
        !enif_get_resource(env, argv[1], view_res_type, (void**)&child))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);

    jobject actual_parent = (parent->vtype == VTYPE_SCROLL)
        ? parent->scroll_inner
        : parent->view;

    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.add_child,
        actual_parent, child->view, (jboolean)parent->is_row);

    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: remove_child/1 ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_remove_child(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.remove_child, res->view);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_text/2 ──────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_set_text(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    char text[512] = {0};
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res) ||
        !get_string(env, argv[1], text, sizeof(text)))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    jstring jtext = (*jenv)->NewStringUTF(jenv, text);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_text, res->view, jtext);
    (*jenv)->DeleteLocalRef(jenv, jtext);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_text_size/2 ─────────────────────────────────────────────────────

static ERL_NIF_TERM nif_set_text_size(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    double sz;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res) ||
        !enif_get_double(env, argv[1], &sz)) {
        int ival;
        if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res) ||
            !enif_get_int(env, argv[1], &ival))
            return enif_make_badarg(env);
        sz = (double)ival;
    }

    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_text_size,
        res->view, (jfloat)sz);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_text_color/2 ────────────────────────────────────────────────────

static ERL_NIF_TERM nif_set_text_color(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    long color;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res) ||
        !enif_get_long(env, argv[1], &color))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_text_color,
        res->view, (jint)color);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_background_color/2 ──────────────────────────────────────────────

static ERL_NIF_TERM nif_set_background_color(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    long color;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res) ||
        !enif_get_long(env, argv[1], &color))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_background_color,
        res->view, (jint)color);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_padding/2 ───────────────────────────────────────────────────────

static ERL_NIF_TERM nif_set_padding(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    int dp;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res) ||
        !enif_get_int(env, argv[1], &dp))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_padding,
        res->view, (jint)dp);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: on_tap/2 ────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_on_tap(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    ErlNifPid pid;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res) ||
        !enif_get_local_pid(env, argv[1], &pid))
        return enif_make_badarg(env);

    res->tap_pid = pid;
    if (!res->has_tap_pid) {
        enif_keep_resource(res);
        res->has_tap_pid = 1;
    }

    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_on_tap_listener,
        res->view, (jlong)(uintptr_t)res);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_root/1 ──────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_set_root(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ViewRes* res;
    if (!enif_get_resource(env, argv[0], view_res_type, (void**)&res))
        return enif_make_badarg(env);

    int att; JNIEnv* jenv = get_jenv(&att);
    (*jenv)->CallStaticVoidMethod(jenv, Bridge.cls, Bridge.set_root, res->view);
    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    return enif_make_atom(env, "ok");
}

// ── NIF: log/1 ───────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_log(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char buf[512];
    if (!enif_get_string(env, argv[0], buf, sizeof(buf), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    __android_log_print(ANDROID_LOG_INFO, "MobNIF", "[mob] %s", buf);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_platform(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "android");
}

// ── NIF table & load ─────────────────────────────────────────────────────────

static ErlNifFunc nif_funcs[] = {
    {"platform",              0, nif_platform,             0},
    {"log",                  1, nif_log,                  0},
    {"create_column",        0, nif_create_column,        0},
    {"create_row",           0, nif_create_row,           0},
    {"create_label",         1, nif_create_label,         0},
    {"create_button",        1, nif_create_button,        0},
    {"create_scroll",        0, nif_create_scroll,        0},
    {"add_child",            2, nif_add_child,            0},
    {"remove_child",         1, nif_remove_child,         0},
    {"set_text",             2, nif_set_text,             0},
    {"set_text_size",        2, nif_set_text_size,        0},
    {"set_text_color",       2, nif_set_text_color,       0},
    {"set_background_color", 2, nif_set_background_color, 0},
    {"set_padding",          2, nif_set_padding,          0},
    {"on_tap",               2, nif_on_tap,               0},
    {"set_root",             1, nif_set_root,             0},
};

static int nif_load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
    LOGI("nif_load: entered, Bridge.cls=%p", (void*)Bridge.cls);
    view_res_type = enif_open_resource_type(env, NULL, "mob_view",
        view_destructor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (!view_res_type) { LOGE("nif_load: enif_open_resource_type failed"); return -1; }

    if (!Bridge.cls) { LOGE("Bridge.cls not cached — was mob_ui_cache_class called?"); return -1; }

    int att; JNIEnv* jenv = get_jenv(&att);

    Bridge.create_column       = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "createColumn",      "()Landroid/view/View;");
    Bridge.create_row          = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "createRow",         "()Landroid/view/View;");
    Bridge.create_label        = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "createLabel",       "(Ljava/lang/String;)Landroid/view/View;");
    Bridge.create_button       = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "createButton",      "(Ljava/lang/String;)Landroid/view/View;");
    Bridge.create_scroll_view  = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "createScrollView",  "()Landroid/view/View;");
    Bridge.add_child           = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "addChild",          "(Landroid/view/View;Landroid/view/View;Z)V");
    Bridge.remove_child        = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "removeChild",       "(Landroid/view/View;)V");
    Bridge.set_text            = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setText",           "(Landroid/view/View;Ljava/lang/String;)V");
    Bridge.set_text_size       = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setTextSize",       "(Landroid/view/View;F)V");
    Bridge.set_text_color      = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setTextColor",      "(Landroid/view/View;I)V");
    Bridge.set_background_color= (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setBackgroundColor","(Landroid/view/View;I)V");
    Bridge.set_padding         = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setPadding",        "(Landroid/view/View;I)V");
    Bridge.set_on_tap_listener = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setOnTapListener",  "(Landroid/view/View;J)V");
    Bridge.set_root            = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "setRoot",           "(Landroid/view/View;)V");
    Bridge.get_tag             = (*jenv)->GetStaticMethodID(jenv, Bridge.cls, "getTag",            "(Landroid/view/View;)Landroid/view/View;");

    if (att) (*g_jvm)->DetachCurrentThread(g_jvm);
    LOGI("Mob NIF loaded, resource type registered");
    return 0;
}

ERL_NIF_INIT(mob_nif, nif_funcs, nif_load, NULL, NULL, NULL)
