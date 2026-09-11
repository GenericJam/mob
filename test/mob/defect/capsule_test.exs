defmodule Mob.Defect.CapsuleTest do
  use ExUnit.Case, async: true

  alias Mob.Defect.Capsule

  describe "new/1" do
    test "populates every required schema field" do
      c =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :critical,
          fingerprint_key: %{invariant: :parked_screen_alive, screen: MyScreen}
        )

      assert %Capsule{
               schema: "mob.defect/1",
               kind: :invariant,
               owner: :mob,
               severity: :critical,
               redaction: :applied,
               id: id,
               fingerprint: fp,
               detected_at: dt,
               build: build,
               device: device,
               evidence: evidence,
               repro: %{available: false, minimized: false, steps: []}
             } = c

      assert is_binary(id) and byte_size(id) > 0
      assert String.starts_with?(fp, "sha256:")
      # ISO 8601 with either "Z" or explicit offset
      assert String.match?(
               dt,
               ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/
             )

      # Build has the platform-populated shape: at least the mob version and
      # the runtime versions this test's own BEAM was compiled against.
      assert %{mob: mob_vsn, otp: otp, elixir: elixir} = build
      assert is_binary(mob_vsn) or is_nil(mob_vsn)
      assert is_binary(otp) and byte_size(otp) > 0
      assert elixir == System.version()

      # Device is the shape the schema promises, even in a host test run.
      assert %{platform: platform, os: _os, model: _model} = device
      assert platform in [:ios, :android, :host]

      # Evidence carries the fingerprint_key back (that is what makes a class
      # row self-describing).
      assert %{invariant: :parked_screen_alive, screen: MyScreen} = evidence
    end

    test "detected_at is formatted from :now_ms and stable" do
      c =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{invariant: :x},
          now_ms: 1_756_566_663_418
        )

      assert c.detected_at == "2025-08-30T15:11:03.418Z"
    end

    test "evidence keeps the fingerprint_key and adds caller evidence" do
      c =
        Capsule.new(
          kind: :divergence,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{reason: :type, path: []},
          evidence: %{ios: :button, android: :label}
        )

      assert c.evidence == %{reason: :type, path: [], ios: :button, android: :label}
    end

    test "redaction defaults to :applied and accepts :none" do
      applied =
        Capsule.new(kind: :invariant, owner: :mob, severity: :warning, fingerprint_key: %{a: 1})

      none =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{a: 1},
          redaction: :none
        )

      assert applied.redaction == :applied
      assert none.redaction == :none
    end

    test "invalid redaction raises rather than silently accepting" do
      assert_raise ArgumentError, fn ->
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{a: 1},
          redaction: :maybe
        )
      end
    end

    test "distinct occurrences share a fingerprint and get different ids" do
      opts = [
        kind: :invariant,
        owner: :mob,
        severity: :critical,
        fingerprint_key: %{invariant: :parked_screen_alive, screen: MyScreen}
      ]

      a = Capsule.new(opts)
      b = Capsule.new(opts)

      assert a.fingerprint == b.fingerprint
      assert a.id != b.id
    end
  end

  describe "device_info/0 caching" do
    setup do
      Capsule.forget_device_info()
      on_exit(fn -> Capsule.forget_device_info() end)
      :ok
    end

    test "populates on first call and returns the same map on the second" do
      # After forget, the cache slot is genuinely absent — assert directly on
      # the persistent_term so a change that stopped writing there fails here.
      assert :persistent_term.get({Capsule, :device_info}, :none) == :none

      first = Capsule.device_info()
      cached = :persistent_term.get({Capsule, :device_info}, :none)
      second = Capsule.device_info()

      # The persistent_term now holds the same map device_info/0 returned.
      assert cached == first
      # The second call gets the cached value, not a fresh computation.
      assert second == first
    end

    test "forget_device_info/0 re-arms the cache" do
      first = Capsule.device_info()
      Capsule.forget_device_info()
      assert :persistent_term.get({Capsule, :device_info}, :none) == :none

      # A re-populate follows the same code path and lands on the same value
      # on a host with no live device changes.
      second = Capsule.device_info()
      assert second == first
      assert :persistent_term.get({Capsule, :device_info}, :none) == second
    end
  end

  describe "fingerprint/3" do
    test "is stable when atom and string keys are mixed" do
      # Modern Erlang map iteration is content-stable, so a same-typed-keys
      # map produces the same iteration order no matter how it was built —
      # a shuffled-construction test is a false positive.
      #
      # Where iteration order actually differs is when the map mixes atom
      # keys and string keys: the atom :a and the string "a" hash to
      # different positions and iterate in a different sequence than a
      # same-shaped map with the atom/string spellings swapped. After
      # stringify_key normalises both to strings the two are semantically the
      # same defect, and only sort_by makes the two fingerprints match.
      atom_first = %{:screen => MyScreen, "invariant" => :parked}
      string_first = %{"screen" => MyScreen, :invariant => :parked}

      assert Capsule.fingerprint(:invariant, :mob, atom_first) ==
               Capsule.fingerprint(:invariant, :mob, string_first)
    end

    test "treats an atom key and a string key of the same name as identical" do
      assert Capsule.fingerprint(:invariant, :mob, %{screen: MyScreen}) ==
               Capsule.fingerprint(:invariant, :mob, %{"screen" => MyScreen})
    end

    test "changes when the defect-defining fields change" do
      base = %{invariant: :parked_screen_alive, screen: MyScreen}

      assert Capsule.fingerprint(:invariant, :mob, base) !=
               Capsule.fingerprint(:invariant, :mob, %{base | invariant: :orphaned_component})

      assert Capsule.fingerprint(:invariant, :mob, base) !=
               Capsule.fingerprint(:divergence, :mob, base)

      assert Capsule.fingerprint(:invariant, :mob, base) !=
               Capsule.fingerprint(:invariant, {:plugin, :some_plugin}, base)
    end

    test "does not change when build, device, id, or timestamp change" do
      base_key = %{invariant: :parked_screen_alive, screen: MyScreen}

      a =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :critical,
          fingerprint_key: base_key,
          now_ms: 1_756_566_663_418,
          build: %{
            mob: "0.7.0",
            mob_dev: "0.6.0",
            app: nil,
            commit: "abc",
            dirty: false,
            otp: "27",
            elixir: "1.20.0",
            loaded_md5: %{}
          },
          device: %{
            platform: :ios,
            os: "17.0",
            model: "iPhone SE",
            simulator: true,
            locale: "en_US",
            scale: 3.0
          }
        )

      b =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :critical,
          fingerprint_key: base_key,
          now_ms: 1_800_000_000_000,
          build: %{
            mob: "1.0.0",
            mob_dev: "1.0.0",
            app: nil,
            commit: "def",
            dirty: true,
            otp: "28",
            elixir: "1.21.0",
            loaded_md5: %{}
          },
          device: %{
            platform: :android,
            os: "14",
            model: "Pixel 7",
            simulator: false,
            locale: "en_CA",
            scale: 2.5
          }
        )

      assert a.fingerprint == b.fingerprint
      assert a.id != b.id
    end
  end

  describe "truncation" do
    test "clips long strings and tags them" do
      big = String.duplicate("x", 10_000)

      c =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{a: 1},
          evidence: %{blob: big}
        )

      assert {:truncated, :string, kept} = c.evidence.blob
      # Default limit is 4096
      assert byte_size(kept) == 4_096
    end

    test "clips long lists and tags them" do
      long = Enum.to_list(1..200)

      c =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{a: 1},
          evidence: %{items: long}
        )

      assert [_ | _] = kept = c.evidence.items
      # Kept 64 items plus a truncation tag
      assert length(kept) == 65
      assert List.last(kept) == {:truncated, :list, 200 - 64}
    end

    test "caps recursion depth so a deep map cannot exhaust the packager" do
      deep =
        Enum.reduce(1..50, %{leaf: :bottom}, fn _, acc -> %{nested: acc} end)

      c =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{a: 1},
          evidence: %{deep: deep}
        )

      # Walk down until we hit the truncation tag — must appear within a
      # bounded number of steps regardless of how deep the input was.
      depth = walk_until_truncated(c.evidence, 0)
      assert depth <= 12, "expected truncation within 12 levels, got #{depth}"
    end

    defp walk_until_truncated({:truncated, :depth}, d), do: d

    defp walk_until_truncated(m, d) when is_map(m) do
      m
      |> Map.values()
      |> Enum.map(&walk_until_truncated(&1, d + 1))
      |> Enum.max(fn -> d end)
    end

    defp walk_until_truncated(_v, d), do: d
  end

  describe "to_json/1" do
    test "produces the mob.defect/1 wire shape with stringified keys" do
      c =
        Capsule.new(
          kind: :invariant,
          owner: :mob,
          severity: :critical,
          fingerprint_key: %{invariant: :parked_screen_alive, screen: MyScreen}
        )

      json = Capsule.to_json(c)

      assert json["schema"] == "mob.defect/1"
      assert json["kind"] == "invariant"
      assert json["severity"] == "critical"
      assert json["owner"] == "mob"
      assert json["redaction"] == "applied"
      assert is_binary(json["id"]) and byte_size(json["id"]) > 0
      assert String.starts_with?(json["fingerprint"], "sha256:")
      # Every build key is a string, and the ones this test's BEAM populates
      # carry sensible values.
      assert Enum.all?(Map.keys(json["build"]), &is_binary/1)
      assert is_binary(json["build"]["otp"]) and byte_size(json["build"]["otp"]) > 0
      assert json["build"]["elixir"] == System.version()
      # Device platform is stringified — one of the three the schema names.
      assert json["device"]["platform"] in ["ios", "android", "host"]
    end

    test "encodes {:plugin, name} owner as \"plugin:name\"" do
      c =
        Capsule.new(
          kind: :beam_crash,
          owner: {:plugin, :mob_biometric},
          severity: :fatal,
          fingerprint_key: %{module: SomeMod}
        )

      assert Capsule.to_json(c)["owner"] == "plugin:mob_biometric"
    end

    test "renders unencodable evidence terms as strings so Jason will not crash" do
      c =
        Capsule.new(
          kind: :beam_crash,
          owner: :mob,
          severity: :fatal,
          fingerprint_key: %{module: SomeMod},
          evidence: %{pid: self(), ref: make_ref(), tuple: {:frame, {1, 2, 3, 4}}}
        )

      json = Capsule.to_json(c)

      # inspect(self()) produces "#PID<0.N.0>" — the reduced value keeps the
      # shape so a triager can still see there was a pid without any of the
      # process state the pid holds.
      assert String.starts_with?(json["evidence"]["pid"], "#PID<")
      assert String.starts_with?(json["evidence"]["ref"], "#Reference<")
      # A tuple survives as a list; every element is JSON-encodable
      assert json["evidence"]["tuple"] == ["frame", [1, 2, 3, 4]]
    end

    test "the whole wire form encodes with Jason" do
      c =
        Capsule.new(
          kind: :divergence,
          owner: :mob,
          severity: :warning,
          fingerprint_key: %{reason: :type, path: [0, 2]},
          evidence: %{ios: :button, android: :label}
        )

      json = c |> Capsule.to_json() |> Jason.encode!()
      decoded = Jason.decode!(json)
      assert decoded["schema"] == "mob.defect/1"
      assert decoded["fingerprint"] == c.fingerprint
    end
  end
end
