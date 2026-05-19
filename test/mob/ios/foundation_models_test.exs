defmodule Mob.IOS.FoundationModelsTest do
  use ExUnit.Case, async: true

  alias Mob.IOS.FoundationModels

  describe "generate_text_opts/1" do
    test "defaults are string keyed" do
      assert FoundationModels.generate_text_opts([]) == %{
               "instructions" => "",
               "temperature" => 0.2,
               "maximum_response_tokens" => 256
             }
    end

    test "custom values are passed through" do
      assert FoundationModels.generate_text_opts(
               instructions: "Be concise",
               temperature: 0.7,
               maximum_response_tokens: 64
             ) == %{
               "instructions" => "Be concise",
               "temperature" => 0.7,
               "maximum_response_tokens" => 64
             }
    end
  end
end
