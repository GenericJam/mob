defmodule Mob.DefectTest do
  # Not async — the bus and invariant registry are process-global.
  use ExUnit.Case, async: false

  alias Mob.Defect
  alias Mob.Defect.Bus
  alias Mob.Invariant

  setup do
    Bus.start()
    Bus.reset()
    Invariant.start()
    Invariant.reset()
    Bus.unsubscribe()
    :ok
  end

  describe "emit_invariant_violation/1" do
    test "a confirmed invariant violation lands on the defect bus as :invariant/:mob" do
      # Subscribe first so the fanout reaches this test process.
      Bus.subscribe()

      # A hand-built violation to avoid depending on the invariant maturation
      # timing here — the wiring in `Mob.Invariant.record/1` uses this same
      # entry point, and there is a separate test below that goes through the
      # full registry path.
      violation = %Invariant.Violation{
        invariant: :leaked_component,
        severity: :critical,
        at: :on_screen_stop,
        details: %{pid: :c.pid(0, 100, 0), count: 3},
        screen: __MODULE__.FakeScreen,
        monotonic_us: System.monotonic_time(:microsecond)
      }

      capsule = Defect.emit_invariant_violation(violation)

      assert capsule.kind == :invariant
      assert capsule.owner == :mob
      assert capsule.severity == :critical
      assert capsule.evidence.invariant == :leaked_component
      assert capsule.evidence.screen == __MODULE__.FakeScreen

      assert_receive {:mob_defect, ^capsule}, 500
    end

    test "two violations of the same invariant on the same screen share a fingerprint" do
      v1 = %Invariant.Violation{
        invariant: :leaked_component,
        severity: :critical,
        at: :on_screen_stop,
        details: %{count: 1},
        screen: __MODULE__.FakeScreen,
        monotonic_us: 0
      }

      v2 = %{v1 | details: %{count: 2}}

      a = Defect.emit_invariant_violation(v1)
      b = Defect.emit_invariant_violation(v2)

      assert a.fingerprint == b.fingerprint
    end

    test "the same invariant on a different screen fingerprints differently" do
      v1 = %Invariant.Violation{
        invariant: :leaked_component,
        severity: :critical,
        at: :on_screen_stop,
        details: %{count: 1},
        screen: __MODULE__.FakeScreenA,
        monotonic_us: 0
      }

      v2 = %{v1 | screen: __MODULE__.FakeScreenB}

      a = Defect.emit_invariant_violation(v1)
      b = Defect.emit_invariant_violation(v2)

      assert a.fingerprint != b.fingerprint
    end
  end

  describe "emit_divergence/2" do
    test "reports a divergence as :divergence/:mob with fixture on evidence" do
      Bus.subscribe()

      div = %{path: [0, 2], reason: :type, ios: :button, android: :label}
      capsule = Defect.emit_divergence(div, fixture: :counter_screen)

      assert capsule.kind == :divergence
      assert capsule.owner == :mob
      assert capsule.severity == :warning
      assert capsule.evidence.reason == :type
      assert capsule.evidence.ios == :button
      assert capsule.evidence.android == :label
      assert capsule.evidence.fixture == :counter_screen

      assert_receive {:mob_defect, ^capsule}, 500
    end

    test "same fixture + reason + path fingerprint the same across tree-value changes" do
      div_a = %{path: [0, 2], reason: :type, ios: :button, android: :label}
      div_b = %{path: [0, 2], reason: :type, ios: :text_field, android: :label}

      a = Defect.emit_divergence(div_a, fixture: :counter_screen)
      b = Defect.emit_divergence(div_b, fixture: :counter_screen)

      # Evidence differs; fingerprint does not.
      assert a.fingerprint == b.fingerprint
    end

    test "a different fixture, path, or reason changes the fingerprint" do
      base = %{path: [0, 2], reason: :type, ios: :button, android: :label}

      a = Defect.emit_divergence(base, fixture: :counter_screen)
      b = Defect.emit_divergence(base, fixture: :other_screen)
      c = Defect.emit_divergence(%{base | path: [1]}, fixture: :counter_screen)
      d = Defect.emit_divergence(%{base | reason: :label}, fixture: :counter_screen)

      # Each of the three changes moves the fingerprint away from the base.
      assert a.fingerprint != b.fingerprint
      assert a.fingerprint != c.fingerprint
      assert a.fingerprint != d.fingerprint
    end
  end

  describe "wiring: invariant registry → bus" do
    test "a confirmed violation on the registry emits a defect on the bus" do
      Bus.subscribe()

      # Zero the maturation age so `Mob.Invariant.run/2` confirms on the second
      # sample immediately — the same knob the invariant test suite uses.
      Application.put_env(:mob, :invariant_min_candidate_age_us, 0)

      Invariant.register(:test_ping,
        at: :periodic,
        severity: :critical,
        check: fn _ -> {:violation, %{seen: 1}} end
      )

      Invariant.run(:periodic)
      # Second run must return a confirmed violation, which calls record/1
      # which emits the capsule.
      confirmed = Invariant.run(:periodic)
      assert length(confirmed) == 1

      assert_receive {:mob_defect, capsule}, 500
      assert capsule.kind == :invariant
      assert capsule.owner == :mob
      assert capsule.evidence.invariant == :test_ping

      Invariant.unregister(:test_ping)
      Application.delete_env(:mob, :invariant_min_candidate_age_us)
    end
  end
end
