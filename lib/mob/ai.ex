defmodule Mob.AI do
  @moduledoc """
  Native AI capabilities exposed by the platform.

  These calls are asynchronous. The native side sends results back to the
  calling process as `{:ai, event, payload}` messages.

  ## Text generation

      Mob.AI.generate_text(socket, "Summarize this note")
      # -> handle_info({:ai, :generated_text, %{text: text}}, socket)
      # -> handle_info({:ai, :error, %{operation: :generate_text, reason: reason}}, socket)

  On iOS this uses Apple's Foundation Models framework when available. The iOS
  simulator does not provide the on-device system language model.

  ## Vision OCR

      Mob.AI.recognize_text(socket, "/path/to/image.png")
      # -> handle_info({:ai, :recognized_text, %{text: text}}, socket)

  ## Speech transcription

      Mob.AI.transcribe_audio(socket, "/path/to/audio.m4a")
      # -> handle_info({:ai, :transcribed_audio, %{text: text}}, socket)

  Speech transcription requires speech recognition permission on iOS.
  """

  @type generate_option ::
          {:instructions, String.t()}
          | {:temperature, number()}
          | {:maximum_response_tokens, pos_integer()}

  @type ocr_option ::
          {:recognition_level, :fast | :accurate}
          | {:uses_language_correction, boolean()}

  @type speech_option ::
          {:locale, String.t()}
          | {:requires_on_device_recognition, boolean()}

  @doc """
  Generate text using the platform language model.

  Result arrives as:

    * `{:ai, :generated_text, %{text: text}}`
    * `{:ai, :error, %{operation: :generate_text, reason: reason}}`
  """
  @spec generate_text(Mob.Socket.t(), String.t(), [generate_option()]) :: Mob.Socket.t()
  def generate_text(socket, prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    invoke(
      :mob_nif.ai_generate_text(prompt, :json.encode(generate_text_opts(opts))),
      :generate_text
    )

    socket
  end

  @doc false
  @spec generate_text_opts(keyword()) :: %{String.t() => term()}
  def generate_text_opts(opts) do
    %{
      "instructions" => Keyword.get(opts, :instructions, ""),
      "temperature" => Keyword.get(opts, :temperature, 0.2) / 1,
      "maximum_response_tokens" => Keyword.get(opts, :maximum_response_tokens, 256)
    }
  end

  @doc """
  Recognize text in an image file using platform OCR.

  Result arrives as:

    * `{:ai, :recognized_text, %{text: text}}`
    * `{:ai, :error, %{operation: :recognize_text, reason: reason}}`
  """
  @spec recognize_text(Mob.Socket.t(), String.t(), [ocr_option()]) :: Mob.Socket.t()
  def recognize_text(socket, path, opts \\ []) when is_binary(path) and is_list(opts) do
    invoke(
      :mob_nif.ai_recognize_text(path, :json.encode(recognize_text_opts(opts))),
      :recognize_text
    )

    socket
  end

  @doc false
  @spec recognize_text_opts(keyword()) :: %{String.t() => term()}
  def recognize_text_opts(opts) do
    %{
      "recognition_level" => Keyword.get(opts, :recognition_level, :accurate) |> Atom.to_string(),
      "uses_language_correction" => Keyword.get(opts, :uses_language_correction, true)
    }
  end

  @doc """
  Transcribe an audio file using platform speech recognition.

  Result arrives as:

    * `{:ai, :transcribed_audio, %{text: text}}`
    * `{:ai, :error, %{operation: :transcribe_audio, reason: reason}}`
  """
  @spec transcribe_audio(Mob.Socket.t(), String.t(), [speech_option()]) :: Mob.Socket.t()
  def transcribe_audio(socket, path, opts \\ []) when is_binary(path) and is_list(opts) do
    invoke(
      :mob_nif.ai_transcribe_audio(path, :json.encode(transcribe_audio_opts(opts))),
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
      {:ai, :error,
       %{operation: operation, reason: "Native AI is not supported on this platform."}}
    )

    :ok
  end
end
