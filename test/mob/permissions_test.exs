defmodule Mob.PermissionsTest do
  use ExUnit.Case, async: true

  # request/2 is a thin wrapper over the request_permission NIF (not loaded on
  # the host), so the testable kernel is the arity/guard: it accepts any atom
  # capability (so plugin-registered caps pass through to the native registry)
  # and rejects non-atoms before reaching the NIF.

  test "accepts any atom capability (delegates validity to the native layer)" do
    # Atom args clear the guard and reach the NIF stub, which errors with
    # not-loaded on the host — proving the guard let the call through rather
    # than rejecting the capability in Elixir.
    for cap <- [:camera, :location, :some_plugin_cap] do
      assert_raise UndefinedFunctionError, fn -> Mob.Permissions.request(%{}, cap) end
    end
  end

  test "rejects a non-atom capability via the guard" do
    assert_raise FunctionClauseError, fn -> Mob.Permissions.request(%{}, "camera") end
  end
end
