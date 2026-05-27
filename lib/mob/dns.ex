defmodule Mob.DNS do
  @moduledoc """
  Hostname → IP resolution that works around BEAM's broken DNS path
  on iOS.

  ## Why this exists

  BEAM resolves hostnames by spawning an external helper called
  `inet_gethost` (a port program). On macOS, Linux, Windows that
  works fine. On **iOS** it doesn't — the iOS app sandbox forbids
  `execve` of any binary the app didn't get a special pass for, and
  there's no equivalent of Android's `lib*.so` escape hatch.
  Result: `:inet.getaddr/2` (and therefore Req, Finch, Mint,
  ReqLLM, and basically every Elixir HTTP library) fails on iOS
  the moment a request hits a hostname rather than a literal IP.

  This module side-steps the problem by calling Darwin's
  `getaddrinfo` directly via a NIF, then seeding `:inet_db` with
  the result so subsequent BEAM-level lookups for the same host
  succeed from the in-process file table.

  Android isn't affected — `mob_beam.zig` ships `inet_gethost` as
  `libinet_gethost.so` in `jniLibs/`, which the SELinux policy
  allows to `execve`. The NIF here would work on Android too but
  isn't wired up by default; the BEAM path is already functional
  there.

  ## How to use it

  ### Robust everywhere, incl. cellular: `resolve/1` · `preresolve/1`

  `resolve/1` calls Darwin's `getaddrinfo` via a NIF — iOS's *own*
  resolver — then seeds `:inet_db`'s `:file` table, so subsequent
  `:inet.getaddr/2` lookups (Req / Finch / Mint) find the result.
  Because it uses the OS resolver, it works wherever the OS does —
  **including cellular** (it resolves via the carrier's DNS). This is
  the recommended path and is device-verified on cellular.

  Preresolve your known hosts at startup — that's all most apps need:

      def on_start do
        Mob.DNS.preresolve(["api.example.com", "cdn.example.com"])
        # …rest of startup…
      end

  For a host not known until request time, call `resolve/1` just
  before the request. Idempotent and cheap.

  ### General fallback (WiFi-friendly): `configure_pure_beam/1`

  Flips the lookup chain to `[:file, :dns]` and seeds nameservers so
  *any* hostname resolves via raw DNS from inside BEAM — useful when
  you can't enumerate hosts up front:

      def on_start do
        if :mob_nif.platform() == :ios, do: Mob.DNS.configure_pure_beam()
      end

  Two caveats that make this the *fallback*, not the default:

    * **Gate it to iOS.** On Android `:native` works (mob ships
      `inet_gethost` as a `.so`); forcing pure-`:dns` there *breaks*
      lookups. (And never reset the chain to include `:native` on iOS —
      exec'ing `inet_gethost` there is *fatal*, it crashes the BEAM.)
    * **It can't resolve on cellular by default.** Its default
      nameservers are public (Google / Cloudflare), which carriers
      **commonly block** → `:nxdomain`. iOS exposes no reliable API to
      read the carrier's resolvers, so there's nothing dependable to
      seed instead. On cellular, **prefer `preresolve`/`resolve`**
      above, or pass `:nameservers` you know are reachable.

  The two compose: `:file` is consulted before `:dns`, so anything you
  `resolve/1` wins over the `configure_pure_beam` fallback.

  ## Scope and limitations

  - **IPv4 only.** Most cloud endpoints serve A records; IPv6 is a
    follow-up if it becomes useful.
  - **One IP per host.** If the hostname has multiple A records,
    the first one is used. BEAM caches the result; failover isn't
    automatic. If your endpoint cycles IPs frequently you may need
    to re-resolve.
  - **No automatic refresh.** Mappings stay in `:inet_db` until
    the BEAM exits. If a backend's IP changes mid-session, the
    cached entry will be stale — call `resolve/1` again to
    refresh.
  - **Doesn't help raw NIF networking.** If a third-party NIF calls
    libc `getaddrinfo` itself, it never goes through BEAM's DNS
    layer and doesn't need (or benefit from) this fix — it already
    works on iOS. Only `:inet`-mediated lookups (which covers
    almost all Elixir HTTP libraries) need our help.
  - **iOS only effectively.** On Android and host (dev, macOS,
    Linux) the NIF works but is unnecessary; BEAM's built-in path
    is fine there.

  ## Errors

      {:ok, {a, b, c, d}}              # success
      {:error, :badarg}                # host arg invalid
      {:error, :nxdomain}              # no such hostname
      {:error, :timeout}               # resolver TRY_AGAIN
      {:error, :no_address}            # resolved but no IPv4
      {:error, {:gai, code}}           # raw getaddrinfo error code
      {:error, :nif_not_loaded}        # called off-device (host tests)
  """

  @typedoc "Hostname to resolve. Latin-1 only — we're not in a domain that uses IDN."
  @type host :: String.t() | charlist()

  @typedoc "The error shapes `resolve/1` can return."
  @type error_reason ::
          :badarg
          | :nxdomain
          | :timeout
          | :no_address
          | :nif_not_loaded
          | {:gai, integer()}

  @doc """
  Resolve `host` to an IPv4 address and seed `:inet_db` so subsequent
  `:inet.getaddr/2` lookups (and thus Req / Finch / Mint) find it.

  Idempotent — calling for the same host twice is harmless.

  See module doc for usage, scope, and error shapes.
  """
  @spec resolve(host()) :: {:ok, :inet.ip4_address()} | {:error, error_reason()}
  def resolve(host) when is_binary(host), do: resolve(String.to_charlist(host))

  def resolve(host) when is_list(host) do
    case safe_nif_call(host) do
      {:ok, {_, _, _, _} = ip} ->
        :inet_db.add_host(ip, [host])
        ensure_file_lookup_first()
        {:ok, ip}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Resolve a list of hostnames. Returns a map of host → result so the
  caller can see which ones failed.

  Useful at app startup for the known-fixed set of backends your app
  talks to.

      %{
        "api.example.com" => {:ok, {93, 184, 216, 34}},
        "auth.example.com" => {:error, :nxdomain}
      }
  """
  @spec preresolve([host()]) :: %{host() => {:ok, :inet.ip4_address()} | {:error, error_reason()}}
  def preresolve(hosts) when is_list(hosts) do
    Map.new(hosts, fn host -> {host, resolve(host)} end)
  end

  @doc """
  Configure BEAM's DNS path so `:inet.getaddr/2` (and Req / Finch /
  Mint / `gen_tcp:connect/3` with a hostname) works without per-host
  setup.

  Sets the lookup chain to `[:file, :dns]` and seeds fallback
  nameservers. Both ops are idempotent.

  ## Why

  BEAM's default `:native` lookup spawns `inet_gethost`, which iOS
  refuses to `execve`. The `:dns` lookup, by contrast, performs raw
  UDP/TCP DNS queries from inside BEAM via `gen_udp` / `gen_tcp` —
  no port program, no fork. iOS doesn't block sockets, so the `:dns`
  path Just Works.

  After calling this, the whole `:inet`-mediated HTTP stack stops
  needing a per-host `resolve/1` call. `:file` stays first in the
  chain so any host you do `resolve/1` manually still wins — the two
  paths compose.

  ## When NOT to default to this

  Reach for per-host `resolve/1` (which uses libc `getaddrinfo` via
  the NIF, going through Apple's resolver) when you need any of:

    * VPN-pushed DNS for internal hostnames
    * `.local` / mDNS service discovery
    * Search-domain expansion (single-label hostnames like `https://api/`)
    * Captive-portal-aware lookup
    * Encrypted-DNS-at-OS-level (DoH / DoT configured in iOS Settings)

  These all require Apple's resolver, which only the NIF path
  consults. The pure-BEAM `:dns` path queries whatever nameservers
  you seed and nothing else.

  ## Cellular caveat

  This won't resolve on cellular with the defaults: the seeded public
  resolvers (8.8.8.8 / 1.1.1.1) are **commonly blocked by carriers** →
  `:nxdomain`. iOS exposes no reliable API to read the carrier's
  resolvers, so there's nothing dependable to seed instead. For hosts
  you can name, prefer `preresolve/1` / `resolve/1` (they use the OS
  resolver and work on cellular); otherwise pass `:nameservers` you
  know are reachable.

  ## Opts

    * `:nameservers` — list of nameserver IP tuples (IPv4 or IPv6).
      Defaults to `[{8, 8, 8, 8}, {1, 1, 1, 1}]` (Google + Cloudflare).
      Pass any list, including `[]` to skip seeding (e.g. if your
      app's `:kernel` env already configures them). Common
      alternatives:

        * `[{9, 9, 9, 9}]` — Quad9 (privacy-leaning, no logging)
        * `[{10, 0, 0, 1}, {10, 0, 0, 2}]` — your corporate resolvers

  ## Idempotent

  Calling this twice is a no-op on the second call — duplicate
  nameservers aren't added, the lookup chain isn't reordered.

  ## Examples

      # Default — most apps need nothing more
      Mob.DNS.configure_pure_beam()

      # Override the fallback nameservers
      Mob.DNS.configure_pure_beam(nameservers: [{9, 9, 9, 9}])

      # Set the lookup chain but skip nameserver seeding
      Mob.DNS.configure_pure_beam(nameservers: [])
  """
  @spec configure_pure_beam([{:nameservers, [:inet.ip_address()]}]) :: :ok
  def configure_pure_beam(opts \\ []) do
    nameservers = Keyword.get(opts, :nameservers, [{8, 8, 8, 8}, {1, 1, 1, 1}])

    set_lookup_chain([:file, :dns])
    Enum.each(nameservers, &add_ns_if_missing/1)

    :ok
  end

  @doc """
  True when `host` is already seeded in `:inet_db`.

  Useful for short-circuiting in caller code that wants to avoid an
  unnecessary NIF call — but `resolve/1` is idempotent, so calling
  it again is also fine.
  """
  @spec resolved?(host()) :: boolean()
  def resolved?(host) when is_binary(host), do: resolved?(String.to_charlist(host))

  def resolved?(host) when is_list(host) do
    case :inet.gethostbyname(host) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # ── internals ─────────────────────────────────────────────────────────

  # Wrap the NIF call so we surface a structured error when running
  # outside the device (host tests, IEx on the Mac before any deploy).
  # Without this rescue, callers get an UndefinedFunctionError that's
  # hard to interpret.
  defp safe_nif_call(host) do
    :mob_nif.resolve_ipv4(host)
  rescue
    UndefinedFunctionError -> {:error, :nif_not_loaded}
    ErlangError -> {:error, :nif_not_loaded}
  end

  # `:inet_db.set_lookup/1` controls the order BEAM tries lookup
  # methods. Default on iOS includes `:native` (the broken
  # `inet_gethost` path). We push `:file` to the front so seeded
  # entries are found first. Idempotent: only modifies if `:file`
  # isn't already in front.
  defp ensure_file_lookup_first do
    current = :inet_db.res_option(:lookup)

    case current do
      [:file | _] ->
        :ok

      _ ->
        with_file = [:file | List.delete(current, :file)]
        :inet_db.set_lookup(with_file)
        :ok
    end
  end

  # Set the lookup chain to exactly `chain` if it isn't already.
  # Used by `configure_pure_beam/1` to flip to `[:file, :dns]`.
  defp set_lookup_chain(chain) do
    if :inet_db.res_option(:lookup) != chain do
      :inet_db.set_lookup(chain)
    end

    :ok
  end

  # Add a nameserver to `:inet_db` if not already configured.
  # `:inet_db.res_option(:nameservers)` returns `[{ip, port}]`;
  # `add_ns/1` adds at default port 53.
  defp add_ns_if_missing(ns) do
    existing = :inet_db.res_option(:nameservers)

    unless Enum.any?(existing, fn {ip, _port} -> ip == ns end) do
      :inet_db.add_ns(ns)
    end

    :ok
  end
end
