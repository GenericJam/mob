defmodule Mob.IOS.Vision do
  @moduledoc """
  iOS Vision framework capabilities.

  Text recognition wraps Apple's `VNRecognizeTextRequest`.
  See Apple's API documentation:
  https://developer.apple.com/documentation/vision/vnrecognizetextrequest

  Calls are asynchronous. Results are delivered to the calling process:

      Mob.IOS.Vision.recognize_text(socket, "/path/to/image.png")

      def handle_info({:vision, :recognized_text, %{text: text}}, socket) do
        {:noreply, Mob.Socket.assign(socket, :ocr_text, text)}
      end
  """

  @type recognize_text_option ::
          {:recognition_level, :fast | :accurate}
          | {:uses_language_correction, boolean()}

  @doc """
  Recognize text in an image file using Apple's Vision framework.
  """
  @spec recognize_text(Mob.Socket.t(), String.t(), [recognize_text_option()]) :: Mob.Socket.t()
  def recognize_text(socket, path, opts \\ []) when is_binary(path) and is_list(opts) do
    invoke(
      :mob_nif.vision_recognize_text(path, :json.encode(recognize_text_opts(opts))),
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

  defp invoke(:ok, _operation), do: :ok

  defp invoke(:unsupported, operation) do
    send(
      self(),
      {:vision, :error,
       %{
         operation: operation,
         reason: "Vision text recognition is not supported on this platform."
       }}
    )

    :ok
  end
end
