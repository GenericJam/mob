// mob_dist_cookie.h — choose the BEAM's distribution cookie on iOS (MOB-348).
//
// Header-only and free of Foundation/UIKit so the native harness
// (test/native/dist_cookie_test.c) compiles and runs this exact code on the
// host. Included by mob_beam.m only.
//
// Resolution, mirroring Android's Mob.Dist:
//   1. MOB_DIST_COOKIE in the launch environment (1..255 bytes). mob_dev passes
//      it when it launches the app (SIMCTL_CHILD_ / DEVICECTL_CHILD_ prefix).
//      The public pre-MOB-49 cookie `mob_secret` is ignored, as Android's
//      Mob.Dist ignores it.
//   2. `<beams_dir>/mob_dist_cookie`, the project's private cookie that
//      `mix mob.deploy` writes next to the BEAMs: the simulator runtime dir on
//      the Mac, or Documents/otp/<app> on a physical iPhone. Only mob_dev's
//      format is accepted: 64 lowercase hex characters, optionally followed by
//      whitespace. This is what keeps a node reachable after a launch mob_dev
//      didn't make (icon tap, `xcrun simctl launch`, agent-device relaunch).
//   3. A random 256-bit cookie, new on every launch and never logged. No
//      shared public cookie is ever used (MOB-49).
#ifndef MOB_DIST_COOKIE_H
#define MOB_DIST_COOKIE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MOB_DIST_COOKIE_FILE "mob_dist_cookie"
#define MOB_DIST_COOKIE_HEX_LEN 64
#define MOB_DIST_COOKIE_LEGACY "mob_secret"

typedef enum {
    MOB_DIST_COOKIE_FROM_ENV,
    MOB_DIST_COOKIE_FROM_FILE,
    MOB_DIST_COOKIE_RANDOM,
} mob_dist_cookie_source;

// Reads mob_dev's cookie file into `out` (at least 65 bytes). Returns 1 when
// the file holds exactly one valid cookie, 0 otherwise (`out` is then empty).
static inline int mob_dist_cookie_read_file(const char *path, char *out) {
    out[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    char buf[128];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);
    if (n < MOB_DIST_COOKIE_HEX_LEN || n == sizeof(buf))
        return 0;
    for (size_t i = 0; i < MOB_DIST_COOKIE_HEX_LEN; i++) {
        char c = buf[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return 0;
    }
    for (size_t i = MOB_DIST_COOKIE_HEX_LEN; i < n; i++) {
        char c = buf[i];
        if (c != '\n' && c != '\r' && c != ' ' && c != '\t')
            return 0;
    }
    memcpy(out, buf, MOB_DIST_COOKIE_HEX_LEN);
    out[MOB_DIST_COOKIE_HEX_LEN] = '\0';
    return 1;
}

// Fills `out` (`out_len` >= 65) with the cookie to start the node with and
// returns where it came from. `env_cookie` is MOB_DIST_COOKIE (may be NULL);
// `beams_dir` is where the app's BEAMs load from (may be NULL).
static inline mob_dist_cookie_source
mob_resolve_dist_cookie(const char *env_cookie, const char *beams_dir, char *out, size_t out_len) {
    if (env_cookie && strcmp(env_cookie, MOB_DIST_COOKIE_LEGACY) != 0) {
        size_t len = strlen(env_cookie);
        if (len > 0 && len < out_len && len <= 255) {
            memcpy(out, env_cookie, len + 1);
            return MOB_DIST_COOKIE_FROM_ENV;
        }
    }

    if (beams_dir && beams_dir[0]) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", beams_dir, MOB_DIST_COOKIE_FILE);
        if (mob_dist_cookie_read_file(path, out))
            return MOB_DIST_COOKIE_FROM_FILE;
    }

    static const char hex[] = "0123456789abcdef";
    unsigned char random_bytes[MOB_DIST_COOKIE_HEX_LEN / 2];
    arc4random_buf(random_bytes, sizeof(random_bytes));
    for (size_t i = 0; i < sizeof(random_bytes); i++) {
        out[i * 2] = hex[random_bytes[i] >> 4];
        out[i * 2 + 1] = hex[random_bytes[i] & 0x0f];
    }
    out[MOB_DIST_COOKIE_HEX_LEN] = '\0';
    return MOB_DIST_COOKIE_RANDOM;
}

#endif // MOB_DIST_COOKIE_H
