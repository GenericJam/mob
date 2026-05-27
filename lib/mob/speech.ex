defmodule Mob.Speech do
  @moduledoc """
  Text-to-speech. No permission required on either platform.

  ## Usage

      def handle_event("read_aloud", _params, socket) do
        Mob.Speech.speak(socket, socket.assigns.article_text)
        {:noreply, socket}
      end

  Stop mid-utterance:

      Mob.Speech.stop_speaking(socket)

  ## Options

  | Option   | Type    | Meaning                                  | Default |
  |----------|---------|------------------------------------------|---------|
  | `:rate`  | float   | Speech rate (0.0–1.0, platform-scaled)   | system  |
  | `:pitch` | float   | Pitch multiplier (0.5–2.0)               | 1.0     |
  | `:voice` | binary  | BCP-47 language/voice id (e.g. `"en-US"`)| system  |

  Calling `speak/3` while speech is in progress enqueues the new utterance.
  iOS uses `AVSpeechSynthesizer`; Android uses `TextToSpeech`.
  """

  @opt_keys [:rate, :pitch, :voice]

  @doc """
  Speak `text` aloud. Fire-and-forget; returns the socket unchanged so it can be
  used inline without disrupting a `handle_event`/`handle_info` return value.

      Mob.Speech.speak(socket, "Returns a list.", rate: 0.5)
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
