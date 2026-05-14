defmodule Mob.Photos do
  @moduledoc """
  Photo / video library picker.

  On iOS 14+ no permission is required for the picker (it runs out of
  process). `Mob.Storage.save_to_photo_library/2` does require
  `NSPhotoLibraryAddUsageDescription` in `Info.plist`. On Android,
  `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` (API 33+) or
  `READ_EXTERNAL_STORAGE` (API ≤ 32) need to be declared in
  `AndroidManifest.xml` — `mix mob.new` ships all three. See the
  [permissions guide](permissions.html) for the cross-platform table.

  Results arrive as:

      handle_info({:photos, :picked,    items},   socket)
      handle_info({:photos, :cancelled},           socket)

  Each item in `items` is:

      %{path: "/tmp/mob_pick_xxx.jpg", type: :image | :video,
        width: 1920, height: 1080}

  iOS: `PHPickerViewController`. Android: `PickMultipleVisualMedia`.
  """

  @spec pick(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def pick(socket, opts \\ []) do
    max = Keyword.get(opts, :max, 1)
    types = Keyword.get(opts, :types, [:image]) |> Enum.map(&Atom.to_string/1)
    :mob_nif.photos_pick(max, types)
    socket
  end
end
