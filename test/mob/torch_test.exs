defmodule Mob.TorchTest do
  use ExUnit.Case, async: true

  # set/2 calls into the NIF (unavailable on the host), so we test the pure
  # wire-atom mapping that decides what the native layer receives, plus the
  # boolean guard.
  describe "state_atom/1" do
    test "true maps to :on" do
      assert Mob.Torch.state_atom(true) == :on
    end

    test "false maps to :off" do
      assert Mob.Torch.state_atom(false) == :off
    end
  end

  describe "set/2 guard" do
    test "rejects a non-boolean before reaching the NIF" do
      assert_raise FunctionClauseError, fn -> Mob.Torch.set(%{}, :yes) end
    end
  end
end
