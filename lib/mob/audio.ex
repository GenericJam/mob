defmodule Mob.Audio do
  @moduledoc """
  Microphone recording and audio playback.

  Recording requires `:microphone` permission (`Mob.Permissions.request/2`).
  iOS additionally needs `NSMicrophoneUsageDescription` in
  `Info.plist`; Android needs `RECORD_AUDIO` in
  `AndroidManifest.xml`. The default `mix mob.new` templates ship
  both. See the [permissions guide](permissions.html) for the
  cross-platform table.

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

  @doc """
  Schedule `path` to begin playing at absolute local wall-clock time
  `at_wall_ms` (in `System.system_time(:millisecond)` terms — caller is
  responsible for translating from a server-supplied target time via their
  own clock-sync component).

  The audio hardware clock — not BEAM's timer wheel — fires playback at
  the requested instant. Multiple `play_at/3` calls accumulate on the
  player's timeline (call `stop_playback/1` to flush). If `at_wall_ms` is
  already in the past, the buffer plays as soon as the audio engine can.

  Options:
    - `volume: float 0.0–1.0` (default `1.0`)

  Result arrives as `{:audio, :playback_finished, %{path: path}}` when
  the scheduled buffer drains, or `{:audio, :playback_error,
  %{reason: reason}}` if the file fails to open.

  iOS: `AVAudioEngine` + `AVAudioPlayerNode.scheduleBuffer(_:at:options:)`,
  with the `at:` `AVAudioTime` constructed from `mach_absolute_time` so the
  buffer starts at the requested host time.

  Android: TODO — falls back to immediate playback on Android until the
  AAudio port lands.
  """
  @spec play_at(Mob.Socket.t(), String.t(), integer(), keyword()) :: Mob.Socket.t()
  def play_at(socket, path, at_wall_ms, opts \\ []) when is_integer(at_wall_ms) do
    # at_wall_ms is shipped as a binary string. ms-since-epoch values exceed
    # the 32-bit range that mob's Android ERTS build can read via
    # `enif_get_int`, and the `enif_get_int64` symbol isn't dynamically
    # exported on that build. Strings cross both NIF boundaries cleanly.
    :mob_nif.audio_play_at(
      path,
      :json.encode(play_at_opts(opts)),
      Integer.to_string(at_wall_ms)
    )

    socket
  end

  @doc false
  @spec play_at_opts(keyword()) :: %{String.t() => term()}
  def play_at_opts(opts) do
    %{"volume" => Keyword.get(opts, :volume, 1.0) * 1.0}
  end
end
