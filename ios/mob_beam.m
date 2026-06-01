// mob_beam.m — Mob BEAM launcher for iOS.
// Extracted from the per-app beam_main.m stub so app code stays minimal.
// mob_set_startup_phase/error are implemented in mob_nif.m (which imports the
// Swift-generated header) so this file stays free of app-specific includes.

#include "mob_beam.h"
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// EPMD compiled into the binary (epmd.c / epmd_srv.c / epmd_cli.c compiled
// with -Dmain=epmd_ios_main). Only present in device builds; the simulator
// connects to the Mac's EPMD via the shared network stack.
//
// MOB_RELEASE: App Store builds (mix mob.release) drop EPMD entirely so the
// shipped binary has no distribution surface — Apple is unhappy with apps
// that listen on arbitrary network ports for remote-code-execution-shaped
// traffic, and TestFlight review may flag it. The BEAM still boots, the NIF
// still works, but the app is networkless from a distribution POV.
#if defined(MOB_BUNDLE_OTP) && !defined(MOB_RELEASE)
extern int epmd_ios_main(int argc, char **argv);
static void *epmd_thread(void *arg) {
    char *args[] = {"epmd", NULL};
    epmd_ios_main(1, args); // runs the EPMD event loop (does not return)
    return NULL;
}
#endif

// Compile-time defaults (simulator). Override via -D flags for device builds.
//
// On simulator the OTP runtime is not bundled in the .app — it's written to a
// directory on the Mac filesystem that the simulator app can read. The legacy
// path was hardcoded to /tmp/otp-ios-sim; mob_new ≥ 0.1.20 instead resolves
// the runtime dir from the MOB_SIM_RUNTIME_DIR env var (passed by mix mob.deploy
// via simctl's SIMCTL_CHILD_* mechanism) and defaults to ~/.mob/runtime/ios-sim.
//
// resolve_sim_otp_root() below handles both paths so old and new projects work
// against the same compiled mob_beam.m.
#ifndef OTP_ROOT_LEGACY
#define OTP_ROOT_LEGACY "/tmp/otp-ios-sim"
#endif
#ifndef ERTS_VSN
#define ERTS_VSN "erts-17.0"
#endif
#ifndef OTP_RELEASE
#define OTP_RELEASE "29"
#endif

// Resolve the simulator's OTP runtime root at startup.
//
// Resolution order:
//   1. MOB_SIM_RUNTIME_DIR env var if set (passed via SIMCTL_CHILD_*)
//   2. ~/.mob/runtime/ios-sim if that path contains <app_module>/ — the new
//      canonical location written by `mix mob.cache` and `mix mob.deploy`
//   3. /tmp/otp-ios-sim — legacy fallback for projects whose ios/build.sh
//      predates MOB_SIM_RUNTIME_DIR support (pre-mob_new 0.1.20)
//
// app_module is required for #2 so we don't pick a runtime that has no
// matching <app>.app inside (which is what causes the silent "BEAM exits
// 135ms after Starting BEAM" symptom — see common_fixes.md).
//
// Without #2, launches outside `mix mob.deploy` (Springboard tap, Xcode Run,
// `xcrun simctl launch`, MCP launch_app) inherit no env vars and resolve to
// /tmp/otp-ios-sim regardless of where the runtime actually lives. ERTS then
// fails to start the named app and aborts to stderr — which iOS sim doesn't
// route to os_log, so the failure is invisible.
static const char *resolve_sim_otp_root(const char *app_module) {
    const char *env = getenv("MOB_SIM_RUNTIME_DIR");
    if (env && env[0])
        return env;

    // iOS sim apps inherit HOME pointing to the per-app sandbox container
    // (…/CoreSimulator/Devices/<udid>/data/Containers/Data/Application/<uuid>),
    // not the Mac user's home. The simulator runtime exposes the host's home
    // via SIMULATOR_HOST_HOME — that's the path that contains
    // ~/.mob/runtime/ios-sim. Fall back to HOME so this still works when the
    // binary runs outside simctl (e.g. raw test harness on the Mac).
    const char *home = getenv("SIMULATOR_HOST_HOME");
    if (!home || !home[0])
        home = getenv("HOME");
    if (home && app_module && app_module[0]) {
        static char new_default[1024];
        snprintf(new_default, sizeof(new_default), "%s/.mob/runtime/ios-sim", home);

        char check[1280];
        snprintf(check, sizeof(check), "%s/%s", new_default, app_module);
        struct stat st;
        if (stat(check, &st) == 0 && S_ISDIR(st.st_mode)) {
            return new_default;
        }
    }

    return OTP_ROOT_LEGACY;
}

void mob_init_ui(void) {
    // SwiftUI: the UI is driven by MobViewModel (Swift ObservableObject).
    // No UIViewController reference needed here; the hosting controller is
    // created by MobUIFactory in AppDelegate.m.
    NSLog(@"[MobBeam] mob_init_ui: SwiftUI mode ready");
}

static void mob_write_diag(const char *docs_dir, const char *name, const char *info) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", docs_dir, name);
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "%s\n", info);
        fclose(f);
    }
}

// Find the device's own USB link-local (169.254.x.x) IP by walking ifaddrs.
// On simulator there is no such interface; returns NULL so callers fall back to 127.0.0.1.
static const char *find_link_local_ip(char *buf, size_t len) {
    struct ifaddrs *ifa_list;
    if (getifaddrs(&ifa_list) != 0)
        return NULL;
    const char *found = NULL;
    for (struct ifaddrs *ifa = ifa_list; ifa && !found; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
        uint32_t addr = ntohl(sa->sin_addr.s_addr);
        if ((addr >> 16) == 0xA9FE) { // 169.254.0.0/16
            inet_ntop(AF_INET, &sa->sin_addr, buf, (socklen_t)len);
            found = buf;
        }
    }
    freeifaddrs(ifa_list);
    return found;
}

// Find a routable LAN IP (10.x.x.x, 172.16-31.x.x, 192.168.x.x) for WiFi distribution
// when no USB link-local interface is present. Returns NULL if none found.
static const char *find_lan_ip(char *buf, size_t len) {
    struct ifaddrs *ifa_list;
    if (getifaddrs(&ifa_list) != 0)
        return NULL;
    const char *found = NULL;
    for (struct ifaddrs *ifa = ifa_list; ifa && !found; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
        uint32_t addr = ntohl(sa->sin_addr.s_addr);
        uint32_t top8 = addr >> 24;
        uint32_t top16 = addr >> 16;
        if (top8 == 10 ||                           // 10.0.0.0/8
            (top16 >= 0xAC10 && top16 <= 0xAC1F) || // 172.16.0.0/12
            top16 == 0xC0A8 ||                      // 192.168.0.0/16
            (top16 >= 0x6440 && top16 <= 0x647F)) { // 100.64.0.0/10 (Tailscale)
            inet_ntop(AF_INET, &sa->sin_addr, buf, (socklen_t)len);
            found = buf;
        }
    }
    freeifaddrs(ifa_list);
    return found;
}

void mob_start_beam(const char *app_module) {
    mob_set_startup_phase("Setting up BEAM environment…");

    // Resolve Documents dir early for diagnostics.
    NSArray *dp = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs_ns = [dp firstObject];
    const char *docs_dir = docs_ns ? [docs_ns UTF8String] : "/tmp";
    mob_write_diag(docs_dir, "mob_diag_a_entered.txt", "mob_start_beam entered");

    // On physical device the OTP runtime is bundled inside the .app — resolve
    // the path at runtime so it works regardless of where iOS installs the app.
    // On simulator the runtime lives on the Mac filesystem; resolve_sim_otp_root()
    // reads MOB_SIM_RUNTIME_DIR (set by mix mob.deploy via simctl) with a /tmp
    // fallback for legacy projects.
#ifdef MOB_BUNDLE_OTP
    NSString *bundle_otp =
        [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"otp"];
    const char *otp_root = [bundle_otp UTF8String];
    const char *erts_vsn = ERTS_VSN;
    const char *otp_release = OTP_RELEASE;
#else
    const char *otp_root = resolve_sim_otp_root(app_module);
    const char *erts_vsn = ERTS_VSN;
    const char *otp_release = OTP_RELEASE;
#endif

    mob_write_diag(docs_dir, "mob_diag_b_otp_root.txt", otp_root);

    // Compose dynamic paths that depend on otp_root.
    static char bindir[512], elixir_dir[512], logger_dir[512], boot_path[512];
    snprintf(bindir, sizeof(bindir), "%s/%s/bin", otp_root, erts_vsn);
    snprintf(elixir_dir, sizeof(elixir_dir), "%s/lib/elixir/ebin", otp_root);
    snprintf(logger_dir, sizeof(logger_dir), "%s/lib/logger/ebin", otp_root);
    snprintf(boot_path, sizeof(boot_path), "%s/releases/%s/start_clean", otp_root, otp_release);

    mob_write_diag(docs_dir, "mob_diag_c_paths.txt", bindir);
    NSLog(@"[MobBeam] otp_root=%s erts=%s release=%s", otp_root, erts_vsn, otp_release);

    setenv("BINDIR", bindir, 1);
    setenv("ROOTDIR", otp_root, 1);
    setenv("PROGNAME", "erl", 1);
    setenv("EMU", "beam", 1);
    setenv("HOME", "/tmp", 1);
    // Set MOB_DATA_DIR to the app's Documents directory — persistent storage
    // accessible to the app and backed up by iCloud. Used by the generated Repo
    // module to determine where to place the SQLite database file.
    // Falls back to /tmp when the documents path is unavailable (e.g. on simulator
    // when the sandbox isn't fully resolved at BEAM launch time).
    setenv("MOB_DATA_DIR", docs_dir, 1);

    // Write crash dump to app's Documents so it survives the crash and can be retrieved.
    static char crash_dump[512];
    snprintf(crash_dump, sizeof(crash_dump), "%s/mob_erl_crash.dump", docs_dir);
    setenv("ERL_CRASH_DUMP", crash_dump, 1);
    setenv("ERL_CRASH_DUMP_SECONDS", "30", 1);

    // Dist port: read from MOB_DIST_PORT env var (simulator via SIMCTL_CHILD_ prefix),
    // default to 9101 for standalone/physical launch.
    const char *env_port = getenv("MOB_DIST_PORT");
    static char dist_port_min[16], dist_port_max[16];
    snprintf(dist_port_min, sizeof(dist_port_min), "%s", env_port ? env_port : "9101");
    snprintf(dist_port_max, sizeof(dist_port_max), "%s", env_port ? env_port : "9101");

    // Determine node hostname:
    //   MOB_BUNDLE_OTP = physical device build (OTP bundled in .app).
    //   Priority: WiFi/LAN (10/172/192.168/Tailscale) > USB link-local (169.254.x.x) > 127.0.0.1
    //
    //   WiFi is preferred over USB because the node name is fixed at startup.
    //   If USB were preferred, unplugging the cable would strand the node at a
    //   link-local address that is no longer reachable — requiring an app restart
    //   to regain connectivity. With WiFi first, the node stays reachable on the
    //   same IP whether the cable is plugged in or not.
    //   USB link-local is the fallback for cable-only setups (no WiFi).
    //   127.0.0.1 is last resort; dist only reachable via iproxy in that case.
    //   The in-process EPMD and dist port both bind 0.0.0.0, so the node is
    //   reachable via any interface regardless of which IP was chosen as the name.
    //
    //   Without MOB_BUNDLE_OTP = simulator build. Simulator shares the Mac's network
    //   stack, including Mac's USB link-local interfaces, so find_link_local_ip()
    //   would return the Mac's USB IP (wrong). Always use 127.0.0.1 on simulator.
#ifdef MOB_BUNDLE_OTP
    // Physical device: WiFi/LAN → USB link-local → loopback fallback.
    // Two physical devices on different LAN IPs already get distinct node
    // names via the @host_ip part. MOB_NODE_SUFFIX is honored here too,
    // for scripted scenarios where multiple builds of the same app run on
    // distinct devices behind one IP (rare, but the override is harmless
    // when unused).
    static char lan_ip_buf[64], link_local_buf[64];
    const char *lan_ip = find_lan_ip(lan_ip_buf, sizeof(lan_ip_buf));
    const char *ll_ip = lan_ip ? NULL : find_link_local_ip(link_local_buf, sizeof(link_local_buf));
    const char *host_ip = lan_ip ? lan_ip : (ll_ip ? ll_ip : "127.0.0.1");
    static char eval_expr[280], node_name[128], beams_dir[512];
    snprintf(eval_expr, sizeof(eval_expr), "%s:start().", app_module);
    const char *phys_suffix = getenv("MOB_NODE_SUFFIX");
    if (phys_suffix && phys_suffix[0]) {
        snprintf(node_name, sizeof(node_name), "%s_ios_%s@%s", app_module, phys_suffix, host_ip);
    } else {
        snprintf(node_name, sizeof(node_name), "%s_ios@%s", app_module, host_ip);
    }
#else
    // Simulator: use 127.0.0.1 but include a short suffix so concurrent
    // simulators get unique node names and don't conflict in Mac's EPMD.
    //
    // Node-suffix resolution order (mirrors Android's Mob.Dist behaviour):
    //   1. MOB_NODE_SUFFIX env var — explicit override, e.g. set by
    //      `mix mob.deploy --node-suffix foo` (forwarded to simctl via
    //      SIMCTL_CHILD_MOB_NODE_SUFFIX). Use this when the auto-derived
    //      UDID suffix isn't what you want (running two distinct apps in
    //      one sim, scripting a specific naming scheme, etc.).
    //   2. SIMULATOR_UDID-derived hex (first 8 hex chars). Set
    //      automatically by the iOS simulator runtime; gives every sim a
    //      unique suffix out of the box so concurrent sims don't collide.
    //   3. No suffix — bare `<app>_ios@127.0.0.1`. Only hit when neither
    //      env var is set.
    const char *host_ip = "127.0.0.1";
    const char *node_suffix_override = getenv("MOB_NODE_SUFFIX");
    const char *sim_udid = getenv("SIMULATOR_UDID");
    static char sim_short[64];
    sim_short[0] = '\0';
    if (node_suffix_override && node_suffix_override[0]) {
        strncpy(sim_short, node_suffix_override, sizeof(sim_short) - 1);
        sim_short[sizeof(sim_short) - 1] = '\0';
    } else if (sim_udid) {
        int n = 0;
        for (int i = 0; sim_udid[i] && n < 8; i++) {
            unsigned char c = (unsigned char)sim_udid[i];
            if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f')) {
                sim_short[n++] = (char)tolower(c);
            }
        }
        sim_short[n] = '\0';
    }
    static char eval_expr[280], node_name[128], beams_dir[512];
    snprintf(eval_expr, sizeof(eval_expr), "%s:start().", app_module);
    if (sim_short[0]) {
        snprintf(node_name, sizeof(node_name), "%s_ios_%s@%s", app_module, sim_short, host_ip);
    } else {
        snprintf(node_name, sizeof(node_name), "%s_ios@%s", app_module, host_ip);
    }
#endif
    mob_write_diag(docs_dir, "mob_diag_host_ip.txt", host_ip);
    snprintf(beams_dir, sizeof(beams_dir), "%s/%s", otp_root, app_module);

#ifdef MOB_BUNDLE_OTP
    // On physical device, the bundle BEAMs are read-only (code-signed).
    // deployer.ex can push updated BEAMs to Documents/otp/<app>/ via
    // `xcrun devicectl device copy to --domain-type appDataContainer`.
    // If that directory exists, prefer it over the in-bundle copy.
    static char docs_beams[512];
    snprintf(docs_beams, sizeof(docs_beams), "%s/otp/%s", docs_dir, app_module);
    if ([[NSFileManager defaultManager] fileExistsAtPath:@(docs_beams)]) {
        strlcpy(beams_dir, docs_beams, sizeof(beams_dir));
    }
    mob_write_diag(docs_dir, "mob_diag_beams_dir.txt", beams_dir);
#endif

    // MOB_BEAMS_DIR — the directory where app BEAMs (and priv/) are deployed.
    //
    // Ecto.Migrator uses :code.priv_dir(app) to locate migration .exs files, but
    // that requires an OTP lib structure ($OTP_ROOT/lib/APP-VERSION/ebin/). Mob
    // apps use a flat -pa directory, so :code.priv_dir/1 returns {error, bad_name}
    // and Ecto silently reports "Migrations already up" without running anything.
    //
    // Fix: deployer.ex copies priv/ into beams_dir/priv/. App code reads this
    // env var and passes the explicit path to Ecto.Migrator.run/4. See also the
    // corresponding comment in mob_beam.c for the Android side.
    setenv("MOB_BEAMS_DIR", beams_dir, 1);

    // Compile-time default BEAM tuning flags.
    // Overridden at runtime if beams_dir/mob_beam_flags exists
    // (written by `mix mob.deploy --schedulers N` or `--beam-flags "..."`).
    //
    // `-MIscs 128` sets the literal super-carrier to 128 MB. On iOS the runtime
    // can't reserve the OTP default 1 GB literal area (ERTS_LITERAL_VIRTUAL_AREA_SIZE)
    // and falls back to ~10 MB. A large app — e.g. an embedded Livebook — plus a
    // notebook's Mix.install fills that and the VM aborts with
    // "literal_alloc: Cannot allocate N bytes (of type \"literal\")". 128 MB is a
    // virtual (MAP_NORESERVE) reservation, so it costs ~nothing until used and iOS
    // accepts it where 1 GB fails. iOS-only: Android keeps the normal large
    // carrier (don't shrink it here).
    static const char *s_default_flags[] = {"-S", "1:1",   "-SDcpu", "1:1",    "-SDio", "1", "-A",
                                            "1",  "-sbwt", "none",   "-MIscs", "128",   NULL};

    // Runtime override: read whitespace-separated flags from beams_dir/mob_beam_flags.
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
            NSLog(@"[MobBeam] loaded %d runtime flags from %s", s_runtime_flag_count, flags_path);
        }
    }

    const char **selected_flags = (s_runtime_flag_count > 0) ? s_runtime_flags : s_default_flags;

    static const char *args[128];
    int ac = 0;
    args[ac++] = "beam";
    for (int i = 0; selected_flags[i]; i++)
        args[ac++] = selected_flags[i];
    // NOTE: the literal super-carrier size is set via -MIscs in selected_flags
    // above (128 MB default; see s_default_flags). iOS rejects the OTP default
    // 1 GB reservation but accepts 128 MB. (A hardcoded "-MIscs 10" used to be
    // appended HERE and silently overrode the 128 above — allocator flags are
    // last-wins — capping the literal area at 10 MB, which crashed Mix.install of
    // any sizable dep once an embedded Livebook had filled it.)
    args[ac++] = "--";
    args[ac++] = "-root";
    args[ac++] = otp_root;
    args[ac++] = "-bindir";
    args[ac++] = bindir;
    args[ac++] = "-progname";
    args[ac++] = "erl";
    args[ac++] = "--";
#ifndef MOB_RELEASE
    // Distribution flags. Omitted for App Store builds — see MOB_RELEASE
    // notes at the top of this file.
    args[ac++] = "-name";
    args[ac++] = node_name;
    args[ac++] = "-setcookie";
    args[ac++] = "mob_secret";
    args[ac++] = "-kernel";
    args[ac++] = "inet_dist_listen_min";
    args[ac++] = dist_port_min;
    args[ac++] = "-kernel";
    args[ac++] = "inet_dist_listen_max";
    args[ac++] = dist_port_max;
#else
    // Mark MOB_RELEASE in env so Mob.Dist.ensure_started/1 short-circuits
    // before trying Node.start (which would fail without -name anyway, but
    // the env var lets app code probe for release mode without parsing
    // erl args).
    setenv("MOB_RELEASE", "1", 1);
    (void)dist_port_min;
    (void)dist_port_max;
    (void)node_name;
#endif
    args[ac++] = "-noshell";
    args[ac++] = "-noinput";
    args[ac++] = "-boot";
    args[ac++] = boot_path;
    args[ac++] = "-pa";
    args[ac++] = elixir_dir;
    args[ac++] = "-pa";
    args[ac++] = logger_dir;
    args[ac++] = "-pa";
    args[ac++] = beams_dir;
    args[ac++] = "-eval";
    args[ac++] = eval_expr;
    args[ac] = NULL;
    NSLog(@"[MobBeam] mob_start_beam: starting BEAM module=%s argc=%d", app_module, ac);
    mob_set_startup_phase("Starting BEAM…");
    mob_write_diag(docs_dir, "mob_diag_d_erl_start.txt", "calling erl_start");

    // Redirect stdout/stderr to a log file so BEAM error output is captured.
    char beam_log_path[512];
    snprintf(beam_log_path, sizeof(beam_log_path), "%s/beam_stdout.log", docs_dir);
    int log_fd = open(beam_log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log_fd >= 0) {
        dup2(log_fd, STDOUT_FILENO);
        dup2(log_fd, STDERR_FILENO);
        close(log_fd);
    }

#if defined(MOB_BUNDLE_OTP) && !defined(MOB_RELEASE)
    // Start EPMD as a thread so the BEAM can register for distribution.
    // On simulator the Mac's EPMD is reachable via the shared network stack;
    // on device there is no host EPMD, so we run our own in-process.
    // App Store builds (MOB_RELEASE) drop EPMD entirely.
    pthread_t epmd_t;
    pthread_create(&epmd_t, NULL, epmd_thread, NULL);
    pthread_detach(epmd_t);
    usleep(300000); // 300ms — give EPMD time to bind port 4369
#endif

    void erl_start(int, char **);
    erl_start(ac, (char **)args);
    mob_write_diag(docs_dir, "mob_diag_e_erl_exited.txt", "erl_start returned");
    mob_set_startup_error("BEAM exited unexpectedly — check Documents/mob_erl_crash.dump");
    NSLog(@"[MobBeam] mob_start_beam: erl_start returned (unexpected)");
}
