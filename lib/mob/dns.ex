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

  Resolve each hostname your app talks to **before** the first
  Req / Finch / Mint call to that host. Once resolved, `:inet_db`
  retains the mapping for the lifetime of the BEAM, so subsequent
  HTTP calls go through without you doing anything else.

      # At app startup, or before the first call:
      {:ok, _ip} = Mob.DNS.resolve("api.example.com")

      # Now this just works on iOS:
      Req.get!("https://api.example.com/v1/things")

  For a small fixed set of hosts, the convenience helper
  `preresolve/1` does the whole list at once:

      Mob.DNS.preresolve([
        "api.example.com",
        "auth.example.com"
      ])

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
end
