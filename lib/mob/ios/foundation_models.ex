defmodule Mob.IOS.FoundationModels do
  @moduledoc """
  iOS Foundation Models text generation.

  This wraps Apple's Foundation Models framework, specifically
  `SystemLanguageModel`, `LanguageModelSession`, and `GenerationOptions`.
  See Apple's guide:
  https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models

  Calls are asynchronous. Results are delivered to the calling process:

      Mob.IOS.FoundationModels.generate_text(socket, "Summarize this note")

      def handle_info({:foundation_models, :generated_text, %{text: text}}, socket) do
        {:noreply, Mob.Socket.assign(socket, :summary, text)}
      end

      def handle_info({:foundation_models, :error, %{reason: reason}}, socket) do
        {:noreply, Mob.Socket.assign(socket, :error, reason)}
      end

  Foundation Models requires an eligible physical iOS device with Apple
  Intelligence enabled. The iOS simulator does not provide the on-device system
  language model.
  """

  @type generate_option ::
          {:instructions, String.t()}
          | {:temperature, number()}
          | {:maximum_response_tokens, pos_integer()}

  @doc """
  Generate text using Apple's on-device Foundation Models framework.
  """
  @spec generate_text(Mob.Socket.t(), String.t(), [generate_option()]) :: Mob.Socket.t()
  def generate_text(socket, prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    invoke(
      :mob_nif.foundation_models_generate_text(prompt, :json.encode(generate_text_opts(opts))),
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

  defp invoke(:ok, _operation), do: :ok

  defp invoke(:unsupported, operation) do
    send(
      self(),
      {:foundation_models, :error,
       %{operation: operation, reason: "Foundation Models is not supported on this platform."}}
    )

    :ok
  end
end
