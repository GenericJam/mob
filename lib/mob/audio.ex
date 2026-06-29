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

  ## Output probes — is sound actually working?

  Two read-only probes answer "is audio coming out right now," the audio
  analog of `Mob.Test`'s in-process `screenshot/2` for video. Use them in
  tests and agent-driven verification.

      Mob.Audio.output_status()
      # => %{volume: 0.8, muted: false, route: :speaker, other_audio: false}

      Mob.Audio.play(socket, "blip.wav")
      Mob.Audio.output_level(source: :mob)
      # => {-18.4, -6.1}   # {rms_db, peak_db}, or :silent

  `output_status/0` is a cheap, permission-free read of the system audio
  config (volume, mute, route). It catches the common "no sound" causes:
  muted, volume 0, routed to a disconnected sink. `output_level/1` reads
  actual signal energy so you can tell live audio from pushed silence — the
  part `output_status` (and `adb dumpsys audio`) cannot answer.

  `output_level/1` takes a `:source`:

    - `:mob` (default) — meters `Mob.Audio`'s own player. iOS reads the
      `AVAudioPlayer` meter (free, no permission); Android attaches a
      `Visualizer` to the player's own audio session (needs `RECORD_AUDIO`,
      granted at runtime — without it you get `{:error, :needs_record_audio}`).
      Returns `{:error, :not_playing}` when no `Mob.Audio` playback is active.
    - `:mix` — *would* tap the global output mix to observe audio that bypasses
      `Mob.Audio` (a game's own `AudioTrack`, another app). This is **not
      available to a normal app**: iOS forbids it (sandbox) and modern Android
      treats a session-0 `Visualizer` as privileged (`ERROR_NO_INIT` even with
      `RECORD_AUDIO`). So `:mix` returns `{:error, :unsupported_on_platform}`
      on both platforms. Global device-audio capture lives in a separate,
      MediaProjection-based capture plugin intended as a test-environment
      dependency, not here.

  So in-app these probes verify *your own* audio. To check audio from a
  foreign native player (e.g. a bundled game) without that plugin, read
  `adb shell dumpsys media.audio_flinger` (active track + underrun counts).

  Metering is instantaneous and only meaningful while audio is playing, so
  the idiom is `play → sleep a beat → output_level`.
  """

  @type format :: :aac | :wav
  @type quality :: :low | :medium | :high
  @type route :: :speaker | :headphones | :bluetooth | :receiver | :none | :unknown
  @type level_source :: :mix | :mob

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

  @doc """
  Read the current system audio output configuration.

  Returns `%{volume: float, muted: boolean, route: route(), other_audio:
  boolean}`. Cheap, synchronous, no permission. The first thing to check
  when verifying sound: a `volume` of `0.0`, `muted: true`, or a `route` of
  `:none` explains silence regardless of what a player is doing.

  `volume` is normalized 0.0–1.0 (the media stream volume on Android,
  `AVAudioSession.outputVolume` on iOS). `route` is the active output sink.
  `other_audio` is true when another app is already playing (iOS
  `isOtherAudioPlaying` / Android `isMusicActive`).
  """
  @spec output_status() :: %{
          volume: float(),
          muted: boolean(),
          route: route(),
          other_audio: boolean()
        }
  def output_status do
    decode_status(:mob_nif.audio_output_status())
  end

  @doc false
  @spec decode_status(term()) :: %{
          volume: float(),
          muted: boolean(),
          route: route(),
          other_audio: boolean()
        }
  def decode_status({volume, muted, route_code, other_audio}) do
    %{
      volume: volume,
      muted: muted >= 0.5,
      route: decode_route(route_code),
      other_audio: other_audio >= 0.5
    }
  end

  def decode_status(_), do: %{volume: 0.0, muted: false, route: :unknown, other_audio: false}

  @doc """
  Read the current output signal level as `{rms_db, peak_db}` (dBFS, e.g.
  `{-18.0, -6.0}`), or `:silent` when there is no measurable signal.

  This is the probe that distinguishes live audio from pushed silence — the
  one thing `output_status/0` and `adb dumpsys audio` cannot tell you.
  Metering is instantaneous and only valid while audio plays, so call it as
  `play → sleep a beat → output_level`.

  Options:
    - `source: :mob` (default) — meters `Mob.Audio`'s own player. Android needs
      `RECORD_AUDIO` (runtime-granted); iOS uses `AVAudioPlayer` metering.
    - `source: :mix` — the global output mix. Unsupported for a normal app on
      both platforms (see module docs); use the separate capture plugin.

  Returns `{:error, reason}` when unavailable: `:not_playing` (no active
  `Mob.Audio` player), `:needs_record_audio` (Android, permission not granted
  at runtime), or `:unsupported_on_platform` (`:mix`).
  """
  @spec output_level(keyword()) :: {float(), float()} | :silent | {:error, atom()}
  def output_level(opts \\ []) do
    source = Keyword.get(opts, :source, :mob)
    decode_level(:mob_nif.audio_output_level(Atom.to_string(source)))
  end

  @doc false
  @spec decode_level(term()) :: {float(), float()} | :silent | {:error, atom()}
  def decode_level({_rms, peak}) when peak <= -120.0, do: :silent
  def decode_level({rms, peak}), do: {rms, peak}
  def decode_level(reason) when is_atom(reason), do: {:error, reason}
  def decode_level(_), do: {:error, :unknown}

  # Native side returns a numeric route code (kept numeric to avoid building
  # atoms in C/Zig); decode here.
  @spec decode_route(number()) :: route()
  defp decode_route(1), do: :speaker
  defp decode_route(2), do: :headphones
  defp decode_route(3), do: :bluetooth
  defp decode_route(4), do: :receiver
  defp decode_route(0), do: :none
  defp decode_route(code) when is_float(code), do: decode_route(round(code))
  defp decode_route(_), do: :unknown
end
