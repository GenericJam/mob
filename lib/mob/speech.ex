defmodule Mob.Speech do
  @moduledoc """
  Text-to-speech. No permission required on either platform. For
  speech-to-text (listening), use the `mob_speech` plugin, with `mob_whisper`
  for offline recognition.

  ## Usage

      def handle_event("read_aloud", _params, socket) do
        Mob.Speech.speak(socket, socket.assigns.article_text)
        {:noreply, socket}
      end

  Stop mid-utterance:

      Mob.Speech.stop_speaking(socket)

  ## Options

  | Option   | Type    | Meaning                                              | Default |
  |----------|---------|------------------------------------------------------|---------|
  | `:rate`  | float   | Speech rate (platform-scaled, see below)             | system  |
  | `:pitch` | float   | Pitch multiplier (0.5–2.0)                           | system  |
  | `:voice` | binary  | A voice `id` from `voices/0`, or a BCP-47 language tag (`"en-US"`) | system  |

  Options apply to that utterance only: a `speak/3` without `:voice` uses the
  system default voice even if the previous call chose one, and one without
  `:rate` or `:pitch` uses the user's text-to-speech settings. `:rate` is
  platform-scaled: iOS takes 0.0–1.0 (0.5 is normal), Android centres on 1.0
  (about 0.5–2.0).

  ## Choosing a voice

  `voices/0` lists the voices installed on this device. Pass one's `id` as
  `:voice`:

      {:ok, voices} = Mob.Speech.voices()
      voice = Enum.find(voices, &String.starts_with?(&1.language, "en"))
      Mob.Speech.speak(socket, "Hello", voice: voice.id)

  `:voice` is matched against the device's voice ids first, exactly. When no
  voice has that id, the value is read as a BCP-47 language tag and the
  platform's preferred voice for that language speaks. When it is neither (an
  iOS id saved on another device, say), the system default voice speaks. Ids
  are per platform and per device: iOS ids look like
  `"com.apple.voice.compact.en-US.Samantha"`, Android ids like
  `"en-us-x-sfg-local"`. An Android id is itself a valid language tag, so a
  missing one falls back to a voice for its language (`en-US` there) rather
  than the default. Store the id a user picked, and expect it to be gone on
  another device.

  ## End-of-speech events

  The process that called `speak/3` (normally the screen) receives one message
  when that utterance ends:

  | Message               | When                                                       |
  |-----------------------|------------------------------------------------------------|
  | `{:speech, :done}`      | The utterance was spoken to the end.                      |
  | `{:speech, :cancelled}` | `stop_speaking/1` interrupted it.                         |
  | `{:speech, :failed}`    | The engine couldn't speak it (Android only).              |

  Each queued utterance sends exactly one message, so after three `speak/3`
  calls the third `{:speech, :done}` means reading has finished, and
  `stop_speaking/1` sends `:cancelled` for every utterance that hadn't ended
  (the one speaking and the ones queued behind it). An Android engine that
  doesn't start within 10 s fails what was waiting for it with `:failed`. The
  one exception: when Android's TTS engine process dies mid-utterance, that
  utterance sends nothing.

      def handle_info({:speech, :done}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :reading, false)}

  Android needs a `MobBridge.kt` from mob_new 0.6.14 or newer for voice ids,
  `voices/0` and these events. With an older bridge, `voices/0` returns
  `{:error, :unsupported}` and `speak/3` still speaks, reading `:voice` as a
  language tag only and sending no events.

  Calling `speak/3` while speech is in progress enqueues the new utterance.
  iOS uses `AVSpeechSynthesizer`; Android uses `TextToSpeech`.
  """

  @opt_keys [:rate, :pitch, :voice]

  @typedoc """
  Synthesis quality, normalised across platforms. Android reports all five
  (`Voice.QUALITY_*`); iOS maps `default` to `:normal`, `enhanced` to `:high`
  and `premium` to `:very_high`.
  """
  @type quality :: :very_low | :low | :normal | :high | :very_high

  @typedoc """
  A system voice. `id` is what `speak/3` takes as `:voice`. `name` is a label
  for a picker: iOS's voice name (`"Samantha"`); Android has no voice names, so
  it's the language's display name plus the voice's short code
  (`"English (United States) sfg"`). `network` is true when the voice
  synthesises on a server and needs a connection (Android; always false on
  iOS).
  """
  @type voice :: %{
          id: String.t(),
          name: String.t(),
          language: String.t(),
          quality: quality(),
          network: boolean()
        }

  @doc """
  Speak `text` aloud. Fire-and-forget; returns the socket unchanged so it can be
  used inline without disrupting a `handle_event`/`handle_info` return value.
  The calling process gets an end-of-speech message (see the moduledoc).

      Mob.Speech.speak(socket, "Returns a list.", rate: 0.5)
      Mob.Speech.speak(socket, "Bonjour", voice: "fr-FR")
      Mob.Speech.speak(socket, "Hello", voice: "com.apple.voice.compact.en-US.Samantha")
  """
  @spec speak(Mob.Socket.t(), binary(), keyword()) :: Mob.Socket.t()
  def speak(socket, text, opts \\ []) when is_binary(text) and is_list(opts) do
    :mob_nif.tts_speak(text, :json.encode(speak_opts(opts)))
    socket
  end

  @doc "Stop any in-progress speech immediately. Returns the socket."
  @spec stop_speaking(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_speaking(socket) do
    :mob_nif.tts_stop()
    socket
  end

  @doc """
  The text-to-speech voices installed on this device, sorted by language, then
  best quality first, then name, then on-device before network, then id.

      {:ok, [%{id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha",
               language: "en-US", quality: :normal, network: false} | _]}

  Blocks the caller until the platform answers. On Android that means waiting
  for the `TextToSpeech` engine to start the first time (usually well under a
  second, at most 5 s), so call it from `Mob.Socket.start_async/3` rather than
  `mount/3`. Android leaves out voices whose data isn't downloaded.

  Returns `{:error, :unavailable}` when the engine didn't start (no TTS engine
  installed, or it timed out) and `{:error, :unsupported}` off device, on a
  native build that predates this function, or on Android with a
  `MobBridge.kt` older than mob_new 0.6.14.
  """
  @spec voices(module()) :: {:ok, [voice()]} | {:error, :unavailable | :unsupported}
  def voices(nif \\ :mob_nif) do
    case call_voices(nif) do
      json when is_binary(json) -> {:ok, decode_voices(json)}
      :unsupported -> {:error, :unsupported}
      _ -> {:error, :unavailable}
    end
  end

  # The NIF is absent off device or on an older stub module
  # (UndefinedFunctionError), and raises :not_loaded when the stub is current
  # but the native build predates it. Either way this build can't list voices.
  defp call_voices(nif) do
    nif.tts_voices()
  rescue
    e in UndefinedFunctionError ->
      if e.module == nif and e.function == :tts_voices,
        do: :unsupported,
        else: reraise(e, __STACKTRACE__)

    e in ErlangError ->
      if Map.get(e, :original) == :not_loaded,
        do: :unsupported,
        else: reraise(e, __STACKTRACE__)
  end

  @doc false
  # Native code returns a JSON array of {"id","name","language","quality",
  # "network"} with the platform's raw quality number: Android's
  # Voice.QUALITY_* (100–500) or iOS's AVSpeechSynthesisVoiceQuality (1–3).
  # The ranges don't overlap, so one table maps both.
  @spec decode_voices(binary()) :: [voice()]
  def decode_voices(json) do
    json
    |> :json.decode()
    |> Enum.map(fn v ->
      %{
        id: v["id"],
        name: v["name"],
        language: v["language"],
        quality: quality(v["quality"]),
        network: v["network"] == true
      }
    end)
    |> Enum.sort_by(&{&1.language, -quality_rank(&1.quality), &1.name, &1.network, &1.id})
  end

  defp quality(100), do: :very_low
  defp quality(200), do: :low
  defp quality(400), do: :high
  defp quality(500), do: :very_high
  defp quality(2), do: :high
  defp quality(3), do: :very_high
  defp quality(_), do: :normal

  defp quality_rank(:very_low), do: 0
  defp quality_rank(:low), do: 1
  defp quality_rank(:normal), do: 2
  defp quality_rank(:high), do: 3
  defp quality_rank(:very_high), do: 4

  @doc false
  # Whitelist + stringify known options into a JSON-encodable map. Unknown keys
  # are dropped so a typo can't reach the native layer as a surprise option.
  # Public-but-undocumented so the encoding can be unit-tested without the NIF.
  @spec speak_opts(keyword()) :: %{optional(String.t()) => term()}
  def speak_opts(opts) do
    opts
    |> Keyword.take(@opt_keys)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end
end
