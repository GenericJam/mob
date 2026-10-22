// Which erts-<vsn> directory the iOS simulator BEAM boots from (MOB-493).
//
//     make -C test/native run
//
// Compiles ios/mob_erts_dir.h itself — the code mob_beam.m runs when the
// build doesn't pass -DERTS_VSN — against a real directory tree standing in
// for the OTP runtime root. android/jni/mob_erts_dir.zig has the same rule and
// its own `zig test`.
#include "../../ios/mob_erts_dir.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures = 0;

#define CHECK(cond, ...)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                   \
            fprintf(stderr, __VA_ARGS__);                                                          \
            fprintf(stderr, "\n");                                                                 \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

static char root[256];

static void mk(const char *name) {
    char p[512];
    snprintf(p, sizeof(p), "%s/%s", root, name);
    mkdir(p, 0755);
}

int main(void) {
    CHECK(mob_erts_cmp("erts-17.1.1", "erts-17.0") > 0, "17.1.1 > 17.0");
    CHECK(mob_erts_cmp("erts-17.0", "erts-17.1.1") < 0, "17.0 < 17.1.1");
    CHECK(mob_erts_cmp("erts-17.10", "erts-17.9") > 0, "17.10 > 17.9");
    CHECK(mob_erts_cmp("erts-17.1.1", "erts-17.1") > 0, "17.1.1 > 17.1");
    CHECK(mob_erts_cmp("erts-17.1", "erts-17.1") == 0, "17.1 == 17.1");

    snprintf(root, sizeof(root), "/tmp/mob_erts_dir_test_%d", (int)getpid());
    mkdir(root, 0755);

    char out[64];
    CHECK(mob_erts_dir(root, out, sizeof(out)) == 0, "empty root has no erts dir");
    CHECK(mob_erts_dir("/nonexistent/otp", out, sizeof(out)) == 0, "missing root");

    mk("lib");
    mk("releases");
    mk("erts");
    mk("erts-17.0");
    CHECK(mob_erts_dir(root, out, sizeof(out)) == 1 && strcmp(out, "erts-17.0") == 0,
          "single erts dir, got %s", out);

    mk("erts-17.1.1");
    mk("erts-17.1");
    CHECK(mob_erts_dir(root, out, sizeof(out)) == 1 && strcmp(out, "erts-17.1.1") == 0,
          "highest of three, got %s", out);

    char tiny[8];
    CHECK(mob_erts_dir(root, tiny, sizeof(tiny)) == 0, "names that don't fit are skipped");

    char cmd[600];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", root);
    if (system(cmd) != 0)
        fprintf(stderr, "warning: could not remove %s\n", root);

    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("erts_dir_test: ok\n");
    return 0;
}
