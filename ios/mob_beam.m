// mob_beam.m — Mob BEAM launcher for iOS.
// Extracted from the per-app beam_main.m stub so app code stays minimal.
// mob_set_startup_phase/error are implemented in mob_nif.m (which imports the
// Swift-generated header) so this file stays free of app-specific includes.

#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "mob_beam.h"

#define OTP_ROOT   "/tmp/otp-ios-sim"
#define ERTS_VSN   "erts-16.3"
#define ELIXIR_DIR OTP_ROOT "/lib/elixir/ebin"
#define LOGGER_DIR OTP_ROOT "/lib/logger/ebin"

void mob_init_ui(void) {
    // SwiftUI: the UI is driven by MobViewModel (Swift ObservableObject).
    // No UIViewController reference needed here; the hosting controller is
    // created by MobUIFactory in AppDelegate.m.
    NSLog(@"[MobBeam] mob_init_ui: SwiftUI mode ready");
}

void mob_start_beam(const char* app_module) {
    mob_set_startup_phase("Setting up BEAM environment…");
    setenv("BINDIR",   OTP_ROOT "/" ERTS_VSN "/bin", 1);
    setenv("ROOTDIR",  OTP_ROOT, 1);
    setenv("PROGNAME", "erl", 1);
    setenv("EMU",      "beam", 1);
    setenv("HOME",     "/tmp", 1);
    setenv("ERL_CRASH_DUMP", "/tmp/mob_erl_crash.dump", 1);
    setenv("ERL_CRASH_DUMP_SECONDS", "30", 1);

    // Read dist port from MOB_DIST_PORT env var (set by mob_dev via xcrun simctl launch --setenv).
    // Defaults to 9100 if not set (standalone launch without mob_dev).
    const char *env_port = getenv("MOB_DIST_PORT");
    static char dist_port_min[16], dist_port_max[16];
    snprintf(dist_port_min, sizeof(dist_port_min), "%s", env_port ? env_port : "9101");
    snprintf(dist_port_max, sizeof(dist_port_max), "%s", env_port ? env_port : "9101");

    // Build dynamic strings from app_module.
    char eval_expr[280];
    snprintf(eval_expr, sizeof(eval_expr), "%s:start().", app_module);

    char node_name[128];
    snprintf(node_name, sizeof(node_name), "%s_ios@127.0.0.1", app_module);

    char beams_dir[256];
    snprintf(beams_dir, sizeof(beams_dir), OTP_ROOT "/%s", app_module);

    const char* args[] = {
        "beam",
        "-S", "1:1", "-SDcpu", "1:1", "-SDio", "1", "-A", "1", "-sbwt", "none",
        // elixir-desktop added "-MIscs", "10" to cap the BEAM's memory super carrier at 10MB
        // after seeing "erts_mmap: Failed to create super carrier of size 1024 MB" on 9th gen iPads.
        // The default is 1GB virtual reservation which iOS silently rejects. Their fix is correct in
        // effect but may be masking wrong flags elsewhere — enable this if we see the same error.
        // "-MIscs", "10",
        "--",
        "-root",     OTP_ROOT,
        "-bindir",   OTP_ROOT "/" ERTS_VSN "/bin",
        "-progname", "erl",
        "--",
        "-name",     node_name,
        "-setcookie", "mob_secret",
        "-kernel", "inet_dist_listen_min", dist_port_min,
        "-kernel", "inet_dist_listen_max", dist_port_max,
        "-noshell", "-noinput",
        "-boot",   OTP_ROOT "/releases/29/start_clean",
        "-pa",     ELIXIR_DIR,
        "-pa",     LOGGER_DIR,
        "-pa",     beams_dir,
        "-eval",   eval_expr,
        NULL
    };
    int ac = 0;
    while (args[ac]) ac++;
    NSLog(@"[MobBeam] mob_start_beam: starting BEAM module=%s argc=%d", app_module, ac);
    mob_set_startup_phase("Starting BEAM…");

    void erl_start(int, char**);
    erl_start(ac, (char**)args);
    mob_set_startup_error("BEAM exited unexpectedly — check /tmp/mob_erl_crash.dump");
    NSLog(@"[MobBeam] mob_start_beam: erl_start returned (unexpected)");
}
