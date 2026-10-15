// mob_code_versions.h — which directory a physical iPhone loads the app's
// BEAMs from, and removal of the ones it no longer needs (MOB-408).
//
// Header-only and free of Foundation/UIKit so the native harness
// (test/native/code_versions_test.c) compiles and runs this exact code on the
// host. Included by mob_beam.m only. mob_dev looks for this file in the app's
// mob dependency to tell whether the app's runtime reads the layout below, so
// keep its name.
//
// The signed bundle is read-only, so `mix mob.deploy` uploads the app's BEAMs
// (with priv/, mob_dist_cookie and mob_beam_flags) into the app's Documents
// with `xcrun devicectl device copy to`. Under Documents/otp:
//
//   <app>.versions/<N>/               one deploy. N is decimal; mob_dev writes
//                                     it zero-padded to 10 digits.
//   <app>.versions/<N>/.mob_complete  copied on its own once the upload has
//                                     succeeded and been verified.
//   <app>/                            the legacy override (one directory,
//                                     overwritten in place).
//
// Each deploy uses an N above every existing entry and never touches it
// again. The marker is the commit: a copy that dies part-way leaves an N
// without it, which is never loaded, so the previous version keeps booting.
// (Replacing one directory in place took devicectl's
// --remove-existing-content, which empties the app's whole data container,
// Documents and Library included: MOB-408.)
//
// The choice, in order:
//   1. the highest N that has the marker;
//   2. <app>/, written by mob_dev < 0.7.28, or by a later mob_dev before this
//      runtime first booted (mob_dev uses <app>.versions/ only once it exists;
//      mob_code_advertise creates it);
//   3. the BEAMs in the signed bundle.
//
// Clean-up, when 1 was chosen: every N below it, marked or not, and <app>/.
// A higher N without the marker is kept, since it may be a deploy in
// progress; it goes once a later deploy completes and boots.
#ifndef MOB_CODE_VERSIONS_H
#define MOB_CODE_VERSIONS_H

#include <dirent.h>
#include <errno.h>
#include <ftw.h>
#include <limits.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#define MOB_CODE_VERSIONS_SUFFIX ".versions"
#define MOB_CODE_COMPLETE_MARKER ".mob_complete"
// 18 digits always fit an unsigned long long.
#define MOB_CODE_VERSION_MAX_DIGITS 18

typedef enum {
    MOB_CODE_FROM_VERSION,
    MOB_CODE_FROM_LEGACY,
    MOB_CODE_FROM_BUNDLE,
} mob_code_source;

// 1 when `name` is 1..18 ASCII digits, with its value in *out; 0 otherwise.
static inline int mob_code_parse_version(const char *name, unsigned long long *out) {
    unsigned long long v = 0;
    size_t n = 0;
    for (; name[n]; n++) {
        if (n == MOB_CODE_VERSION_MAX_DIGITS || name[n] < '0' || name[n] > '9')
            return 0;
        v = v * 10 + (unsigned long long)(name[n] - '0');
    }
    if (n == 0)
        return 0;
    *out = v;
    return 1;
}

// "<dir>/<name>" into `out`. 0 when it doesn't fit: a truncated path names
// something else, so callers treat it as absent.
static inline int mob_code_join(char *out, size_t out_size, const char *dir, const char *name) {
    int n = snprintf(out, out_size, "%s/%s", dir, name);
    return n > 0 && (size_t)n < out_size;
}

static inline int mob_code_is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

// Documents/otp/<app>.versions into `out`. 0 when it doesn't fit.
static inline int mob_code_versions_dir(const char *docs_dir, const char *app, char *out,
                                        size_t out_size) {
    int n = snprintf(out, out_size, "%s/otp/%s%s", docs_dir, app, MOB_CODE_VERSIONS_SUFFIX);
    return n > 0 && (size_t)n < out_size;
}

// Documents/otp/<app> (the legacy override) into `out`. 0 when it doesn't fit.
static inline int mob_code_legacy_dir(const char *docs_dir, const char *app, char *out,
                                      size_t out_size) {
    int n = snprintf(out, out_size, "%s/otp/%s", docs_dir, app);
    return n > 0 && (size_t)n < out_size;
}

// Whether <versions_dir>/<name> has the marker that commits it.
static inline int mob_code_is_complete(const char *versions_dir, const char *name) {
    char dir[PATH_MAX], marker[PATH_MAX];
    struct stat st;
    return mob_code_join(dir, sizeof(dir), versions_dir, name) &&
           mob_code_join(marker, sizeof(marker), dir, MOB_CODE_COMPLETE_MARKER) &&
           stat(marker, &st) == 0 && S_ISREG(st.st_mode);
}

// The highest N under `versions_dir` that has the marker: its value in *out
// and its directory name, as spelled on disk, in `name` (at least
// MOB_CODE_VERSION_MAX_DIGITS + 1 bytes). Returns 1 when there is one.
static inline int mob_code_latest_complete(const char *versions_dir, unsigned long long *out,
                                           char *name) {
    DIR *d = opendir(versions_dir);
    if (!d)
        return 0;
    int found = 0;
    unsigned long long best = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        unsigned long long v;
        if (!mob_code_parse_version(e->d_name, &v) || (found && v <= best) ||
            !mob_code_is_complete(versions_dir, e->d_name))
            continue;
        best = v;
        found = 1;
        snprintf(name, MOB_CODE_VERSION_MAX_DIGITS + 1, "%s", e->d_name);
    }
    closedir(d);
    if (found)
        *out = best;
    return found;
}

// The directory to load the app's BEAMs from (see the top of this file), in
// `out`. `bundle_dir` is the signed bundle's copy, the last resort. For
// MOB_CODE_FROM_VERSION, *version is the N chosen.
static inline mob_code_source mob_code_choose(const char *docs_dir, const char *app,
                                              const char *bundle_dir, char *out, size_t out_size,
                                              unsigned long long *version) {
    char dir[PATH_MAX];
    char name[MOB_CODE_VERSION_MAX_DIGITS + 1];
    unsigned long long v;
    if (mob_code_versions_dir(docs_dir, app, dir, sizeof(dir)) &&
        mob_code_latest_complete(dir, &v, name) && mob_code_join(out, out_size, dir, name)) {
        *version = v;
        return MOB_CODE_FROM_VERSION;
    }
    if (mob_code_legacy_dir(docs_dir, app, out, out_size) && mob_code_is_dir(out))
        return MOB_CODE_FROM_LEGACY;
    snprintf(out, out_size, "%s", bundle_dir);
    return MOB_CODE_FROM_BUNDLE;
}

// Creates Documents/otp/<app>.versions, which tells mob_dev this runtime reads
// that layout. Returns 1 when the directory exists afterwards.
static inline int mob_code_advertise(const char *docs_dir, const char *app) {
    char path[PATH_MAX];
    if (!mob_code_join(path, sizeof(path), docs_dir, "otp") ||
        (mkdir(path, 0755) != 0 && errno != EEXIST) ||
        !mob_code_versions_dir(docs_dir, app, path, sizeof(path)) ||
        (mkdir(path, 0755) != 0 && errno != EEXIST))
        return 0;
    return mob_code_is_dir(path);
}

static inline int mob_code_remove_entry(const char *path, const struct stat *st, int type,
                                        struct FTW *ftw) {
    (void)st;
    (void)type;
    (void)ftw;
    // Keep going past a failure: the rest is still garbage.
    remove(path);
    return 0;
}

// Deletes `path` and everything under it, without following symlinks.
// Returns 1 when nothing is left at `path`.
static inline int mob_code_remove_tree(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0)
        return errno == ENOENT;
    if (S_ISDIR(st.st_mode))
        nftw(path, mob_code_remove_entry, 16, FTW_DEPTH | FTW_PHYS);
    else
        remove(path);
    return lstat(path, &st) != 0 && errno == ENOENT;
}

// After choosing version `keep`: deletes every N below it (its marker first,
// so a half-deleted directory is never chosen) and the legacy <app>/. Returns
// how many of those it removed.
static inline int mob_code_collect_garbage(const char *docs_dir, const char *app,
                                           unsigned long long keep) {
    int removed = 0;
    char versions[PATH_MAX], path[PATH_MAX], marker[PATH_MAX];
    DIR *d =
        mob_code_versions_dir(docs_dir, app, versions, sizeof(versions)) ? opendir(versions) : NULL;
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            unsigned long long v;
            if (!mob_code_parse_version(e->d_name, &v) || v >= keep ||
                !mob_code_join(path, sizeof(path), versions, e->d_name))
                continue;
            if (mob_code_join(marker, sizeof(marker), path, MOB_CODE_COMPLETE_MARKER))
                unlink(marker);
            removed += mob_code_remove_tree(path);
        }
        closedir(d);
    }
    if (mob_code_legacy_dir(docs_dir, app, path, sizeof(path)) && mob_code_is_dir(path))
        removed += mob_code_remove_tree(path);
    return removed;
}

#endif // MOB_CODE_VERSIONS_H
