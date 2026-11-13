defmodule Mob.Event.TouchTest do
  use ExUnit.Case, async: true

  alias Mob.Event.Touch

  doctest Mob.Event.Touch

  describe "parse_opts/1" do
    test "moves default to off; turning them on keeps the 16 ms / 1 dp defaults" do
      assert %{moves: false} = Touch.parse_opts([])
      assert Touch.parse_opts(moves: true) == %{moves: true, throttle_ms: 16, delta: 1.0}
    end

    test "throttle or delta without moves: true raises instead of doing nothing" do
      assert_raise ArgumentError, ~r/add moves: true/, fn -> Touch.parse_opts(throttle: 8) end
      assert_raise ArgumentError, ~r/add moves: true/, fn -> Touch.parse_opts(delta: 2) end

      assert_raise ArgumentError, ~r/add moves: true/, fn ->
        Touch.parse_opts(moves: false, throttle: 8)
      end
    end

    test "rejects unknown options, including drag-style throttle options touch doesn't implement" do
      assert_raise ArgumentError, ~r/unknown on_touch option/, fn ->
        Touch.parse_opts(moves: true, debounce: 100)
      end
    end

    test "rejects values native can't apply" do
      assert_raise ArgumentError, ~r/moves: must be a boolean/, fn ->
        Touch.parse_opts(moves: :yes)
      end

      assert_raise ArgumentError, ~r/throttle: must be a non-negative integer/, fn ->
        Touch.parse_opts(moves: true, throttle: -1)
      end

      assert_raise ArgumentError, ~r/throttle: must be a non-negative integer/, fn ->
        Touch.parse_opts(moves: true, throttle: 1.5)
      end

      assert_raise ArgumentError, ~r/delta: must be a non-negative number/, fn ->
        Touch.parse_opts(moves: true, delta: -0.5)
      end
    end
  end

  describe "message/3" do
    test "has exactly the keys native sends, with native's number types" do
      {:touch, :pad, payload} =
        Touch.message(:pad, :up, pointer_id: 3, x: 1, y: 2, width: 40, height: 50, ts: 9)

      assert payload == %{
               phase: :up,
               pointer_id: 3,
               x: 1.0,
               y: 2.0,
               width: 40.0,
               height: 50.0,
               ts: 9
             }
    end

    test "ts defaults to this node's monotonic milliseconds" do
      before = System.monotonic_time(:millisecond)
      {:touch, _, %{ts: ts}} = Touch.message(:pad, :down)
      assert ts >= before and ts <= System.monotonic_time(:millisecond)
    end

    test "rejects a phase or field native never sends" do
      assert_raise FunctionClauseError, fn -> Touch.message(:pad, :began) end

      assert_raise ArgumentError, ~r/unknown touch field/, fn ->
        Touch.message(:pad, :down, pressure: 0.5)
      end
    end
  end
end
