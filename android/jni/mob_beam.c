// mob_beam.c — Mob BEAM launcher and JNI bridge initialisation.
// Extracted from the per-app beam_jni.c stub so app code stays minimal.

#include "mob_beam.h"
#include <android/log.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LOG_TAG "MobBeam"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ── BEAM stdout/stderr → logcat ──────────────────────────────────────────
// Without this, anything the BEAM writes to stderr (including ** crash
// reports from Logger and the boot script's :application.start/2 errors)
// is silently dropped on Android. Wire stdout + stderr to a pipe and read
// them on a detached thread, emitting each line under the "BEAMout" tag.
// One-shot: called once from mob_init_bridge before any BEAM code runs.
//
// See beam_crash.md (Incident #1) for the case that motivated this.

static void *mob_beam_log_reader(void *arg) {
    int fd = (int)(intptr_t)arg;
    char buf[4096];
    char line[4096];
    int line_pos = 0;
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < n; i++) {
            char c = buf[i];
            if (c == '\n' || line_pos >= (int)sizeof(line) - 1) {
                line[line_pos] = '\0';
                if (line_pos > 0) {
                    __android_log_write(ANDROID_LOG_INFO, "BEAMout", line);
                }
                line_pos = 0;
            } else if (c != '\r') {
                line[line_pos++] = c;
            }
        }
    }
    return NULL;
}

static void mob_capture_beam_stdio(void) {
    int pipe_fds[2];
    if (pipe(pipe_fds) != 0) {
        LOGE("mob_capture_beam_stdio: pipe() failed: %s", strerror(errno));
        return;
    }
    if (dup2(pipe_fds[1], STDOUT_FILENO) < 0)
        LOGE("mob_capture_beam_stdio: dup2 stdout failed: %s", strerror(errno));
    if (dup2(pipe_fds[1], STDERR_FILENO) < 0)
        LOGE("mob_capture_beam_stdio: dup2 stderr failed: %s", strerror(errno));
    close(pipe_fds[1]);

    pthread_t tid;
    if (pthread_create(&tid, NULL, mob_beam_log_reader, (void *)(intptr_t)pipe_fds[0]) != 0) {
        LOGE("mob_capture_beam_stdio: pthread_create failed: %s", strerror(errno));
        close(pipe_fds[0]);
        return;
    }
    pthread_detach(tid);

    // Disable buffering so output reaches the pipe immediately, not on
    // exit (which we never reach for a long-running BEAM).
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    LOGI("mob_capture_beam_stdio: piping stdout/stderr to logcat (tag: BEAMout)");
}

#define ERTS_VSN "erts-17.0"

// Declared in mob_nif.c — caches MobBridge methods on the main thread.
extern void _mob_ui_cache_class_impl(JNIEnv *env, const char *bridge_class);

// Native lib dir and app files dir — populated in mob_init_bridge, used in mob_start_beam.
static char s_native_lib_dir[512] = {0};
static char s_files_dir[512] = {0};

void mob_ui_cache_class(JNIEnv *env, const char *bridge_class) {
    _mob_ui_cache_class_impl(env, bridge_class);
}

// Declared in mob_nif.c — the cached Bridge.cls global ref.
extern void _mob_bridge_init_activity(JNIEnv *env, jobject activity);

void mob_init_bridge(JNIEnv *env, jobject activity) {
    // Capture BEAM stdio first so any startup errors (NIF load failures,
    // application:start/2 crashes) land in logcat instead of /dev/null.
    mob_capture_beam_stdio();

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
    jfieldID fid = (*env)->GetFieldID(env, app_info_cls, "nativeLibraryDir", "Ljava/lang/String;");
    jstring jdir = (*env)->GetObjectField(env, app_info, fid);
    const char *dir = (*env)->GetStringUTFChars(env, jdir, NULL);
    snprintf(s_native_lib_dir, sizeof(s_native_lib_dir), "%s", dir);
    (*env)->ReleaseStringUTFChars(env, jdir, dir);
    LOGI("mob_init_bridge: native lib dir = %s", s_native_lib_dir);

    // Get filesDir for OTP root path (app-specific, avoids hardcoding package name).
    jmethodID get_files_dir = (*env)->GetMethodID(env, ctx_cls, "getFilesDir", "()Ljava/io/File;");
    jobject files_dir_obj = (*env)->CallObjectMethod(env, activity, get_files_dir);
    jclass file_cls = (*env)->FindClass(env, "java/io/File");
    jmethodID get_path = (*env)->GetMethodID(env, file_cls, "getPath", "()Ljava/lang/String;");
    jstring jfiles_path = (*env)->CallObjectMethod(env, files_dir_obj, get_path);
    const char *files_path = (*env)->GetStringUTFChars(env, jfiles_path, NULL);
    snprintf(s_files_dir, sizeof(s_files_dir), "%s", files_path);
    (*env)->ReleaseStringUTFChars(env, jfiles_path, files_path);
    LOGI("mob_init_bridge: files dir = %s", s_files_dir);
}

void mob_start_beam(const char *app_module) {
#ifdef NO_BEAM
    // Config A: baseline measurement — stock Android activity, BEAM never launched.
    LOGI("mob_start_beam: NO_BEAM defined, skipping BEAM launch (battery baseline)");
    return;
#endif
    // Re-dlopen ourselves with RTLD_GLOBAL so the BEAM's enif_* symbols
    // (statically linked into this library) are visible when the BEAM
    // later dlopens a NIF library (e.g. crypto.so). Without this, Android
    // loads libpigeon.so with RTLD_LOCAL by default, hiding enif_* from
    // dlopen'd children — crypto.so on_load fails with
    // `cannot locate symbol enif_get_tuple`.
    {
        char self_path[600];
        snprintf(self_path, sizeof(self_path), "%s/lib%s.so", s_native_lib_dir, app_module);
        if (!dlopen(self_path, RTLD_NOW | RTLD_GLOBAL)) {
            LOGE("mob_start_beam: dlopen self with RTLD_GLOBAL failed: %s", dlerror());
        } else {
            LOGI("mob_start_beam: re-dlopened self RTLD_GLOBAL: %s", self_path);
        }
    }
    mob_set_startup_phase("Setting up BEAM environment…");
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

    char eex_dir[600];
    snprintf(eex_dir, sizeof(eex_dir), "%s/lib/eex/ebin", otp_root);

    char crash_dump[560];
    snprintf(crash_dump, sizeof(crash_dump), "%s/erl_crash.dump", s_files_dir);

    setenv("BINDIR", bindir, 1);
    setenv("ROOTDIR", otp_root, 1);
    setenv("PROGNAME", "erl", 1);
    setenv("EMU", "beam", 1);
    setenv("HOME", s_files_dir, 1);
    setenv("MOB_DATA_DIR", s_files_dir, 1);

    // MOB_BEAMS_DIR — the directory where app BEAMs (and priv/) are deployed.
    //
    // Problem: Ecto.Migrator uses :code.priv_dir(app) to locate migration .exs
    // files. :code.priv_dir/1 works by looking up the app's OTP lib structure
    // ($OTP_ROOT/lib/APP-VERSION/ebin/). Mob apps are deployed to a flat -pa
    // directory (e.g. files/otp/my_app/*.beam), not an OTP lib structure, so
    // :code.priv_dir/1 returns {error, bad_name} and Ecto silently reports
    // "Migrations already up" without running anything.
    //
    // Fix: deployer.ex pushes priv/ alongside the BEAMs into beams_dir/priv/.
    // App code reads MOB_BEAMS_DIR at startup and passes the explicit path to
    // Ecto.Migrator.run/4 instead of relying on :code.priv_dir/1. This env var
    // is the only reliable way to communicate beams_dir to Elixir code since it
    // is computed here from getFilesDir() at runtime (the path includes the
    // Android user ID which is not predictable at compile time).
    setenv("MOB_BEAMS_DIR", beams_dir, 1);
    setenv("ERL_CRASH_DUMP", crash_dump, 1);
    setenv("ERL_CRASH_DUMP_SECONDS", "30", 1);

    char eval_expr[280];
    snprintf(eval_expr, sizeof(eval_expr), "%s:start().", app_module);

    // Compile-time default BEAM tuning flags.
    // Selected by -D flag: BEAM_UNTUNED, BEAM_SBWT_ONLY, BEAM_FULL_NERVES,
    // or BEAM_USE_CUSTOM_FLAGS (includes mob_beam_flags.h from battery bench).
    // These are overridden at runtime if beams_dir/mob_beam_flags exists.
#ifdef BEAM_USE_CUSTOM_FLAGS
#include "mob_beam_flags.h"
    static const char *s_default_flags[] = {BEAM_EXTRA_FLAGS NULL};
#elif defined(BEAM_UNTUNED)
    static const char *s_default_flags[] = {NULL};
#elif defined(BEAM_SBWT_ONLY)
    static const char *s_default_flags[] = {"-sbwt",    "none", "-sbwtdcpu", "none",
                                            "-sbwtdio", "none", NULL};
#else
    // Default and BEAM_FULL_NERVES both use full Nerves-style tuning.
    static const char *s_default_flags[] = {"-S",        "1:1",  "-SDcpu",   "1:1",   "-SDio",
                                            "1",         "-A",   "1",        "-sbwt", "none",
                                            "-sbwtdcpu", "none", "-sbwtdio", "none",  NULL};
#endif

    // Runtime override: read whitespace-separated flags from beams_dir/mob_beam_flags.
    // Written by `mix mob.deploy --schedulers N` or `--beam-flags "..."`.
    static char s_flags_buf[512] = {0};
    static const char *s_runtime_flags[64] = {NULL};
    static int s_runtime_flag_count = 0;
    {
        char flags_path[640];
        snprintf(flags_path, sizeof(flags_path), "%s/mob_beam_flags", beams_dir);
        FILE *f = fopen(flags_path, "r");
        if (f) {
            size_t n = fread(s_flags_buf, 1, sizeof(s_flags_buf) - 1, f);
            fclose(f);
            s_flags_buf[n] = '\0';
            s_runtime_flag_count = 0;
            char *p = s_flags_buf;
            while (*p && s_runtime_flag_count < 63) {
                while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
                    p++;
                if (!*p)
                    break;
                s_runtime_flags[s_runtime_flag_count++] = p;
                while (*p && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r')
                    p++;
                if (*p)
                    *p++ = '\0';
            }
            s_runtime_flags[s_runtime_flag_count] = NULL;
            LOGI("mob_start_beam: loaded %d runtime flags from %s", s_runtime_flag_count,
                 flags_path);
        }
    }

    const char **selected_flags = (s_runtime_flag_count > 0) ? s_runtime_flags : s_default_flags;

    char boot_path[580];
    snprintf(boot_path, sizeof(boot_path), "%s/releases/29/start_clean", otp_root);

    static const char *args[128];
    int ac = 0;
    args[ac++] = "beam";
    for (int i = 0; selected_flags[i]; i++)
        args[ac++] = selected_flags[i];
    args[ac++] = "--";
    args[ac++] = "-root";
    args[ac++] = otp_root;
    args[ac++] = "-bindir";
    args[ac++] = bindir;
    args[ac++] = "-progname";
    args[ac++] = "erl";
    args[ac++] = "--";
    args[ac++] = "-noshell";
    args[ac++] = "-noinput";
    args[ac++] = "-boot";
    args[ac++] = boot_path;
    args[ac++] = "-pa";
    args[ac++] = elixir_dir;
    args[ac++] = "-pa";
    args[ac++] = logger_dir;
    args[ac++] = "-pa";
    args[ac++] = eex_dir;
    args[ac++] = "-pa";
    args[ac++] = beams_dir;
    args[ac++] = "-eval";
    args[ac++] = eval_expr;
    args[ac] = NULL;

    // ── Cold-start race condition fix ────────────────────────────────────────
    //
    // DO NOT REMOVE THIS BLOCK.
    //
    // Problem: on a cold start (first launch after install or after the process
    // was killed), calling erl_start() too early causes a SIGABRT deep inside
    // ERTS pthread initialisation.  The crash looks like:
    //
    //   FORTIFY: pthread_mutex_lock called on a destroyed mutex
    //   backtrace:
    //     #00  abort
    //     #01  pthread_mutex_lock (FORTIFY wrapper)
    //     #02  ... (ERTS internal thread pool setup)
    //     #03  erl_start
    //
    // Root cause: Android's hwui (hardware-accelerated UI renderer) creates its
    // own native thread pool during the very first layout/draw pass.  That
    // initialisation uses pthread mutexes that it allocates and later destroys.
    // ERTS also calls into pthreads during erl_start().  If erl_start() runs
    // concurrently with hwui's first-draw setup, the two pthread paths race on
    // the same internal libc state and the FORTIFY mutex check fires → SIGABRT.
    //
    // The race only reproduces on cold start because:
    //   • On warm start hwui's thread pool already exists → no race.
    //   • The window-focus event is the earliest point at which Android
    //     guarantees the first layout/draw pass has completed, so hwui's
    //     pthread state is stable.
    //
    // Fix: poll Activity.hasWindowFocus() every 50 ms before calling erl_start().
    // hasWindowFocus() returns true only after the window has been drawn and
    // given input focus, which is *after* hwui finishes its thread-pool setup.
    // We wait up to 3 seconds (covers slow emulators and heavily loaded devices)
    // and fall through anyway so a stuck window never blocks BEAM forever.
    //
    // Why this lives here instead of in MainActivity.kt:
    //   Putting the delay in Kotlin would mean every app built on Mob needs to
    //   replicate and maintain the fix.  Centralising it in mob_beam.c means
    //   app code can stay a simple `Thread({ nativeStartBeam() }).start()`.
    //
    // JNI threading notes:
    //   • beam-main is created via `new Thread()` in Kotlin, so it is already
    //     attached to the JVM when this function runs.  Calling
    //     AttachCurrentThread on an already-attached thread is a no-op, but
    //     calling DetachCurrentThread on a Java-created thread makes ART abort.
    //   • We therefore call GetEnv first.  If the thread is already attached
    //     (needs_detach == 0) we skip both Attach and Detach.  Only a purely
    //     native thread that was never attached would set needs_detach == 1.
    if (g_jvm && g_activity) {
        mob_set_startup_phase("Waiting for window focus…");
        JNIEnv *env2 = NULL;
        int needs_detach = ((*g_jvm)->GetEnv(g_jvm, (void **)&env2, JNI_VERSION_1_6) != JNI_OK);
        if (needs_detach)
            (*g_jvm)->AttachCurrentThread(g_jvm, &env2, NULL);

        jclass act_cls = (*env2)->GetObjectClass(env2, g_activity);
        jmethodID has_focus = (*env2)->GetMethodID(env2, act_cls, "hasWindowFocus", "()Z");
        int waited = 0;
        const int max_wait = 3000; /* ms — fall through if focus never arrives */
        while (!(*env2)->CallBooleanMethod(env2, g_activity, has_focus) && waited < max_wait) {
            struct timespec ts = {0, 50000000}; /* 50 ms */
            nanosleep(&ts, NULL);
            waited += 50;
        }
        /* Only detach if we attached above — detaching a Java thread aborts ART. */
        if (needs_detach)
            (*g_jvm)->DetachCurrentThread(g_jvm);
        if (waited >= max_wait)
            LOGI("mob_start_beam: focus timeout (%d ms) — starting BEAM anyway", waited);
        else if (waited)
            LOGI("mob_start_beam: waited %d ms for window focus", waited);
    }
    // ── end cold-start race condition fix ────────────────────────────────────

    mob_set_startup_phase("Starting BEAM…");
    LOGI("mob_start_beam: starting BEAM with module=%s, argc=%d", app_module, ac);

    // Symlink ERTS executables from BINDIR to the native lib dir.
    //
    // When installed via `adb install`, nativeLibraryDir contains the .so files
    // and the symlink approach works (apk_data_file SELinux label allows execve).
    //
    // When installed via Play Store (split APKs), Android does NOT extract .so
    // files to nativeLibraryDir on modern devices — they stay inside the split APK
    // zip. In that case MobBridge.extractBeamHelpersFromSplitApk() copies the
    // binaries directly into erts/bin/ before this point. We detect that scenario
    // by checking whether the nativeLibDir target exists: if it doesn't, skip the
    // unlink+symlink so we don't clobber the already-extracted real file.
    if (s_native_lib_dir[0]) {
        static const char *const exes[] = {"erl_child_setup", "inet_gethost", "epmd", NULL};
        static const char *const libs[] = {"liberl_child_setup.so", "libinet_gethost.so",
                                           "libepmd.so", NULL};
        char bin_path[512], lib_path[512];
        for (int i = 0; exes[i]; i++) {
            snprintf(bin_path, sizeof(bin_path), "%s/" ERTS_VSN "/bin/%s", otp_root, exes[i]);
            snprintf(lib_path, sizeof(lib_path), "%s/%s", s_native_lib_dir, libs[i]);
            struct stat lib_st;
            if (stat(lib_path, &lib_st) == 0) {
                // nativeLibDir has the file (adb install) — use symlink
                unlink(bin_path);
                if (symlink(lib_path, bin_path) == 0) {
                    LOGI("mob_start_beam: symlink %s -> %s", exes[i], lib_path);
                } else {
                    LOGE("mob_start_beam: symlink %s failed: %s", exes[i], strerror(errno));
                }
            } else {
                // nativeLibDir empty (Play Store split APK) — MobBridge should have
                // extracted the binary directly to bin_path; leave it in place.
                struct stat bin_st;
                if (stat(bin_path, &bin_st) == 0) {
                    LOGI("mob_start_beam: symlink %s (extracted from split APK)", exes[i]);
                } else {
                    LOGE("mob_start_beam: symlink %s missing from both nativeLibDir and bin/",
                         exes[i]);
                }
            }
        }
    }

    // Symlink sqlite3_nif.so into the exqlite OTP lib structure so that
    // code:priv_dir(:exqlite) resolves correctly.
    //
    // The OTP code server registers lib_dirs by scanning $OTP_ROOT/lib/*/ebin
    // at boot. For code:lib_dir(:exqlite) to work, exqlite must live at
    // $OTP_ROOT/lib/exqlite-VERSION/ — a flat -pa dir is NOT sufficient.
    // The deployer creates $OTP_ROOT/lib/exqlite-VERSION/{ebin,priv}; we
    // create the sqlite3_nif.so symlink inside priv/ at runtime so the path
    // (which contains the APK install hash) is always up-to-date.
    if (s_native_lib_dir[0]) {
        char nif_target[560];
        snprintf(nif_target, sizeof(nif_target), "%s/libsqlite3_nif.so", s_native_lib_dir);

        // Scan $OTP_ROOT/lib/ for exqlite-* and symlink the NIF in its priv/.
        char lib_path[600];
        snprintf(lib_path, sizeof(lib_path), "%s/lib", otp_root);
        DIR *d = opendir(lib_path);
        int found = 0;
        if (d) {
            struct dirent *entry;
            while ((entry = readdir(d)) != NULL) {
                if (strncmp(entry->d_name, "exqlite-", 8) == 0) {
                    char exqlite_priv[700];
                    snprintf(exqlite_priv, sizeof(exqlite_priv), "%s/%s/priv", lib_path,
                             entry->d_name);
                    mkdir(exqlite_priv, 0755);
                    char nif_link[760];
                    snprintf(nif_link, sizeof(nif_link), "%s/sqlite3_nif.so", exqlite_priv);
                    struct stat nif_lib_st;
                    if (stat(nif_target, &nif_lib_st) == 0) {
                        // nativeLibDir has the NIF (adb install) — use symlink
                        unlink(nif_link);
                        if (symlink(nif_target, nif_link) == 0) {
                            LOGI("mob_start_beam: symlink exqlite NIF -> %s", nif_target);
                            found = 1;
                        } else {
                            LOGE("mob_start_beam: symlink exqlite NIF failed: %s", strerror(errno));
                        }
                    } else {
                        // nativeLibDir empty — MobBridge extracted NIF directly to nif_link
                        struct stat nif_file_st;
                        if (stat(nif_link, &nif_file_st) == 0) {
                            LOGI("mob_start_beam: exqlite NIF extracted from split APK");
                            found = 1;
                        } else {
                            LOGE("mob_start_beam: exqlite NIF missing from both nativeLibDir and "
                                 "priv/");
                        }
                    }
                    break;
                }
            }
            closedir(d);
        }

        if (!found) {
            // Fallback: symlink into flat beams_dir/priv/ for backward compatibility
            // while the deployer hasn't yet created the versioned lib structure.
            char priv_dir[660];
            snprintf(priv_dir, sizeof(priv_dir), "%s/priv", beams_dir);
            mkdir(priv_dir, 0755);
            char nif_link[720];
            snprintf(nif_link, sizeof(nif_link), "%s/sqlite3_nif.so", priv_dir);
            struct stat nif_lib_fb_st;
            if (stat(nif_target, &nif_lib_fb_st) == 0) {
                unlink(nif_link);
                if (symlink(nif_target, nif_link) == 0) {
                    LOGI("mob_start_beam: symlink sqlite3_nif.so (fallback) -> %s", nif_target);
                } else {
                    LOGE("mob_start_beam: symlink sqlite3_nif (fallback) failed: %s",
                         strerror(errno));
                }
            } else {
                struct stat nif_fb_file_st;
                if (stat(nif_link, &nif_fb_file_st) == 0) {
                    LOGI("mob_start_beam: sqlite3_nif.so (fallback) extracted from split APK");
                } else {
                    LOGE("mob_start_beam: sqlite3_nif.so (fallback) missing — NIF load will fail");
                }
            }
        }
    }

    // Symlink libpythonx.so into the pythonx OTP lib structure for the
    // same reason as exqlite above. Pythonx's NIF on_load does
    //   path = :filename.join(:code.priv_dir(:pythonx), 'libpythonx')
    //   :erlang.load_nif(path, 0)
    // For dlopen to resolve enif_* (defined in the main app native lib)
    // the .so has to live in the app's namespace — i.e. nativeLibraryDir.
    // mob_dev's NativeBuild already places libpythonx.so in jniLibs, so
    // the APK installer extracts it to nativeLibraryDir at install time.
    // We just symlink into the OTP lib priv/ to make :code.priv_dir
    // return a path that dlopen can follow.
    if (s_native_lib_dir[0]) {
        char pyx_target[560];
        snprintf(pyx_target, sizeof(pyx_target), "%s/libpythonx.so", s_native_lib_dir);

        struct stat pyx_target_st;
        if (stat(pyx_target, &pyx_target_st) == 0) {
            char lib_path[600];
            snprintf(lib_path, sizeof(lib_path), "%s/lib", otp_root);
            DIR *d2 = opendir(lib_path);
            if (d2) {
                struct dirent *entry;
                while ((entry = readdir(d2)) != NULL) {
                    if (strncmp(entry->d_name, "pythonx-", 8) == 0) {
                        char pyx_priv[700];
                        snprintf(pyx_priv, sizeof(pyx_priv), "%s/%s/priv", lib_path, entry->d_name);
                        mkdir(pyx_priv, 0755);
                        char pyx_link[760];
                        snprintf(pyx_link, sizeof(pyx_link), "%s/libpythonx.so", pyx_priv);
                        unlink(pyx_link);
                        if (symlink(pyx_target, pyx_link) == 0) {
                            LOGI("mob_start_beam: symlink pythonx NIF -> %s", pyx_target);
                        } else {
                            LOGE("mob_start_beam: symlink pythonx NIF failed: %s", strerror(errno));
                        }
                        break;
                    }
                }
                closedir(d2);
            }
        }
    }

    void erl_start(int, char **);
    erl_start(ac, (char **)args);
    mob_set_startup_error("BEAM exited unexpectedly — see logcat (tag: MobBeam) for details");
    LOGE("mob_start_beam: erl_start returned (unexpected)");
}
