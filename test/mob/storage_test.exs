defmodule Mob.StorageTest do
  use ExUnit.Case, async: true

  alias Mob.Storage

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_storage_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # ── extension/1 ─────────────────────────────────────────────────────────────

  describe "extension/1" do
    test "returns extension with leading dot" do
      assert Storage.extension("/tmp/clip.mp4") == ".mp4"
    end

    test "returns empty string when no extension" do
      assert Storage.extension("/tmp/notes") == ""
    end

    test "returns only the last extension for dotted names" do
      assert Storage.extension("/tmp/archive.tar.gz") == ".gz"
    end

    test "is case-preserving" do
      assert Storage.extension("/tmp/Photo.HEIC") == ".HEIC"
    end
  end

  # ── write/2 and read/1 ──────────────────────────────────────────────────────

  describe "write/2 and read/1" do
    test "round-trips arbitrary binary data", %{dir: dir} do
      path = Path.join(dir, "data.bin")
      assert {:ok, ^path} = Storage.write(path, <<0, 1, 2, 255>>)
      assert {:ok, <<0, 1, 2, 255>>} = Storage.read(path)
    end

    test "write returns the path on success", %{dir: dir} do
      path = Path.join(dir, "out.txt")
      assert {:ok, ^path} = Storage.write(path, "hello")
    end

    test "read returns error for missing file" do
      assert {:error, :enoent} = Storage.read("/nonexistent/mob_storage_test_file.txt")
    end

    test "write overwrites existing content", %{dir: dir} do
      path = Path.join(dir, "overwrite.txt")
      Storage.write(path, "first")
      Storage.write(path, "second")
      assert {:ok, "second"} = Storage.read(path)
    end
  end

  # ── stat/1 ──────────────────────────────────────────────────────────────────

  describe "stat/1" do
    test "returns name, path, size and modified_at for an existing file", %{dir: dir} do
      path = Path.join(dir, "stat_me.txt")
      Storage.write(path, "hello")
      assert {:ok, stat} = Storage.stat(path)
      assert stat.name == "stat_me.txt"
      assert stat.path == path
      assert stat.size == 5
      assert %DateTime{} = stat.modified_at
    end

    test "size reflects actual byte count", %{dir: dir} do
      path = Path.join(dir, "sized.bin")
      Storage.write(path, <<1, 2, 3, 4, 5, 6, 7, 8>>)
      assert {:ok, %{size: 8}} = Storage.stat(path)
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Storage.stat("/nonexistent/mob_storage_test_file.txt")
    end
  end

  # ── list/1 ──────────────────────────────────────────────────────────────────

  describe "list/1" do
    test "returns full paths for all files in a directory", %{dir: dir} do
      Storage.write(Path.join(dir, "a.txt"), "a")
      Storage.write(Path.join(dir, "b.txt"), "b")
      assert {:ok, paths} = Storage.list(dir)
      assert length(paths) == 2
      assert Enum.all?(paths, &String.starts_with?(&1, dir))
    end

    test "returns empty list for an empty directory", %{dir: dir} do
      assert {:ok, []} = Storage.list(dir)
    end

    test "returns error for a missing directory" do
      assert {:error, :enoent} = Storage.list("/nonexistent/mob_storage_test_dir")
    end
  end

  # ── delete/1 ────────────────────────────────────────────────────────────────

  describe "delete/1" do
    test "removes the file", %{dir: dir} do
      path = Path.join(dir, "gone.txt")
      Storage.write(path, "bye")
      assert :ok = Storage.delete(path)
      assert {:error, :enoent} = Storage.read(path)
    end

    test "returns error for a missing file" do
      assert {:error, :enoent} = Storage.delete("/nonexistent/mob_storage_test_file.txt")
    end
  end

  # ── copy/2 ──────────────────────────────────────────────────────────────────

  describe "copy/2" do
    test "copies file to dest path and returns dest", %{dir: dir} do
      src = Path.join(dir, "src.txt")
      dest = Path.join(dir, "dest.txt")
      Storage.write(src, "original")
      assert {:ok, ^dest} = Storage.copy(src, dest)
      assert {:ok, "original"} = Storage.read(dest)
    end

    test "leaves the source intact after copy", %{dir: dir} do
      src = Path.join(dir, "src.txt")
      dest = Path.join(dir, "dest.txt")
      Storage.write(src, "original")
      Storage.copy(src, dest)
      assert {:ok, "original"} = Storage.read(src)
    end

    test "returns error when source is missing", %{dir: dir} do
      assert {:error, :enoent} = Storage.copy("/nonexistent/file.txt", Path.join(dir, "dest.txt"))
    end
  end

  # ── move/2 ──────────────────────────────────────────────────────────────────

  describe "move/2" do
    test "moves file to dest path and returns dest", %{dir: dir} do
      src = Path.join(dir, "move_src.txt")
      dest = Path.join(dir, "move_dest.txt")
      Storage.write(src, "moving")
      assert {:ok, ^dest} = Storage.move(src, dest)
      assert {:ok, "moving"} = Storage.read(dest)
    end

    test "source no longer exists after move", %{dir: dir} do
      src = Path.join(dir, "move_src.txt")
      dest = Path.join(dir, "move_dest.txt")
      Storage.write(src, "moving")
      Storage.move(src, dest)
      assert {:error, :enoent} = Storage.read(src)
    end
  end
end
