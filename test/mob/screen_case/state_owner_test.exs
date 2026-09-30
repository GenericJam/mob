defmodule Mob.ScreenCase.StateOwnerTest do
  # async: false — these assert on the single globally named `Mob.State` and
  # the global MOB_DATA_DIR, which async `Mob.ScreenCase` tests also check out.
  use ExUnit.Case, async: false

  alias Mob.ScreenCase.StateOwner
  alias Mob.Test.ProcessHelpers

  # The owner is a long-lived singleton; stopping it (it restarts lazily)
  # keeps a failure that skips a check-in from leaking holders into the
  # next test.
  defp reset do
    ProcessHelpers.stop_if_running(StateOwner)
    ProcessHelpers.stop_if_running(Mob.State)
  end

  setup do
    reset()
    prev = System.get_env("MOB_DATA_DIR")

    on_exit(fn ->
      reset()
      if prev, do: System.put_env("MOB_DATA_DIR", prev), else: System.delete_env("MOB_DATA_DIR")
    end)

    %{prev_env: prev}
  end

  defp checkout_all_at_once(n) do
    parent = self()

    tasks =
      for _ <- 1..n do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          {StateOwner.checkout(), Process.whereis(Mob.State)}
        end)
      end

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid})
    for %Task{pid: pid} <- tasks, do: send(pid, :go)
    Enum.map(tasks, &Task.await/1)
  end

  test "concurrent first checkouts all succeed and share one store" do
    results = checkout_all_at_once(40)

    assert Enum.all?(results, &match?({{:ok, _ref}, pid} when is_pid(pid), &1))
    assert results |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1

    for {{:ok, ref}, _} <- results, do: StateOwner.checkin(ref)
  end

  test "the store survives until the last holder checks in", %{prev_env: prev} do
    {:ok, first} = StateOwner.checkout()
    {:ok, second} = StateOwner.checkout()
    store = Process.whereis(Mob.State)
    data_dir = System.get_env("MOB_DATA_DIR")

    Mob.State.put(:shared, :yes)
    :ok = StateOwner.checkin(first)

    assert Process.whereis(Mob.State) == store
    assert Mob.State.get(:shared) == :yes

    :ok = StateOwner.checkin(second)

    assert Process.whereis(Mob.State) == nil
    assert System.get_env("MOB_DATA_DIR") == prev
    refute File.exists?(data_dir)
  end

  test "a store started by something else is shared but never stopped" do
    tmp = ProcessHelpers.tmp_path("mob_state_owner_external")
    File.mkdir_p!(tmp)
    System.put_env("MOB_DATA_DIR", tmp)
    {:ok, external} = Mob.State.start_link()
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, ref} = StateOwner.checkout()
    assert Process.whereis(Mob.State) == external
    assert System.get_env("MOB_DATA_DIR") == tmp
    :ok = StateOwner.checkin(ref)

    assert Process.whereis(Mob.State) == external
    assert System.get_env("MOB_DATA_DIR") == tmp
  end

  test "a store that died while held is replaced on the next checkout" do
    {:ok, first} = StateOwner.checkout()
    store = Process.whereis(Mob.State)
    Process.exit(store, :kill)
    ProcessHelpers.await_exit(store)

    {:ok, second} = StateOwner.checkout()
    replacement = Process.whereis(Mob.State)

    assert is_pid(replacement)
    refute replacement == store
    assert Mob.State.put(:after_restart, 1) == :ok

    for ref <- [first, second], do: StateOwner.checkin(ref)
    assert Process.whereis(Mob.State) == nil
  end
end
