// mob_dist_port.h — choose the BEAM's distribution listen port on iOS (MOB-139).
//
// Header-only and free of Foundation/UIKit so the native harness
// (test/native/dist_port_test.c) compiles and runs this exact code on the host.
// Included by mob_beam.m only.
//
// Resolution:
//   1. MOB_DIST_PORT set to a valid port: pinned to it. `mix mob.deploy` and
//      `mix mob.connect` pass one (SIMCTL_CHILD_MOB_DIST_PORT on a simulator).
//      If something already listens there, `busy` is set and the caller reports
//      it instead of letting the BEAM halt on eaddrinuse.
//   2. Simulator, no usable MOB_DIST_PORT: derived from the app and the
//      simulator UDID exactly as mob_dev's MobDev.Tunnel.base_port/2 does
//      (9100 + crc32("<app>@<udid>") rem 800), then walked forward through the
//      same 800-port window to the first port that binds. Simulators share the
//      Mac's network stack, so a fixed default (it was 9101) collides as soon
//      as two mob simulator apps run outside mob_dev. Tools find the node
//      through the Mac's EPMD, so the exact port only has to be free.
//   3. Physical device, no usable MOB_DIST_PORT: pinned to 9101. The device
//      has its own network stack and its own in-process EPMD.
#ifndef MOB_DIST_PORT_H
#define MOB_DIST_PORT_H

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// Same window as mob_dev's MobDev.Tunnel (@base_dist_port, @port_span).
#define MOB_DIST_PORT_BASE 9100
#define MOB_DIST_PORT_SPAN 800
#define MOB_DIST_PORT_DEVICE_DEFAULT 9101

typedef enum {
    MOB_DIST_PORT_FROM_ENV,      // MOB_DIST_PORT
    MOB_DIST_PORT_FROM_APP_UDID, // derived on a simulator
    MOB_DIST_PORT_FROM_DEFAULT,  // physical device fallback
} mob_dist_port_source;

typedef struct {
    int port;     // the port to listen on (inet_dist_listen_min)
    int port_max; // inet_dist_listen_max: == port when pinned, the window end when derived
    int base;     // derived only: the app+UDID base port before any walk
    int busy;     // no free port: `port` is held by another listener
    mob_dist_port_source source;
} mob_dist_port_choice;

// zlib-compatible CRC-32, the same function as erlang:crc32/1.
static inline uint32_t mob_dist_crc32(const char *s) {
    uint32_t crc = 0xFFFFFFFFu;
    for (; *s; s++) {
        crc ^= (unsigned char)*s;
        for (int k = 0; k < 8; k++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

// MobDev.Tunnel.base_port/2: 9100 + crc32("<app>@<serial>") rem 800.
static inline int mob_dist_base_port(const char *app, const char *serial) {
    char key[512];
    snprintf(key, sizeof(key), "%s@%s", app ? app : "", serial ? serial : "");
    return MOB_DIST_PORT_BASE + (int)(mob_dist_crc32(key) % MOB_DIST_PORT_SPAN);
}

// A decimal port in 1..65535, or 0 for NULL, empty or anything else.
static inline int mob_dist_parse_port(const char *s) {
    if (!s || !*s)
        return 0;
    long v = 0;
    for (const char *p = s; *p; p++) {
        if (*p < '0' || *p > '9')
            return 0;
        v = v * 10 + (*p - '0');
        if (v > 65535)
            return 0;
    }
    return v >= 1 ? (int)v : 0;
}

// Can a dist listener bind `port` on `addr` (host order) right now? Uses the
// options inet_tcp_dist listens with (SO_REUSEADDR), so it fails exactly when
// the BEAM would fail with eaddrinuse. The probe socket is closed again.
static inline int mob_dist_port_free(int port, uint32_t addr) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0)
        return 1; // can't probe; let the BEAM try
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    sa.sin_addr.s_addr = htonl(addr);
    int ok = bind(s, (struct sockaddr *)&sa, sizeof(sa)) == 0 && listen(s, 1) == 0;
    close(s);
    return ok;
}

// `env_port`: MOB_DIST_PORT (may be NULL). `simulator`: derive when unset.
// `addr`: the address the BEAM will listen on (loopback on a simulator).
static inline mob_dist_port_choice mob_resolve_dist_port(const char *env_port, int simulator,
                                                         const char *app, const char *udid,
                                                         uint32_t addr) {
    mob_dist_port_choice c = {0, 0, 0, 0, MOB_DIST_PORT_FROM_DEFAULT};
    int pinned = mob_dist_parse_port(env_port);

    if (pinned || !simulator) {
        c.source = pinned ? MOB_DIST_PORT_FROM_ENV : MOB_DIST_PORT_FROM_DEFAULT;
        c.port = c.port_max = pinned ? pinned : MOB_DIST_PORT_DEVICE_DEFAULT;
        c.busy = !mob_dist_port_free(c.port, addr);
        return c;
    }

    // MobDev.Tunnel.assign_dist_port/3, with "in use" meaning "won't bind".
    c.source = MOB_DIST_PORT_FROM_APP_UDID;
    c.base = mob_dist_base_port(app, udid);
    int base_off = c.base - MOB_DIST_PORT_BASE;
    for (int off = 0; off < MOB_DIST_PORT_SPAN; off++) {
        int port = MOB_DIST_PORT_BASE + (base_off + off) % MOB_DIST_PORT_SPAN;
        if (mob_dist_port_free(port, addr)) {
            c.port = port;
            // The BEAM walks min..max itself, so a port taken between this
            // probe and its listen still finds the next free one.
            c.port_max = MOB_DIST_PORT_BASE + MOB_DIST_PORT_SPAN - 1;
            return c;
        }
    }
    c.port = c.port_max = c.base;
    c.busy = 1;
    return c;
}

#endif // MOB_DIST_PORT_H
