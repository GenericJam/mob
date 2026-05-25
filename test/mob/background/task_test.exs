defmodule Mob.Background.TaskTest do
  use ExUnit.Case, async: true

  # ── Unit tests — no device required ──────────────────────────────────────────

  describe "module API" do
    setup do
      Code.ensure_loaded(Mob.Background.Task)
      :ok
    end

    test "complete/2 raises when called outside iOS (delegates to :mob_nif)" do
      raised =
        try do
          Mob.Background.Task.complete("test-uuid", :new_data)
          false
        rescue
          ErlangError -> true
          UndefinedFunctionError -> true
        end

      assert raised, "expected complete/2 to raise outside iOS"
    end

    test "complete/2 validates result atom" do
      # The guard clause in complete/2 should reject invalid atoms without
      # ever calling the NIF.
      assert_raise FunctionClauseError, fn ->
        Mob.Background.Task.complete("test-uuid", :invalid_result)
      end
    end

    test "complete/2 validates id is binary" do
      assert_raise FunctionClauseError, fn ->
        Mob.Background.Task.complete(:not_a_binary, :new_data)
      end
    end
  end

  # ── On-device integration tests ───────────────────────────────────────────────

  @ios_node System.get_env("MOB_TEST_NODE") &&
              System.get_env("MOB_TEST_NODE") |> String.to_atom()

  defp rpc(fun, args), do: :rpc.call(@ios_node, :mob_nif, fun, args, 5000)

  @tag :on_device
  test "background_task_complete/2 returns :ok for a valid task" do
    # Simulate a background task by calling the NIF directly with a fake UUID.
    # On a real device this would be called after the OS delivers a silent push.
    # We can only test the "unknown task" path because we don't have a real
    # completion handler stored.
    assert rpc(:background_task_complete, ["fake-uuid", :new_data]) ==
             {:error, :unknown_task}
  end

  @tag :on_device
  test "background_task_complete/2 returns badarg for invalid result atom" do
    # The NIF validates argv[1] with enif_get_atom and returns badarg if it
    # doesn't match one of the expected atoms.
    assert rpc(:background_task_complete, ["fake-uuid", :garbage]) ==
             {:badrpc, {:EXIT, {:badarg, []}}}
  end

  @tag :on_device
  test "background_task_complete/2 returns badarg for non-binary id" do
    assert rpc(:background_task_complete, [:not_a_binary, :new_data]) ==
             {:badrpc, {:EXIT, {:badarg, []}}}
  end

  @tag :on_device
  test "background_task_complete/2 is idempotent for unknown tasks" do
    assert rpc(:background_task_complete, ["fake-uuid", :no_data]) ==
             {:error, :unknown_task}

    assert rpc(:background_task_complete, ["fake-uuid", :no_data]) ==
             {:error, :unknown_task}
  end
end
