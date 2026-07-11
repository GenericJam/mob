defmodule Mob.MotionAccelTest do
  use ExUnit.Case, async: true

  # The accel normalization lives inside the CoreMotion callback in ios/mob_nif.m:
  # ObjC reading live hardware, so no host test can exercise it — and the iOS
  # Simulator delivers no CMMotionManager data, so it isn't integration-testable off
  # a physical device either. But the CONVENTION it must honor is a hard contract:
  # `Mob.Motion` promises `accel` in m/s² with Android's sign — specific force, i.e.
  # +g on the up-axis at rest. CoreMotion natively reports G (~1.0) with the opposite
  # gravity sign (its gravity vector points down), so the iOS NIF MUST subtract
  # gravity AND scale by g. A silent revert to `+ gravity` (iOS's own convention) or
  # a dropped scale factor makes every tilt/shake UI wrong on iOS — the exact 0.7.x
  # regression this guards. Same source-level strategy as Mob.NifDeclarationTest:
  # pin a native invariant that runtime tests can't reach.
  @objc Path.expand("../../ios/mob_nif.m", __DIR__)
  @g "9.80665"

  describe "iOS accel convention (ios/mob_nif.m source guard)" do
    setup do
      %{lines: @objc |> File.read!() |> String.split("\n")}
    end

    for axis <- ~w(x y z) do
      test "a#{axis} = (userAcceleration.#{axis} - gravity.#{axis}) * g", %{lines: lines} do
        axis = unquote(axis)

        line = Enum.find(lines, &(&1 =~ ~r/\bdouble a#{axis}\s*=/))
        assert line, "no `double a#{axis} = ...` line in ios/mob_nif.m"

        assert line =~ "userAcceleration.#{axis}",
               "a#{axis} must derive from userAcceleration.#{axis}: #{line}"

        # SUBTRACT gravity, never add it. `+ motion.gravity` is iOS's own
        # total-acceleration convention — sign-flipped from Android — and is the bug.
        assert line =~ ~r/-\s*motion\.gravity\.#{axis}/,
               "a#{axis} must SUBTRACT gravity (Android specific-force sign), not add: #{line}"

        refute line =~ ~r/\+\s*motion\.gravity\.#{axis}/,
               "a#{axis} must not ADD gravity (that reintroduces the inverted-sign bug): #{line}"

        # Convert CoreMotion's G to the documented m/s².
        assert line =~ @g,
               "a#{axis} must scale G to m/s² (× #{@g}): #{line}"
      end
    end
  end
end
