defmodule Mob.Storage do
  @moduledoc """
  App-local file storage.

  Provides a thin Elixir wrapper over the device filesystem using named
  locations instead of raw paths. Basic file operations (`list`, `stat`,
  `delete`, `copy`, `move`, `read`, `write`) are pure `File.*` calls —
  no NIF overhead except for the initial `dir/1` path resolution.

  ## Locations

    - `:temp`        — ephemeral; may be purged by the OS at any time
    - `:documents`   — persists across app sessions; user-visible on iOS
                       when `UIFileSharingEnabled` is set (see `mix mob.enable`)
    - `:cache`       — persists until OS needs space; not user-visible
    - `:app_support` — persists, hidden from user, backed up on iOS

  ## Platform-specific storage

  See `Mob.Storage.Apple` and `Mob.Storage.Android` for saving to the native
  photo/media library and accessing platform-specific directories.

  ## Results

  Operations that can fail return `{:ok, value} | {:error, posix}`.
  `dir/1` raises on an unknown location atom.
  """

  @locations [:temp, :documents, :cache, :app_support]

  @doc "Resolve a location atom to its absolute path on the current device."
  @spec dir(atom()) :: String.t()
  def dir(location) when location in @locations do
    :mob_nif.storage_dir(location) |> IO.iodata_to_binary()
  end

  @doc """
  List all files in a location or an absolute path.

  Returns full paths, not just names.
  """
  @spec list(atom() | String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def list(location) when is_atom(location), do: list(dir(location))

  def list(path) when is_binary(path) do
    case File.ls(path) do
      {:ok, names} -> {:ok, Enum.map(names, &Path.join(path, &1))}
      error -> error
    end
  end

  @doc """
  Return metadata for a file.

      %{name: "clip.mp4", path: "/…/clip.mp4", size: 204_800,
        modified_at: ~U[2026-04-24 10:00:00Z]}
  """
  @spec stat(String.t()) :: {:ok, map()} | {:error, atom()}
  def stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        {:ok,
         %{
           name: Path.basename(path),
           path: path,
           size: size,
           modified_at: DateTime.from_unix!(mtime)
         }}

      error ->
        error
    end
  end

  @doc "Delete a file."
  @spec delete(String.t()) :: :ok | {:error, atom()}
  def delete(path), do: File.rm(path)

  @doc """
  Copy `src` to `dest`.

  `dest` may be a location atom (file is placed there keeping its basename)
  or a full absolute path.

  Returns `{:ok, dest_path}` on success.
  """
  @spec copy(String.t(), atom() | String.t()) :: {:ok, String.t()} | {:error, atom()}
  def copy(src, dest) when is_atom(dest) do
    copy(src, Path.join(dir(dest), Path.basename(src)))
  end

  def copy(src, dest) when is_binary(dest) do
    with :ok <- File.cp(src, dest), do: {:ok, dest}
  end

  @doc """
  Move `src` to `dest`.

  `dest` may be a location atom or a full absolute path.

  Returns `{:ok, dest_path}` on success.
  """
  @spec move(String.t(), atom() | String.t()) :: {:ok, String.t()} | {:error, atom()}
  def move(src, dest) when is_atom(dest) do
    move(src, Path.join(dir(dest), Path.basename(src)))
  end

  def move(src, dest) when is_binary(dest) do
    with :ok <- File.rename(src, dest), do: {:ok, dest}
  end

  @doc "Read a file's contents as a binary."
  @spec read(String.t()) :: {:ok, binary()} | {:error, atom()}
  def read(path), do: File.read(path)

  @doc """
  Write `data` to `path`.

  Returns `{:ok, path}` on success.
  """
  @spec write(String.t(), binary()) :: {:ok, String.t()} | {:error, atom()}
  def write(path, data) do
    with :ok <- File.write(path, data), do: {:ok, path}
  end

  @doc """
  Return the file extension including the leading dot, or `""` if none.

  No I/O — derived from the filename only.

      Mob.Storage.extension("/tmp/clip.mp4")   #=> ".mp4"
      Mob.Storage.extension("/tmp/notes")      #=> ""
  """
  @spec extension(String.t()) :: String.t()
  def extension(path), do: Path.extname(path)
end
