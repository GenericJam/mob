defmodule Mob.StateTest do
  use ExUnit.Case, async: false

  # Each test uses an isolated DETS file so tests don't share state.
  setup do
    tmp = Path.join(System.tmp_dir!(), "mob_state_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("MOB_DATA_DIR", tmp)
    on_exit(fn ->
      System.delete_env("MOB_DATA_DIR")
      # Close the DETS table if still open, then clean up.
      :dets.close(:mob_state)
      File.rm_rf!(tmp)
    end)
    # Stop any running State process from a prior test.
    case Process.whereis(Mob.State) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
    {:ok, _} = Mob.State.start_link()
    :ok
  end

  describe "get/2" do
    test "returns default when key is absent" do
      assert Mob.State.get(:missing) == nil
      assert Mob.State.get(:missing, :fallback) == :fallback
    end

    test "returns stored value after put" do
      Mob.State.put(:counter, 42)
      assert Mob.State.get(:counter) == 42
    end

    test "stores arbitrary terms — maps, lists, atoms" do
      Mob.State.put(:prefs, %{theme: :citrus, font_size: 16})
      assert Mob.State.get(:prefs) == %{theme: :citrus, font_size: 16}

      Mob.State.put(:tags, [:a, :b, :c])
      assert Mob.State.get(:tags) == [:a, :b, :c]
    end
  end

  describe "put/2" do
    test "overwrites existing value" do
      Mob.State.put(:x, 1)
      Mob.State.put(:x, 2)
      assert Mob.State.get(:x) == 2
    end

    test "persists across clean process stop" do
      Mob.State.put(:survived, true)
      pid = Process.whereis(Mob.State)
      GenServer.stop(pid)
      {:ok, _} = Mob.State.start_link()
      assert Mob.State.get(:survived) == true
    end

    test "persists across abrupt kill (SIGKILL simulation — no terminate callback)" do
      # dets.sync/1 is called after every write so data is on disk even when
      # the GenServer is killed before its terminate/2 can run dets.close/1.
      Mob.State.put(:kill_survived, :yes)
      pid = Process.whereis(Mob.State)
      Process.unlink(pid)        # don't cascade the kill to the test process
      Process.exit(pid, :kill)   # bypasses terminate/2, no dets.close
      Process.sleep(10)
      {:ok, _} = Mob.State.start_link()
      assert Mob.State.get(:kill_survived) == :yes
    end
  end

  describe "delete/1" do
    test "removes the key" do
      Mob.State.put(:temp, "ephemeral")
      Mob.State.delete(:temp)
      assert Mob.State.get(:temp) == nil
    end

    test "is a no-op for absent keys" do
      assert Mob.State.delete(:nonexistent) == :ok
    end
  end
end
