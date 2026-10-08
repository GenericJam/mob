// iOS app init arguments (MOB-406).
//
//     make -C test/native run
//
// Compiles ios/mob_init_args.h itself — the code mob_beam.m uses — against real
// files in a temp directory, including the launcher's development/release
// distribution policy and final argv placement.
#include "../../ios/mob_init_args.h"

#include <stdlib.h>
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

static char dir[256];
static char path[512];
static mob_init_args args;

static void write_file(const char *content, size_t len) {
    snprintf(path, sizeof(path), "%s/%s", dir, MOB_INIT_ARGS_FILE);
    FILE *f = fopen(path, "w");
    fwrite(content, 1, len, f);
    fclose(f);
}

static int load(void) {
    return mob_init_args_load(&args, dir, path, sizeof(path));
}

static void test_absent_file(void) {
    unlink(path);
    CHECK(load() == 0, "absent file reported as present");
    CHECK(args.count == 0, "absent file gave %d args", args.count);
}

static void test_tokens(void) {
    const char *s = "  -proto_dist inet_tls\t-ssl_dist_optfile /x/ssl.conf\r\n";
    write_file(s, strlen(s));
    CHECK(load() == 1, "present file reported absent");
    CHECK(args.count == 4, "expected 4 args, got %d", args.count);
    CHECK(args.count == 4 && strcmp(args.argv[0], "-proto_dist") == 0 &&
              strcmp(args.argv[1], "inet_tls") == 0 &&
              strcmp(args.argv[2], "-ssl_dist_optfile") == 0 &&
              strcmp(args.argv[3], "/x/ssl.conf") == 0,
          "wrong tokens");
    CHECK(!args.truncated, "short file marked truncated");
    CHECK(!mob_init_args_names_node(&args), "no -name, but names_node");
}

static void test_names_node(void) {
    const char *a = "-proto_dist inet_tls -name op@10.0.0.2";
    write_file(a, strlen(a));
    load();
    CHECK(mob_init_args_names_node(&args), "-name not detected");
    const char *b = "-sname op";
    write_file(b, strlen(b));
    load();
    CHECK(mob_init_args_names_node(&args), "-sname not detected");
    const char *c = "-names -snamex x-name";
    write_file(c, strlen(c));
    load();
    CHECK(!mob_init_args_names_node(&args), "prefix/suffix matched as -name");
}

static void test_exact_fit(void) {
    char buf[MOB_INIT_ARGS_BUF - 1];
    memset(buf, 'x', sizeof(buf));
    write_file(buf, sizeof(buf));
    load();
    CHECK(!args.truncated, "a file of BUF-1 bytes marked truncated");
    CHECK(args.count == 1 && strlen(args.argv[0]) == sizeof(buf), "BUF-1 token not kept whole");
}

static void test_cut_token_dropped(void) {
    char buf[MOB_INIT_ARGS_BUF + 50];
    memset(buf, 'y', sizeof(buf));
    memcpy(buf, "-a b ", 5);
    write_file(buf, sizeof(buf));
    load();
    CHECK(args.truncated, "over-long file not marked truncated");
    CHECK(args.count == 2 && strcmp(args.argv[0], "-a") == 0 && strcmp(args.argv[1], "b") == 0,
          "token cut at the buffer edge was kept (count %d)", args.count);
}

static void test_cut_on_separator(void) {
    char buf[MOB_INIT_ARGS_BUF + 10];
    memset(buf, 'z', sizeof(buf));
    buf[MOB_INIT_ARGS_BUF - 1] = ' ';
    write_file(buf, sizeof(buf));
    load();
    CHECK(args.truncated, "over-long file not marked truncated");
    CHECK(args.count == 1 && strlen(args.argv[0]) == MOB_INIT_ARGS_BUF - 1,
          "complete token before the edge was dropped");
}

static void test_count_cap(void) {
    char buf[2 * (MOB_INIT_ARGS_MAX + 5)];
    for (size_t i = 0; i < sizeof(buf); i += 2)
        memcpy(buf + i, "a ", 2);
    write_file(buf, sizeof(buf));
    load();
    CHECK(args.truncated, "too many tokens not marked truncated");
    CHECK(args.count == MOB_INIT_ARGS_MAX, "expected %d args, got %d", MOB_INIT_ARGS_MAX,
          args.count);

    write_file(buf, 2 * MOB_INIT_ARGS_MAX);
    load();
    CHECK(!args.truncated, "exactly MAX tokens marked truncated");
    CHECK(args.count == MOB_INIT_ARGS_MAX, "expected %d args, got %d", MOB_INIT_ARGS_MAX,
          args.count);
}

static void test_embedded_nul(void) {
    write_file("-a\0-b c", 7);
    load();
    CHECK(args.count == 3, "NUL ended the list (count %d)", args.count);
}

static void test_launcher_policy_and_append(void) {
    write_file("-proto_dist operator", strlen("-proto_dist operator"));
    load();
    CHECK(mob_init_args_add_mob_dist(&args, 0), "transport-only args suppressed dev dist");
    CHECK(!mob_init_args_add_mob_dist(&args, 1), "release build enabled mob dev dist");

    const char *argv[6] = {"beam", "--", NULL, NULL, NULL, NULL};
    int argc = mob_init_args_append(&args, argv, 2, 6);
    CHECK(argc == 4, "expected argc 4, got %d", argc);
    CHECK(strcmp(argv[0], "beam") == 0 && strcmp(argv[1], "--") == 0,
          "launcher-owned argv changed");
    CHECK(strcmp(argv[2], "-proto_dist") == 0 && strcmp(argv[3], "operator") == 0,
          "app args were not appended after launcher args");
    CHECK(argv[4] == NULL, "argv lacks trailing NULL");
    CHECK(mob_init_args_append(&args, argv, 4, 6) == -1, "undersized argv was accepted");

    write_file("-name app@10.0.0.2", strlen("-name app@10.0.0.2"));
    load();
    CHECK(!mob_init_args_add_mob_dist(&args, 0), "app-owned -name did not suppress dev dist");
    CHECK(!mob_init_args_add_mob_dist(&args, 1), "release build enabled mob dev dist");
}

int main(void) {
    snprintf(dir, sizeof(dir), "/tmp/mob_init_args_test.XXXXXX");
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    snprintf(path, sizeof(path), "%s/%s", dir, MOB_INIT_ARGS_FILE);
    test_absent_file();
    test_tokens();
    test_names_node();
    test_exact_fit();
    test_cut_token_dropped();
    test_cut_on_separator();
    test_count_cap();
    test_embedded_nul();
    test_launcher_policy_and_append();
    unlink(path);
    rmdir(dir);
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("init_args_test: ok\n");
    return 0;
}
