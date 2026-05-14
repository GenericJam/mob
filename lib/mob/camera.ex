defmodule Mob.Camera do
  @moduledoc """
  Native camera capture for photos and videos.

  Requires `:camera` permission (and `:microphone` for video). iOS
  additionally needs `NSCameraUsageDescription` (and
  `NSMicrophoneUsageDescription` for video) in `Info.plist`;
  Android needs `CAMERA` (and `RECORD_AUDIO` for video) in
  `AndroidManifest.xml`. The default `mix mob.new` templates ship
  both. See the [permissions guide](permissions.html) for the
  cross-platform table.

  Opens the native OS camera UI. Results arrive as:

      handle_info({:camera, :photo, %{path: path, width: w, height: h}}, socket)
      handle_info({:camera, :video, %{path: path, duration: seconds}},   socket)
      handle_info({:camera, :cancelled},                                   socket)

  The `path` is a local temp file. Copy it elsewhere before the next capture.

  iOS: `UIImagePickerController`. Android: `TakePicture` / `CaptureVideo` activity contracts.
  """

  @doc """
  Open the camera to capture a photo.

  Options:
    - `quality: :high | :medium | :low` (default `:high`) — JPEG compression level
  """
  @spec capture_photo(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def capture_photo(socket, opts \\ []) do
    quality = Keyword.get(opts, :quality, :high)
    :mob_nif.camera_capture_photo(quality)
    socket
  end

  @doc """
  Open the camera to record a video.

  Options:
    - `max_duration: integer` — maximum clip length in seconds (default `60`)
  """
  @spec capture_video(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def capture_video(socket, opts \\ []) do
    max_duration = Keyword.get(opts, :max_duration, 60)
    :mob_nif.camera_capture_video(max_duration)
    socket
  end

  @doc """
  Start a live camera preview session. Pair with a `:camera_preview` component
  in your render tree to display the feed.

  Options:
    - `facing: :back | :front` (default `:back`)
  """
  @spec start_preview(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start_preview(socket, opts \\ []) do
    facing = Keyword.get(opts, :facing, :back) |> Atom.to_string()
    :mob_nif.camera_start_preview(:json.encode(%{"facing" => facing}))
    socket
  end

  @doc "Stop the active camera preview session."
  @spec stop_preview(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_preview(socket) do
    :mob_nif.camera_stop_preview()
    socket
  end
end
