// Which directory a physical iPhone loads the app's BEAMs from (MOB-408).
//
//     make -C test/native run
//
// Compiles ios/mob_code_versions.h itself — the code mob_beam.m runs — against
// a real directory tree standing in for the app's Documents. It does not cover
// mob_dev uploading the versions or mob_beam.m passing the choice to -pa; those
// were verified on an iPhone. See decisions/2026-10-15-ios-versioned-code-dirs.md.
#include "../../ios/mob_code_versions.h"

#include <stdlib.h>
#include <string.h>

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

#define APP "demo"
#define BUNDLE "/bundle/otp/demo"

static char docs[256];

static void path_of(char *out, size_t size, const char *rel) {
    snprintf(out, size, "%s/%s", docs, rel);
}

static void make_dir(const char *rel) {
    char path[512], partial[512];
    path_of(path, sizeof(path), rel);
    for (char *p = path + strlen(docs) + 1; *p; p++) {
        if (*p == '/') {
            snprintf(partial, sizeof(partial), "%.*s", (int)(p - path), path);
            mkdir(partial, 0755);
        }
    }
    mkdir(path, 0755);
}

static void write_file(const char *rel, const char *content) {
    char path[512];
    path_of(path, sizeof(path), rel);
    FILE *f = fopen(path, "w");
    if (!f) {
        perror(path);
        exit(1);
    }
    fputs(content, f);
    fclose(f);
}

static int exists(const char *rel) {
    char path[512];
    struct stat st;
    path_of(path, sizeof(path), rel);
    return lstat(path, &st) == 0;
}

// A version directory as mob_dev leaves it: BEAMs, then (if the upload
// finished) the marker.
static void deploy(const char *n, int complete) {
    char rel[256];
    snprintf(rel, sizeof(rel), "otp/" APP ".versions/%s", n);
    make_dir(rel);
    snprintf(rel, sizeof(rel), "otp/" APP ".versions/%s/" APP ".beam", n);
    write_file(rel, n);
    if (complete) {
        snprintf(rel, sizeof(rel), "otp/" APP ".versions/%s/" MOB_CODE_COMPLETE_MARKER, n);
        write_file(rel, n);
    }
}

static mob_code_source choose(char *out, size_t size, unsigned long long *version) {
    *version = 0;
    return mob_code_choose(docs, APP, BUNDLE, out, size, version);
}

static void reset_docs(void) {
    mob_code_remove_tree(docs);
    mkdir(docs, 0755);
}

static void test_parse_version(void) {
    unsigned long long v = 99;
    CHECK(mob_code_parse_version("0000000007", &v) && v == 7, "zero-padded");
    CHECK(mob_code_parse_version("123456789012345678", &v) && v == 123456789012345678ULL,
          "18 digits");
    CHECK(!mob_code_parse_version("1234567890123456789", &v), "19 digits overflow");
    CHECK(!mob_code_parse_version("", &v), "empty");
    CHECK(!mob_code_parse_version("12a", &v), "letters");
    CHECK(!mob_code_parse_version("-1", &v), "sign");
    CHECK(!mob_code_parse_version(".", &v) && !mob_code_parse_version("..", &v), "dot entries");
}

static void test_bundle_then_legacy(void) {
    char out[512], want[512];
    unsigned long long v;
    reset_docs();
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_BUNDLE && strcmp(out, BUNDLE) == 0,
          "nothing deployed: the bundle, got %s", out);

    // What mob_dev < 0.7.28 writes, and what a newer one writes before this
    // runtime has booted once.
    make_dir("otp/" APP);
    write_file("otp/" APP "/" APP ".beam", "legacy");
    path_of(want, sizeof(want), "otp/" APP);
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_LEGACY && strcmp(out, want) == 0,
          "legacy override wins over the bundle, got %s", out);
}

// The MOB-408 crash-safety claim: an upload that dies before its marker is
// never loaded, so the previous version keeps booting.
static void test_highest_complete_version_wins(void) {
    char out[512], want[512];
    unsigned long long v;
    reset_docs();
    make_dir("otp/" APP);
    write_file("otp/" APP "/" APP ".beam", "legacy");

    make_dir("otp/" APP ".versions");
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_LEGACY, "an empty versions dir: legacy");

    deploy("0000000001", 0);
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_LEGACY,
          "an interrupted first upload is not loaded");

    deploy("0000000002", 1);
    path_of(want, sizeof(want), "otp/" APP ".versions/0000000002");
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_VERSION && v == 2 && strcmp(out, want) == 0,
          "a complete version wins over legacy, got %llu %s", v, out);

    deploy("0000000003", 0);
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_VERSION && v == 2,
          "an interrupted later upload keeps the previous version, got %llu", v);

    deploy("0000000010", 1);
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_VERSION && v == 10,
          "numeric, not lexical, order, got %llu", v);

    // A marker that is a directory is not a commit; junk names are ignored.
    make_dir("otp/" APP ".versions/0000000011/" MOB_CODE_COMPLETE_MARKER);
    make_dir("otp/" APP ".versions/0000000099x");
    write_file("otp/" APP ".versions/0000000099x/" MOB_CODE_COMPLETE_MARKER, "x");
    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_VERSION && v == 10,
          "directory marker and non-numeric names ignored, got %llu", v);
}

static void test_advertise(void) {
    reset_docs();
    CHECK(mob_code_advertise(docs, APP), "creates otp/ and the versions dir");
    CHECK(exists("otp/" APP ".versions"), "versions dir exists");
    CHECK(mob_code_advertise(docs, APP), "idempotent");
    write_file("otp/" APP ".versions/keep.txt", "k");
    CHECK(mob_code_advertise(docs, APP) && exists("otp/" APP ".versions/keep.txt"),
          "doesn't disturb what's there");
}

// Clean-up removes only code mob owns, below the chosen version.
static void test_collect_garbage(void) {
    char out[512];
    unsigned long long v;
    reset_docs();
    write_file("app.db", "user data");
    make_dir("cluster");
    write_file("cluster/cluster.json", "{}");
    make_dir("otp/" APP);
    write_file("otp/" APP "/" APP ".beam", "legacy");
    write_file("otp/sibling.txt", "s");
    deploy("0000000001", 1);
    deploy("0000000002", 0);
    deploy("0000000003", 1);
    deploy("0000000004", 0); // an upload in progress
    make_dir("otp/" APP ".versions/notes");

    // A symlink in an old version must be removed, not followed.
    make_dir("outside");
    write_file("outside/precious.txt", "p");
    char link[512], target[512];
    path_of(link, sizeof(link), "otp/" APP ".versions/0000000001/link");
    path_of(target, sizeof(target), "outside");
    CHECK(symlink(target, link) == 0, "symlink");

    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_VERSION && v == 3, "chose 3, got %llu", v);
    int removed = mob_code_collect_garbage(docs, APP, v);
    CHECK(removed == 3, "removed 1, 2 and legacy, got %d", removed);
    CHECK(!exists("otp/" APP ".versions/0000000001"), "older complete version removed");
    CHECK(!exists("otp/" APP ".versions/0000000002"), "older interrupted upload removed");
    CHECK(!exists("otp/" APP), "legacy override removed");
    CHECK(exists("otp/" APP ".versions/0000000003/" APP ".beam"), "chosen version kept");
    CHECK(exists("otp/" APP ".versions/0000000004/" APP ".beam"), "later upload kept");
    CHECK(exists("otp/" APP ".versions/notes"), "unknown entries kept");
    CHECK(exists("app.db") && exists("cluster/cluster.json") && exists("otp/sibling.txt"),
          "app data untouched");
    CHECK(exists("outside/precious.txt"), "symlink target untouched");

    CHECK(choose(out, sizeof(out), &v) == MOB_CODE_FROM_VERSION && v == 3,
          "still 3 after clean-up, got %llu", v);
    CHECK(mob_code_collect_garbage(docs, APP, v) == 0, "nothing more to remove");
}

int main(void) {
    snprintf(docs, sizeof(docs), "/tmp/mob_code_versions_test.XXXXXX");
    if (!mkdtemp(docs)) {
        perror("mkdtemp");
        return 1;
    }
    test_parse_version();
    test_bundle_then_legacy();
    test_highest_complete_version_wins();
    test_advertise();
    test_collect_garbage();
    mob_code_remove_tree(docs);
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("code_versions_test: ok\n");
    return 0;
}
