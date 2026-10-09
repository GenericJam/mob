// Physical iPhone node host selection (MOB-428).
//
//     make -C test/native run
//
// Compiles ios/mob_node_host.h itself — the code mob_beam.m runs — and drives
// it with synthetic getifaddrs() lists shaped like a wired iPhone's: loopback,
// WiFi, the USB link-local interface. It does not cover mob_beam.m reading
// MOB_NODE_HOST from the environment or naming the node; that needs a device.
// See decisions/2026-10-09-ios-node-host-override.md.
#include "../../ios/mob_node_host.h"

#include <stdio.h>

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

#define MAX_IFS 4

static struct ifaddrs ifs[MAX_IFS];
static struct sockaddr_in addrs[MAX_IFS];

// Build a getifaddrs()-shaped list from dotted quads (NULL-terminated), in order.
static struct ifaddrs *list_of(const char *ips[]) {
    struct ifaddrs *head = NULL, *prev = NULL;
    for (int i = 0; i < MAX_IFS && ips[i]; i++) {
        memset(&ifs[i], 0, sizeof(ifs[i]));
        memset(&addrs[i], 0, sizeof(addrs[i]));
        addrs[i].sin_family = AF_INET;
        inet_pton(AF_INET, ips[i], &addrs[i].sin_addr);
        ifs[i].ifa_addr = (struct sockaddr *)&addrs[i];
        if (prev)
            prev->ifa_next = &ifs[i];
        else
            head = &ifs[i];
        prev = &ifs[i];
    }
    return head;
}

static void expect(const char *what, const char *override, const char *ips[], const char *want,
                   mob_node_host_source want_src) {
    char buf[INET_ADDRSTRLEN];
    mob_node_host_source src = mob_choose_node_host(override, list_of(ips), buf, sizeof(buf));
    CHECK(strcmp(buf, want) == 0, "%s: host %s, want %s", what, buf, want);
    CHECK(src == want_src, "%s: source %d, want %d", what, src, want_src);
}

int main(void) {
    // Kevin's iPhone on 2026-10-09: WiFi on a network the Mac can't route to.
    const char *wired[] = {"127.0.0.1", "192.168.0.185", "169.254.1.100", NULL};
    const char *cable_only[] = {"127.0.0.1", "169.254.1.100", NULL};
    const char *nothing[] = {"127.0.0.1", NULL};

    // Without an override: WiFi first, as before.
    expect("no override, WiFi up", NULL, wired, "192.168.0.185", MOB_NODE_HOST_FROM_LAN);
    expect("empty override", "", wired, "192.168.0.185", MOB_NODE_HOST_FROM_LAN);
    expect("cable only", NULL, cable_only, "169.254.1.100", MOB_NODE_HOST_FROM_LINK_LOCAL);
    expect("no network", NULL, nothing, "127.0.0.1", MOB_NODE_HOST_FROM_LOOPBACK);

    // The override names the address the Mac reaches the phone at.
    expect("override: USB link-local", "169.254.1.100", wired, "169.254.1.100",
           MOB_NODE_HOST_FROM_ENV);
    expect("override: the WiFi address", "192.168.0.185", wired, "192.168.0.185",
           MOB_NODE_HOST_FROM_ENV);

    // An address the phone doesn't hold would name an unreachable node: ignored.
    expect("override: someone else's IP", "10.0.0.71", wired, "192.168.0.185",
           MOB_NODE_HOST_FROM_LAN);
    expect("override: not an IPv4", "kevins-iphone.local", wired, "192.168.0.185",
           MOB_NODE_HOST_FROM_LAN);
    expect("override: trailing junk", "169.254.1.100x", wired, "192.168.0.185",
           MOB_NODE_HOST_FROM_LAN);
    expect("override: link-local gone", "169.254.1.100", nothing, "127.0.0.1",
           MOB_NODE_HOST_FROM_LOOPBACK);

    // Entries that aren't IPv4 (no address; IPv6) are skipped, not misread. The
    // IPv6 entry's flowinfo sits where a sockaddr_in keeps its address, set so
    // that misreading it would yield the LAN address 10.9.9.9.
    {
        const char *ips[] = {"192.168.0.185", NULL};
        struct ifaddrs *l = list_of(ips);
        struct sockaddr_in6 v6;
        memset(&v6, 0, sizeof(v6));
        v6.sin6_family = AF_INET6;
        v6.sin6_flowinfo = htonl(0x0A090909);
        inet_pton(AF_INET6, "fe80::1", &v6.sin6_addr);
        struct ifaddrs six;
        memset(&six, 0, sizeof(six));
        six.ifa_addr = (struct sockaddr *)&v6;
        six.ifa_next = l;
        struct ifaddrs bare;
        memset(&bare, 0, sizeof(bare));
        bare.ifa_next = &six;
        char buf[INET_ADDRSTRLEN];
        CHECK(mob_choose_node_host(NULL, &bare, buf, sizeof(buf)) == MOB_NODE_HOST_FROM_LAN &&
                  strcmp(buf, "192.168.0.185") == 0,
              "no-address and IPv6 entries are skipped, got %s", buf);
        CHECK(mob_choose_node_host("10.9.9.9", &bare, buf, sizeof(buf)) == MOB_NODE_HOST_FROM_LAN &&
                  strcmp(buf, "192.168.0.185") == 0,
              "an IPv6 entry is not taken for an own IPv4 address, got %s", buf);
    }

    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("node_host_test: ok\n");
    return 0;
}
