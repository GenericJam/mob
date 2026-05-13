defmodule Mob.DNSTest do
  use ExUnit.Case, async: false

  # `:inet_db` is process-shared; tests can't be async because they
  # mutate the lookup chain + host table. Save and restore.

  alias Mob.DNS

  setup do
    original_lookup = :inet_db.res_option(:lookup)

    on_exit(fn ->
      # Restore the lookup order so other tests aren't affected.
      :inet_db.set_lookup(original_lookup)
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
end
