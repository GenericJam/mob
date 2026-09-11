defmodule Mob.PostMortem.IOSTest do
  # async: false — Bus + Registry are process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mob.Defect.Bus
  alias Mob.PostMortem.IOS
  alias Mob.PostMortem.Registry

  # Fake NIF module used with sweep_with/1. Real callers use :mob_nif,
  # but on host we mock the native calls so the Elixir side can be
  # exercised without an iPhone.
  #
  # A test sets `:test_platform` and `:test_payloads` in the process
  # dictionary before calling sweep_with; the fake reads from there.
  # This gives per-test isolation without the extra ceremony of a mock
  # library.
  defmodule FakeNIF do
    def platform, do: Process.get(:test_platform, :host)
    def post_mortem_ios_drain, do: Process.get(:test_payloads, [])
  end

  setup do
    Bus.start()
    Bus.reset()
    Registry.start()
    Registry.reset()
    Bus.unsubscribe()
    {:ok, _ref} = Bus.subscribe()

    Process.put(:test_platform, :ios)
    Process.put(:test_payloads, [])
    :ok
  end

  defp crash_payload(opts \\ []) do
    %{
      kind: :native_crash,
      top_frame: %{
        binary: Keyword.get(opts, :binary, "MyApp"),
        offset: Keyword.get(opts, :offset, 12_345)
      },
      timestamp_ms: Keyword.get(opts, :timestamp_ms, 1_726_050_000_000),
      raw_json: Keyword.get(opts, :raw_json, ~s({"payload":true}))
    }
  end

  describe "platform gating" do
    test "returns [] on Android" do
      Process.put(:test_platform, :android)
      Process.put(:test_payloads, [crash_payload()])
      assert IOS.sweep_with(FakeNIF) == []
    end

    test "returns [] on host" do
      Process.put(:test_platform, :host)
      Process.put(:test_payloads, [crash_payload()])
      assert IOS.sweep_with(FakeNIF) == []
    end

    test "returns [] on iOS when the NIF is not loaded (default sweep/0)" do
      # `:mob_nif.platform/0` raises `:undef` in the host test suite,
      # so the safe_platform wrapper falls through to :host and sweep
      # returns [].
      assert IOS.sweep() == []
    end
  end

  describe "on iOS with payloads" do
    test "emits one capsule per payload with the mapped kind" do
      Process.put(:test_payloads, [
        crash_payload(),
        %{crash_payload() | kind: :anr, top_frame: %{binary: "MyApp", offset: 99}},
        %{crash_payload() | kind: :perf_regression, top_frame: %{binary: "MyApp", offset: 42}}
      ])

      capsules = IOS.sweep_with(FakeNIF)
      assert length(capsules) == 3

      kinds = Enum.map(capsules, & &1.kind)
      assert kinds == [:native_crash, :anr, :perf_regression]

      severities = Enum.map(capsules, & &1.severity)
      # native_crash → fatal, anr → critical, perf_regression → warning
      assert severities == [:fatal, :critical, :warning]

      # Each capsule reaches the subscribed test process.
      for capsule <- capsules do
        assert_receive {:mob_defect, ^capsule}, 500
      end
    end

    test "fingerprints group across timestamps but split across kind + top frame" do
      # Two crashes at the same top frame — different timestamps — group
      # into one fingerprint (a crash re-occurring in the same place).
      Process.put(:test_payloads, [
        crash_payload(timestamp_ms: 1_000),
        crash_payload(timestamp_ms: 2_000)
      ])

      [a, b] = IOS.sweep_with(FakeNIF)
      assert a.fingerprint == b.fingerprint
    end

    test "a different top-frame binary or offset produces a different fingerprint" do
      Process.put(:test_payloads, [
        crash_payload(binary: "MyApp", offset: 1),
        crash_payload(binary: "MyApp", offset: 2),
        crash_payload(binary: "OtherLib", offset: 1)
      ])

      [a, b, c] = IOS.sweep_with(FakeNIF)

      refute a.fingerprint == b.fingerprint
      refute a.fingerprint == c.fingerprint
      refute b.fingerprint == c.fingerprint
    end

    test "a different kind at the same top frame produces a different fingerprint" do
      # A hang and a crash at the same top frame are different classes
      # of defect even though the location matches — kind is on the
      # fingerprint key exactly to keep them apart.
      Process.put(:test_payloads, [
        crash_payload(),
        %{crash_payload() | kind: :anr}
      ])

      [a, b] = IOS.sweep_with(FakeNIF)
      refute a.fingerprint == b.fingerprint
    end

    test "raw_json rides on evidence" do
      Process.put(:test_payloads, [crash_payload(raw_json: ~s({"stuff":123}))])

      [capsule] = IOS.sweep_with(FakeNIF)
      assert capsule.evidence.raw_json == ~s({"stuff":123})
    end

    test "idempotent — same payload drained twice emits once" do
      # In production the NIF's own queue would be empty on the second
      # drain, so this scenario needs the fake to return the same payload
      # both times. The Registry is what stops the second emit — a
      # revert (removing Registry.mark_seen) would let both emit.
      payloads = [crash_payload()]
      Process.put(:test_payloads, payloads)

      first = IOS.sweep_with(FakeNIF)
      # sweep again with the same payloads still in the fake's return
      second = IOS.sweep_with(FakeNIF)

      assert length(first) == 1
      assert second == []
    end
  end

  describe "malformed input" do
    test "a non-map payload is silently skipped" do
      # A NIF bug that returned wrong shapes should not crash the
      # emit path — a caller sees fewer capsules, and the framework
      # keeps running.
      Process.put(:test_payloads, [:garbage, crash_payload(), nil])

      capsules = IOS.sweep_with(FakeNIF)
      assert length(capsules) == 1
    end

    test "a partial-shape map (missing required keys) is dropped without crashing the sweep" do
      # A payload that passes `is_map/1` but lacks `:top_frame` /
      # `:timestamp_ms` would previously reach `Defect.emit_metrickit_payload/1`,
      # crash with `FunctionClauseError` inside `Enum.flat_map/2`, and
      # take out the whole sweep — losing every later well-formed
      # payload in the same drain. The valid_shape? gate keeps the
      # sweep going.
      Process.put(:test_payloads, [
        %{kind: :native_crash},
        crash_payload(binary: "MyApp", offset: 111),
        %{kind: :anr, top_frame: %{binary: "OtherLib"}},
        crash_payload(binary: "MyApp", offset: 222)
      ])

      {capsules, log} =
        with_log(fn -> IOS.sweep_with(FakeNIF) end)
        |> then(fn {caps, log} -> {caps, log} end)

      # Two well-formed payloads through, two malformed dropped.
      assert length(capsules) == 2
      assert Enum.all?(capsules, &(&1.kind in [:native_crash, :anr]))

      # The drop path logs at :warning so an operator sees the bad
      # shape rather than getting silent data loss.
      assert log =~ "[warning]"
      assert log =~ "malformed MetricKit payload"
    end
  end
end
