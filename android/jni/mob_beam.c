// mob_beam.c — Mob BEAM launcher and JNI bridge initialisation.
// Extracted from the per-app beam_jni.c stub so app code stays minimal.

#include <jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>
#include "mob_beam.h"

#define LOG_TAG "MobBeam"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#define ERTS_VSN    "erts-16.3"

// Declared in mob_nif.c — caches MobBridge methods on the main thread.
extern void _mob_ui_cache_class_impl(JNIEnv* env, const char* bridge_class);

// Native lib dir and app files dir — populated in mob_init_bridge, used in mob_start_beam.
static char s_native_lib_dir[512] = {0};
static char s_files_dir[512]      = {0};

// Declared in mob_nif.c — the C function registered as the tap native.
extern void mob_native_on_tap(JNIEnv* jenv, jclass cls, jlong ptr);

void mob_ui_cache_class(JNIEnv* env, const char* bridge_class) {
    _mob_ui_cache_class_impl(env, bridge_class);
}

void mob_register_tap_native(JNIEnv* env, const char* tap_class) {
    jclass cls = (*env)->FindClass(env, tap_class);
    if (!cls) { LOGE("mob_register_tap_native: class %s not found", tap_class); return; }
    JNINativeMethod methods[] = {
        {"nativeOnTap", "(J)V", (void*)mob_native_on_tap}
    };
    (*env)->RegisterNatives(env, cls, methods, 1);
    (*env)->DeleteLocalRef(env, cls);
    LOGI("mob_register_tap_native: registered nativeOnTap on %s", tap_class);
}

// Declared in mob_nif.c — the cached Bridge.cls global ref.
extern void _mob_bridge_init_activity(JNIEnv* env, jobject activity);

void mob_init_bridge(JNIEnv* env, jobject activity) {
    g_activity = (*env)->NewGlobalRef(env, activity);
    _mob_bridge_init_activity(env, g_activity);

    // Get nativeLibraryDir so mob_start_beam can symlink ERTS executables there.
    // Files in the native lib dir carry the apk_data_file SELinux label which
    // allows execve() from untrusted_app, unlike files in app_data_file.
    jclass ctx_cls = (*env)->FindClass(env, "android/content/Context");
    jmethodID get_app_info = (*env)->GetMethodID(env, ctx_cls, "getApplicationInfo",
                                                   "()Landroid/content/pm/ApplicationInfo;");
    jobject app_info = (*env)->CallObjectMethod(env, activity, get_app_info);
    jclass app_info_cls = (*env)->FindClass(env, "android/content/pm/ApplicationInfo");
    jfieldID fid = (*env)->GetFieldID(env, app_info_cls, "nativeLibraryDir",
                                       "Ljava/lang/String;");
    jstring jdir = (*env)->GetObjectField(env, app_info, fid);
    const char* dir = (*env)->GetStringUTFChars(env, jdir, NULL);
    snprintf(s_native_lib_dir, sizeof(s_native_lib_dir), "%s", dir);
    (*env)->ReleaseStringUTFChars(env, jdir, dir);
    LOGI("mob_init_bridge: native lib dir = %s", s_native_lib_dir);

    // Get filesDir for OTP root path (app-specific, avoids hardcoding package name).
    jmethodID get_files_dir = (*env)->GetMethodID(env, ctx_cls, "getFilesDir", "()Ljava/io/File;");
    jobject files_dir_obj = (*env)->CallObjectMethod(env, activity, get_files_dir);
    jclass file_cls = (*env)->FindClass(env, "java/io/File");
    jmethodID get_path = (*env)->GetMethodID(env, file_cls, "getPath", "()Ljava/lang/String;");
    jstring jfiles_path = (*env)->CallObjectMethod(env, files_dir_obj, get_path);
    const char* files_path = (*env)->GetStringUTFChars(env, jfiles_path, NULL);
    snprintf(s_files_dir, sizeof(s_files_dir), "%s", files_path);
    (*env)->ReleaseStringUTFChars(env, jfiles_path, files_path);
    LOGI("mob_init_bridge: files dir = %s", s_files_dir);
}

void mob_start_beam(const char* app_module) {
#ifdef NO_BEAM
    // Config A: baseline measurement — stock Android activity, BEAM never launched.
    LOGI("mob_start_beam: NO_BEAM defined, skipping BEAM launch (battery baseline)");
    return;
#endif
    // Build all paths dynamically from s_files_dir (set in mob_init_bridge).
    char otp_root[560];
    snprintf(otp_root, sizeof(otp_root), "%s/otp", s_files_dir);

    char bindir[600];
    snprintf(bindir, sizeof(bindir), "%s/" ERTS_VSN "/bin", otp_root);

    char beams_dir[600];
    snprintf(beams_dir, sizeof(beams_dir), "%s/%s", otp_root, app_module);

    char elixir_dir[600];
    snprintf(elixir_dir, sizeof(elixir_dir), "%s/lib/elixir/ebin", otp_root);

    char logger_dir[600];
    snprintf(logger_dir, sizeof(logger_dir), "%s/lib/logger/ebin", otp_root);

    char crash_dump[560];
    snprintf(crash_dump, sizeof(crash_dump), "%s/erl_crash.dump", s_files_dir);

    setenv("BINDIR",   bindir,      1);
    setenv("ROOTDIR",  otp_root,    1);
    setenv("PROGNAME", "erl",       1);
    setenv("EMU",      "beam",      1);
    setenv("HOME",     s_files_dir, 1);
    setenv("ERL_CRASH_DUMP",         crash_dump, 1);
    setenv("ERL_CRASH_DUMP_SECONDS", "30",       1);

    char eval_expr[280];
    snprintf(eval_expr, sizeof(eval_expr), "%s:start().", app_module);

    // BEAM_EXTRA_FLAGS is injected at compile time for battery benchmarking.
    // Default (production): single scheduler + busy-wait disabled.
    // Override via CMake: -DBEAM_EXTRA_FLAGS="..."
    // Use BEAM_FLAG_NONE to build with no tuning flags at all (benchmark baseline).
#ifndef BEAM_EXTRA_FLAGS
#define BEAM_EXTRA_FLAGS "-S", "1:1", "-SDcpu", "1:1", "-SDio", "1", "-A", "1", "-sbwt", "none",
#endif

    char boot_path[580];
    snprintf(boot_path, sizeof(boot_path), "%s/releases/29/start_clean", otp_root);

    const char* args[] = {
        "beam",
        BEAM_EXTRA_FLAGS
        "--",
        "-root",     otp_root,
        "-bindir",   bindir,
        "-progname", "erl",
        "--",
        "-noshell", "-noinput",
        "-boot",   boot_path,
        "-pa",     elixir_dir,
        "-pa",     logger_dir,
        "-pa",     beams_dir,
        "-eval",   eval_expr,
        NULL
    };
    int ac = 0;
    while (args[ac]) ac++;
    LOGI("mob_start_beam: starting BEAM with module=%s, argc=%d", app_module, ac);

    // Symlink ERTS executables from BINDIR to the native lib dir.
    // The native lib dir has apk_data_file SELinux label, allowing execve() from
    // untrusted_app. Plain app_data_file (files/) blocks execute_no_trans.
    if (s_native_lib_dir[0]) {
        static const char* const exes[] = {
            "erl_child_setup", "inet_gethost", "epmd", NULL
        };
        static const char* const libs[] = {
            "liberl_child_setup.so", "libinet_gethost.so", "libepmd.so", NULL
        };
        char bin_path[512], lib_path[512];
        for (int i = 0; exes[i]; i++) {
            snprintf(bin_path, sizeof(bin_path),
                     "%s/" ERTS_VSN "/bin/%s", otp_root, exes[i]);
            snprintf(lib_path, sizeof(lib_path),
                     "%s/%s", s_native_lib_dir, libs[i]);
            unlink(bin_path);
            if (symlink(lib_path, bin_path) == 0) {
                LOGI("mob_start_beam: symlink %s -> %s", exes[i], lib_path);
            } else {
                LOGE("mob_start_beam: symlink %s failed: %s", exes[i], strerror(errno));
            }
        }
    }

    void erl_start(int, char**);
    erl_start(ac, (char**)args);
    LOGE("mob_start_beam: erl_start returned (unexpected)");
}
