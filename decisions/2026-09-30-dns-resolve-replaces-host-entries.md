# `Mob.DNS.resolve/1` replaces a host's entries instead of appending

- Date: 2026-09-30
- Status: accepted
- Issue: user report (Android). No Linear issue: the workspace was at its
  free-issue cap when this was filed.

## Context

`resolve/1` seeds BEAM's `:file` lookup table with the OS resolver's answer so
`:inet.getaddr/2` (Req, Finch, Mint) can find it. It did so with a bare
`:inet_db.add_host(ip, [host])`, and the moduledoc told callers to "call
`resolve/1` again to refresh" after an IP change. That never worked, because of
how OTP's `inet_db` stores runtime-added hosts (`inet_db.erl`, OTP 29):

1. **Appends per host.** `add_ip_bynms` appends a new address to the host's
   by-name list (`IPs ++ [IP]`). `:inet.getaddr/2` returns the head, which is
   the stale address. A user saw this after a Wi-Fi network whose DNS
   sinkholed a host switched to mobile data. Req kept connecting to the
   sinkhole address until the app restarted.
2. **Keyed by address.** `do_add_host` replaces the whole name list stored
   under an address. So two hosts resolving to one address evict each other:
   the earlier one falls out of the `:file` table while `resolve/1` still
   returned `{:ok, _}` for it. This happens with shared CDN addresses and with
   every name a sinkhole answers with `0.0.0.0`.

The workaround the user tried, `:inet_db.del_host(stale_ip)`, removes the
address for every name, which unseeds co-tenants in exactly the sinkhole case.

## Decision

`resolve/1` rebuilds both sides of the table for the host:

- It reads the runtime-added IPv4 entries through `:inet_db.get_rc/0`. That
  returns only the runtime table (`inet_hosts_byaddr`), never the hosts file.
  `get_rc/0` and `tolower/1` are exported but undocumented (`inet_db` is
  `-moduledoc false`), so they carry no stability promise. Their shape and
  behaviour are identical in the OTP 26.2, 27.3, 28.5 and 29.0 sources.
- For every other address that lists the host, it re-adds the address without
  the host, or calls `del_host` when the host was the only name.
- It seeds the fresh address with the host plus the names already sharing it.
- Names are compared with `:inet_db.tolower/1`, the rule `inet_db` itself uses
  for by-name keys.
- IPv6 entries an app added itself are left alone. `resolve/1` only answers
  IPv4.

The read-modify-write spans several `inet_db` calls, so it runs inside
`Mob.DNS.Seeder`, a locally registered process that is started on first use
and unlinked. Its mailbox serialises concurrent resolves. Without
serialisation, 40 concurrent resolves onto one address lost 27 to 30 hosts in
every round of a host stress run. With it, none were lost.

The call into the seeder waits with `:infinity`, as `:inet_db`'s own calls do.
Review of the first seeder version showed why a finite timeout is wrong: the
caller exits with `:timeout` while its queued request still rewrites the table
afterwards, without the `:file` lookup step that follows. A `:noproc` exit,
usually because the seeder died between `start/0` returning it and the call,
is retried once against a fresh seeder. Replacing a host is idempotent. Any
other exit, and a second `:noproc`, propagates to the caller. The retry branch
itself has no test: the race window can't be opened deterministically from
outside the process.

The guarantee covers only hosts seeded through `resolve/1`. Code that calls
`:inet_db.add_host/2` itself at the same moment can still have its name
replaced by the seeder's stale snapshot. OTP offers no compare-and-swap on the
host table, and `Mob.App.configure_ios_inet_db/0`, the one framework writer,
runs before app code can resolve anything.

A failed resolve leaves the previous mapping in place. A transient resolver
failure shouldn't unseed a host that may still be reachable.

Alternatives rejected:

- **`:inet_db.clear_hosts/0` then re-seed everything.** This drops entries the
  app added itself (`Mob.App.configure_ios_inet_db/0` seeds `localhost`), and
  it needs every other host re-resolved.
- **`:global.trans({Mob.DNS, self()}, _, [node()])` as the lock.** This was the
  first version, and pre-commit review (codex) rejected it. `trans/3` releases
  the lock on the node list captured at acquire time. `Mob.Dist` starts
  distribution a few seconds after boot on Android, which renames `nonode@nohost`,
  so a resolve in flight at that moment sends its release to a node name that
  no longer exists. The lock stays in `global_locks` and every later
  `resolve/1` retries forever. The reviewer reproduced this against OTP 29.
  A locally registered name doesn't depend on the node name.
- **Reading the `inet_hosts_by*` ETS tables directly.** These are private to
  `inet_db`. `get_rc/0` and `tolower/1` are exported.

## Consequences

- Re-resolving after a network change now refreshes the mapping, which is what
  the docs always promised. Apps don't need a workaround. They should drop any
  `del_host` workaround, because it unseeds co-tenants.
- The test seam is `Mob.DNS.resolve_with/2` (`@doc false`), which takes the NIF
  module, following `Mob.PostMortem.Android.sweep_with/1`. `test/mob/dns_test.exs`
  drives the real seeding path through a scripted NIF. Between them the seeding
  tests fail against the old bare `add_host`, and against removing the IPv4
  filter, co-tenant merge, case folding, empty-entry delete or seeder
  serialisation. The failed-re-resolve test pins a boundary instead: it passes
  on the old code too, and fails if an error path starts unseeding. A dead
  seeder is replaced on the next resolve.
- Verified on a physical Moto G power (2021), Android 11, OTP 29, inside a
  running app (`muster_app`) with the final `Mob.DNS` and `Mob.DNS.Seeder`
  loaded over dist. The seeder ran as a local process on the distributed node.
  The sinkhole-to-real-resolver switch was reproduced with Android Private DNS
  (`dns.adguard-dns.com` then off):
  - With the old code, `doubleclick.net` was evicted by `googleadservices.com`
    on `0.0.0.0`, and after the switch `getaddr` still returned `0.0.0.0`.
  - With the new code, both hosts were seeded on `0.0.0.0`. After the switch,
    the re-resolved host's hostent held only `142.250.73.66`, and a
    `:gen_tcp.connect` by hostname reached it on 443. The co-tenant stayed on
    `0.0.0.0` until it was re-resolved itself.
- On the host, resolves in flight while `Node.start/2` renamed the node, and
  50 more afterwards, all completed with no host lost. The rejected
  `:global.trans` version lost 35 hosts in the same script.
- On that same Moto G (Android 11), BEAM's built-in `inet_gethost` path
  resolved normally, so the moduledoc's "physical Android fails" (seen on a
  Moto G Power 5G 2024, Android 14) is device-dependent. The module and
  `guides/dns_on_ios.md` now say so, and still recommend `resolve/1` on
  Android.
- Mappings still don't refresh automatically. The app decides when to
  re-resolve, e.g. on a connectivity change.
