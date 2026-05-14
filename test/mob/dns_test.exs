defmodule Mob.DNSTest do
  use ExUnit.Case, async: false

  # `:inet_db` is process-shared; tests can't be async because they
  # mutate the lookup chain + host table. Save and restore.

  alias Mob.DNS

  setup do
    original_lookup = :inet_db.res_option(:lookup)
    original_ns = :inet_db.res_option(:nameservers)

    on_exit(fn ->
      # Restore the lookup order so other tests aren't affected.
      :inet_db.set_lookup(original_lookup)

      # Restore nameservers — `configure_pure_beam/1` adds {8.8.8.8, 53}
      # and {1.1.1.1, 53} by default, which would leak across tests.
      # `set_resolv_conf("")` clears all then `add_ns/1` per restored entry.
      for {ip, port} <- :inet_db.res_option(:nameservers) do
        :inet_db.del_ns(ip, port)
      end

      for {ip, port} <- original_ns do
        :inet_db.add_ns(ip, port)
      end

      # Best-effort host-table cleanup for the names we used.
      for host <-
            ~c"a.test a.test.local b.test missing.test bogus.test"
            |> List.to_string()
            |> String.split() do
        :inet_db.del_host(String.to_charlist(host))
      end
    end)

    :ok
  end

  # ── resolve/1 — host tests work without the NIF loaded ──────────────────

  describe "resolve/1 when the NIF isn't loaded (host / CI)" do
    test "returns {:error, :nif_not_loaded} for a binary host" do
      assert {:error, :nif_not_loaded} = DNS.resolve("api.example.com")
    end

    test "returns {:error, :nif_not_loaded} for a charlist host" do
      assert {:error, :nif_not_loaded} = DNS.resolve(~c"api.example.com")
    end

    test ":inet_db is NOT polluted when the NIF fails" do
      # Important: a failed resolve must not leave a half-seeded entry.
      _ = DNS.resolve("a.test")
      refute DNS.resolved?("a.test"), "host must not be seeded after NIF failure"
    end
  end

  # ── resolve/1 — happy path simulated by directly seeding inet_db ────────
  #
  # We can't easily intercept the NIF call without a runtime DI seam, but
  # we can pin the post-condition: when an IP IS in inet_db (regardless
  # of who put it there), `resolved?/1` reports true and BEAM's lookup
  # finds it. Combined with the NIF-error tests above, the wrapper logic
  # is fully covered modulo the trivial `enif_make_*` mapping in C.

  describe "resolved?/1" do
    test "false for a host that's not in inet_db" do
      refute DNS.resolved?("never.seeded.test")
    end

    test "true after seeding inet_db AND setting :file-first lookup" do
      # This is the post-condition `resolve/1` establishes on a real
      # device. Replicate it manually here since the NIF doesn't run
      # in host tests.
      :inet_db.set_lookup([:file, :native])
      :inet_db.add_host({203, 0, 113, 7}, [~c"manual.seeded.test"])

      assert DNS.resolved?("manual.seeded.test")
    end

    test "accepts both binary and charlist forms" do
      :inet_db.set_lookup([:file, :native])
      :inet_db.add_host({203, 0, 113, 8}, [~c"both.forms.test"])

      assert DNS.resolved?("both.forms.test")
      assert DNS.resolved?(~c"both.forms.test")
    end

    test "false when an entry exists in inet_db but the lookup chain skips :file" do
      # Defensive — pin the chain-dependence semantics. If someone
      # manually adds a host but the chain doesn't include :file,
      # resolved?/1 (and any Req/Finch lookup) correctly reports
      # "not findable." resolve/1 sets the chain, so users following
      # the documented path won't hit this.
      :inet_db.set_lookup([:native])
      :inet_db.add_host({203, 0, 113, 9}, [~c"chain.bypass.test"])

      refute DNS.resolved?("chain.bypass.test")
    end
  end

  # ── preresolve/1 ───────────────────────────────────────────────────────

  describe "preresolve/1" do
    test "returns a host → result map covering every input" do
      result = DNS.preresolve(["a.test", "b.test"])

      assert map_size(result) == 2
      assert Map.has_key?(result, "a.test")
      assert Map.has_key?(result, "b.test")
    end

    test "preserves per-host failures rather than failing the whole batch" do
      result = DNS.preresolve(["a.test", "b.test"])

      # On the host without the NIF every entry is :nif_not_loaded.
      for {_host, outcome} <- result do
        assert {:error, :nif_not_loaded} = outcome
      end
    end

    test "empty list → empty map" do
      assert DNS.preresolve([]) == %{}
    end
  end

  # ── Lookup-chain side effects ──────────────────────────────────────────
  #
  # On host BEAM the default lookup is `[:native]` — adding a host to the
  # file table is NOT enough on its own; you also need `:file` in the
  # chain. This is exactly the situation `resolve/1` works around by
  # pushing `:file` to the front. Pin the contract.

  describe ":inet_db lookup chain" do
    test "seeding a host alone is not enough — the chain must include :file" do
      # Same seed as the "happy path" tests above, but WITHOUT mutating
      # the lookup chain. On a default-config BEAM, `resolved?/1` should
      # report false because `:native` doesn't see the file table.
      :inet_db.add_host({203, 0, 113, 99}, [~c"chain.test"])

      # If this ever flips to true on a future OTP, it means the default
      # chain changed to include `:file`. Update the comment and
      # consider whether `resolve/1` still needs `ensure_file_lookup_first/0`.
      refute DNS.resolved?("chain.test")
    end

    test "after pushing :file to the front, the seeded host IS findable" do
      # This is the post-condition `resolve/1` establishes. Replicating
      # it confirms the wrapper's chain-mutation strategy is sound.
      :inet_db.add_host({203, 0, 113, 99}, [~c"chain.test"])
      :inet_db.set_lookup([:file | :inet_db.res_option(:lookup)])

      assert DNS.resolved?("chain.test")
    end
  end

  # ── configure_pure_beam/1 ──────────────────────────────────────────────
  #
  # Flips BEAM's lookup chain to `[:file, :dns]` and seeds nameservers so
  # `:inet.getaddr/2` resolves via raw DNS queries from inside BEAM
  # instead of the iOS-broken `:native` (inet_gethost) path. Pure state
  # mutation on `:inet_db`; nothing to mock.

  describe "configure_pure_beam/1" do
    test "sets the lookup chain to [:file, :dns]" do
      DNS.configure_pure_beam(nameservers: [])
      assert :inet_db.res_option(:lookup) == [:file, :dns]
    end

    test "seeds Google + Cloudflare DNS by default" do
      DNS.configure_pure_beam()
      nameservers = :inet_db.res_option(:nameservers)
      ips = Enum.map(nameservers, fn {ip, _port} -> ip end)
      assert {8, 8, 8, 8} in ips
      assert {1, 1, 1, 1} in ips
    end

    test "honors a custom :nameservers list" do
      DNS.configure_pure_beam(nameservers: [{9, 9, 9, 9}])
      ips = :inet_db.res_option(:nameservers) |> Enum.map(fn {ip, _port} -> ip end)
      assert {9, 9, 9, 9} in ips
      refute {8, 8, 8, 8} in ips
    end

    test ":nameservers: [] sets the lookup chain but skips ns seeding" do
      # Snapshot ns count before so we don't false-positive on a leftover
      # from another test (setup restores, but order isn't guaranteed).
      before = length(:inet_db.res_option(:nameservers))
      DNS.configure_pure_beam(nameservers: [])
      assert :inet_db.res_option(:lookup) == [:file, :dns]
      assert length(:inet_db.res_option(:nameservers)) == before
    end

    test "is idempotent — calling twice doesn't duplicate nameservers" do
      DNS.configure_pure_beam(nameservers: [{8, 8, 8, 8}])
      first = length(:inet_db.res_option(:nameservers))
      DNS.configure_pure_beam(nameservers: [{8, 8, 8, 8}])
      second = length(:inet_db.res_option(:nameservers))
      assert first == second
    end

    test "preserves manually-seeded :file entries (composes with resolve/1)" do
      # The whole point of `:file` being first in the chain — manually-
      # resolved hosts (Apple-resolver-backed) still win over the :dns
      # fallback, so a user can use configure_pure_beam as a default and
      # selectively call resolve/1 for VPN/mDNS hosts.
      :inet_db.add_host({203, 0, 113, 50}, [~c"compose.test"])
      DNS.configure_pure_beam(nameservers: [])
      assert DNS.resolved?("compose.test")
    end
  end
end
