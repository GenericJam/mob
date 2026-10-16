defmodule Mob.Storage do
  @moduledoc """
  App-local file storage.

  Provides a thin Elixir wrapper over the device filesystem using named
  locations instead of raw paths. Basic file operations (`list`, `stat`,
  `delete`, `copy`, `move`, `read`, `write`) are pure `File.*` calls —
  no NIF overhead except for the initial `dir/1` path resolution.

  ## Locations

    - `:temp`        — ephemeral; may be purged by the OS at any time
    - `:documents`   — persists across app sessions; backed up to iCloud on
                       iOS; user-visible there when `UIFileSharingEnabled` is
                       set (see `mix mob.enable`)
    - `:cache`       — persists until OS needs space; not user-visible, not
                       backed up
    - `:app_support` — persists, hidden from user; backed up to iCloud on iOS
                       unless excluded (see `exclude_from_backup/1`)

  On Android a generated app sets `android:allowBackup="false"`, so none of
  these go to a cloud backup. On Android 12 and higher that flag doesn't stop
  a device-to-device transfer; only `android:dataExtractionRules` does.

  ## Backup

  Apple rejects apps that back up data they can download again. Keep such data
  (downloaded models, content packs, media caches you don't want purged) in
  `:app_support` and mark its directory with `exclude_from_backup/1`.

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
  Exclude a file or directory from iCloud and device backups.

  On iOS this sets `NSURLIsExcludedFromBackupKey` on `path`. On a directory
  the flag covers everything beneath it, including files created later, so
  marking the top directory of your downloaded data is enough. Call it at
  every launch, not once: restoring the app or moving it to a new device can
  drop the attribute, and setting it again is cheap.

  On Android this does nothing; Android has no per-file flag. Generated apps
  set `android:allowBackup="false"`, which keeps app data out of cloud
  backups (and, up to Android 11, device-to-device transfers). To keep a
  path out of either when backup is on, or out of an Android 12+
  device-to-device transfer, exclude it in the app's backup rules
  (`android:fullBackupContent` for Android 11 and lower,
  `android:dataExtractionRules` for 12 and higher). Off device (host, tests)
  it also does nothing.

  Returns `{:error, :enoent}` on every platform when `path` doesn't exist,
  and on iOS `{:error, description}` with the system's message when the
  attribute can't be set. On an iOS app whose native build predates this
  function (mob 0.9.20 or older, not rebuilt with `mix mob.deploy --native`)
  it returns `{:error, :unsupported}`: the path stays backed up, and saying
  `:ok` would hide that.
  """
  @spec exclude_from_backup(String.t(), module()) ::
          :ok | {:error, :enoent | :unsupported | String.t()}
  def exclude_from_backup(path, nif \\ :mob_nif) when is_binary(path) do
    if File.exists?(path),
      do: nif_or(nif, :storage_exclude_from_backup, path, :ok, {:error, :unsupported}),
      else: {:error, :enoent}
  end

  @doc """
  Whether `path` is excluded from backup, read back from the filesystem.

  `true` only on iOS, for a path whose `NSURLIsExcludedFromBackupKey` is set.
  A path inside an excluded directory reports `false` (the flag is on the
  directory, not copied to its contents), yet it is not backed up. Android and
  the host always answer `false`, and so does an iOS native build that
  predates this function; see `exclude_from_backup/1`.
  """
  @spec excluded_from_backup?(String.t(), module()) :: boolean()
  def excluded_from_backup?(path, nif \\ :mob_nif) when is_binary(path) do
    nif_or(nif, :storage_excluded_from_backup, path, false, false)
  end

  # The NIF is missing in two ways: the module or its export is absent
  # (UndefinedFunctionError: off device, or an older stub module), or the
  # Erlang stub is current but the native build predates the function, so the
  # stub raises :not_loaded. Off device and on Android there is no backup
  # to exclude from (`no_backup`); on iOS the path is still backed up, so the
  # caller gets `old_ios`, not a false success.
  defp nif_or(nif, fun, path, no_backup, old_ios) do
    apply(nif, fun, [path])
  rescue
    e in UndefinedFunctionError ->
      if e.module == nif and e.function == fun,
        do: missing_nif(nif, no_backup, old_ios),
        else: reraise(e, __STACKTRACE__)

    e in ErlangError ->
      if Map.get(e, :original) == :not_loaded,
        do: missing_nif(nif, no_backup, old_ios),
        else: reraise(e, __STACKTRACE__)
  end

  defp missing_nif(nif, no_backup, old_ios) do
    if platform(nif) == :ios, do: old_ios, else: no_backup
  end

  # :mob_nif.platform/0 is as old as mob's native layer; off device it's absent.
  defp platform(nif) do
    nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
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
