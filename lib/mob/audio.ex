defmodule Mob.Audio do
  @moduledoc """
  Microphone recording and audio playback.

  Recording requires `:microphone` permission (`Mob.Permissions.request/2`).
  Playback requires no permission.

  ## Recording

      Mob.Audio.start_recording(socket, format: :aac, quality: :medium)
      Mob.Audio.stop_recording(socket)
      # → handle_info({:audio, :recorded, %{path: path, duration: seconds}}, socket)
      # → handle_info({:audio, :error,    reason},                            socket)

  ## Playback

      Mob.Audio.play(socket, "/path/to/file.m4a")
      Mob.Audio.play(socket, "/path/to/file.m4a", loop: true, volume: 0.8)
      Mob.Audio.stop_playback(socket)
      Mob.Audio.set_volume(socket, 0.5)
      # → handle_info({:audio, :playback_finished, %{path: path}}, socket)
      # → handle_info({:audio, :playback_error,    %{reason: reason}}, socket)

  iOS: `AVAudioPlayer` / `AVPlayer`. Android: `MediaPlayer`.
  """

  @type format :: :aac | :wav
  @type quality :: :low | :medium | :high

  @doc """
  Start recording audio from the microphone.

  Options:
    - `format: :aac | :wav` (default `:aac`)
    - `quality: :low | :medium | :high` (default `:medium`)
  """
  @spec start_recording(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start_recording(socket, opts \\ []) do
    :mob_nif.audio_start_recording(:json.encode(recording_opts(opts)))
    socket
  end

  @doc false
  @spec recording_opts(keyword()) :: %{String.t() => String.t()}
  def recording_opts(opts) do
    %{
      "format" => Keyword.get(opts, :format, :aac) |> Atom.to_string(),
      "quality" => Keyword.get(opts, :quality, :medium) |> Atom.to_string()
    }
  end

  @doc """
  Stop the in-progress recording and save it to a temp file.
  Result arrives as `{:audio, :recorded, %{path: ..., duration: ...}}`.
  """
  @spec stop_recording(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_recording(socket) do
    :mob_nif.audio_stop_recording()
    socket
  end

  @doc """
  Play an audio file. Stops any currently playing audio first.

  Options:
    - `loop: boolean` (default `false`)
    - `volume: float 0.0–1.0` (default `1.0`)

  Result arrives as:
    - `{:audio, :playback_finished, %{path: path}}`
    - `{:audio, :playback_error, %{reason: reason}}`
  """
  @spec play(Mob.Socket.t(), String.t(), keyword()) :: Mob.Socket.t()
  def play(socket, path, opts \\ []) do
    :mob_nif.audio_play(path, :json.encode(play_opts(opts)))
    socket
  end

  @doc false
  @spec play_opts(keyword()) :: %{String.t() => term()}
  def play_opts(opts) do
    %{
      "loop" => Keyword.get(opts, :loop, false),
      "volume" => Keyword.get(opts, :volume, 1.0) * 1.0
    }
  end

  @doc "Stop the currently playing audio."
  @spec stop_playback(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_playback(socket) do
    :mob_nif.audio_stop_playback()
    socket
  end

  @doc "Adjust playback volume (0.0–1.0) without stopping playback."
  @spec set_volume(Mob.Socket.t(), float()) :: Mob.Socket.t()
  def set_volume(socket, volume) when is_float(volume) or is_integer(volume) do
    :mob_nif.audio_set_volume(volume / 1.0)
    socket
  end
end
