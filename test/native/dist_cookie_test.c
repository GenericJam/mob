// iOS dist cookie resolution (MOB-348).
//
//     make -C test/native run
//
// Compiles ios/mob_dist_cookie.h itself — the code mob_beam.m runs — against
// real files in a temp directory. It does not cover mob_dev writing the file or
// mob_beam.m passing the result to -setcookie; those were verified on a
// simulator. See decisions/2026-10-01-ios-dist-cookie-file.md.
#include "../../ios/mob_dist_cookie.h"

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

static const char *MANAGED = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

static char dir[256];

static void write_cookie_file(const char *content) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", dir, MOB_DIST_COOKIE_FILE);
    FILE *f = fopen(path, "w");
    fputs(content, f);
    fclose(f);
}

static void remove_cookie_file(void) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", dir, MOB_DIST_COOKIE_FILE);
    unlink(path);
}

static int is_hex64(const char *s) {
    if (strlen(s) != MOB_DIST_COOKIE_HEX_LEN)
        return 0;
    for (; *s; s++)
        if (!((*s >= '0' && *s <= '9') || (*s >= 'a' && *s <= 'f')))
            return 0;
    return 1;
}

// The MOB-348 failure: a launch without MOB_DIST_COOKIE must still use the
// project cookie mob_dev deployed, or no tool can reach the node.
static void test_file_used_without_env(void) {
    char out[256];
    write_cookie_file("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n");
    mob_dist_cookie_source src = mob_resolve_dist_cookie(NULL, dir, out, sizeof(out));
    CHECK(src == MOB_DIST_COOKIE_FROM_FILE, "expected file, got source %d", src);
    CHECK(strcmp(out, MANAGED) == 0, "file cookie, got %s", out);

    src = mob_resolve_dist_cookie("", dir, out, sizeof(out));
    CHECK(src == MOB_DIST_COOKIE_FROM_FILE && strcmp(out, MANAGED) == 0, "empty env ignored");
    remove_cookie_file();
}

static void test_env_wins(void) {
    char out[256];
    write_cookie_file(MANAGED);
    mob_dist_cookie_source src = mob_resolve_dist_cookie("from_env", dir, out, sizeof(out));
    CHECK(src == MOB_DIST_COOKIE_FROM_ENV && strcmp(out, "from_env") == 0,
          "env must win over the file, got %d %s", src, out);
    remove_cookie_file();
}

static void expect_rejected(const char *content, const char *why) {
    char out[256];
    write_cookie_file(content);
    mob_dist_cookie_source src = mob_resolve_dist_cookie(NULL, dir, out, sizeof(out));
    CHECK(src == MOB_DIST_COOKIE_RANDOM, "%s: expected random, got %d", why, src);
    CHECK(strcmp(out, MANAGED) != 0, "%s: must not use the file", why);
    remove_cookie_file();
}

static void test_invalid_file_falls_back_to_random(void) {
    expect_rejected("", "empty");
    expect_rejected("mob_secret\n", "legacy public cookie");
    expect_rejected("0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef",
                    "uppercase");
    expect_rejected("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde", "63 chars");
    expect_rejected("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0",
                    "65 chars");
    expect_rejected("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nx",
                    "trailer");
}

static void test_random_without_env_or_file(void) {
    char a[256], b[256];
    CHECK(mob_resolve_dist_cookie(NULL, dir, a, sizeof(a)) == MOB_DIST_COOKIE_RANDOM, "random");
    CHECK(mob_resolve_dist_cookie(NULL, NULL, b, sizeof(b)) == MOB_DIST_COOKIE_RANDOM, "NULL dir");
    CHECK(is_hex64(a) && is_hex64(b), "random cookies are 64 hex chars");
    CHECK(strcmp(a, b) != 0, "random cookie changes per launch");
}

int main(void) {
    snprintf(dir, sizeof(dir), "/tmp/mob_dist_cookie_test.XXXXXX");
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    test_file_used_without_env();
    test_env_wins();
    test_invalid_file_falls_back_to_random();
    test_random_without_env_or_file();
    rmdir(dir);
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("dist_cookie_test: ok\n");
    return 0;
}
