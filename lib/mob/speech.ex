defmodule Mob.Speech do
  @moduledoc """
  iOS Speech framework transcription.

  File transcription wraps Apple's `SFSpeechRecognizer` and
  `SFSpeechURLRecognitionRequest`.
  See Apple's API documentation:
  https://developer.apple.com/documentation/speech/sfspeechrecognizer
  https://developer.apple.com/documentation/speech/sfspeechurlrecognitionrequest

  Calls are asynchronous. Results are delivered to the calling process:

      Mob.Speech.transcribe_audio(socket, "/path/to/audio.m4a")

      def handle_info({:speech, :transcribed_audio, %{text: text}}, socket) do
        {:noreply, Mob.Socket.assign(socket, :transcript, text)}
      end

  On iOS, speech transcription requires speech recognition authorization. Audio
  recording still uses `Mob.Audio`; this module only transcribes an existing
  audio file.
  """

  @type transcribe_audio_option ::
          {:locale, String.t()}
          | {:requires_on_device_recognition, boolean()}

  @doc """
  Transcribe an audio file using Apple's Speech framework.
  """
  @spec transcribe_audio(Mob.Socket.t(), String.t(), [transcribe_audio_option()]) ::
          Mob.Socket.t()
  def transcribe_audio(socket, path, opts \\ []) when is_binary(path) and is_list(opts) do
    invoke(
      :mob_nif.speech_transcribe_audio(path, :json.encode(transcribe_audio_opts(opts))),
      :transcribe_audio
    )

    socket
  end

  @doc false
  @spec transcribe_audio_opts(keyword()) :: %{String.t() => term()}
  def transcribe_audio_opts(opts) do
    %{
      "locale" => Keyword.get(opts, :locale, ""),
      "requires_on_device_recognition" =>
        Keyword.get(opts, :requires_on_device_recognition, false)
    }
  end

  defp invoke(:ok, _operation), do: :ok

  defp invoke(:unsupported, operation) do
    send(
      self(),
      {:speech, :error,
       %{operation: operation, reason: "Speech transcription is not supported on this platform."}}
    )

    :ok
  end
end
