defmodule Mob.StorageTest do
  use ExUnit.Case, async: true

  alias Mob.Storage

  setup do
    dir = Mob.Test.ProcessHelpers.tmp_path("mob_storage")
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
      assert Enum.count(paths) == 2
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

  # ── exclude_from_backup/1 and excluded_from_backup?/1 ───────────────────────

  describe "backup exclusion off device" do
    # The host has no backup and no NIF: both calls answer as a platform that
    # backs nothing up would, so app startup code can call them unguarded.
    test "exclude_from_backup/1 is :ok and leaves the directory as it was", %{dir: dir} do
      File.write!(Path.join(dir, "pack.db"), "x")
      assert Storage.exclude_from_backup(dir) == :ok
      assert File.read!(Path.join(dir, "pack.db")) == "x"
    end

    test "excluded_from_backup?/1 is false, even after excluding", %{dir: dir} do
      :ok = Storage.exclude_from_backup(dir)
      refute Storage.excluded_from_backup?(dir)
    end

    test "a missing path is {:error, :enoent}, as on a device", %{dir: dir} do
      assert Storage.exclude_from_backup(Path.join(dir, "not_yet")) == {:error, :enoent}
    end
  end

  describe "backup exclusion on a native build that predates it" do
    # The phone's Erlang stub is current but its native library is older: the
    # stub raises :not_loaded, as mob_nif.erl's does. On iOS the path is still
    # backed up, so the call must not claim success.
    defmodule OldIosNif do
      def platform, do: :ios
      def storage_exclude_from_backup(_path), do: :erlang.nif_error(:not_loaded)
      def storage_excluded_from_backup(_path), do: :erlang.nif_error(:not_loaded)
    end

    defmodule OldAndroidNif do
      def platform, do: :android
      def storage_exclude_from_backup(_path), do: :erlang.nif_error(:not_loaded)
    end

    # An older stub module: platform/0 but no storage exports at all.
    defmodule OlderIosModule do
      def platform, do: :ios
    end

    defmodule CurrentIosNif do
      def platform, do: :ios
      def storage_exclude_from_backup(_path), do: :ok
      def storage_excluded_from_backup(_path), do: true
    end

    test "iOS without the NIF says it couldn't, instead of :ok", %{dir: dir} do
      assert Storage.exclude_from_backup(dir, OldIosNif) == {:error, :unsupported}
      refute Storage.excluded_from_backup?(dir, OldIosNif)
    end

    test "iOS whose module lacks the export says it couldn't too", %{dir: dir} do
      assert Storage.exclude_from_backup(dir, OlderIosModule) == {:error, :unsupported}
      refute Storage.excluded_from_backup?(dir, OlderIosModule)
    end

    test "Android without the NIF is :ok (nothing is backed up there)", %{dir: dir} do
      assert Storage.exclude_from_backup(dir, OldAndroidNif) == :ok
    end

    test "a missing path is still {:error, :enoent}", %{dir: dir} do
      assert Storage.exclude_from_backup(Path.join(dir, "nope"), OldIosNif) == {:error, :enoent}
    end

    test "a current iOS NIF answers for itself", %{dir: dir} do
      assert Storage.exclude_from_backup(dir, CurrentIosNif) == :ok
      assert Storage.excluded_from_backup?(dir, CurrentIosNif)
    end
  end
end
