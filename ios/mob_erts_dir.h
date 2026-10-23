// mob_erts_dir.h — which `erts-<vsn>` directory under the OTP root the BEAM
// boots from (BINDIR = <otp_root>/<erts>/bin), for builds that don't pass
// -DERTS_VSN (the simulator; the device build passes the tarball's version).
//
// The ERTS version follows the OTP runtime mob_dev ships (erts-17.0 for
// OTP 29.0, erts-17.1.1 for OTP 29.1.2), so mob can't hard-code it. When more
// than one erts-* is present, the highest version that has a bin/ wins (a
// half-copied newer runtime doesn't beat a complete older one). Same rule as
// android/jni/mob_erts_dir.zig plus mob_beam.zig's bin/ check; keep the two
// in step.
//
// Header-only and free of Foundation/UIKit so the native harness
// (test/native/erts_dir_test.c) compiles and runs this exact code on the host.
#ifndef MOB_ERTS_DIR_H
#define MOB_ERTS_DIR_H

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define MOB_ERTS_PREFIX "erts-"

// One dot-separated component of a version, as an integer: all digits, or 0
// (like Zig's parseInt-or-0). Advances *p past the component and its dot.
static inline unsigned long mob_erts_component(const char **p) {
    const char *s = *p;
    const char *end = s;
    while (*end && *end != '.')
        end++;
    unsigned long v = 0;
    int ok = end > s && end - s <= 9;
    for (const char *c = s; ok && c < end; c++) {
        if (*c < '0' || *c > '9')
            ok = 0;
        else
            v = v * 10 + (unsigned long)(*c - '0');
    }
    *p = *end == '.' ? end + 1 : end;
    return ok ? v : 0;
}

// > 0 when erts dir name `a` has a higher version than `b`, < 0 when lower,
// 0 when equal. Versions compare as dot-separated integers (erts-17.10 >
// erts-17.9, erts-17.1.1 > erts-17.1); a non-numeric component counts as 0.
static inline int mob_erts_cmp(const char *a, const char *b) {
    const char *pa = a + sizeof(MOB_ERTS_PREFIX) - 1;
    const char *pb = b + sizeof(MOB_ERTS_PREFIX) - 1;
    while (*pa || *pb) {
        unsigned long na = mob_erts_component(&pa);
        unsigned long nb = mob_erts_component(&pb);
        if (na != nb)
            return na > nb ? 1 : -1;
    }
    return 0;
}

// Writes the highest `erts-*` entry of `otp_root` that has a bin/ into `out`
// (NUL-terminated) and returns 1, or returns 0 when there is none or it
// doesn't fit.
static inline int mob_erts_dir(const char *otp_root, char *out, size_t out_len) {
    DIR *d = opendir(otp_root);
    if (!d)
        return 0;
    int found = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        size_t n = strlen(e->d_name);
        if (n <= sizeof(MOB_ERTS_PREFIX) - 1 || n >= out_len)
            continue;
        if (strncmp(e->d_name, MOB_ERTS_PREFIX, sizeof(MOB_ERTS_PREFIX) - 1) != 0)
            continue;
        if (found && mob_erts_cmp(e->d_name, out) <= 0)
            continue;
        char bin[1024];
        struct stat st;
        snprintf(bin, sizeof(bin), "%s/%s/bin", otp_root, e->d_name);
        if (stat(bin, &st) != 0 || !S_ISDIR(st.st_mode))
            continue;
        memcpy(out, e->d_name, n + 1);
        found = 1;
    }
    closedir(d);
    return found;
}

#endif
