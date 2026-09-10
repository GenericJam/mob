defmodule Mob.InvariantTest do
  use ExUnit.Case, async: false

  alias Mob.Invariant
  alias Mob.Invariant.Violation

  setup do
    # Confirmation also requires a minimum candidate age. These tests sample
    # back-to-back, so the floor is removed here and asserted on its own below.
    Application.put_env(:mob, :invariant_min_candidate_age_us, 0)
    on_exit(fn -> Application.delete_env(:mob, :invariant_min_candidate_age_us) end)

    Invariant.reset()

    # `reset/0` deliberately keeps the built-ins registered — an earlier version
    # wiped them and left the framework's shipped diagnostics permanently off.
    # These tests want an empty registry, so they drop them explicitly; the
    # preservation itself is asserted in its own test below.
    for {name, _} <- [orphaned_component: 1, dead_screen_in_nav: 1],
        do: Invariant.unregister(name)

    on_exit(&Invariant.reset/0)
    :ok
  end

  test "reset/0 keeps the built-in checks registered" do
    # Wiping them left the shipped diagnostics off for the life of the owner,
    # and nothing re-installed them: `start/0` short-circuits once the table
    # exists.
    Invariant.reset()

    names =
      [:on_screen_stop, :periodic]
      |> Enum.flat_map(&Invariant.registered/1)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == [:dead_screen_in_nav, :orphaned_component]
  end

  defp register(name, check, opts \\ []) do
    Invariant.register(name,
      at: Keyword.get(opts, :at, :periodic),
      severity: Keyword.get(opts, :severity, :warning),
      check: check
    )
  end

  describe "the confirmation rule" do
    # The whole design. Every check reads live state from concurrently changing
    # processes, so a single sample sees transients constantly — a screen
    # mid-teardown looks exactly like a leak. Confirmation is deferred to the
    # NEXT sampling of the point, because that is the only version with real
    # time separation: an earlier version re-ran the check back-to-back and was
    # measured filtering ~0% of the transients it was written for.

    test "a violation seen once is held, not reported" do
      register(:once, fn _ctx -> {:violation, %{real: true}} end)

      assert Invariant.run(:periodic) == []
      assert Invariant.violation_count() == 0
    end

    test "a violation still there at the next sample is reported" do
      register(:persistent, fn _ctx -> {:violation, %{real: true}} end)

      assert Invariant.run(:periodic) == []

      assert [%Violation{invariant: :persistent, details: %{real: true}}] =
               Invariant.run(:periodic)

      assert Invariant.violation_count() == 1
    end

    test "a transient that has resolved by the next sample is never reported" do
      # The case the rule exists for: seen once, gone by the time anyone looks
      # again. This is what a screen mid-teardown produces.
      counter = :counters.new(1, [])

      register(:transient, fn _ctx ->
        case :counters.get(counter, 1) do
          0 ->
            :counters.add(counter, 1, 1)
            {:violation, %{gone_next_time: true}}

          _ ->
            :ok
        end
      end)

      assert Invariant.run(:periodic) == []
      assert Invariant.run(:periodic) == []
      assert Invariant.violation_count() == 0
    end

    test "a different violation at the next sample does not confirm the first" do
      # Two unrelated transients in a row must not vouch for each other, which
      # is why sameness is by fingerprint over the details rather than by the
      # check merely having failed twice.
      counter = :counters.new(1, [])

      register(:changing, fn _ctx ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        {:violation, %{which: n}}
      end)

      assert Invariant.run(:periodic) == []
      assert Invariant.run(:periodic) == []
      assert Invariant.violation_count() == 0
    end

    test "a candidate younger than the age floor is not confirmed yet" do
      # Sampling points are event-driven, so "the next sample" can arrive almost
      # immediately: the router stops screens in a tight loop, and a component
      # still being reaped was seen twice in under a millisecond. A real leak
      # persists and does not notice the wait.
      Application.put_env(:mob, :invariant_min_candidate_age_us, 5_000_000)
      register(:too_young, fn _ctx -> {:violation, %{stable: true}} end)

      assert Invariant.run(:periodic) == []
      assert Invariant.run(:periodic) == []
      assert Invariant.run(:periodic) == []
      assert Invariant.violation_count() == 0
    end

    test "an intermittent violation is reported once it repeats identically" do
      register(:same_again, fn _ctx -> {:violation, %{identity: :stable}} end)

      assert Invariant.run(:periodic) == []
      assert [%Violation{}] = Invariant.run(:periodic)

      # The candidate is consumed, so the next sighting starts over rather than
      # reporting the same violation on every subsequent sample.
      assert Invariant.run(:periodic) == []
    end
  end

  describe "isolation from the thing being observed" do
    test "a check that raises is reported, not propagated" do
      # A diagnostic that can crash the process sampling it is worse than no
      # diagnostic. `terminate/2` calls this.
      register(:explodes, fn _ctx -> raise "check blew up" end)

      # A check that keeps raising is a stable violation, so it confirms on the
      # second sample like any other.
      assert Invariant.run(:periodic) == []
      assert [%Violation{details: details}] = Invariant.run(:periodic)
      assert details.invariant_check_failed == :explodes
      assert details.exception == RuntimeError
    end

    test "a check that throws is reported, not propagated" do
      register(:throws, fn _ctx -> throw(:nope) end)

      Invariant.run(:periodic)
      assert [%Violation{details: %{invariant_check_failed: :throws}}] = Invariant.run(:periodic)
    end

    test "one broken check does not stop the others running" do
      register(:broken, fn _ctx -> raise "boom" end)
      register(:fine, fn _ctx -> {:violation, %{ok: true}} end)

      Invariant.run(:periodic)
      names = Invariant.run(:periodic) |> Enum.map(& &1.invariant) |> Enum.sort()
      assert names == [:broken, :fine]
    end
  end

  describe "registry" do
    test "checks only run at their own sampling point" do
      register(:at_stop, fn _ctx -> {:violation, %{}} end, at: :on_screen_stop)
      register(:at_periodic, fn _ctx -> {:violation, %{}} end, at: :periodic)

      Invariant.run(:periodic)
      Invariant.run(:on_screen_stop)

      assert [%Violation{invariant: :at_periodic}] = Invariant.run(:periodic)
      assert [%Violation{invariant: :at_stop}] = Invariant.run(:on_screen_stop)
    end

    test "re-registering a name replaces it rather than duplicating" do
      # A hot code push re-runs `install/0`; accumulating duplicates would
      # multiply both the cost and the reports.
      register(:same, fn _ctx -> :ok end)
      register(:same, fn _ctx -> {:violation, %{}} end)

      assert length(Invariant.registered(:periodic)) == 1
      Invariant.run(:periodic)
      assert [%Violation{invariant: :same}] = Invariant.run(:periodic)
    end

    test "unregister removes a check" do
      register(:temp, fn _ctx -> {:violation, %{}} end)
      Invariant.unregister(:temp)

      assert Invariant.run(:periodic) == []
    end

    test "severity and sampling point are carried onto the violation" do
      register(:tagged, fn _ctx -> {:violation, %{}} end, severity: :critical, at: :periodic)

      Invariant.run(:periodic)
      assert [%Violation{severity: :critical, at: :periodic}] = Invariant.run(:periodic)
    end
  end

  describe "violation store" do
    test "is bounded, keeping the newest" do
      # Same details each time so every pair confirms; the counter distinguishes
      # nothing, which is what makes 200 samples produce 100 recordings.
      register(:always, fn _ctx -> {:violation, %{stable: true}} end)

      for _ <- 1..400, do: Invariant.run(:periodic)

      assert Invariant.violation_count() == 128
      assert [%Violation{invariant: :always} | _] = Invariant.violations(1)
    end
  end

  describe "cost_us/2" do
    test "reports a number for the checks actually registered" do
      # Invariants ship in release builds, so the cost is real and has to be
      # measurable on the device that matters rather than estimated on a laptop.
      register(:cheap, fn _ctx -> :ok end)

      assert is_integer(Invariant.cost_us(:periodic))
      assert Invariant.cost_us(:periodic) >= 0
    end

    test "does not record violations while measuring" do
      # Measuring must not pollute the report stream, or a budget check on a
      # device becomes a source of defects.
      register(:violating, fn _ctx -> {:violation, %{}} end)

      Invariant.cost_us(:periodic)
      Invariant.cost_us(:periodic)
      assert Invariant.violation_count() == 0
    end
  end
end
