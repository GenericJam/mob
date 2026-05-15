defmodule Mob.AITest do
  use ExUnit.Case, async: true

  alias Mob.AI

  describe "generate_text_opts/1" do
    test "defaults are string keyed" do
      assert AI.generate_text_opts([]) == %{
               "instructions" => "",
               "temperature" => 0.2,
               "maximum_response_tokens" => 256
             }
    end

    test "custom values are passed through" do
      assert AI.generate_text_opts(
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

  describe "recognize_text_opts/1" do
    test "defaults to accurate OCR with language correction" do
      assert AI.recognize_text_opts([]) == %{
               "recognition_level" => "accurate",
               "uses_language_correction" => true
             }
    end

    test "recognition level is encoded as a string" do
      assert AI.recognize_text_opts(recognition_level: :fast) == %{
               "recognition_level" => "fast",
               "uses_language_correction" => true
             }
    end
  end

  describe "transcribe_audio_opts/1" do
    test "defaults to platform locale and server-capable recognition" do
      assert AI.transcribe_audio_opts([]) == %{
               "locale" => "",
               "requires_on_device_recognition" => false
             }
    end

    test "custom locale and on-device setting are passed through" do
      assert AI.transcribe_audio_opts(locale: "en-US", requires_on_device_recognition: true) == %{
               "locale" => "en-US",
               "requires_on_device_recognition" => true
             }
    end
  end
end
