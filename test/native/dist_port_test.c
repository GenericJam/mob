// iOS dist port resolution (MOB-139).
//
//     make -C test/native run
//
// Compiles ios/mob_dist_port.h itself — the code mob_beam.m runs — and drives
// it against real sockets on this host's loopback, which is the network stack a
// simulator app shares. It does not cover mob_beam.m's handling of the result
// (the log line, the startup error screen, not calling erl_start); that needs a
// simulator. See decisions/2026-10-01-ios-sim-dist-port-per-app.md.
#include "../../ios/mob_dist_port.h"

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

#define LOOPBACK INADDR_LOOPBACK

// Listen on 127.0.0.1:port the way another app's BEAM would. Returns the fd,
// or -1 if the port was already taken by someone else (still held, then).
static int hold(int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    sa.sin_addr.s_addr = htonl(LOOPBACK);
    if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) != 0 || listen(s, 8) != 0) {
        close(s);
        return -1;
    }
    return s;
}

// An ephemeral loopback port we hold until `*fd` is closed.
static int hold_any(int *fd) {
    *fd = hold(0);
    struct sockaddr_in sa;
    socklen_t len = sizeof(sa);
    getsockname(*fd, (struct sockaddr *)&sa, &len);
    return ntohs(sa.sin_port);
}

static void test_crc32_matches_erlang(void) {
    // erlang:crc32("123456789")
    CHECK(mob_dist_crc32("123456789") == 0xCBF43926u, "crc32 check value");
}

static void test_base_port_matches_mob_dev(void) {
    // 9100 + erlang:crc32(Key) rem 800 — MobDev.Tunnel.base_port/2.
    CHECK(mob_dist_base_port("mob_plugin_demo", "A9AE3D62-0000-4000-8000-000000000001") == 9472,
          "mob_plugin_demo base");
    CHECK(mob_dist_base_port("notif_probe", "90E55910-1111-2222-3333-444455556666") == 9750,
          "notif_probe base");
    CHECK(mob_dist_base_port("muster_style_dev", NULL) == 9873, "NULL udid is empty");
}

static void test_parse_port(void) {
    CHECK(mob_dist_parse_port("9101") == 9101, "plain port");
    CHECK(mob_dist_parse_port("65535") == 65535, "max port");
    CHECK(mob_dist_parse_port(NULL) == 0, "NULL");
    CHECK(mob_dist_parse_port("") == 0, "empty");
    CHECK(mob_dist_parse_port("0") == 0, "zero");
    CHECK(mob_dist_parse_port("65536") == 0, "too big");
    CHECK(mob_dist_parse_port("9101x") == 0, "trailing junk");
    CHECK(mob_dist_parse_port("-1") == 0, "negative");
}

// The MOB-139 failure: with nothing in MOB_DIST_PORT, a simulator app must not
// land on a port another app already listens on.
static void test_simulator_skips_a_held_port(void) {
    const char *app = "mob_plugin_demo", *udid = "A9AE3D62-0000-4000-8000-000000000001";
    int base = mob_dist_base_port(app, udid);
    int fd = hold(base);
    CHECK(!mob_dist_port_free(base, LOOPBACK), "base %d should be held", base);

    mob_dist_port_choice c = mob_resolve_dist_port(NULL, 1, app, udid, LOOPBACK);
    CHECK(c.source == MOB_DIST_PORT_FROM_APP_UDID, "derived, got source %d", c.source);
    CHECK(!c.busy, "a free port exists in the window");
    CHECK(c.base == base, "base %d, got %d", base, c.base);
    CHECK(c.port != base, "must not reuse held base %d", base);
    CHECK(c.port >= MOB_DIST_PORT_BASE && c.port < MOB_DIST_PORT_BASE + MOB_DIST_PORT_SPAN,
          "port %d outside window", c.port);
    CHECK(mob_dist_port_free(c.port, LOOPBACK), "chosen %d must bind", c.port);
    CHECK(c.port_max == MOB_DIST_PORT_BASE + MOB_DIST_PORT_SPAN - 1, "BEAM walks to window end");

    // An unparseable MOB_DIST_PORT is ignored the same way.
    mob_dist_port_choice junk = mob_resolve_dist_port("abc", 1, app, udid, LOOPBACK);
    CHECK(junk.source == MOB_DIST_PORT_FROM_APP_UDID && junk.port != base, "junk env ignored");
    if (fd >= 0)
        close(fd);
}

// Held from the base to the window end: the walk wraps to the window start.
static void test_simulator_walk_wraps(void) {
    const char *app = "muster_style_dev";
    int base = mob_dist_base_port(app, ""); // 9873
    int last = MOB_DIST_PORT_BASE + MOB_DIST_PORT_SPAN - 1;
    int fds[MOB_DIST_PORT_SPAN];
    int n = 0;
    for (int p = base; p <= last; p++)
        fds[n++] = hold(p);

    mob_dist_port_choice c = mob_resolve_dist_port(NULL, 1, app, "", LOOPBACK);
    CHECK(!c.busy && c.port >= MOB_DIST_PORT_BASE && c.port < base,
          "expected a wrapped port below %d, got %d (busy %d)", base, c.port, c.busy);
    for (int i = 0; i < n; i++)
        if (fds[i] >= 0)
            close(fds[i]);
}

// An explicit MOB_DIST_PORT is pinned: never moved, and reported when taken.
static void test_pinned_port_reports_busy(void) {
    int fd;
    int port = hold_any(&fd);
    char env[16];
    snprintf(env, sizeof(env), "%d", port);

    mob_dist_port_choice c = mob_resolve_dist_port(env, 1, "app", "UDID", LOOPBACK);
    CHECK(c.source == MOB_DIST_PORT_FROM_ENV, "env source");
    CHECK(c.port == port && c.port_max == port, "pinned to %d, got %d..%d", port, c.port,
          c.port_max);
    CHECK(c.busy, "held pinned port %d must be reported busy", port);

    close(fd);
    c = mob_resolve_dist_port(env, 1, "app", "UDID", LOOPBACK);
    CHECK(c.port == port && !c.busy, "free pinned port %d not busy", port);
}

static void test_physical_device_default(void) {
    mob_dist_port_choice c = mob_resolve_dist_port(NULL, 0, "app", NULL, LOOPBACK);
    CHECK(c.source == MOB_DIST_PORT_FROM_DEFAULT, "device default source");
    CHECK(c.port == MOB_DIST_PORT_DEVICE_DEFAULT && c.port_max == MOB_DIST_PORT_DEVICE_DEFAULT,
          "device pinned to 9101, got %d", c.port);
}

int main(void) {
    test_crc32_matches_erlang();
    test_base_port_matches_mob_dev();
    test_parse_port();
    test_simulator_skips_a_held_port();
    test_simulator_walk_wraps();
    test_pinned_port_reports_busy();
    test_physical_device_default();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("dist_port_test: ok\n");
    return 0;
}
