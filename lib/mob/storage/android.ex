defmodule Mob.Storage.Android do
  @moduledoc """
  Android-specific storage locations and MediaStore integration.

  ## External files directory

  `external_files_dir/1` returns the app's scoped directory on external
  storage (`getExternalFilesDir`). This is visible to the user via a file
  manager or USB, but scoped to the app — no `WRITE_EXTERNAL_STORAGE`
  permission required. Returns `nil` if external storage is unavailable.

  Common type atoms: `:documents`, `:pictures`, `:movies`, `:music`,
  `:downloads`, `:dcim`. Maps to `Environment.DIRECTORY_*` constants.

  ## MediaStore

  `save_to_media_store/3` inserts a file into the Android media library
  so it appears in the Gallery, Music, or Files app. It is asynchronous —
  the result arrives via `handle_info`:

      handle_info({:storage, :saved_to_library, path}, socket)
      handle_info({:storage, :error, :save_to_library, reason}, socket)

  `type` is `:image`, `:video`, or `:audio`. On API 29+ no permission is
  needed for files the app created. On API 28 and below,
  `WRITE_EXTERNAL_STORAGE` is required — add it via:

      mix mob.enable media_store
  """

  @doc """
  Return the app's scoped external storage directory for `type`.

  Returns `nil` if external storage is not available on this device.
  """
  @spec external_files_dir(atom()) :: String.t() | nil
  def external_files_dir(type \\ :documents) do
    case :mob_nif.storage_external_files_dir(type) do
      nil -> nil
      path -> IO.iodata_to_binary(path)
    end
  end

  @doc """
  Save a file to the MediaStore so it appears in the system Gallery,
  Music, or Files app.

  `type` is `:image`, `:video`, or `:audio`. Defaults to `:auto`, which
  infers the type from the file extension.
  """
  @spec save_to_media_store(Mob.Socket.t(), String.t(), atom()) :: Mob.Socket.t()
  def save_to_media_store(socket, path, type \\ :auto) do
    :mob_nif.storage_save_to_media_store(path, type)
    socket
  end
end
