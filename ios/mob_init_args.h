// mob_init_args.h — the app's own Erlang init arguments on iOS (MOB-406).
//
// Header-only and free of Foundation/UIKit so the native harness
// (test/native/init_args_test.c) compiles and runs this exact code on the
// host. Included by mob_beam.m only.
//
// The app writes whitespace-separated tokens to `$MOB_DATA_DIR/mob_init_args`
// (`Mob.InitArgs.write/1`); mob_beam.m appends them after mob's own init
// arguments (after the second `--`) at the next launch, in dev and release
// builds. Unlike `beams_dir/mob_beam_flags`, which feeds the *emulator*
// section, these are what `-proto_dist` / `-ssl_dist_optfile` need: the
// emulator rejects init flags before the first `--`.
//
// android/jni/mob_init_args.zig is the same algorithm with the same limits;
// keep the two (and `Mob.InitArgs`'s validation) in step.
#ifndef MOB_INIT_ARGS_H
#define MOB_INIT_ARGS_H

#include <stdio.h>
#include <string.h>

#define MOB_INIT_ARGS_FILE "mob_init_args"
// The whole file must fit with room for the terminating NUL; Mob.InitArgs
// refuses to write more than MOB_INIT_ARGS_BUF - 1 bytes.
#define MOB_INIT_ARGS_BUF 1024
#define MOB_INIT_ARGS_MAX 63

typedef struct {
    char buf[MOB_INIT_ARGS_BUF];
    const char *argv[MOB_INIT_ARGS_MAX];
    int count;
    // Set when the file was longer than MOB_INIT_ARGS_BUF - 1 bytes or held
    // more than MOB_INIT_ARGS_MAX tokens. What was kept ends on a token
    // boundary.
    int truncated;
} mob_init_args;

// NUL separates too, so a stray one can't swallow the rest of the file.
static inline int mob_init_args_is_separator(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\0';
}

// Tokenises a->buf[0..n) in place. n == MOB_INIT_ARGS_BUF means the file
// filled the buffer, i.e. it may continue past it.
static inline void mob_init_args_parse(mob_init_args *a, size_t n) {
    size_t end = n;
    a->count = 0;
    a->truncated = 0;
    if (n >= MOB_INIT_ARGS_BUF) {
        a->truncated = 1;
        end = MOB_INIT_ARGS_BUF - 1;
        // A token running into the last byte may continue in the file: drop it
        // rather than pass half of it.
        if (!mob_init_args_is_separator(a->buf[end])) {
            while (end > 0 && !mob_init_args_is_separator(a->buf[end - 1]))
                end--;
        }
    }
    a->buf[end] = '\0';

    size_t p = 0;
    while (p < end) {
        while (p < end && mob_init_args_is_separator(a->buf[p]))
            p++;
        if (p >= end)
            break;
        if (a->count == MOB_INIT_ARGS_MAX) {
            a->truncated = 1;
            break;
        }
        a->argv[a->count++] = &a->buf[p];
        while (p < end && !mob_init_args_is_separator(a->buf[p]))
            p++;
        a->buf[p++] = '\0';
    }
}

// Loads `<dir>/mob_init_args` into `a`, writing the path it tried to `path`.
// Returns 1 when the file exists (even if it holds no tokens), 0 when it
// can't be opened; `a` then holds no arguments.
static inline int mob_init_args_load(mob_init_args *a, const char *dir, char *path,
                                     size_t path_len) {
    a->count = 0;
    a->truncated = 0;
    snprintf(path, path_len, "%s/%s", dir, MOB_INIT_ARGS_FILE);
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    size_t n = fread(a->buf, 1, sizeof(a->buf), f);
    fclose(f);
    mob_init_args_parse(a, n);
    return 1;
}

// Whether the app names the node itself. mob_beam.m then leaves out its own
// development distribution flags, so the BEAM never sees two -name flags.
static inline int mob_init_args_names_node(const mob_init_args *a) {
    for (int i = 0; i < a->count; i++) {
        if (strcmp(a->argv[i], "-name") == 0 || strcmp(a->argv[i], "-sname") == 0)
            return 1;
    }
    return 0;
}

// True only when mob should add its development distribution arguments.
// Release builds never add them; development builds yield to an app-owned
// -name/-sname.
static inline int mob_init_args_add_mob_dist(const mob_init_args *a, int release_build) {
    return !release_build && !mob_init_args_names_node(a);
}

// Appends app-owned arguments after the launcher's existing arguments and
// writes erl_start's trailing NULL. Returns the new argc, or -1 if capacity
// cannot hold every argument and the terminator.
static inline int mob_init_args_append(const mob_init_args *a, const char **out, int argc,
                                       int capacity) {
    if (argc < 0 || capacity - argc <= a->count)
        return -1;
    for (int i = 0; i < a->count; i++)
        out[argc++] = a->argv[i];
    out[argc] = NULL;
    return argc;
}

#endif
