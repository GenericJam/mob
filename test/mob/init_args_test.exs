defmodule Mob.InitArgsTest do
  # async: false — mutates the shared MOB_DATA_DIR environment variable.
  use ExUnit.Case, async: false

  alias Mob.InitArgs

  setup do
    prev = System.get_env("MOB_DATA_DIR")
    dir = Mob.Test.ProcessHelpers.tmp_path("mob_init_args_test")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    System.put_env("MOB_DATA_DIR", dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      if prev, do: System.put_env("MOB_DATA_DIR", prev), else: System.delete_env("MOB_DATA_DIR")
    end)

    {:ok, dir: dir}
  end

  defp file(dir), do: Path.join(dir, "mob_init_args")

  test "the file lives in MOB_DATA_DIR, where the launchers read it", %{dir: dir} do
    assert InitArgs.path() == file(dir)
  end

  test "write/1 stores space-separated args that read/1 returns", %{dir: dir} do
    args = ["-proto_dist", "inet_tls", "-ssl_dist_optfile", "/data/ssl.conf"]
    assert InitArgs.write(args) == :ok
    assert File.read!(file(dir)) == "-proto_dist inet_tls -ssl_dist_optfile /data/ssl.conf\n"
    assert InitArgs.read() == args
  end

  test "read/1 splits a hand-written file the way the launcher does", %{dir: dir} do
    File.write!(file(dir), "  -a\tb\r\n-c\0d  ")
    assert InitArgs.read() == ["-a", "b", "-c", "d"]
  end

  test "read/1 is [] without a file" do
    assert InitArgs.read() == []
  end

  test "without MOB_DATA_DIR there is no path, nothing to read and nothing written" do
    System.delete_env("MOB_DATA_DIR")
    assert InitArgs.path() == nil
    assert InitArgs.read() == []
    assert InitArgs.write(["-a"]) == {:error, :no_data_dir}
    assert InitArgs.clear() == :ok
  end

  describe "write/1 refuses an argument the launcher would split or mangle" do
    for {label, bad} <- [
          empty: "",
          space: "a b",
          tab: "a\tb",
          newline: "a\nb",
          carriage_return: "a\rb",
          vertical_tab: "a\vb",
          form_feed: "a\fb",
          nul: "a\0b"
        ] do
      test "#{label}", %{dir: dir} do
        :ok = InitArgs.write(["-keep"])
        assert InitArgs.write(["-ok", unquote(bad)]) == {:error, {:invalid_arg, unquote(bad)}}
        assert File.read!(file(dir)) == "-keep\n"
      end
    end

    test "a non-binary leaves an existing file untouched", %{dir: dir} do
      :ok = InitArgs.write(["-keep"])

      for bad <- [:atom, ~c"chars", nil, false] do
        assert InitArgs.write(["-ok", bad]) == {:error, {:invalid_arg, bad}}
        assert File.read!(file(dir)) == "-keep\n"
      end
    end
  end

  describe "the launcher's limits" do
    test "63 args are written; 64 are refused and the file is left alone", %{dir: dir} do
      sixty_three = List.duplicate("a", 63)
      assert InitArgs.write(sixty_three) == :ok
      assert InitArgs.read() == sixty_three

      assert InitArgs.write(List.duplicate("a", 64)) == {:error, {:too_many_args, 64}}
      assert File.read!(file(dir)) == Enum.join(sixty_three, " ") <> "\n"
    end

    test "a file of 1023 bytes is written; 1024 is refused", %{dir: dir} do
      # One arg plus the trailing newline: 1022 + 1 = 1023 bytes.
      fits = String.duplicate("x", 1022)
      assert InitArgs.write([fits]) == :ok
      assert byte_size(File.read!(file(dir))) == 1023

      too_big = String.duplicate("x", 1023)
      assert InitArgs.write([too_big]) == {:error, {:too_large, 1024}}
      assert File.read!(file(dir)) == fits <> "\n"
    end
  end

  test "write/1 replaces the file rather than rewriting it in place", %{dir: dir} do
    :ok = InitArgs.write(["-old"])
    # A reader that opened the old file (a launch racing the write) keeps
    # seeing the old contents in full: the new one is renamed over it.
    {:ok, reader} = File.open(file(dir), [:read])
    :ok = InitArgs.write(["-new"])
    assert IO.read(reader, :eof) == "-old\n"
    File.close(reader)

    assert File.read!(file(dir)) == "-new\n"
    assert File.ls!(dir) == ["mob_init_args"]
  end

  test "write([]) and clear/0 remove the file", %{dir: dir} do
    :ok = InitArgs.write(["-a"])
    assert InitArgs.write([]) == :ok
    refute File.exists?(file(dir))
    assert InitArgs.write([]) == :ok

    :ok = InitArgs.write(["-a"])
    assert InitArgs.clear() == :ok
    refute File.exists?(file(dir))
    assert InitArgs.clear() == :ok
  end
end
