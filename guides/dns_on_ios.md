# DNS on iOS — Why Req / Finch / Mint Fail Without Configuring BEAM's DNS Path

If you're running a mob app on iOS and you call out to an HTTPS endpoint
by hostname — `Req.get!("https://api.example.com/...")` — the request
fails. The same code works on macOS, Linux, the iOS simulator, Android,
and physical Android. **Only the iOS device sees the failure**, and the
error is usually some flavour of "nxdomain" or "lookup failed."

This document explains why that happens and how to fix it.

---

## TL;DR

```elixir
# Once, in your app's on_start/0 (already in the mob.new template):
Mob.DNS.configure_pure_beam()

# Now Req / Finch / Mint / HTTPoison / Tesla all work normally:
Req.get!("https://api.example.com/things")
```

`configure_pure_beam/1` flips BEAM's lookup chain from the broken
`:native` (port-program) path to `[:file, :dns]` — BEAM does raw DNS
queries from inside Erlang via `gen_udp` / `gen_tcp`, no fork, no
`execve`. Defaults to Google + Cloudflare as fallback nameservers;
override with `nameservers:` if you need to.

For hosts that need iOS's own resolver — VPN-pushed DNS, `.local` /
mDNS, search-domain expansion, captive portals — use the per-host
`Mob.DNS.resolve/1` / `preresolve/1` path described below. Both
mechanisms compose; the per-host calls always win because `:file` is
first in the chain.

---

## Why this exists

BEAM resolves hostnames the same way it always has: it spawns an
external helper called `inet_gethost` — a small port program shipped
with OTP — and pipes hostname requests to it. The helper calls libc
`getaddrinfo` on your behalf and pipes the result back. The reason it's
out-of-process is historical (the BEAM didn't always trust libc to be
non-blocking, and `getaddrinfo` can block for seconds on slow
networks).

On macOS, Linux, Windows, and Android this works fine.

**On iOS it doesn't.** iOS sandboxes apps and forbids `execve` of any
binary the app didn't get a special pass for. There is no equivalent of
Android's "ship the helper as a `lib*.so` in `jniLibs/` and the SELinux
policy will let you `execve` it" escape hatch. When BEAM tries to spawn
`inet_gethost`, the kernel refuses. From the app's perspective, every
hostname lookup fails immediately.

Everything that resolves hostnames through `:inet` is affected:

- Req
- Finch
- Mint
- HTTPoison
- Tesla (via any of the above adapters)
- `:httpc` (the built-in OTP client)
- `gen_tcp:connect/3,4` when given a hostname

Anything that resolves *outside* of `:inet` is fine — see "What this
does NOT affect" below.

---

## Two ways to fix it

`Mob.DNS` exposes two complementary mechanisms. They compose — call
`configure_pure_beam` once at startup as the default, then `resolve/1`
only for the specific hosts where Apple-resolver semantics matter.

### 1. `configure_pure_beam/1` — pure-BEAM DNS as default

```elixir
def on_start do
  Mob.DNS.configure_pure_beam()
  # …rest of startup…
end
```

What it does:

1. Calls `:inet_db.set_lookup([:file, :dns])`. The `:dns` method
   resolves via raw UDP/TCP queries performed inside BEAM by
   `inet_res` (`gen_udp` / `gen_tcp`). No port program, no fork, no
   `execve`. iOS doesn't block sockets, so this Just Works.
2. Seeds fallback nameservers — defaults to Google + Cloudflare
   (`{8,8,8,8}` and `{1,1,1,1}`). Override via `nameservers:` opt.

After this, `:inet.getaddr/2` (and therefore the entire HTTP-library
ecosystem) resolves any public hostname without per-host setup.

### 2. `Mob.DNS.resolve/1` / `preresolve/1` — Apple-resolver-backed, per host

```elixir
{:ok, _ip} = Mob.DNS.resolve("internal.corp.local")
```

What it does:

1. Calls Darwin's `getaddrinfo` directly via a NIF (iOS allows
   in-process libc calls — only `execve` of foreign binaries is
   blocked).
2. Walks the result for the first IPv4 address.
3. Seeds it into `:inet_db`'s file table via `:inet_db.add_host/2`.
4. Ensures `:file` is first in the lookup chain so the seeded entry
   wins over whatever comes after.

Because the NIF goes through Apple's resolver, this path honours
**everything iOS knows about DNS** — VPN-pushed nameservers, search
domains, `.local` / mDNS, captive portals, encrypted-DNS configured
in iOS Settings. The pure-BEAM `:dns` path does none of that; it
just queries whatever nameservers you seeded.

### How they compose

`configure_pure_beam` puts `:file` first in the chain. So when you
later call `resolve/1` for `internal.corp.local`, the Apple-resolved
IP is added to the file table and **always wins** over the `:dns`
fallback. The two paths don't conflict.

---

## What this does NOT affect

If a NIF resolves hostnames itself — by calling libc `getaddrinfo`
directly inside its own C/Zig/Rust code — it doesn't go through BEAM's
`:inet` layer and so doesn't need (or benefit from) this fix. It
already works on iOS.

Examples of NIFs that already do their own DNS:

- **`crypto`** and **`ssl`** don't do DNS at all; they're handed an
  already-connected socket.
- **`reticulum_nif`** (Pigeon's transport NIF) calls `getaddrinfo`
  inside Reticulum's network stack. Pigeon transports work on iOS
  without `Mob.DNS`.
- Most Rust NIFs using `tokio`/`hyper` (e.g. `Reqwest`-backed clients)
  do their own DNS via libc.

If you're not sure whether a particular library needs `Mob.DNS`, the
quick check is: does it eventually call `:inet.getaddr/2`,
`:gen_tcp.connect/3,4`, or `:ssl.connect/3,4` with a hostname (binary
or charlist)? If yes, it goes through BEAM's `:inet` layer and needs
`Mob.DNS`. If it shells out to a NIF that does its own networking, it
doesn't.

---

## Android is unaffected — here's why

The exact same `inet_gethost` mechanism *would* be blocked on Android
by default — SELinux policy refuses `execute_no_trans` on binaries in
the app's data directory. But Android has a documented escape hatch:
binaries packaged as `lib<name>.so` inside `jniLibs/<abi>/` get the
`apk_data_file` SELinux label, which *does* allow execution.

`mob_beam.zig` (the Android BEAM launcher) ships the OTP helpers
(`inet_gethost`, `erl_child_setup`, `epmd`) as `lib*.so` files in
`jniLibs/arm64-v8a/`, then symlinks `BINDIR/<name>` →
`<nativeLibraryDir>/lib<name>.so` before calling `erl_start`. From
BEAM's perspective, the helpers live exactly where it expects them and
are executable. DNS works normally.

iOS has no comparable mechanism. The `Mob.DNS` NIF is the workaround.

---

## Trade-offs — pure-BEAM vs. Apple-resolver

| Concern | `configure_pure_beam` (`:dns` method) | `resolve/1` / `preresolve/1` (libc NIF) |
|---|---|---|
| Who runs the DNS query? | BEAM's `inet_res` — raw UDP/TCP from Erlang | Apple's resolver, in-process via libc |
| Nameservers used | Whatever you seeded (defaults to Google + Cloudflare) | Whatever iOS knows about — DHCP, VPN, configured DoH/DoT |
| Captive portals (hotel / airport Wi-Fi) | Often broken — captive nets hijack DNS in ways the OS handles, raw UDP doesn't | Handled by iOS |
| Corporate / VPN DNS for internal hostnames | Doesn't work unless you also seed the corporate resolver | Works — iOS picks up DNS pushed by the VPN profile |
| Search-domain expansion (single-label `https://api/`) | Not applied | Applied by iOS resolver |
| `.local` / mDNS service discovery | Doesn't work | Works |
| IPv6 dual-stack (Happy Eyeballs) | Manual | Automatic |
| TTL respected; auto-refresh when an IP rotates | Yes (DNS TTLs honoured per lookup) | No — `inet_db` seed persists until you re-`resolve/1` |
| Cost per lookup | UDP round-trip every time `:dns` fires | Zero after the first call (cached in `inet_db`) |
| Per-host setup required? | No | Yes (`resolve/1` per hostname, or `preresolve/1` for a batch) |
| Code surface | One function call at startup | NIF + Elixir wrapper |

**Default to `configure_pure_beam`.** It covers everything most apps
talk to (consumer Wi-Fi or cellular + public-internet endpoints) with
one line of setup.

**Reach for `resolve/1` per-host** when you specifically need the
Apple-resolver behaviour from the table above. The two compose — the
manually-seeded entry always wins over the `:dns` fallback because
`:file` is first in the chain.

---

## When to call `resolve` / `preresolve`

**At app startup, for known-fixed backends.** List the backends that
need Apple-resolver semantics (VPN, mDNS, etc.) and resolve them
alongside the `configure_pure_beam` call:

```elixir
def on_start do
  Mob.DNS.configure_pure_beam()                      # public-internet hosts

  Mob.DNS.preresolve([                               # OS-resolver-special hosts
    "internal.corp.local",
    "files.local"
  ])

  # …rest of startup…
end
```

The map returned from `preresolve/1` lets you log per-host failures
without aborting the whole startup:

```elixir
for {host, result} <- Mob.DNS.preresolve(hosts) do
  case result do
    {:ok, ip} -> Logger.info("[dns] #{host} → #{:inet.ntoa(ip)}")
    {:error, reason} -> Logger.warning("[dns] #{host} failed: #{inspect(reason)}")
  end
end
```

**Lazily, right before the first request.** Useful if the set of
backends isn't known until login or some other runtime event:

```elixir
def authenticated_request(host, path) do
  Mob.DNS.resolve(host)  # idempotent; fast if already resolved
  Req.get!("https://#{host}#{path}")
end
```

`resolved?/1` lets you skip the call if you want to:

```elixir
unless Mob.DNS.resolved?(host), do: Mob.DNS.resolve(host)
```

…but `resolve/1` is already cheap on the happy path (one libc call,
one map insertion), so the explicit guard is rarely worth it.

---

## Limitations and caveats

- **IPv4 only.** Most cloud endpoints serve A records and BEAM picks
  the first one anyway. IPv6 (AAAA) is a follow-up — file an issue if
  you need it.
- **One IP per host.** If the hostname has multiple A records, the
  first one is used. There's no failover; if that IP becomes
  unreachable mid-session, requests will fail until you call
  `resolve/1` again.
- **No automatic refresh.** Seeded entries stay in `:inet_db` until
  the BEAM exits. If your backend's IP changes (DNS round-robin, blue/
  green deploy), the cached entry will be stale until you re-resolve.
  For most apps this is fine; if it isn't, set up a periodic
  re-resolve task.
- **iOS only effectively.** On Android and host (Mac dev, Linux, the
  iOS simulator) the NIF works but is unnecessary; BEAM's built-in
  DNS path is fine. Calling `Mob.DNS.resolve/1` on those platforms is
  harmless but redundant.
- **Doesn't help raw NIF networking.** See "What this does NOT
  affect" above.

---

## Errors `resolve/1` can return

```elixir
{:ok, {a, b, c, d}}        # success — IPv4 address
{:error, :badarg}          # host arg invalid (not a charlist/binary)
{:error, :nxdomain}        # no such hostname
{:error, :timeout}         # resolver TRY_AGAIN
{:error, :no_address}      # resolved but no IPv4 result
{:error, {:gai, code}}     # raw getaddrinfo error code
{:error, :nif_not_loaded}  # called off-device (host tests / IEx)
```

Treat `:nif_not_loaded` as "you're not on a device" — it's the signal
that returns from host BEAM where the NIF isn't compiled in. Useful in
tests; in production code on iOS you should never see it.

---

## App Transport Security is a separate concern

ATS (Apple's TLS-enforcement policy) is a different gate. If your
endpoint serves plain HTTP, or uses a self-signed cert, or uses an
older TLS version, ATS will block the connection even after DNS
succeeds. The errors look completely different (`NSURLErrorDomain
-1022` or similar), but it's worth knowing that "my request fails on
iOS" can mean DNS *or* ATS. If `Mob.DNS.resolve/1` returns `{:ok, _}`
and the request still fails with a TLS-looking error, suspect ATS
next.

---

## Why the manual call instead of automatic interception

In principle a startup hook could intercept every `:inet.getaddr`
call, resolve via NIF, and seed `:inet_db` transparently — and the
user would never have to touch `Mob.DNS` at all. We didn't go that
route because:

1. **Predictability.** Explicit `resolve/1` calls show up in your
   startup code and in profiles. Magic interception that fails
   silently is harder to diagnose when a host you forgot to whitelist
   breaks in production.
2. **Cost.** Resolving every hostname on every request adds a libc
   round-trip even when the entry is already cached. Manual
   `preresolve/1` at startup keeps the hot path zero-cost.
3. **Compatibility.** Some apps want to use a custom DNS server
   (mDNS for service discovery, DNS-over-HTTPS for privacy). Manual
   resolution leaves those paths open; automatic interception would
   need to grow more configuration than the explicit call.

If your app talks to a small fixed set of hosts (which most do), the
extra `preresolve/1` line at startup is the lowest-friction option.

---

## Other gotchas (empirically discovered)

Once `Mob.DNS` is in place, the next failures down the HTTPS stack
are easy to misread as "DNS still broken." They aren't — they're
separate issues that the iOS-device deployment surfaces because
the BEAM bootstrap is more minimal than a normal Mix project. If
your request still fails after seeding DNS, check these:

### 1. Start the HTTP client's application

Mob's iOS launcher (`mob_beam.m`) boots a minimal BEAM:
`compiler` → `elixir` → `logger` → `<your_app>.start/0`. That's
*all*. Hex dependencies like `:req` are **not auto-started** — the
normal OTP `applications:` list in your `.app` file isn't being
consulted by this boot path.

If Req's `Finch` supervisor isn't running you'll see:

```
GenServer.call(Req.FinchSupervisor, ...)
** (EXIT) no process: the process is not alive ...
```

Fix: explicitly start the HTTP client and the cert store in your
`on_start/0`, after `Mob.DNS.preresolve/1`:

```elixir
def on_start do
  # ... your usual startup ...

  {:ok, _} = Application.ensure_all_started(:req)
  {:ok, _} = Application.ensure_all_started(:castore)

  Mob.DNS.preresolve(["api.example.com"])

  Mob.Screen.start_root(MyApp.HomeScreen)
end
```

Same pattern for `:finch`/`:mint`/`:httpoison`/`:tesla` if you're
using those directly.

### 2. TLS trust store — `:castore` or `:public_key.cacerts_load!/0`

Mint's HTTPS path verifies the server certificate by default and
needs a CA bundle. On iOS-device builds the default
`Application.app_dir(:castore, "priv/cacerts.pem")` path doesn't
always resolve correctly even with castore in deps. Two working
options:

```elixir
# Option A — explicit CA file via transport opts
Req.get(url, connect_options: [transport_opts: [cacertfile: ...]])

# Option B — load the OS CA store (OTP 25+)
:public_key.cacerts_load!()
Req.get(url, connect_options: [
  transport_opts: [cacerts: :public_key.cacerts_get()]
])
```

For dev / spike testing where you don't care about cert validation,
`verify: :verify_none` works but **never ship this**:

```elixir
Req.get(url, connect_options: [transport_opts: [verify: :verify_none]])
```

### 3. Stale `:inet_db` if the IP rotates

`Mob.DNS.resolve/1` seeds `:inet_db` once per BEAM lifetime. If the
backend's IP changes mid-session (DNS round-robin, blue/green
deploy), subsequent requests will keep hitting the cached IP until
you call `resolve/1` again. For long-running apps that talk to
volatile endpoints, schedule a periodic re-resolve.

### 4. Hot-push doesn't re-run `on_start/0`

`mix mob.deploy` (without `--native`) hot-loads new BEAMs via
`:code.load_binary` — the running app's `on_start/0` is *not*
re-invoked, and the on-disk `.beam` files in the app's Documents
dir aren't updated. If you change `on_start/0` (e.g., to add the
`ensure_all_started` calls above), use `mix mob.deploy --native`
to actually reinstall the app with the new beams on disk so a
restart will pick them up.
