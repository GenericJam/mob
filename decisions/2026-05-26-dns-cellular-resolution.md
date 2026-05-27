# On iOS, resolve/preresolve is the robust DNS path; configure_pure_beam fails on cellular

- Date: 2026-05-26
- Status: accepted

## Context

iOS apps couldn't reach servers by hostname (Mint/Req `:nxdomain`). On iOS
`inet_gethost` can't `execve`, so `Mob.DNS` offers two workarounds:

- `configure_pure_beam/1` — flip the lookup chain to `[:file, :dns]` and seed
  nameservers (default: public 8.8.8.8 / 1.1.1.1) for in-BEAM raw DNS.
- `resolve/1` · `preresolve/1` — call Darwin `getaddrinfo` via a NIF (iOS's own
  resolver) and seed `:inet_db`'s `:file` table.

**Device-verified on a physical iPhone over cellular (Wi-Fi off):** `resolve/1`
(`getaddrinfo`) returns `{:ok, ip}`; pure-`:dns` to the public resolvers returns
`{:error, :nxdomain}` — **carriers block public DNS**. (Also confirmed forcing
`:native` is *fatal* on iOS: `getaddrs` tries to exec `inet_gethost` and crashes
the BEAM.)

We tried to fix `configure_pure_beam` by seeding the device's *own* resolvers
instead of public ones, but no reliable way exists to read them on iOS:

- `res_ninit` / `res_getservers` returns `[]` on-device (reads the static, empty
  `/etc/resolv.conf`). Confirmed on cellular.
- `dns_configuration_copy` (`<dnsinfo.h>`) is private — the header ships in no
  SDK on this machine, so the structs would have to be hand-declared (ABI risk).
- `SCDynamicStore` needs the SystemConfiguration framework linked (a build change
  in the in-flux mob_dev build) and may be sandbox-restricted on iOS.

iOS intentionally abstracts the resolver away — there's no clean public "list my
DNS servers" API. Seeding nameservers for pure-`:dns` fights the platform.

## Decision

Don't extract iOS nameservers. Treat **`resolve/1` · `preresolve/1` as the
robust path** (they use the OS resolver — cellular-safe — and already exist);
**`configure_pure_beam` is a WiFi-friendly fallback** for hosts you can't
enumerate. Land the fix as documentation, not code:

- `Mob.DNS` moduledoc now leads with `preresolve`/`resolve` ("robust everywhere,
  incl. cellular") and demotes `configure_pure_beam` to a fallback.
- `configure_pure_beam/1` gains a **Cellular caveat** (public resolvers blocked;
  no reliable way to read the carrier's; prefer `preresolve`/`resolve`) and an
  iOS-gating note (don't run it on Android; never force `:native` on iOS).
- No change to `Mob.DNS` code — the working mechanism (`getaddrinfo` NIF) already
  exists. Code-To-Cloud already preresolves its hosts in `on_start`.

## Consequences

- iOS apps that hit known hosts should `preresolve` them at startup (works on
  cellular without IP-pinning). For request-time-only hosts, call `resolve/1`
  first.
- `configure_pure_beam` stays useful where public DNS is reachable (most WiFi)
  and for dynamic hosts there; its cellular limitation is now documented.
- If a clean iOS API for the system resolvers appears, or `SCDynamicStore` is
  confirmed readable in-sandbox, `configure_pure_beam` could seed them by
  default — revisit then. (An earlier `system_nameservers/0` NIF via
  `res_getservers` was prototyped and dropped: no-op on iOS.)
