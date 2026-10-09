// mob_node_host.h — choose the host part of a physical iPhone's node name
// (`<app>_ios@<host>`, MOB-428).
//
// Header-only and free of Foundation/UIKit so the native harness
// (test/native/node_host_test.c) compiles and runs this exact code on the host.
// Included by mob_beam.m only.
//
// Resolution:
//   1. MOB_NODE_HOST set to one of this device's own IPv4 addresses: that
//      address. mob_dev passes the address the Mac reaches the phone at when
//      it relaunches the app for `mix mob.connect` (DEVICECTL_CHILD_MOB_NODE_HOST).
//      Over USB that is the link-local address: a phone whose WiFi is on a
//      network the Mac can't route to is otherwise named after an address the
//      Mac can never dial, and the node is unreachable although its EPMD
//      answers over the cable. Anything that is not one of the device's own
//      addresses is ignored: a node named after someone else's IP is
//      unreachable by construction.
//   2. Otherwise WiFi/LAN (10/8, 172.16/12, 192.168/16, 100.64/10 Tailscale),
//      then USB link-local (169.254/16), then 127.0.0.1. WiFi comes first so a
//      node started with the cable in stays reachable when it is pulled.
//
// The in-process EPMD and the dist port bind 0.0.0.0, so the node listens on
// every interface whichever name it takes.
#ifndef MOB_NODE_HOST_H
#define MOB_NODE_HOST_H

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>

typedef enum {
    MOB_NODE_HOST_FROM_ENV,        // MOB_NODE_HOST, one of the device's addresses
    MOB_NODE_HOST_FROM_LAN,        // WiFi / LAN / Tailscale
    MOB_NODE_HOST_FROM_LINK_LOCAL, // USB link-local
    MOB_NODE_HOST_FROM_LOOPBACK,   // nothing else
} mob_node_host_source;

static inline int mob_node_host_is_lan(uint32_t addr) {
    uint32_t top8 = addr >> 24;
    uint32_t top16 = addr >> 16;
    return top8 == 10 ||                           // 10.0.0.0/8
           (top16 >= 0xAC10 && top16 <= 0xAC1F) || // 172.16.0.0/12
           top16 == 0xC0A8 ||                      // 192.168.0.0/16
           (top16 >= 0x6440 && top16 <= 0x647F);   // 100.64.0.0/10 (Tailscale)
}

static inline int mob_node_host_is_link_local(uint32_t addr) {
    return (addr >> 16) == 0xA9FE; // 169.254.0.0/16
}

// The first IPv4 address in `list` (a getifaddrs() result) matching `pred`,
// written to `buf`; 1 when found.
static inline int mob_node_host_find(const struct ifaddrs *list, int (*pred)(uint32_t), char *buf,
                                     size_t len) {
    for (const struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        const struct sockaddr_in *sa = (const struct sockaddr_in *)ifa->ifa_addr;
        if (pred(ntohl(sa->sin_addr.s_addr))) {
            return inet_ntop(AF_INET, &sa->sin_addr, buf, (socklen_t)len) != NULL;
        }
    }
    return 0;
}

// Whether `override` is a dotted-quad IPv4 address one of `list`'s
// interfaces holds.
static inline int mob_node_host_is_own(const struct ifaddrs *list, const char *override) {
    struct in_addr want;
    if (!override || inet_pton(AF_INET, override, &want) != 1)
        return 0;
    for (const struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        const struct sockaddr_in *sa = (const struct sockaddr_in *)ifa->ifa_addr;
        if (sa->sin_addr.s_addr == want.s_addr)
            return 1;
    }
    return 0;
}

// Write the node host for a physical device to `buf` (at least
// INET_ADDRSTRLEN bytes) and return where it came from. `override` is
// getenv("MOB_NODE_HOST") (may be NULL), `list` the device's getifaddrs().
static inline mob_node_host_source
mob_choose_node_host(const char *override, const struct ifaddrs *list, char *buf, size_t len) {
    if (mob_node_host_is_own(list, override)) {
        struct in_addr a;
        inet_pton(AF_INET, override, &a);
        inet_ntop(AF_INET, &a, buf, (socklen_t)len);
        return MOB_NODE_HOST_FROM_ENV;
    }
    if (mob_node_host_find(list, mob_node_host_is_lan, buf, len))
        return MOB_NODE_HOST_FROM_LAN;
    if (mob_node_host_find(list, mob_node_host_is_link_local, buf, len))
        return MOB_NODE_HOST_FROM_LINK_LOCAL;
    strncpy(buf, "127.0.0.1", len - 1);
    buf[len - 1] = '\0';
    return MOB_NODE_HOST_FROM_LOOPBACK;
}

#endif
