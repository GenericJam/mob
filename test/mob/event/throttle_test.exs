defmodule Mob.Event.ThrottleTest do
  use ExUnit.Case, async: true
  doctest Mob.Event.Throttle

  alias Mob.Event.Throttle

  describe "default_for/1" do
    test "scroll default is 30 Hz, 1 px delta" do
      d = Throttle.default_for(:scroll)
      assert d.throttle_ms == 33
      assert d.delta_threshold == 1
      assert d.leading == true
      assert d.trailing == true
    end

    test "pointer_move has trailing=false (only emit on movement)" do
      d = Throttle.default_for(:pointer_move)
      assert d.trailing == false
      assert d.delta_threshold == 4
    end

    test "pinch uses fractional delta threshold" do
      d = Throttle.default_for(:pinch)
      assert d.delta_threshold == 0.01
    end

    test "all event kinds have a default" do
      for kind <- [:scroll, :drag, :pinch, :rotate, :pointer_move] do
        d = Throttle.default_for(kind)
        assert is_map(d) and Map.has_key?(d, :throttle_ms)
        assert is_integer(d.throttle_ms) and d.throttle_ms >= 0
      end
    end

    test "unknown event kind raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> Throttle.default_for(:totally_unknown) end
    end
  end

  describe "parse/2 — pass-through values" do
    test "throttle override" do
      c = Throttle.parse(:scroll, throttle: 100)
      assert c.throttle_ms == 100
      assert c.delta_threshold == 1
    end

    test "debounce override" do
      c = Throttle.parse(:scroll, debounce: 200)
      assert c.debounce_ms == 200
      assert c.throttle_ms == 33
    end

    test "delta override" do
      c = Throttle.parse(:scroll, delta: 5)
      assert c.delta_threshold == 5
    end

    test "leading + trailing flags" do
      c = Throttle.parse(:scroll, leading: false, trailing: true)
      assert c.leading == false
      assert c.trailing == true
    end

    test "throttle: 0 is valid (means raw firing rate)" do
      c = Throttle.parse(:scroll, throttle: 0)
      assert c.throttle_ms == 0
    end

    test "multiple overrides combine" do
      c = Throttle.parse(:scroll, throttle: 50, debounce: 100, delta: 8)
      assert c.throttle_ms == 50
      assert c.debounce_ms == 100
      assert c.delta_threshold == 8
    end

    test "empty opts returns default" do
      assert Throttle.parse(:scroll, []) == Throttle.default_for(:scroll)
    end
  end

  describe "parse/2 — validation" do
    test "negative throttle raises" do
      assert_raise ArgumentError, ~r/throttle.*non-negative/, fn ->
        Throttle.parse(:scroll, throttle: -1)
      end
    end

    test "non-integer throttle raises" do
      assert_raise ArgumentError, ~r/throttle.*non-negative integer/, fn ->
        Throttle.parse(:scroll, throttle: 1.5)
      end
    end

    test "negative debounce raises" do
      assert_raise ArgumentError, ~r/debounce.*non-negative/, fn ->
        Throttle.parse(:scroll, debounce: -10)
      end
    end

    test "negative delta raises" do
      assert_raise ArgumentError, ~r/delta.*non-negative/, fn ->
        Throttle.parse(:scroll, delta: -1)
      end
    end

    test "non-numeric delta raises" do
      assert_raise ArgumentError, ~r/delta.*non-negative number/, fn ->
        Throttle.parse(:scroll, delta: "string")
      end
    end

    test "non-boolean leading raises" do
      assert_raise ArgumentError, ~r/leading.*boolean/, fn ->
        Throttle.parse(:scroll, leading: 1)
      end
    end

    test "non-boolean trailing raises" do
      assert_raise ArgumentError, ~r/trailing.*boolean/, fn ->
        Throttle.parse(:scroll, trailing: "yes")
      end
    end
  end

  describe "default?/2" do
    test "true for parsed default" do
      c = Throttle.parse(:scroll, [])
      assert Throttle.default?(:scroll, c)
    end

    test "false for any override" do
      c = Throttle.parse(:scroll, throttle: 100)
      refute Throttle.default?(:scroll, c)
    end

    test "different kinds have different defaults" do
      scroll_default = Throttle.default_for(:scroll)
      refute Throttle.default?(:pointer_move, scroll_default)
    end
  end

  describe "delta thresholds match documented values" do
    test "scroll defaults" do
      d = Throttle.default_for(:scroll)
      assert {d.throttle_ms, d.delta_threshold} == {33, 1}
    end

    test "drag defaults" do
      d = Throttle.default_for(:drag)
      assert {d.throttle_ms, d.delta_threshold} == {16, 1}
    end

    test "pinch defaults" do
      d = Throttle.default_for(:pinch)
      assert {d.throttle_ms, d.delta_threshold} == {16, 0.01}
    end

    test "rotate defaults" do
      d = Throttle.default_for(:rotate)
      assert {d.throttle_ms, d.delta_threshold} == {16, 1}
    end

    test "pointer_move defaults" do
      d = Throttle.default_for(:pointer_move)
      assert {d.throttle_ms, d.delta_threshold} == {33, 4}
    end
  end
end
