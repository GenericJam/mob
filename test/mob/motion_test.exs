defmodule Mob.MotionTest do
  use ExUnit.Case, async: true

  # start/2 itself calls into the NIF (unavailable on the host), so we test its
  # pure kernel, parse_opts/1 — where the sensor list + interval are resolved.
  describe "parse_opts/1" do
    test "defaults to accelerometer + gyro at 100ms" do
      assert Mob.Motion.parse_opts([]) == {["accelerometer", "gyro"], 100}
    end

    test "adds magnetometer when requested (the compass path)" do
      assert Mob.Motion.parse_opts(sensors: [:accelerometer, :gyro, :magnetometer]) ==
               {["accelerometer", "gyro", "magnetometer"], 100}
    end

    test "honors a magnetometer-only request" do
      assert Mob.Motion.parse_opts(sensors: [:magnetometer]) == {["magnetometer"], 100}
    end

    test "honors a custom interval while keeping default sensors" do
      assert Mob.Motion.parse_opts(interval_ms: 150) == {["accelerometer", "gyro"], 150}
    end

    test "preserves requested sensor order as strings" do
      assert Mob.Motion.parse_opts(sensors: [:gyro, :magnetometer, :accelerometer]) ==
               {["gyro", "magnetometer", "accelerometer"], 100}
    end
  end
end
