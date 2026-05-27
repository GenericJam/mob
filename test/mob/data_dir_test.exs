defmodule Mob.DataDirTest do
  # async: false — mutates the shared MOB_DATA_DIR environment variable.
  use ExUnit.Case, async: false

  setup do
    prev = System.get_env("MOB_DATA_DIR")
    on_exit(fn -> restore("MOB_DATA_DIR", prev) end)
    :ok
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, val), do: System.put_env(var, val)

  test "data_dir/0 returns MOB_DATA_DIR and creates it" do
    base = Path.join(System.tmp_dir!(), "mob_data_dir_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    System.put_env("MOB_DATA_DIR", base)

    assert Mob.data_dir() == base
    assert File.dir?(base)
  after
    :ok
  end

  test "data_dir/0 falls back to $HOME when MOB_DATA_DIR is unset" do
    System.delete_env("MOB_DATA_DIR")
    assert Mob.data_dir() == System.get_env("HOME")
  end

  test "data_dir/1 returns and creates a subdirectory" do
    base = Path.join(System.tmp_dir!(), "mob_data_dir_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    System.put_env("MOB_DATA_DIR", base)

    sub = Mob.data_dir("audio_cache")
    assert sub == Path.join(base, "audio_cache")
    assert File.dir?(sub)
  end
end
