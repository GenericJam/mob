// iap.c — JNI bridge between mob_nif (C NIF) and MobIapBridge (Kotlin).
//
// Each NIF function in mob_nif.zig delegates to this file's JNI wrappers,
// which call into the singleton MobIapBridge Kotlin instance.
// Results are sent back to the BEAM via the `sendToBeam` / `sendAtom`
// JNI callbacks declared as `@JvmStatic external fun` in MobIapBridge.
//
// Thread model:
//   - NIF calls arrive on the BEAM scheduler thread
//   - JNI calls hop to the Kotlin side via g_jvm (global from main NIF)
//   - MobIapBridge dispatches via coroutines (Dispatchers.Main for billing)
//   - Results come back via JNI callbacks → enif_send (thread-safe)
//
// IMPORTANT: the ErlNifPid* passed through JNI is heap-allocated by the
// Zig NIF stubs. Every JNI callback below MUST free(pid_ptr) after enif_send.

#include <string.h>
#include <stdlib.h>
#include <jni.h>
#include <erl_nif.h>

// g_jvm is set by the main mob NIF (mob_nif.zig / mob_beam.zig) during
// JNI_OnLoad or bridge initialization. We extern it here — do NOT define
// our own JNI_OnLoad or duplicate g_jvm; the linker resolves this symbol.
extern JavaVM *g_jvm;

// ── Global references ───────────────────────────────────────────────────

static jobject g_bridge = NULL;
static jclass g_bridge_class = NULL;
static jmethodID g_fetch_products = NULL;
static jmethodID g_purchase = NULL;
static jmethodID g_restore = NULL;
static jmethodID g_entitlements = NULL;
static jmethodID g_manage_subs = NULL;
static jmethodID g_acknowledge = NULL;
static jmethodID g_consume = NULL;
static jmethodID g_send_atom = NULL;
static jmethodID g_send_atom3 = NULL;
static jmethodID g_send_to_beam = NULL;

// ── JNI callback implementations — called from MobIapBridge Kotlin ──────
// Every callback below heap-allocated ErlNifPid* (jlong pid) after use.

JNIEXPORT void JNICALL
Java_com_mob_iap_MobIapBridge_sendAtom(JNIEnv *env, jclass cls, jlong pid, jstring tag) {
    ErlNifPid *p = (ErlNifPid *)(intptr_t)pid;
    const char *tag_str = (*env)->GetStringUTFChars(env, tag, NULL);

    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, "iap"), enif_make_atom(e, tag_str));
    enif_send(NULL, p, e, msg);
    enif_free_env(e);
    free(p);

    (*env)->ReleaseStringUTFChars(env, tag, tag_str);
}

JNIEXPORT void JNICALL
Java_com_mob_iap_MobIapBridge_sendAtom3(JNIEnv *env, jclass cls, jlong pid,
                                         jstring tag, jstring atom) {
    ErlNifPid *p = (ErlNifPid *)(intptr_t)pid;
    const char *tag_str = (*env)->GetStringUTFChars(env, tag, NULL);
    const char *atom_str = (*env)->GetStringUTFChars(env, atom, NULL);

    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "iap"),
                                        enif_make_atom(e, tag_str),
                                        enif_make_atom(e, atom_str));
    enif_send(NULL, p, e, msg);
    enif_free_env(e);
    free(p);

    (*env)->ReleaseStringUTFChars(env, tag, tag_str);
    (*env)->ReleaseStringUTFChars(env, atom, atom_str);
}

JNIEXPORT void JNICALL
Java_com_mob_iap_MobIapBridge_sendToBeam(JNIEnv *env, jclass cls,
                                          jlong pid, jstring tag, jstring json) {
    ErlNifPid *p = (ErlNifPid *)(intptr_t)pid;
    const char *tag_str = (*env)->GetStringUTFChars(env, tag, NULL);
    const char *json_str = (*env)->GetStringUTFChars(env, json, NULL);

    ErlNifEnv *e = enif_alloc_env();
    ERL_NIF_TERM inner = enif_make_tuple2(e, enif_make_atom(e, "iap"),
                                          enif_make_atom(e, tag_str));

    ERL_NIF_TERM json_bin;
    size_t len = strlen(json_str);
    unsigned char *buf = enif_make_new_binary(e, len, &json_bin);
    memcpy(buf, json_str, len);

    ERL_NIF_TERM msg = enif_make_tuple2(e, inner, json_bin);
    enif_send(NULL, p, e, msg);
    enif_free_env(e);
    free(p);

    (*env)->ReleaseStringUTFChars(env, tag, tag_str);
    (*env)->ReleaseStringUTFChars(env, json, json_str);
}

// ── Initialization — called once from mob_nif.zig to create the Bridge ───

// Initialize the MobIapBridge singleton. Called from mob_nif.zig during
// app startup with a reference to the main Activity.
void mob_iap_init(JNIEnv *env, jobject activity) {
    jclass bridge_class = (*env)->FindClass(env, "com/mob/iap/MobIapBridge");
    if (!bridge_class) {
        // Plugin not installed — JNI functions will be no-ops
        (*env)->ExceptionClear(env);
        return;
    }
    g_bridge_class = (*env)->NewGlobalRef(env, bridge_class);

    g_fetch_products = (*env)->GetMethodID(env, g_bridge_class, "fetchProducts", "(JLjava/util/List;)V");
    g_purchase = (*env)->GetMethodID(env, g_bridge_class, "purchase", "(JLjava/lang/String;)V");
    g_restore = (*env)->GetMethodID(env, g_bridge_class, "restorePurchases", "(J)V");
    g_entitlements = (*env)->GetMethodID(env, g_bridge_class, "currentEntitlements", "(J)V");
    g_manage_subs = (*env)->GetMethodID(env, g_bridge_class, "manageSubscriptions", "()V");
    g_acknowledge = (*env)->GetMethodID(env, g_bridge_class, "acknowledgePurchase", "(Ljava/lang/String;)V");
    g_consume = (*env)->GetMethodID(env, g_bridge_class, "consumePurchase", "(Ljava/lang/String;)V");
    g_send_atom = (*env)->GetStaticMethodID(env, g_bridge_class, "sendAtom", "(JLjava/lang/String;)V");
    g_send_atom3 = (*env)->GetStaticMethodID(env, g_bridge_class, "sendAtom3", "(JLjava/lang/String;Ljava/lang/String;)V");
    g_send_to_beam = (*env)->GetStaticMethodID(env, g_bridge_class, "sendToBeam", "(JLjava/lang/String;Ljava/lang/String;)V");

    if (!g_fetch_products || !g_purchase || !g_restore || !g_entitlements ||
        !g_manage_subs || !g_acknowledge || !g_consume ||
        !g_send_atom || !g_send_atom3 || !g_send_to_beam) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, g_bridge_class);
        g_bridge_class = NULL;
        return;
    }

    jmethodID ctor = (*env)->GetMethodID(env, g_bridge_class, "<init>", "(Landroid/app/Activity;)V");
    if (!ctor) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, g_bridge_class);
        g_bridge_class = NULL;
        return;
    }
    jobject bridge = (*env)->NewObject(env, g_bridge_class, ctor, activity);
    g_bridge = (*env)->NewGlobalRef(env, bridge);
}

//─ Helpers ──────────────────────────────────────────────────────────────

// Build a Java ArrayList<String> from a C string array, then free the
// source strings (they've been copied into Java strings).
static jobject iap_jni_build_string_list(JNIEnv *env, const char **strings, int count) {
    jclass list_class = (*env)->FindClass(env, "java/util/ArrayList");
    jmethodID list_ctor = (*env)->GetMethodID(env, list_class, "<init>", "()V");
    jmethodID list_add = (*env)->GetMethodID(env, list_class, "add", "(Ljava/lang/Object;)Z");

    jobject list = (*env)->NewObject(env, list_class, list_ctor);
    for (int i = 0; i < count; i++) {
        jstring s = (*env)->NewStringUTF(env, strings[i]);
        (*env)->CallBooleanMethod(env, list, list_add, s);
        (*env)->DeleteLocalRef(env, s);
        free((void *)strings[i]);
    }
    (*env)->DeleteLocalRef(env, list_class);
    return list;
}

static inline JNIEnv *iap_jni_get_env(jint *attached) {
    *attached = 0;
    JNIEnv *env;
    jint rc = (*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) == JNI_OK) {
            *attached = 1;
            return env;
        }
        return NULL;
    }
    return env;
}

static inline void iap_jni_detach_if_needed(jint attached) {
    if (attached) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

// ── NIF wrappers — called from mob_nif.zig ──────────────────────────

void mob_iap_fetch_products(void *pid_ptr, const char **ids, int count) {
    if (!g_bridge) { free(pid_ptr); return; }

    jint attached;
    JNIEnv *env = iap_jni_get_env(&attached);
    if (!env) { free(pid_ptr); return; }

    jobject list = iap_jni_build_string_list(env, ids, count);
    jlong pid = (jlong)(intptr_t)pid_ptr;
    (*env)->CallVoidMethod(env, g_bridge, g_fetch_products, pid, list);
    (*env)->DeleteLocalRef(env, list);

    iap_jni_detach_if_needed(attached);
}

void mob_iap_purchase(void *pid_ptr, const char *product_id) {
    if (!g_bridge) { free(pid_ptr); return; }

    jint attached;
    JNIEnv *env = iap_jni_get_env(&attached);
    if (!env) { free(pid_ptr); return; }

    jstring product_jstr = (*env)->NewStringUTF(env, product_id);
    jlong pid = (jlong)(intptr_t)pid_ptr;
    (*env)->CallVoidMethod(env, g_bridge, g_purchase, pid, product_jstr);
    (*env)->DeleteLocalRef(env, product_jstr);

    iap_jni_detach_if_needed(attached);
}

void mob_iap_restore(void *pid_ptr) {
    if (!g_bridge) { free(pid_ptr); return; }

    jint attached;
    JNIEnv *env = iap_jni_get_env(&attached);
    if (!env) { free(pid_ptr); return; }

    jlong pid = (jlong)(intptr_t)pid_ptr;
    (*env)->CallVoidMethod(env, g_bridge, g_restore, pid);

    iap_jni_detach_if_needed(attached);
}

void mob_iap_current_entitlements(void *pid_ptr) {
    if (!g_bridge) { free(pid_ptr); return; }

    jint attached;
    JNIEnv *env = iap_jni_get_env(&attached);
    if (!env) { free(pid_ptr); return; }

    jlong pid = (jlong)(intptr_t)pid_ptr;
    (*env)->CallVoidMethod(env, g_bridge, g_entitlements, pid);

    iap_jni_detach_if_needed(attached);
}

void mob_iap_manage_subscriptions(void) {
    if (!g_bridge) return;

    jint attached;
    JNIEnv *env = iap_jni_get_env(&attached);
    if (!env) return;

    (*env)->CallVoidMethod(env, g_bridge, g_manage_subs);

    iap_jni_detach_if_needed(attached);
}
